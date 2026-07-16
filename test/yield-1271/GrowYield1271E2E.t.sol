// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IEntryPoint} from "@eth-infinitism/account-abstraction/interfaces/IEntryPoint.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {
    ReferenceModularAccount
} from "@erc6900/reference-implementation/account/ReferenceModularAccount.sol";
import {
    Call,
    IERC6900Account
} from "@erc6900/reference-implementation/interfaces/IERC6900Account.sol";
import {
    ValidationConfigLib
} from "@erc6900/reference-implementation/libraries/ValidationConfigLib.sol";
import {
    SingleSignerValidationModule
} from "@erc6900/reference-implementation/modules/validation/SingleSignerValidationModule.sol";
// Etches the canonical EntryPoint v0.7 bytecode at 0x0000000071727De22E5E9d8BAf0edAc6f37da032.
import {EntryPointUtils} from "../../lib/reference-implementation/test/utils/EntryPointUtils.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {GrowYield1271PolicySignerV4} from "../../src/yield-1271/GrowYield1271PolicySignerV4.sol";
import {Operation, OperationKind} from "../../src/yield-1271/IGrowYield1271.sol";

/**
 * @notice Full ERC-4337 lifecycle against the real EntryPoint v0.7 bytecode and a real
 *         ERC-6900 modular account. The ERC-6900 reference `SingleSignerValidationModule`
 *         stands in for Alchemy MA v2's (Alchemy implements ERC-6900 v0.8 and uses the
 *         identical `userOpHash.toEthSignedMessageHash()` wrapping this repo pins).
 *
 *         Flow under test — every step a UserOperation through `EntryPoint.handleOps`:
 *         1. Owner installs the policy signer as a session key: validation entity
 *            scoped to `executeBatch` only, userOp-validation only (no runtime/1271).
 *         2. Owner configures the automation key on the policy signer (the account is
 *            `msg.sender`, exercising the per-account config path).
 *         3. Automation submits deposit, partial withdrawal, and two-op reallocation
 *            batches authorized solely by policy proofs.
 *
 *         Also proves on-chain what unit tests assert in isolation: GrowUserOpHashLib
 *         matches the canonical EntryPoint's `getUserOpHash` exactly (the v0.7 pin),
 *         and EntryPoint nonces make proofs single-use.
 */
contract GrowYield1271E2ETest is GrowYield1271TestBase, EntryPointUtils {
    using MessageHashUtils for bytes32;

    uint32 internal constant OWNER_ENTITY_ID = 0;
    uint32 internal constant SESSION_KEY_ENTITY_ID = 1;
    /// @dev Sparse-calldata-segment terminator for the final signature segment.
    uint8 internal constant FINAL_SEGMENT_INDEX = 0xFF;
    uint8 internal constant GLOBAL_VALIDATION = 1;
    uint8 internal constant SELECTOR_ASSOCIATED_VALIDATION = 0;

    IEntryPoint internal entryPoint;
    SingleSignerValidationModule internal validationModule;
    ReferenceModularAccount internal modularAccount;

    address internal owner;
    uint256 internal ownerKey;
    address internal bundler;
    address payable internal beneficiary;

    function setUp() public {
        entryPoint = _deployEntryPoint();
        assertEq(address(entryPoint), ENTRY_POINT, "canonical EntryPoint address");

        (owner, ownerKey) = makeAddrAndKey("owner");
        bundler = makeAddr("bundler");
        beneficiary = payable(makeAddr("beneficiary"));

        // The real module is the policy signer's pinned isValidSignature caller.
        validationModule = new SingleSignerValidationModule();
        module = address(validationModule);

        // Modular account behind an ERC1967 proxy, owner as global validation.
        // OZ 5.6 ERC1967Proxy requires initialization data: init atomically.
        modularAccount = ReferenceModularAccount(
            payable(address(
                    new ERC1967Proxy(
                        address(new ReferenceModularAccount(entryPoint)),
                        abi.encodeCall(
                            ReferenceModularAccount.initializeWithValidation,
                            (
                                ValidationConfigLib.pack(module, OWNER_ENTITY_ID, true, true, true),
                                new bytes4[](0),
                                abi.encode(OWNER_ENTITY_ID, owner),
                                new bytes[](0)
                            )
                        )
                    )
                ))
        );
        account = address(modularAccount);
        vm.deal(account, 100 ether);

        _deployStack();
    }

    // --- the full lifecycle ---

    function test_e2e_installConfigureDepositWithdrawReallocate() public {
        // 1. Session key install: the policy signer contract is the entity-1 "signer",
        //    valid only for userOp validation of `executeBatch` (not global, no 1271
        //    runtime path) — the account-side blast-radius bound.
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC6900Account.executeBatch.selector;

        _runOwnerUserOp(
            abi.encodeCall(
                IERC6900Account.installValidation,
                (
                    ValidationConfigLib.pack(module, SESSION_KEY_ENTITY_ID, false, false, true),
                    selectors,
                    abi.encode(SESSION_KEY_ENTITY_ID, address(signer)),
                    new bytes[](0)
                )
            )
        );
        assertEq(validationModule.signers(SESSION_KEY_ENTITY_ID, account), address(signer));

        // 2. Configure the automation key — through the account, not a prank, so the
        //    per-account config is written under the real msg.sender.
        _runOwnerUserOp(
            abi.encodeCall(
                IERC6900Account.execute,
                (
                    address(signer),
                    0,
                    abi.encodeCall(GrowYield1271PolicySignerV4.configure, (automation, 0))
                )
            )
        );
        (address configured,) = signer.config(account);
        assertEq(configured, automation);

        // 3. Deposit: full underlying balance into Aave.
        underlying.mint(account, 1_000e6);
        _runPolicyUserOp(
            _batch1(
                address(underlying),
                _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max))
            )
        );
        assertEq(aavePool.aToken().balanceOf(account), 1_000e6);
        assertEq(underlying.balanceOf(account), 0);
        _assertBatchHygiene();

        // 4. Partial withdrawal: granular amount, not full balance.
        _runPolicyUserOp(
            _batch1(
                address(aavePool.aToken()), _ops1(_op(aaveAdapter, OperationKind.REDEEM, 400e6))
            )
        );
        assertEq(underlying.balanceOf(account), 400e6);
        assertEq(aavePool.aToken().balanceOf(account), 600e6);
        _assertBatchHygiene();

        // 5. Reallocate: exit Aave fully, sweep everything into the Morpho wrapper —
        //    one UserOp, two ops, two approval pairs in canonical first-appearance order.
        address[] memory tokens = new address[](2);
        tokens[0] = address(aavePool.aToken());
        tokens[1] = address(underlying);
        _runPolicyUserOp(
            _batch(
                tokens,
                _ops2(
                    _op(aaveAdapter, OperationKind.REDEEM, type(uint256).max),
                    _op(morphoAdapter, OperationKind.DEPOSIT, type(uint256).max)
                )
            )
        );
        assertEq(aavePool.aToken().balanceOf(account), 0);
        assertEq(underlying.balanceOf(account), 0);
        assertEq(morphoWrapper.balanceOf(account), 1_000e6);
        _assertBatchHygiene();
    }

    // --- adversarial paths through the real EntryPoint ---

    function test_e2e_tamperedCallData_failsSignatureValidation() public {
        _installSessionKeyAndConfigure();
        underlying.mint(account, 100e6);

        bytes memory authorized = _batch1(
            address(underlying), _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max))
        );
        PackedUserOperation memory userOp = _buildUserOp(authorized);
        bytes memory proof = _policyProof(userOp);

        // Swap the executed callData for a batch the proof never authorized.
        userOp.callData = _batch1(
            address(otherUnderlying),
            _ops1(_op(aaveAdapterOther, OperationKind.DEPOSIT, type(uint256).max))
        );
        userOp.signature = _sessionKeySignature(proof);

        _expectFailedOp("AA24 signature error");
        _handleOps(userOp);
    }

    function test_e2e_nonCanonicalBatch_failsSignatureValidation() public {
        _installSessionKeyAndConfigure();
        underlying.mint(account, 100e6);

        // Batch missing the trailing approve-zero reset. The automation key signs a
        // fully valid proof over it — the policy alone rejects the shape.
        Call[] memory calls = new Call[](2);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(
            address(executor),
            0,
            _executeData(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max)))
        );

        PackedUserOperation memory userOp =
            _buildUserOp(abi.encodeCall(IERC6900Account.executeBatch, (calls)));
        userOp.signature = _sessionKeySignature(_policyProof(userOp));

        _expectFailedOp("AA24 signature error");
        _handleOps(userOp);
    }

    function test_e2e_replayedUserOp_failsNonce() public {
        _installSessionKeyAndConfigure();
        underlying.mint(account, 200e6);

        PackedUserOperation memory userOp = _buildUserOp(
            _batch1(address(underlying), _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 100e6)))
        );
        userOp.signature = _sessionKeySignature(_policyProof(userOp));
        _handleOps(userOp);

        // Same op again: EntryPoint nonce uniqueness makes proofs single-use.
        _expectFailedOp("AA25 invalid account nonce");
        _handleOps(userOp);
    }

    // --- helpers ---

    function _installSessionKeyAndConfigure() internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC6900Account.executeBatch.selector;
        _runOwnerUserOp(
            abi.encodeCall(
                IERC6900Account.installValidation,
                (
                    ValidationConfigLib.pack(module, SESSION_KEY_ENTITY_ID, false, false, true),
                    selectors,
                    abi.encode(SESSION_KEY_ENTITY_ID, address(signer)),
                    new bytes[](0)
                )
            )
        );
        _runOwnerUserOp(
            abi.encodeCall(
                IERC6900Account.execute,
                (
                    address(signer),
                    0,
                    abi.encodeCall(GrowYield1271PolicySignerV4.configure, (automation, 0))
                )
            )
        );
    }

    /// @dev Fresh UserOp with the account's real EntryPoint nonce and e2e gas limits.
    function _buildUserOp(bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp = _baseUserOp(callData);
        userOp.nonce = entryPoint.getNonce(account, 0);
        userOp.accountGasLimits = bytes32((uint256(2_000_000) << 128) | uint256(1_500_000));
        userOp.preVerificationGas = 100_000;
    }

    /// @dev Owner-authorized userOp: global validation, plain ECDSA over the
    ///      module-wrapped hash.
    function _runOwnerUserOp(bytes memory callData) internal {
        PackedUserOperation memory userOp = _buildUserOp(callData);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, entryPoint.getUserOpHash(userOp).toEthSignedMessageHash());
        userOp.signature = abi.encodePacked(
            module, OWNER_ENTITY_ID, GLOBAL_VALIDATION, FINAL_SEGMENT_INDEX, r, s, v
        );
        _handleOps(userOp);
    }

    /// @dev Policy proof over the unsigned userOp, hash cross-checked against the
    ///      canonical EntryPoint — the on-chain proof of the v0.7 hash-lib pin.
    function _policyProof(PackedUserOperation memory userOp) internal view returns (bytes memory) {
        bytes32 userOpHash = GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        assertEq(userOpHash, entryPoint.getUserOpHash(userOp), "GrowUserOpHashLib desync");
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        return _encodeProof(userOp, ENTRY_POINT, validUntil, _signAuth(userOpHash, validUntil));
    }

    /// @dev ERC-6900 v0.8 signature layout: 24-byte module entity, 1-byte scope flag,
    ///      then the final sparse-calldata segment (0xFF || proof). The account strips
    ///      the prefix; the module receives the raw proof bytes and staticcalls the
    ///      policy signer (msg.sender == module, satisfying the pin).
    function _sessionKeySignature(bytes memory proof) internal view returns (bytes memory) {
        return abi.encodePacked(
            module,
            SESSION_KEY_ENTITY_ID,
            SELECTOR_ASSOCIATED_VALIDATION,
            FINAL_SEGMENT_INDEX,
            proof
        );
    }

    function _runPolicyUserOp(bytes memory callData) internal {
        PackedUserOperation memory userOp = _buildUserOp(callData);
        userOp.signature = _sessionKeySignature(_policyProof(userOp));
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

    /// @dev Post-batch hygiene: zero allowances to the executor, nothing stranded.
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
