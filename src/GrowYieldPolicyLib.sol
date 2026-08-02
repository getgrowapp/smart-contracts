// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IModularAccount} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";

import {IGrowYieldExecutor, MAX_OPS} from "./interfaces/IGrowYieldExecutor.sol";

/// @title GrowYieldPolicyLib
/// @notice Static calldata policy for Grow yield automation.
/// @dev Accepts exactly one shape and nothing else:
///
///          account.execute(executor, 0, executor.execute(ops))
///
///      The operations themselves are deliberately not decoded or vetted. ERC-7562 confines
///      validation to account-associated storage, so the policy cannot read the registry, and
///      every check it could make locally the executor already enforces on the same calldata a
///      moment later.
///
///      What it does enforce is that the sponsor's gas buys exactly one executor call: the target
///      is the account's approved executor, no ether moves, the inner selector is `execute`, and
///      `callData` is byte-for-byte canonical, so nothing can be padded onto a validated request.
/// @custom:security-contact security@getgrowapp.co
library GrowYieldPolicyLib {
    /// @dev Canonical size of `account.execute(executor, 0, executor.execute(ops))` at the
    ///      executor's own `MAX_OPS` ceiling. `Operation` is a static 6-word struct, so:
    ///
    ///          inner = 4 selector + 32 offset + 32 length + 192 * MAX_OPS
    ///          outer = 4 selector + 96 head + 32 length + inner padded to a word
    ///
    ///      Bounding the length caps the batch size without decoding the operations to count them.
    uint256 private constant MAX_INNER_LENGTH = 68 + 192 * MAX_OPS;
    // Round the inner payload up to a whole word; dividing first is the rounding, not a
    // precision loss.
    // forge-lint: disable-next-line(divide-before-multiply)
    uint256 private constant MAX_CALLDATA_LENGTH = 132 + ((MAX_INNER_LENGTH + 31) / 32) * 32;

    /// @notice True if `callData` is the canonical single call to `executor`.
    /// @dev `executor` is never the account itself; `GrowYieldPolicyModule._setExecutor` rejects
    ///      that at configuration, so this does not re-check it.
    function isAllowed(address executor, bytes calldata callData) internal pure returns (bool) {
        if (
            callData.length < 4 || callData.length > MAX_CALLDATA_LENGTH
                || bytes4(callData[:4]) != IModularAccount.execute.selector
        ) return false;

        (address target, uint256 value, bytes memory data) =
            abi.decode(callData[4:], (address, uint256, bytes));

        return target == executor && value == 0 && _isAllowedExecutorPayload(data)
            && keccak256(callData)
                == keccak256(abi.encodeCall(IModularAccount.execute, (target, value, data)));
    }

    /// @dev The inner `executor.execute(ops)` payload. Only the selector and a length ceiling are
    ///      checked; the operations themselves are the executor's business, per `isAllowed`.
    function _isAllowedExecutorPayload(bytes memory data) private pure returns (bool) {
        return data.length >= 4 && data.length <= MAX_INNER_LENGTH
            && bytes4(_loadSelector(data)) == IGrowYieldExecutor.execute.selector;
    }

    function _loadSelector(bytes memory data) private pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(data, 32))
        }
    }
}
