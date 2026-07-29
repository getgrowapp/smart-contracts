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

    function test_executeGrowYieldWithEphemeralAllowance_reallocateWithoutStandingAllowance() public {
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
        assertEq(policyModule.userOpValidationFunction(0, userOp, userOpHash), SIG_VALIDATION_PASSED);
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
        assertEq(policyModule.userOpValidationFunction(0, userOp, userOpHash), SIG_VALIDATION_PASSED);
    }

    function test_userOpValidation_rejectsEphemeralPluginCallWithBadOps() public {
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 100e6));
        bytes memory callData = abi.encodeCall(
            GrowYieldPlugin.executeGrowYieldWithEphemeralAllowance,
            (makeAddr("wrongExecutor"), ops)
        );
        bytes32 userOpHash = keccak256("ephemeral-plugin-bad-executor");
        UserOperation memory userOp = _mscaUserOp(callData, userOpHash);

        vm.prank(account);
        assertEq(policyModule.userOpValidationFunction(0, userOp, userOpHash), uint256(1));
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
