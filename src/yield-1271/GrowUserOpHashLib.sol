// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @notice ERC-4337 v0.7 UserOperation hashing for embedded unsigned UserOps.
 * @dev Matches EntryPoint v0.7 `getUserOpHash` (signature excluded; must be empty).
 *
 *      Deliberately pinned to the v0.7 scheme: EntryPoint v0.8+ switched userOp
 *      hashing to an EIP-712 domain, and Alchemy Modular Account v2 targets
 *      EntryPoint v0.7 (0x0000000071727De22E5E9d8BAf0edAc6f37da032). The vendored
 *      account-abstraction lib is held at v0.7.0 for the same reason — upgrading it
 *      without changing this function would silently desync proof hashes from the
 *      production EntryPoint. Wrong-scheme hashes fail closed (proof mismatch).
 */
library GrowUserOpHashLib {
    error SignatureMustBeEmpty();

    function hash(PackedUserOperation memory userOp, address entryPoint, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        if (userOp.signature.length != 0) {
            revert SignatureMustBeEmpty();
        }

        bytes32 packedHash = keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                keccak256(userOp.paymasterAndData)
            )
        );

        return keccak256(abi.encode(packedHash, entryPoint, chainId));
    }
}
