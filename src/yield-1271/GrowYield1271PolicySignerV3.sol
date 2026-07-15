// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {EIP712} from
    "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MessageHashUtils} from
    "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from
    "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {IGrowYieldRegistry} from "../yield-v6/IGrowYieldSystem.sol";
import {GrowYieldExecutor1271V2} from "./GrowYieldExecutor1271V2.sol";
import {GrowUserOpHashLib} from "./GrowUserOpHashLib.sol";
import {GrowYieldPolicyLib} from "./GrowYieldPolicyLib.sol";

/**
 * @notice EIP-1271 policy signer for Grow yield automation on Alchemy MA v2.
 *
 * @dev Alchemy SingleSignerValidationModule (v2.0.1) calls isValidSignature with
 *      `userOpHash.toEthSignedMessageHash()`, not the raw UserOp hash. Outer
 *      UserOp.signature must be `0xFF || SignatureType.CONTRACT_OWNER (0x01) || proof`.
 *
 *      Malformed proofs and policy/decoding failures return `0xffffffff` and must
 *      not revert (required for gas-estimation dummy proofs).
 */
contract GrowYield1271PolicySignerV3 is IERC1271, EIP712 {
    using SignatureChecker for address;
    using MessageHashUtils for bytes32;

    bytes4 private constant MAGIC = IERC1271.isValidSignature.selector;
    bytes4 private constant INVALID = 0xffffffff;

    bytes32 private constant AUTHORIZATION_TYPEHASH = keccak256(
        "GrowYieldAuthorization(bytes32 userOpHash,uint48 validUntil)"
    );

    uint8 public constant VERSION = 1;
    address public immutable executor;

    struct Config {
        address signer;
        uint48 validUntil;
    }

    struct Proof {
        uint8 version;
        address entryPoint;
        uint48 validUntil;
        PackedUserOperation userOp;
        bytes signature;
    }

    mapping(address account => Config) public config;

    error InvalidConfiguration();
    error OnlySelf();

    constructor(address executor_) EIP712("GrowYieldPolicySigner", "1") {
        if (executor_ == address(0)) revert InvalidConfiguration();
        executor = executor_;
    }

    function configure(address signer, uint48 validUntil) external {
        if (
            signer == address(0)
                || (validUntil != 0 && validUntil <= block.timestamp)
        ) revert InvalidConfiguration();

        config[msg.sender] = Config(signer, validUntil);
    }

    function removeConfiguration() external {
        delete config[msg.sender];
    }

    /// @notice Never reverts: invalid / malformed proofs return EIP-1271 invalid.
    function isValidSignature(
        bytes32 hash,
        bytes calldata encodedProof
    ) external view returns (bytes4) {
        try this.validateProof(hash, encodedProof) returns (bool ok) {
            return ok ? MAGIC : INVALID;
        } catch {
            return INVALID;
        }
    }

    /**
     * @dev External for try/catch so abi.decode / policy decoding reverts become INVALID.
     *      Restricted to self-calls from isValidSignature.
     */
    function validateProof(
        bytes32 hash,
        bytes calldata encodedProof
    ) external view returns (bool) {
        if (msg.sender != address(this)) revert OnlySelf();

        Proof memory proof = abi.decode(encodedProof, (Proof));
        Config memory cfg = config[proof.userOp.sender];

        if (
            proof.version != VERSION || proof.entryPoint == address(0)
                || proof.validUntil <= block.timestamp || cfg.signer == address(0)
                || (cfg.validUntil != 0 && block.timestamp > cfg.validUntil)
                || proof.userOp.signature.length != 0
        ) return false;

        bytes32 userOpHash = GrowUserOpHashLib.hash(
            proof.userOp, proof.entryPoint, block.chainid
        );

        if (userOpHash.toEthSignedMessageHash() != hash) return false;

        IGrowYieldRegistry registry =
            GrowYieldExecutor1271V2(executor).registry();

        if (
            !GrowYieldPolicyLib.isAllowed(
                proof.userOp.sender, executor, registry, proof.userOp.callData
            )
        ) return false;

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(AUTHORIZATION_TYPEHASH, userOpHash, proof.validUntil)
            )
        );

        return cfg.signer.isValidSignatureNow(digest, proof.signature);
    }
}
