// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IModularAccount} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";

import {IGrowYieldExecutor, MAX_OPS} from "./interfaces/IGrowYieldExecutor.sol";

/// @title GrowYieldPolicyLib
/// @notice Static calldata policy for Grow yield automation.
/// @dev Accepts exactly one shape:
///
///          account.execute(executor, 0, executor.execute(ops))
///
///      and nothing else. That is the whole policy, because the executor is what makes the
///      operations safe rather than the calldata around them: `execute` pulls the source token
///      from `msg.sender` and credits every output back to `msg.sender`, so reaching it can only
///      move the account's own funds, into or out of a venue the registry admitted.
///
///      Consequently this library does not decode or vet the operations. It could not usefully
///      do so: ERC-7562 confines validation to account-associated storage, so the policy cannot
///      read the registry, and every check it could make locally — nonzero vault, nonzero source
///      token, nonzero output floor, batch size — the executor already enforces on the same
///      calldata a moment later. Re-implementing them here would duplicate the invariant in a
///      second place that can drift, in exchange for nothing.
///
///      What it does enforce is that the sponsor's gas buys exactly one executor call: the
///      target is the account's approved executor, no ether moves, the inner selector is
///      `execute`, and `callData` is byte-for-byte the canonical encoding of what was inspected,
///      so nothing can be padded onto a validated request.
/// @custom:security-contact security@getgrowapp.co
library GrowYieldPolicyLib {
    /// @dev Canonical size of `account.execute(executor, 0, executor.execute(ops))` at the
    ///      executor's own `MAX_OPS` ceiling. `Operation` is a static 6-word struct, so:
    ///
    ///          inner = 4 selector + 32 offset + 32 length + 192 * MAX_OPS
    ///          outer = 4 selector + 96 head + 32 length + inner padded to a word
    ///
    ///      Bounding the length is how the batch size is capped here, instead of decoding the
    ///      operations only to count them. Any larger request is rejected before it is hashed.
    uint256 private constant MAX_INNER_LENGTH = 68 + 192 * MAX_OPS;
    // Round the inner payload up to a whole word; dividing first is the rounding, not a
    // precision loss.
    // forge-lint: disable-next-line(divide-before-multiply)
    uint256 private constant MAX_CALLDATA_LENGTH = 132 + ((MAX_INNER_LENGTH + 31) / 32) * 32;

    /// @notice True if `callData` is the canonical single executor call for `account`.
    function isAllowed(address account, address executor, bytes calldata callData)
        internal
        pure
        returns (bool)
    {
        if (
            callData.length < 4 || callData.length > MAX_CALLDATA_LENGTH
                || bytes4(callData[:4]) != IModularAccount.execute.selector
        ) return false;

        (address target, uint256 value, bytes memory data) =
            abi.decode(callData[4:], (address, uint256, bytes));

        return target == executor && target != account && value == 0 && data.length >= 4
            // Truncation is the intent: the leading four bytes are the selector, and
            // `data.length >= 4` above guarantees they exist.
            // forge-lint: disable-next-line(unsafe-typecast)
            && bytes4(data) == IGrowYieldExecutor.execute.selector
            && keccak256(callData)
                == keccak256(abi.encodeCall(IModularAccount.execute, (target, value, data)));
    }
}
