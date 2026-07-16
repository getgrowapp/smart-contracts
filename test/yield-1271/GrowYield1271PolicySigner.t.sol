// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Call,
    IERC6900Account
} from "@erc6900/reference-implementation/interfaces/IERC6900Account.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {Operation, OperationKind} from "../../src/yield-1271/IGrowYield1271.sol";

/// @notice Policy signer validation: happy paths, module pin, and shape rejection.
contract GrowYield1271PolicySignerTest is GrowYield1271TestBase {
    using MessageHashUtils for bytes32;

    function setUp() public {
        _setUpBase();
    }

    // --- acceptance ---

    function test_acceptsDepositBatch() public {
        (bytes memory proof, bytes32 ethHash) = _validProof(
            _baseUserOp(
                _batch1(
                    address(underlying),
                    _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max))
                )
            )
        );
        _assertValid(ethHash, proof);
    }

    function test_acceptsGranularAmountDeposit() public {
        (bytes memory proof, bytes32 ethHash) = _validProof(
            _baseUserOp(
                _batch1(
                    address(underlying), _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 123_456))
                )
            )
        );
        _assertValid(ethHash, proof);
    }

    function test_acceptsRedeemBatch_positionTokenApproval() public {
        (bytes memory proof, bytes32 ethHash) = _validProof(
            _baseUserOp(
                _batch1(
                    address(aavePool.aToken()),
                    _ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max))
                )
            )
        );
        _assertValid(ethHash, proof);
    }

    function test_acceptsReallocateBatch_twoTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(aavePool.aToken());
        tokens[1] = address(underlying);

        (bytes memory proof, bytes32 ethHash) = _validProof(
            _baseUserOp(
                _batch(
                    tokens,
                    _ops2(
                        _op(aaveAdapter, OperationKind.REDEEM, type(uint256).max),
                        _op(morphoAdapter, OperationKind.DEPOSIT, type(uint256).max)
                    )
                )
            )
        );
        _assertValid(ethHash, proof);
    }

    function test_acceptsSameTokenTwice_singleApproval() public {
        // Two deposits pulling the same underlying: one approval pair suffices.
        (bytes memory proof, bytes32 ethHash) = _validProof(
            _baseUserOp(
                _batch1(
                    address(underlying),
                    _ops2(
                        _op(aaveAdapter, OperationKind.DEPOSIT, 100e6),
                        _op(morphoAdapter, OperationKind.DEPOSIT, 100e6)
                    )
                )
            )
        );
        _assertValid(ethHash, proof);
    }

    // --- module pin ---

    function test_modulePin_rejectsUnknownCaller() public {
        (bytes memory proof, bytes32 ethHash) = _validProof(
            _baseUserOp(
                _batch1(
                    address(underlying),
                    _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max))
                )
            )
        );

        // Same valid proof: INVALID from an arbitrary caller, MAGIC from the module.
        vm.prank(makeAddr("notTheModule"));
        assertEq(signer.isValidSignature(ethHash, proof), INVALID);
        assertEq(signer.isValidSignature(ethHash, proof), INVALID); // test contract
        _assertValid(ethHash, proof);
    }

    // --- hash discipline ---

    function test_rejectsRawUserOpHash() public {
        PackedUserOperation memory userOp = _baseUserOp(
            _batch1(
                address(underlying),
                _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max))
            )
        );
        bytes32 userOpHash = GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        bytes memory proof =
            _encodeProof(userOp, ENTRY_POINT, validUntil, _signAuth(userOpHash, validUntil));

        _assertInvalid(userOpHash, proof);
    }

    // --- batch shape rejection ---

    function _depositOps() internal view returns (Operation[] memory) {
        return _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max));
    }

    function _assertBatchInvalid(Call[] memory calls) internal {
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(abi.encodeCall(IERC6900Account.executeBatch, (calls))));
        _assertInvalid(ethHash, proof);
    }

    function test_rejectsMissingApprovalReset() public {
        Call[] memory calls = new Call[](2);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(address(executor), 0, _executeData(_depositOps()));
        _assertBatchInvalid(calls);
    }

    function test_rejectsNonMaxApproval() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), 1e6));
        calls[1] = Call(address(executor), 0, _executeData(_depositOps()));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        _assertBatchInvalid(calls);
    }

    function test_rejectsForeignSpender() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(makeAddr("attacker"), type(uint256).max));
        calls[1] = Call(address(executor), 0, _executeData(_depositOps()));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        _assertBatchInvalid(calls);
    }

    function test_rejectsWrongApprovalToken() public {
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch1(address(otherUnderlying), _depositOps())));
        _assertInvalid(ethHash, proof);
    }

    function test_rejectsRedeemWithUnderlyingApproval() public {
        (bytes memory proof, bytes32 ethHash) = _validProof(
            _baseUserOp(
                _batch1(
                    address(underlying),
                    _ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max))
                )
            )
        );
        _assertInvalid(ethHash, proof);
    }

    function test_rejectsExtraApprovalPair() public {
        // Two approval pairs but only one source token in ops.
        address[] memory tokens = new address[](2);
        tokens[0] = address(underlying);
        tokens[1] = address(otherUnderlying);
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch(tokens, _depositOps())));
        _assertInvalid(ethHash, proof);
    }

    function test_rejectsWrongTokenOrder() public {
        // Canonical order is first-appearance: [aToken, underlying] for realloc.
        address[] memory tokens = new address[](2);
        tokens[0] = address(underlying);
        tokens[1] = address(aavePool.aToken());
        (bytes memory proof, bytes32 ethHash) = _validProof(
            _baseUserOp(
                _batch(
                    tokens,
                    _ops2(
                        _op(aaveAdapter, OperationKind.REDEEM, type(uint256).max),
                        _op(morphoAdapter, OperationKind.DEPOSIT, type(uint256).max)
                    )
                )
            )
        );
        _assertInvalid(ethHash, proof);
    }

    function test_rejectsExecuteNotInMiddle() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(executor), 0, _executeData(_depositOps()));
        calls[1] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        _assertBatchInvalid(calls);
    }

    function test_rejectsNonExecutorTarget() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(makeAddr("evil"), 0, _executeData(_depositOps()));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        _assertBatchInvalid(calls);
    }

    function test_rejectsUnsupportedExecutorSelector() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(address(executor), 0, abi.encodeWithSelector(bytes4(keccak256("skim()"))));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        _assertBatchInvalid(calls);
    }

    function test_rejectsNativeValue() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(address(executor), 1 wei, _executeData(_depositOps()));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        _assertBatchInvalid(calls);
    }

    function test_rejectsAccountSelfCallTarget() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(account, 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(address(executor), 0, _executeData(_depositOps()));
        calls[2] = Call(account, 0, _approve(address(executor), 0));
        _assertBatchInvalid(calls);
    }

    function test_rejectsUnregisteredAdapterInOps() public {
        registry.setAdapter(address(aaveAdapter), false, false);
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch1(address(underlying), _depositOps())));
        _assertInvalid(ethHash, proof);
    }

    function test_rejectsDirectionMismatch_depositDisabled() public {
        registry.setAdapter(address(aaveAdapter), false, true);
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch1(address(underlying), _depositOps())));
        _assertInvalid(ethHash, proof);
    }

    function test_rejectsEmptyOps() public {
        Operation[] memory ops = new Operation[](0);
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch1(address(underlying), ops)));
        _assertInvalid(ethHash, proof);
    }

    function test_rejectsTooManyOps() public {
        Operation[] memory ops = new Operation[](5);
        for (uint256 i; i < 5; ++i) {
            ops[i] = _op(aaveAdapter, OperationKind.DEPOSIT, 1e6);
        }
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch1(address(underlying), ops)));
        _assertInvalid(ethHash, proof);
    }

    // --- proof lifecycle ---

    function test_malformedProof_returnsInvalid_notRevert() public {
        _assertInvalid(bytes32(0), hex"");
        _assertInvalid(bytes32(0), hex"aaaa");
        _assertInvalid(bytes32(uint256(1)), abi.encode(uint256(1), uint256(2)));
    }

    function test_expiredProof_returnsInvalid() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        bytes32 userOpHash = GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 10);
        bytes memory proof =
            _encodeProof(userOp, ENTRY_POINT, validUntil, _signAuth(userOpHash, validUntil));

        vm.warp(uint256(validUntil) + 1);
        _assertInvalid(userOpHash.toEthSignedMessageHash(), proof);
    }

    function test_expiredConfig_returnsInvalid() public {
        vm.prank(account);
        signer.configure(automation, uint48(block.timestamp + 100));

        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch1(address(underlying), _depositOps())));

        vm.warp(block.timestamp + 101);
        _assertInvalid(ethHash, proof);
    }

    function test_removedConfig_returnsInvalid() public {
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch1(address(underlying), _depositOps())));
        _assertValid(ethHash, proof);

        vm.prank(account);
        signer.removeConfiguration();
        _assertInvalid(ethHash, proof);
    }

    function test_wrongAutomationKey_returnsInvalid() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        bytes32 userOpHash = GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        bytes memory proof = _encodeProof(
            userOp,
            ENTRY_POINT,
            validUntil,
            _signAuthWithKey(uint256(keccak256("wrong")), userOpHash, validUntil)
        );
        _assertInvalid(userOpHash.toEthSignedMessageHash(), proof);
    }

    function test_wrongEntryPoint_returnsInvalid() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        bytes32 userOpHash = GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        bytes memory proof = _encodeProof(
            userOp, makeAddr("wrongEp"), validUntil, _signAuth(userOpHash, validUntil)
        );
        _assertInvalid(userOpHash.toEthSignedMessageHash(), proof);
    }

    function test_wrongChainId_returnsInvalid() public {
        (bytes memory proof, bytes32 ethHash) =
            _validProof(_baseUserOp(_batch1(address(underlying), _depositOps())));
        vm.chainId(999);
        _assertInvalid(ethHash, proof);
    }

    function test_nonceMutationInvalidatesProof() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertValid(ethHash, proof);

        userOp.nonce = 2;
        bytes32 mutated =
            GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid).toEthSignedMessageHash();
        _assertInvalid(mutated, proof);
    }

    function test_fuzz_junkProofNeverMagic(bytes calldata junk) public {
        assertTrue(_isValid(keccak256(junk), junk) != MAGIC);
    }
}
