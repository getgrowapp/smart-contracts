// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Call, IModularAccount} from
    "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {MessageHashUtils} from
    "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {GrowYield1271PolicySignerV3} from
    "../../src/yield-1271/GrowYield1271PolicySignerV3.sol";

/// @notice Adversarial EIP-1271 / policy cases for yield-1271 beta freeze.
contract GrowYield1271AdversarialTest is GrowYield1271TestBase {
    using MessageHashUtils for bytes32;

    function setUp() public {
        _setUpBase();
    }

    function test_malformedProof_returnsInvalid_notRevert() public view {
        _assertInvalid(bytes32(uint256(1)), hex"");
        _assertInvalid(bytes32(uint256(1)), hex"deadbeef");
        _assertInvalid(bytes32(uint256(1)), abi.encode(uint256(1), uint256(2)));
    }

    function test_structurallyValidDummy_returnsInvalid_forGasEstimation()
        public
        view
    {
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        bytes32 realHash =
            GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        // Valid structure + automation signature over real hash, queried under a
        // mismatched outer hash (as gas-estimation dummy must do).
        bytes memory proof = _encodeProof(
            userOp,
            ENTRY_POINT,
            validUntil,
            _signAuth(realHash, validUntil)
        );
        _assertInvalid(bytes32(uint256(0xDEC0DE)), proof);
    }

    function test_wrongEmbeddedUserOp_returnsInvalid() public view {
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        (bytes memory proof,) = _validProof(userOp);

        PackedUserOperation memory other =
            _baseUserOp(_batch(address(underlying), _withdrawOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        bytes32 otherEth = GrowUserOpHashLib.hash(other, ENTRY_POINT, block.chainid)
            .toEthSignedMessageHash();
        _assertInvalid(otherEth, proof);
    }

    function test_wrongOuterHash_returnsInvalid() public view {
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        (bytes memory proof,) = _validProof(userOp);
        _assertInvalid(keccak256("wrong"), proof);
    }

    function test_wrongEntryPoint_returnsInvalid() public view {
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        bytes32 userOpHash =
            GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        address wrongEp = address(0xBEEF);
        // Proof signs the true EP hash but embeds a different entryPoint →
        // recomputed embed hash ≠ outer eth-signed hash.
        bytes memory proof = _encodeProof(
            userOp, wrongEp, validUntil, _signAuth(userOpHash, validUntil)
        );
        _assertInvalid(userOpHash.toEthSignedMessageHash(), proof);
    }

    function test_wrongChainId_returnsInvalid() public {
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);

        vm.chainId(999);
        _assertInvalid(ethHash, proof);
    }

    function test_expiredOperation_returnsInvalid() public {
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        bytes32 userOpHash =
            GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 10);
        bytes memory proof = _encodeProof(
            userOp, ENTRY_POINT, validUntil, _signAuth(userOpHash, validUntil)
        );

        vm.warp(uint256(validUntil) + 1);
        _assertInvalid(userOpHash.toEthSignedMessageHash(), proof);
    }

    function test_expiredConfiguredSigner_returnsInvalid() public {
        vm.prank(account);
        signer.configure(automation, uint48(block.timestamp + 100));

        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);

        vm.warp(block.timestamp + 101);
        _assertInvalid(ethHash, proof);
    }

    function test_wrongAutomationSigner_returnsInvalid() public view {
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        bytes32 userOpHash =
            GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        uint256 wrongPk = uint256(keccak256("wrong-automation"));
        bytes memory proof = _encodeProof(
            userOp,
            ENTRY_POINT,
            validUntil,
            _signAuthWithKey(wrongPk, userOpHash, validUntil)
        );
        _assertInvalid(userOpHash.toEthSignedMessageHash(), proof);
    }

    function test_modifiedApprovalToken_returnsInvalid() public view {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            address(otherUnderlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            address(executor),
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        calls[2] =
            Call(address(otherUnderlying), 0, _approve(address(executor), 0));
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        PackedUserOperation memory userOp = _baseUserOp(callData);
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_withdrawApprovesUnderlying_notPosition_returnsInvalid()
        public
        view
    {
        // withdrawAll pulls aToken; approving underlying must fail policy.
        PackedUserOperation memory userOp = _baseUserOp(
            _batch(
                address(underlying),
                _withdrawOp(
                    Protocol.AAVE, address(aavePool), address(underlying)
                )
            )
        );
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_reallocateApprovesUnderlying_notSourcePosition_returnsInvalid()
        public
        view
    {
        PackedUserOperation memory userOp = _baseUserOp(
            _batch(
                address(underlying),
                _reallocOp(
                    Protocol.AAVE,
                    address(aavePool),
                    address(underlying),
                    Protocol.MORPHO,
                    address(morphoVault),
                    address(underlying)
                )
            )
        );
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_withdrawApprovesPositionToken_accepted() public view {
        address aToken = address(aavePool.aToken());
        PackedUserOperation memory userOp = _baseUserOp(
            _batch(
                aToken,
                _withdrawOp(
                    Protocol.AAVE, address(aavePool), address(underlying)
                )
            )
        );
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        assertEq(
            signer.isValidSignature(ethHash, proof),
            signer.isValidSignature.selector
        );
    }

    function test_nonMaxApproval_returnsInvalid() public view {
        Call[] memory calls = new Call[](3);
        calls[0] =
            Call(address(underlying), 0, _approve(address(executor), 1e6));
        calls[1] = Call(
            address(executor),
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        calls[2] =
            Call(address(underlying), 0, _approve(address(executor), 0));
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        PackedUserOperation memory userOp = _baseUserOp(callData);
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_missingApprovalReset_returnsInvalid() public view {
        Call[] memory calls = new Call[](2);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            address(executor),
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        PackedUserOperation memory userOp = _baseUserOp(callData);
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_differentTokenInApproveAndApproveZero_returnsInvalid()
        public
        view
    {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            address(executor),
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        calls[2] = Call(
            address(otherUnderlying), 0, _approve(address(executor), 0)
        );
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        PackedUserOperation memory userOp = _baseUserOp(callData);
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_arbitraryExecutorTarget_returnsInvalid() public view {
        address evil = address(uint160(uint256(keccak256("evil"))));
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            evil,
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        calls[2] =
            Call(address(underlying), 0, _approve(address(executor), 0));
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        PackedUserOperation memory userOp = _baseUserOp(callData);
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_unsupportedSelector_returnsInvalid() public view {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            address(executor),
            0,
            abi.encodeWithSelector(bytes4(keccak256("skim()")))
        );
        calls[2] =
            Call(address(underlying), 0, _approve(address(executor), 0));
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        PackedUserOperation memory userOp = _baseUserOp(callData);
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_nativeEthValue_returnsInvalid() public view {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            address(executor),
            1 wei,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        calls[2] =
            Call(address(underlying), 0, _approve(address(executor), 0));
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        PackedUserOperation memory userOp = _baseUserOp(callData);
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_smartAccountSelfCall_returnsInvalid() public view {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            account,
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        calls[2] =
            Call(address(underlying), 0, _approve(address(executor), 0));
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        PackedUserOperation memory userOp = _baseUserOp(callData);
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        _assertInvalid(ethHash, proof);
    }

    function test_staleNonceReplay_sameProofDifferentOuterHash() public view {
        // Proof binds exact packed UserOp (including nonce). Replaying a proof
        // against a mutated nonce/hash fails EIP-1271; EP nonce increment is
        // enforced by EntryPoint off this contract's surface.
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        assertEq(
            signer.isValidSignature(ethHash, proof),
            signer.isValidSignature.selector
        );

        userOp.nonce = 2;
        bytes32 replayEth = GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid)
            .toEthSignedMessageHash();
        _assertInvalid(replayEth, proof);
    }

    function test_validProof_stillAccepted() public view {
        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        assertEq(
            signer.isValidSignature(ethHash, proof),
            signer.isValidSignature.selector
        );
    }
}
