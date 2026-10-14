// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPluginExecutor} from "@alchemy/msca/interfaces/IPluginExecutor.sol";
import {UserOperation} from "@alchemy/msca/interfaces/erc4337/UserOperation.sol";
import {SIG_VALIDATION_PASSED} from "@alchemy/msca/libraries/Constants.sol";

import {GrowYieldTestBase} from "./GrowYieldTestBase.sol";
import {GrowYieldPlugin} from "../../src/GrowYieldPlugin.sol";
import {MockValidationModule} from "./mocks/MockVaultV2Stack.sol";
import {IGrowYieldPolicyModule} from "../../src/interfaces/IGrowYieldPolicyModule.sol";
import {Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";

/// @dev MSCA account surface for plugin ephemeral-allowance tests.
contract MockPluginAccount {
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function executeFromPluginExternal(address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory result)
    {
        return this.execute(target, value, data);
    }
}

/// @dev Drains whatever allowance the caller granted it, standing in for an arbitrary address
///      passed as `executor`.
contract RogueExecutor {
    function execute(Operation[] calldata ops) external returns (uint256[] memory) {
        IERC20 token = IERC20(ops[0].sourceToken);
        token.transferFrom(msg.sender, address(this), token.balanceOf(msg.sender));
        return new uint256[](ops.length);
    }
}

contract GrowYieldPluginEphemeralTest is GrowYieldTestBase {
    MockPluginAccount internal pluginAccount;

    function setUp() public {
        pluginAccount = new MockPluginAccount();
        account = address(pluginAccount);
        sponsorPaymaster = address(new MockValidationModule());
        _deployStack();

        address[] memory initialOwners = new address[](1);
        initialOwners[0] = automation;
        vm.prank(account);
        policyModule.onInstall(
            abi.encode(POLICY_ENTITY_ID, initialOwners, address(executor), sponsorPaymaster)
        );
    }

    function test_executeGrowYieldWithEphemeralAllowance_depositWithoutStandingAllowance() public {
        underlying.mint(account, 250e6);

        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 250e6));
        vm.prank(account);
        policyModule.executeGrowYieldWithEphemeralAllowance(address(executor), ops);

        assertEq(underlying.allowance(account, address(executor)), 0);
        assertEq(aavePool.aToken().balanceOf(account), 250e6);
    }

    function test_executeGrowYieldWithEphemeralAllowance_reallocateWithoutStandingAllowance()
        public
    {
        underlying.mint(account, 500e6);

        Operation[] memory depositOps = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 500e6));
        vm.prank(account);
        policyModule.executeGrowYieldWithEphemeralAllowance(address(executor), depositOps);

        Operation[] memory reallocateOps = _ops2(
            _op(aaveVault, OperationKind.REDEEM, type(uint256).max),
            _op(morphoVault, OperationKind.DEPOSIT, type(uint256).max)
        );
        vm.prank(account);
        policyModule.executeGrowYieldWithEphemeralAllowance(address(executor), reallocateOps);

        assertEq(underlying.allowance(account, address(executor)), 0);
        assertEq(aavePool.aToken().allowance(account, address(executor)), 0);
        assertEq(morphoWrapper.balanceOf(account), 500e6);
    }

    function test_userOpValidation_acceptsEphemeralPluginCallData() public {
        underlying.mint(account, 100e6);
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 100e6));

        bytes memory callData = abi.encodeCall(
            GrowYieldPlugin.executeGrowYieldWithEphemeralAllowance, (address(executor), ops)
        );
        bytes32 userOpHash = keccak256("ephemeral-plugin-deposit");
        UserOperation memory userOp = _mscaUserOp(callData, userOpHash);

        vm.prank(account);
        assertEq(
            policyModule.userOpValidationFunction(0, userOp, userOpHash), SIG_VALIDATION_PASSED
        );
    }

    function test_userOpValidation_acceptsAlchemyGasManagerPaymasterData() public {
        underlying.mint(account, 100e6);
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 100e6));

        bytes memory callData = abi.encodeCall(
            GrowYieldPlugin.executeGrowYieldWithEphemeralAllowance, (address(executor), ops)
        );
        bytes32 userOpHash = keccak256("alchemy-paymaster-deposit");
        UserOperation memory userOp = _mscaUserOp(callData, userOpHash);
        // Alchemy Gas Manager: paymaster + validUntil (uint128) + padding + signature tail.
        // validUntil in the high bytes would exceed legacy paymaster gas caps if misparsed.
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(sponsorPaymaster, uint128(1_784_565_727), uint128(0)),
            hex"e7ee550d37927da76e6f497e4766b6f681f7dd67b4208752bbad4d216425d4257515d00e61335df2c59f7f159f110ea136496e29578055061795a487454aa3ed1c"
        );

        vm.prank(account);
        assertEq(
            policyModule.userOpValidationFunction(0, userOp, userOpHash), SIG_VALIDATION_PASSED
        );
    }

    function test_userOpValidation_rejectsEphemeralPluginCallWithBadOps() public {
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 100e6));
        bytes memory callData = abi.encodeCall(
            GrowYieldPlugin.executeGrowYieldWithEphemeralAllowance, (makeAddr("wrongExecutor"), ops)
        );
        bytes32 userOpHash = keccak256("ephemeral-plugin-bad-executor");
        UserOperation memory userOp = _mscaUserOp(callData, userOpHash);

        vm.prank(account);
        assertEq(policyModule.userOpValidationFunction(0, userOp, userOpHash), uint256(1));
    }

    /// @dev Validation is not the only route to an execution function: `executeFromPlugin` runs
    ///      pre-execution hooks only, so the manifest's `PRE_HOOK_ALWAYS_DENY` pre-runtime hooks
    ///      never cover it. Reaching either execution function with an unapproved executor must
    ///      revert on its own, because the ephemeral path would otherwise approve that address for
    ///      the account's full balance before calling it.
    function test_ephemeralExecution_rejectsUnapprovedExecutor() public {
        underlying.mint(account, 1_000e6);
        RogueExecutor rogue = new RogueExecutor();
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1_000e6));

        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.UnauthorizedExecutor.selector);
        policyModule.executeGrowYieldWithEphemeralAllowance(address(rogue), ops);

        assertEq(underlying.balanceOf(account), 1_000e6);
        assertEq(underlying.balanceOf(address(rogue)), 0);
        assertEq(underlying.allowance(account, address(rogue)), 0);
    }

    function test_execution_rejectsUnapprovedExecutor() public {
        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.UnauthorizedExecutor.selector);
        policyModule.executeGrowYield(makeAddr("wrongExecutor"), hex"deadbeef");
    }

    function test_supplyOnSpoke_rejectsCallWithoutExecutorHook() public {
        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.UnauthorizedExecutor.selector);
        policyModule.supplyOnSpoke(makeAddr("spoke"), 0, 1);
    }

    function test_supplyOnSpoke_rejectsUnadmittedSpokeAfterHook() public {
        vm.startPrank(account);
        _callUint8PreHook(address(executor));
        vm.expectRevert(GrowYieldPlugin.SpokeNotAdmitted.selector);
        policyModule.supplyOnSpoke(makeAddr("spoke"), 0, 1);
        vm.stopPrank();
    }

    function test_preExecutionHook_rejectsCallerOtherThanExecutor() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(account);
        (bool ok, bytes memory ret) = address(policyModule).call(
            abi.encodeWithSelector(
                bytes4(keccak256("preExecutionHook(uint8,address,uint256,bytes)")),
                policyModule.SPOKE_CALL_FUNCTION_ID(),
                stranger,
                uint256(0),
                bytes("")
            )
        );
        assertFalse(ok);
        assertEq(bytes4(ret), IGrowYieldPolicyModule.UnauthorizedExecutor.selector);
        vm.stopPrank();
    }

    function test_spokeCalls_rejectUninstalledAccount() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IGrowYieldPolicyModule.PolicyNotInstalled.selector);
        policyModule.supplyOnSpoke(makeAddr("spoke"), 0, 1);
    }

    function test_runtimeValidation_allowsOnlyTheExecutor() public {
        uint8 functionId = policyModule.SPOKE_CALL_FUNCTION_ID();

        vm.prank(account);
        policyModule.runtimeValidationFunction(functionId, address(executor), 0, "");

        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.UnauthorizedExecutor.selector);
        policyModule.runtimeValidationFunction(functionId, makeAddr("stranger"), 0, "");
    }

    function test_execution_rejectsUninstalledAccount() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IGrowYieldPolicyModule.PolicyNotInstalled.selector);
        policyModule.executeGrowYield(address(executor), hex"deadbeef");
    }

    function _callUint8PreHook(address sender) internal {
        (bool ok, bytes memory ret) = address(policyModule).call(
            abi.encodeWithSelector(
                bytes4(keccak256("preExecutionHook(uint8,address,uint256,bytes)")),
                policyModule.SPOKE_CALL_FUNCTION_ID(),
                sender,
                uint256(0),
                bytes("")
            )
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _mscaUserOp(bytes memory callData, bytes32 userOpHash)
        internal
        view
        returns (UserOperation memory userOp)
    {
        userOp.sender = account;
        userOp.nonce = 1;
        userOp.callData = callData;
        userOp.callGasLimit = MAX_CALL_GAS;
        userOp.verificationGasLimit = MAX_VERIFICATION_GAS;
        userOp.preVerificationGas = 100_000;
        userOp.maxFeePerGas = 1 gwei;
        userOp.maxPriorityFeePerGas = 1 gwei;
        userOp.paymasterAndData =
            abi.encodePacked(sponsorPaymaster, uint128(100_000), uint128(100_000));
        userOp.signature = _signAuthorization(automationPk, userOpHash);
    }
}
