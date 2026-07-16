// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {IGrowYieldExecutor} from "./IGrowYield1271.sol";
import {GrowUserOpHashLib} from "./GrowUserOpHashLib.sol";
import {GrowYieldPolicyLib} from "./GrowYieldPolicyLib.sol";

/**
 * @notice EIP-1271 policy signer for Grow yield automation on Alchemy Modular
 *         Account v2. Installed as the account's session-key "owner" in Alchemy's
 *         SingleSignerValidationModule; approves a UserOperation only if it is the
 *         canonical yield batch (see GrowYieldPolicyLib) and carries a fresh EIP-712
 *         authorization from the account's configured automation key.
 *
 * @dev Hash-wrapping pin. SingleSignerValidationModule v2.0.1 calls
 *      `isValidSignature` with `userOpHash.toEthSignedMessageHash()` — NOT the raw
 *      userOpHash. That wrapping has already changed once across Alchemy versions
 *      (current Alchemy `develop` passes the raw hash), so this contract pins the
 *      exact module address at construction and rejects every other caller. A module
 *      upgrade therefore fails closed here instead of silently validating against the
 *      wrong scheme. Off-chain pre-flight checks must set `from = validationModule`
 *      in `eth_call`, or they will see INVALID for valid proofs.
 *
 *      Per-account configuration (vs. one global automation key). Installing this
 *      contract as session key is only the account's consent to the *policy*; the
 *      `config` mapping is the account's consent to a *specific automation key*, with
 *      per-account expiry and instant revocation (`removeConfiguration`) that doesn't
 *      require a module uninstall UserOp. A single global key would give one
 *      compromised key blast radius over every account and remove per-account
 *      revocation entirely.
 *
 *      Non-reverting validation. `isValidSignature` must return `0xffffffff` for
 *      malformed input rather than revert (bundler gas estimation probes with dummy
 *      proofs). Solidity's `abi.decode` has no non-reverting form, so decoding runs in
 *      an external self-call (`validateProof`) whose reverts are contained by
 *      try/catch. This is the standard containment pattern, not incidental
 *      complexity.
 */
contract GrowYield1271PolicySignerV4 is IERC1271, EIP712 {
    using SignatureChecker for address;
    using MessageHashUtils for bytes32;

    bytes4 private constant MAGIC = IERC1271.isValidSignature.selector;
    bytes4 private constant INVALID = 0xffffffff;

    bytes32 private constant AUTHORIZATION_TYPEHASH =
        keccak256("GrowYieldAuthorization(bytes32 userOpHash,uint48 validUntil)");

    /// @notice Proof encoding version accepted by `validateProof`.
    uint8 public constant VERSION = 1;

    /// @notice Yield executor whose registry scopes what automation may do.
    address public immutable executor;

    /// @notice Pinned SingleSignerValidationModule; sole authorized caller of
    ///         `isValidSignature`. See hash-wrapping pin note above.
    address public immutable validationModule;

    /// @param signer Automation key allowed to authorize batches for the account.
    /// @param validUntil Config expiry (0 = no expiry).
    struct Config {
        address signer;
        uint48 validUntil;
    }

    /**
     * @param version Must equal `VERSION`.
     * @param entryPoint EntryPoint the embedded UserOp targets (v0.7 hashing).
     * @param validUntil Authorization expiry; must be in the future at validation.
     * @param userOp Full unsigned UserOp; its recomputed hash must match the wrapped
     *        hash the validation module passes in.
     * @param signature Automation key's EIP-712 signature over (userOpHash, validUntil).
     */
    struct Proof {
        uint8 version;
        address entryPoint;
        uint48 validUntil;
        PackedUserOperation userOp;
        bytes signature;
    }

    mapping(address account => Config) public config;

    event Configured(address indexed account, address indexed signer, uint48 validUntil);
    event ConfigurationRemoved(address indexed account);

    error InvalidConfiguration();
    error OnlySelf();

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    constructor(address executor_, address validationModule_) EIP712("GrowYieldPolicySigner", "1") {
        if (executor_ == address(0) || validationModule_ == address(0)) {
            revert InvalidConfiguration();
        }

        executor = executor_;
        validationModule = validationModule_;
    }

    /**
     * @notice Set the caller's automation key and optional expiry.
     * @param signer Automation key (EOA or ERC-1271 contract).
     * @param validUntil Expiry timestamp, or 0 for no expiry; must be future if set.
     */
    function configure(address signer, uint48 validUntil) external {
        if (signer == address(0) || (validUntil != 0 && validUntil <= block.timestamp)) {
            revert InvalidConfiguration();
        }

        config[msg.sender] = Config(signer, validUntil);

        emit Configured(msg.sender, signer, validUntil);
    }

    /// @notice Revoke the caller's automation key immediately.
    function removeConfiguration() external {
        delete config[msg.sender];

        emit ConfigurationRemoved(msg.sender);
    }

    /**
     * @notice EIP-1271 entrypoint for the pinned validation module.
     * @dev Never reverts: unknown callers, malformed proofs, and policy failures all
     *      return `0xffffffff` (required for bundler gas-estimation dummy proofs).
     * @param hash `userOpHash.toEthSignedMessageHash()` as passed by the module.
     * @param encodedProof abi-encoded `Proof`.
     */
    function isValidSignature(bytes32 hash, bytes calldata encodedProof)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != validationModule) return INVALID;

        try this.validateProof(hash, encodedProof) returns (bool ok) {
            return ok ? MAGIC : INVALID;
        } catch {
            return INVALID;
        }
    }

    /**
     * @notice Full proof validation; external only so `isValidSignature` can contain
     *         `abi.decode` reverts via try/catch. Not callable by anyone but self.
     * @dev Checks, in order: proof well-formedness and freshness, account has a live
     *      automation key, embedded UserOp hash matches the wrapped `hash`, calldata
     *      passes the static batch policy, and the automation key signed
     *      (userOpHash, validUntil) under this contract's EIP-712 domain.
     */
    function validateProof(bytes32 hash, bytes calldata encodedProof)
        external
        view
        onlySelf
        returns (bool)
    {
        Proof memory proof = abi.decode(encodedProof, (Proof));
        Config memory cfg = config[proof.userOp.sender];

        if (
            proof.version != VERSION || proof.entryPoint == address(0)
                || proof.validUntil <= block.timestamp || cfg.signer == address(0)
                || (cfg.validUntil != 0 && block.timestamp > cfg.validUntil)
                || proof.userOp.signature.length != 0
        ) return false;

        bytes32 userOpHash = GrowUserOpHashLib.hash(proof.userOp, proof.entryPoint, block.chainid);

        if (userOpHash.toEthSignedMessageHash() != hash) return false;

        if (!GrowYieldPolicyLib.isAllowed(
                proof.userOp.sender,
                executor,
                IGrowYieldExecutor(executor).registry(),
                proof.userOp.callData
            )) return false;

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(AUTHORIZATION_TYPEHASH, userOpHash, proof.validUntil))
        );

        return cfg.signer.isValidSignatureNow(digest, proof.signature);
    }
}
