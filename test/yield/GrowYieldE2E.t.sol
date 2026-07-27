// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IEntryPoint} from "@eth-infinitism/account-abstraction/interfaces/IEntryPoint.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {
    Call,
    IModularAccount
} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {
    ValidationConfigLib
} from "@erc6900/reference-implementation/libraries/ValidationConfigLib.sol";
import {EntryPointUtils} from "../../lib/reference-implementation/test/utils/EntryPointUtils.sol";
import {ModularAccount} from "@alchemy/modular-account/account/ModularAccount.sol";
import {
    ExecutionInstallDelegate
} from "@alchemy/modular-account/helpers/ExecutionInstallDelegate.sol";

import {GrowYieldTestBase} from "./GrowYieldTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {
    AlchemySingleSignerValidationModuleHarness
} from "./mocks/AlchemySingleSignerValidationModuleHarness.sol";
import {MockSponsorPaymaster} from "./mocks/MockSponsorPaymaster.sol";

/// @notice Complete EntryPoint v0.7 lifecycle against Alchemy Modular Account v2.0.1.
contract GrowYieldE2ETest is GrowYieldTestBase, EntryPointUtils {
    using MessageHashUtils for bytes32;

    uint32 internal constant OWNER_ENTITY_ID = 0;
    uint8 internal constant FINAL_SEGMENT_INDEX = 0xFF;

    IEntryPoint internal entryPoint;
    AlchemySingleSignerValidationModuleHarness internal ownerValidationModule;
    MockSponsorPaymaster internal paymaster;
    ModularAccount internal modularAccount;

    address internal owner;
    uint256 internal ownerKey;
    address internal bundler;
    address payable internal beneficiary;

    function setUp() public {
        entryPoint = _deployEntryPoint();
        (owner, ownerKey) = makeAddrAndKey("owner");
        bundler = makeAddr("bundler");
        beneficiary = payable(makeAddr("beneficiary"));

        ownerValidationModule = new AlchemySingleSignerValidationModuleHarness();
        ExecutionInstallDelegate executionInstallDelegate = new ExecutionInstallDelegate();
        modularAccount = ModularAccount(
            payable(address(
                    new ERC1967Proxy(
                        address(new ModularAccount(entryPoint, executionInstallDelegate)),
                        abi.encodeCall(
                            ModularAccount.initializeWithValidation,
                            (
                                ValidationConfigLib.pack(
                                    address(ownerValidationModule),
                                    OWNER_ENTITY_ID,
                                    true,
                                    true,
                                    true
                                ),
                                new bytes4[](0),
                                abi.encode(OWNER_ENTITY_ID, owner),
                                new bytes[](0)
                            )
                        )
                    )
                ))
        );
        account = address(modularAccount);

        paymaster = new MockSponsorPaymaster(entryPoint);
        vm.deal(address(this), 100 ether);
        paymaster.deposit{value: 50 ether}();
        sponsorPaymaster = address(paymaster);
        _deployStack();
    }

    function test_e2e_installEnableDepositWithdrawReallocate() public {
        _installPolicy();

        underlying.mint(account, 1_000e6);
        _runPolicyUserOp(
            _policyCall(_ops1(_op(aaveVault, OperationKind.DEPOSIT, type(uint256).max))),
            automationPk
        );
        assertEq(aavePool.aToken().balanceOf(account), 1_000e6);
        _assertBatchHygiene();

        _runPolicyUserOp(
            _policyCall(_ops1(_op(aaveVault, OperationKind.REDEEM, 400e6))), automationPk
        );
        assertEq(underlying.balanceOf(account), 400e6);
        assertEq(aavePool.aToken().balanceOf(account), 600e6);

        _runPolicyUserOp(
            _policyCall(
                _ops2(
                    _op(aaveVault, OperationKind.REDEEM, type(uint256).max),
                    _op(morphoVault, OperationKind.DEPOSIT, type(uint256).max)
                )
            ),
            automationPk
        );
        assertEq(aavePool.aToken().balanceOf(account), 0);
        // PREVIOUS_OUTPUT reallocates only the 600 USDC produced by the redeem and
        // deliberately leaves the account's pre-existing 400 USDC untouched.
        assertEq(underlying.balanceOf(account), 400e6);
        assertEq(morphoWrapper.balanceOf(account), 600e6);
        _assertBatchHygiene();
    }

    function test_e2e_nonceKeysSelectOwnerAndGrowEntities() public view {
        PackedUserOperation memory ownerOp = _buildOwnerUserOp(hex"");
        PackedUserOperation memory growOp = _buildPolicyUserOp(hex"");

        assertEq(uint192(ownerOp.nonce >> 64), 1);
        assertEq(uint192(growOp.nonce >> 64), uint192(POLICY_ENTITY_ID) << 8);
        assertEq(uint192(growOp.nonce >> 64), 0x100);
    }

    function test_e2e_addAndRemovePolicyOwner() public {
        _installPolicy();
        (address secondPolicyOwner, uint256 secondKey) = makeAddrAndKey("secondPolicyOwner");

        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.execute,
                (
                    address(policyModule),
                    0,
                    abi.encodeCall(policyModule.addOwner, (secondPolicyOwner))
                )
            )
        );
        underlying.mint(account, 100e6);
        _runPolicyUserOp(_policyCall(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 50e6))), secondKey);

        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.execute,
                (address(policyModule), 0, abi.encodeCall(policyModule.removeOwner, (automation)))
            )
        );
        PackedUserOperation memory revoked =
            _buildPolicyUserOp(_policyCall(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 50e6))));
        revoked.signature = _policyModuleSignature(revoked, automationPk);
        _expectFailedOp("AA24 signature error");
        _handleOps(revoked);

        assertFalse(policyModule.isOwner(account, automation));
        assertTrue(policyModule.isOwner(account, secondPolicyOwner));
    }

    function test_e2e_tamperedCallDataFailsSignatureValidation() public {
        _installPolicy();
        PackedUserOperation memory userOp =
            _buildPolicyUserOp(_policyCall(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6))));
        bytes memory signature = _policyModuleSignature(userOp, automationPk);
        userOp.callData = _policyCall(_ops1(_op(aaveVaultOther, OperationKind.DEPOSIT, 1e6)));
        userOp.signature = signature;

        _expectFailedOp("AA24 signature error");
        _handleOps(userOp);
    }

    /// @dev The policy accepts one shape and nothing adjacent to it: not a batch that contains
    ///      the same executor call, and not a direct call to a token the account holds.
    function test_e2e_policyOwnerCannotBypassCallPolicy() public {
        _installPolicy();

        Call[] memory calls = new Call[](1);
        calls[1 - 1] = Call(
            address(executor), 0, _executeData(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6)))
        );
        PackedUserOperation memory batched =
            _buildPolicyUserOp(abi.encodeCall(IModularAccount.executeBatch, (calls)));
        batched.signature = _policyModuleSignature(batched, automationPk);
        vm.expectPartialRevert(IEntryPoint.FailedOpWithRevert.selector);
        _handleOps(batched);

        // A direct token transfer wrapped in the accepted selector is still not an executor call.
        PackedUserOperation memory drain = _buildPolicyUserOp(
            abi.encodeCall(
                IModularAccount.execute,
                (address(underlying), 0, abi.encodeCall(IERC20.transfer, (makeAddr("thief"), 1e6)))
            )
        );
        drain.signature = _policyModuleSignature(drain, automationPk);
        _expectFailedOp("AA24 signature error");
        _handleOps(drain);
    }

    /// @dev Requirement: only the account's own owner path may change which executor — and so
    ///      which registry, and so which venue set — the account uses. The policy accepts one
    ///      calldata shape and `setExecutor` is not in it, so a policy-owner signature fails
    ///      however the call is dressed up.
    function test_e2e_policyOwnerCannotRetargetAccountExecutor() public {
        _installPolicy();
        GrowYieldExecutor rogue = _deployExecutor(address(this));
        _admitAaveVaultOn(rogue);

        bytes memory retarget = abi.encodeCall(policyModule.setExecutor, (address(rogue)));

        // `executeBatch` never reaches the module: the Grow entity validates `execute` only, so
        // the account has no validation function for that selector at all.
        Call[] memory calls = new Call[](1);
        calls[0] = Call(address(policyModule), 0, retarget);
        PackedUserOperation memory batched =
            _buildPolicyUserOp(abi.encodeCall(IModularAccount.executeBatch, (calls)));
        batched.signature = _policyModuleSignature(batched, automationPk);
        vm.expectPartialRevert(IEntryPoint.FailedOpWithRevert.selector);
        _handleOps(batched);

        // Wrapped in the one selector the Grow entity does validate, the policy still rejects
        // it: the target is the module, not the account's executor.
        PackedUserOperation memory wrapped = _buildPolicyUserOp(
            abi.encodeCall(IModularAccount.execute, (address(policyModule), 0, retarget))
        );
        wrapped.signature = _policyModuleSignature(wrapped, automationPk);
        _expectFailedOp("AA24 signature error");
        _handleOps(wrapped);

        assertEq(policyModule.accountExecutor(account), address(executor), "unchanged");

        // The owner path performs the same change successfully.
        _setExecutorAsOwner(address(rogue));
        assertEq(policyModule.accountExecutor(account), address(rogue), "owner may switch");
    }

    function test_e2e_policyOperationsAreSponsorPaid() public {
        _installPolicy();
        underlying.mint(account, 1e6);
        uint256 accountNativeBefore = account.balance;
        uint256 sponsorDepositBefore = paymaster.getDeposit();

        _runPolicyUserOp(
            _policyCall(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6))), automationPk
        );

        assertEq(account.balance, accountNativeBefore);
        assertLt(paymaster.getDeposit(), sponsorDepositBefore);
    }

    function test_e2e_inflatedPreVerificationGasIsRejected() public {
        _installPolicy();
        PackedUserOperation memory userOp =
            _buildPolicyUserOp(_policyCall(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6))));
        userOp.preVerificationGas = MAX_PRE_VERIFICATION_GAS + 1;
        userOp.signature = _policyModuleSignature(userOp, automationPk);

        _expectFailedOp("AA24 signature error");
        _handleOps(userOp);
    }

    function test_e2e_replayFailsNonce() public {
        _installPolicy();
        underlying.mint(account, 2e6);
        PackedUserOperation memory userOp =
            _buildPolicyUserOp(_policyCall(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6))));
        userOp.signature = _policyModuleSignature(userOp, automationPk);
        _handleOps(userOp);

        _expectFailedOp("AA25 invalid account nonce");
        _handleOps(userOp);
    }

    /// @dev The account's entire opt-in: one owner-authorized call installing the Grow entity,
    ///      its policy owners, and the executor whose registry defines every usable venue.
    function _installPolicy() internal {
        // The Grow entity validates `execute` only: the policy's one accepted shape is a single
        // forwarded call to the executor, so `executeBatch` is deliberately not enrolled.
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IModularAccount.execute.selector;
        address[] memory initialOwners = new address[](1);
        initialOwners[0] = automation;

        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.installValidation,
                (
                    ValidationConfigLib.pack(
                        address(policyModule), POLICY_ENTITY_ID, false, false, true
                    ),
                    selectors,
                    abi.encode(
                        POLICY_ENTITY_ID, initialOwners, address(executor), address(paymaster)
                    ),
                    new bytes[](0)
                )
            )
        );
        _grantStandingAllowances();
    }

    /// @dev The owner grants the executor a standing allowance once. It is not exploitable:
    ///      `execute` only ever pulls from and pays to `msg.sender`, so reaching the allowance
    ///      still requires a signature authorizing the account itself to call.
    function _grantStandingAllowances() internal {
        address[3] memory tokens =
            [address(underlying), address(aavePool.aToken()), address(morphoWrapper)];
        for (uint256 i; i < tokens.length; ++i) {
            _runOwnerUserOp(
                abi.encodeCall(
                    IModularAccount.execute,
                    (tokens[i], 0, _approve(address(executor), type(uint256).max))
                )
            );
        }
    }

    function _setExecutorAsOwner(address executor_) internal {
        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.execute,
                (address(policyModule), 0, abi.encodeCall(policyModule.setExecutor, (executor_)))
            )
        );
    }

    function _buildPolicyUserOp(bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp = _baseUserOp(callData);
        userOp.nonce = entryPoint.getNonce(account, uint192(POLICY_ENTITY_ID) << 8);
    }

    function _buildOwnerUserOp(bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp = _baseUserOp(callData);
        userOp.nonce = entryPoint.getNonce(account, 1);
    }

    function _runOwnerUserOp(bytes memory callData) internal {
        PackedUserOperation memory userOp = _buildOwnerUserOp(callData);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, entryPoint.getUserOpHash(userOp).toEthSignedMessageHash());
        userOp.signature = abi.encodePacked(FINAL_SEGMENT_INDEX, bytes1(uint8(0)), r, s, v);
        _handleOps(userOp);
    }

    function _policyModuleSignature(PackedUserOperation memory userOp, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        bytes memory authorization = _signAuthorization(key, userOpHash);
        return abi.encodePacked(FINAL_SEGMENT_INDEX, authorization);
    }

    function _runPolicyUserOp(bytes memory callData, uint256 key) internal {
        PackedUserOperation memory userOp = _buildPolicyUserOp(callData);
        userOp.signature = _policyModuleSignature(userOp, key);
        _handleOps(userOp);
    }

    function _handleOps(PackedUserOperation memory userOp) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.prank(bundler);
        entryPoint.handleOps(ops, beneficiary);
    }

    function _expectFailedOp(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, reason));
    }

    /// @dev Allowances are standing by design; what must always be true is that no value is
    ///      parked on the executor or any adapter between operations.
    function _assertBatchHygiene() internal view {
        assertEq(underlying.balanceOf(address(executor)), 0);
        assertEq(underlying.balanceOf(address(aaveAdapter)), 0);
        assertEq(underlying.balanceOf(address(morphoAdapter)), 0);
        assertEq(aavePool.aToken().balanceOf(address(aaveAdapter)), 0);
    }
}
