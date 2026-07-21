// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BasePaymaster} from "@eth-infinitism/account-abstraction/core/BasePaymaster.sol";
import {IEntryPoint} from "@eth-infinitism/account-abstraction/interfaces/IEntryPoint.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Test-only sponsor that accepts every operation and returns no post-op context.
contract MockSponsorPaymaster is BasePaymaster {
    constructor(IEntryPoint entryPoint_) BasePaymaster(entryPoint_) {}

    function _validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        internal
        pure
        override
        returns (bytes memory context, uint256 validationData)
    {
        return ("", 0);
    }
}
