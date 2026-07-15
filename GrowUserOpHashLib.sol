// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @notice ERC-4337 v0.7 UserOperation hashing for embedded unsigned UserOps.
 * @dev Matches EntryPoint.encode (signature excluded from hash; must be empty).
 */
library GrowUserOpHashLib {
    error SignatureMustBeEmpty();

    function hash(
        PackedUserOperation memory userOp,
        address entryPoint,
        uint256 chainId
    ) internal pure returns (bytes32) {
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
