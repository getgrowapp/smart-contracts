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
import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
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
        _installPolicyAndEnableAdapters();

        underlying.mint(account, 1_000e6);
        _runPolicyUserOp(
            _batch1(
                address(underlying), _ops1(_op(aaveVault, OperationKind.DEPOSIT, type(uint256).max))
            ),
            automationPk
        );
        assertEq(aavePool.aToken().balanceOf(account), 1_000e6);
        _assertBatchHygiene();

        _runPolicyUserOp(
            _batch1(address(aavePool.aToken()), _ops1(_op(aaveVault, OperationKind.REDEEM, 400e6))),
            automationPk
        );
        assertEq(underlying.balanceOf(account), 400e6);
        assertEq(aavePool.aToken().balanceOf(account), 600e6);

        address[] memory tokens = new address[](2);
        tokens[0] = address(aavePool.aToken());
        tokens[1] = address(underlying);
        _runPolicyUserOp(
            _batch(
                tokens,
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
        _installPolicyAndEnableAdapters();
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
        _runPolicyUserOp(
            _batch1(address(underlying), _ops1(_op(aaveVault, OperationKind.DEPOSIT, 50e6))),
            secondKey
        );

        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.execute,
                (address(policyModule), 0, abi.encodeCall(policyModule.removeOwner, (automation)))
            )
        );
        PackedUserOperation memory revoked = _buildPolicyUserOp(
            _batch1(address(underlying), _ops1(_op(aaveVault, OperationKind.DEPOSIT, 50e6)))
        );
        revoked.signature = _policyModuleSignature(revoked, automationPk);
        _expectFailedOp("AA24 signature error");
        _handleOps(revoked);

        assertFalse(policyModule.isOwner(account, automation));
        assertTrue(policyModule.isOwner(account, secondPolicyOwner));
    }

    function test_e2e_tamperedCallDataFailsSignatureValidation() public {
        _installPolicyAndEnableAdapters();
        PackedUserOperation memory userOp = _buildPolicyUserOp(
            _batch1(address(underlying), _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6)))
        );
        bytes memory signature = _policyModuleSignature(userOp, automationPk);
        userOp.callData = _batch1(
            address(otherUnderlying), _ops1(_op(aaveVaultOther, OperationKind.DEPOSIT, 1e6))
        );
        userOp.signature = signature;

        _expectFailedOp("AA24 signature error");
        _handleOps(userOp);
    }

    function test_e2e_policyOwnerCannotBypassBatchPolicy() public {
        _installPolicyAndEnableAdapters();
        Call[] memory calls = new Call[](2);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(
            address(executor), 0, _executeData(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6)))
        );
        PackedUserOperation memory userOp =
            _buildPolicyUserOp(abi.encodeCall(IModularAccount.executeBatch, (calls)));
        userOp.signature = _policyModuleSignature(userOp, automationPk);

        _expectFailedOp("AA24 signature error");
        _handleOps(userOp);
    }

    /// @dev Requirement: only the account's own owner path may change the registry. The policy
    ///      library accepts no batch shape containing `setAccountRegistry`, so a policy-owner
    ///      signature fails validation whether the call is sent bare or wrapped in a batch.
    function test_e2e_policyOwnerCannotRetargetAccountRegistry() public {
        _installPolicyAndEnableAdapters();
        GrowYieldAdapterRegistry rogue = _deployRegistry(address(this));
        IGrowYieldAdapterRegistry.VaultConfig[] memory rogueVaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        rogueVaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(aaveAdapter), aaveVaultOther, Protocol.AAVE, true, true
        );
        rogue.addVaults(rogueVaults);

        bytes memory retarget = abi.encodeCall(
            executor.setAccountRegistry, (IGrowYieldAdapterRegistry(address(rogue)))
        );

        // A bare `execute` never reaches the module: the Grow entity is installed for
        // `executeBatch` only, so the account has no validation function for that selector.
        PackedUserOperation memory bare = _buildPolicyUserOp(
            abi.encodeCall(IModularAccount.execute, (address(executor), 0, retarget))
        );
        bare.signature = _policyModuleSignature(bare, automationPk);
        vm.expectPartialRevert(IEntryPoint.FailedOpWithRevert.selector);
        _handleOps(bare);

        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(address(executor), 0, retarget);
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        PackedUserOperation memory batched =
            _buildPolicyUserOp(abi.encodeCall(IModularAccount.executeBatch, (calls)));
        batched.signature = _policyModuleSignature(batched, automationPk);
        _expectFailedOp("AA24 signature error");
        _handleOps(batched);

        assertEq(address(executor.accountRegistry(account)), address(registry), "unchanged");

        // The owner path performs the same change successfully.
        _setAccountRegistryAsOwner(address(rogue));
        assertEq(address(executor.accountRegistry(account)), address(rogue), "owner may switch");
    }

    function test_e2e_policyOperationsAreSponsorPaid() public {
        _installPolicyAndEnableAdapters();
        underlying.mint(account, 1e6);
        uint256 accountNativeBefore = account.balance;
        uint256 sponsorDepositBefore = paymaster.getDeposit();

        _runPolicyUserOp(
            _batch1(address(underlying), _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6))),
            automationPk
        );

        assertEq(account.balance, accountNativeBefore);
        assertLt(paymaster.getDeposit(), sponsorDepositBefore);
    }

    function test_e2e_inflatedPreVerificationGasIsRejected() public {
        _installPolicyAndEnableAdapters();
        PackedUserOperation memory userOp = _buildPolicyUserOp(
            _batch1(address(underlying), _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6)))
        );
        userOp.preVerificationGas = MAX_PRE_VERIFICATION_GAS + 1;
        userOp.signature = _policyModuleSignature(userOp, automationPk);

        _expectFailedOp("AA24 signature error");
        _handleOps(userOp);
    }

    function test_e2e_replayFailsNonce() public {
        _installPolicyAndEnableAdapters();
        underlying.mint(account, 2e6);
        PackedUserOperation memory userOp = _buildPolicyUserOp(
            _batch1(address(underlying), _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6)))
        );
        userOp.signature = _policyModuleSignature(userOp, automationPk);
        _handleOps(userOp);

        _expectFailedOp("AA25 invalid account nonce");
        _handleOps(userOp);
    }

    function _installPolicyAndEnableAdapters() internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IModularAccount.executeBatch.selector;
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
                    abi.encode(POLICY_ENTITY_ID, initialOwners),
                    new bytes[](0)
                )
            )
        );

        // The account owner selects the registry before any limit can be set against it.
        _setAccountRegistryAsOwner(address(registry));
        _setVaultPolicyAsOwner(aaveVault);
        _setVaultPolicyAsOwner(aaveVaultOther);
        _setVaultPolicyAsOwner(morphoVault);
    }

    function _setAccountRegistryAsOwner(address registry_) internal {
        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.execute,
                (
                    address(executor),
                    0,
                    abi.encodeCall(
                        executor.setAccountRegistry, (IGrowYieldAdapterRegistry(registry_))
                    )
                )
            )
        );
    }

    function _setVaultPolicyAsOwner(address vault) internal {
        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.execute,
                (
                    address(executor),
                    0,
                    abi.encodeCall(
                        executor.setVaultPolicy,
                        (vault, DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, uint48(1 days))
                    )
                )
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

    function _assertBatchHygiene() internal view {
        assertEq(underlying.allowance(account, address(executor)), 0);
        assertEq(aavePool.aToken().allowance(account, address(executor)), 0);
        assertEq(morphoWrapper.allowance(account, address(executor)), 0);
        assertEq(underlying.balanceOf(address(executor)), 0);
        assertEq(underlying.balanceOf(address(aaveAdapter)), 0);
        assertEq(underlying.balanceOf(address(morphoAdapter)), 0);
        assertEq(aavePool.aToken().balanceOf(address(aaveAdapter)), 0);
    }
}
