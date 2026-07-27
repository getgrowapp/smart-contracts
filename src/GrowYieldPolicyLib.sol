// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    Call,
    IModularAccount
} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IGrowYieldExecutor, Operation} from "./interfaces/IGrowYieldExecutor.sol";

/// @title GrowYieldPolicyLib
/// @notice Static calldata policy for Grow yield automation batches.
/// @dev Accepts exactly one batch shape:
///
///          [approve(t_1, max) ... approve(t_k, max),
///           executor.execute(ops),
///           approve(t_1, 0) ... approve(t_k, 0)]
///
///      where `t_1..t_k` are the unique source tokens declared by `ops`, in first-appearance
///      order. The bracket exists so the account never carries a standing allowance to the
///      executor; the executor re-verifies every declaration before it moves anything.
///
///      Every check is a pure function of the decoded batch, and each stage rejects by
///      returning rather than reverting, so a malformed batch is a policy failure and not a
///      validation revert. `abi.decode` on structurally invalid ABI still reverts; the
///      validation module contains that with a self-call.
/// @custom:security-contact security@getgrowapp.co
library GrowYieldPolicyLib {
    /// @notice Maximum operations in one batch, which also bounds the approve bracket at `k`.
    /// @dev Validation-phase gas bound; covers deposit, withdraw, reallocate, and small
    ///      multi-venue rebalances.
    uint256 internal constant MAX_OPS = 4;

    /// @dev Pre-filter that bounds the cost of the canonical-encoding hash below. Not a
    ///      security bound: the hash pins the length exactly.
    uint256 private constant MAX_CALLDATA_LENGTH = 7_000;

    /// @notice True if `callData` is a canonical approve/execute/revoke batch for `account`.
    function isAllowed(address account, address executor, bytes calldata callData)
        internal
        pure
        returns (bool)
    {
        if (
            callData.length < 4 || callData.length > MAX_CALLDATA_LENGTH
                || bytes4(callData[:4]) != IModularAccount.executeBatch.selector
        ) return false;

        Call[] memory calls = abi.decode(callData[4:], (Call[]));
        if (!_isCanonical(callData, abi.encodeCall(IModularAccount.executeBatch, (calls)))) {
            return false;
        }

        // k approve-max calls, one execute call, k approve-zero calls.
        if (calls.length < 3 || calls.length % 2 == 0) return false;
        uint256 k = (calls.length - 1) / 2;
        if (k > MAX_OPS) return false;

        Operation[] memory ops = _executeOps(account, executor, calls[k]);
        (address[MAX_OPS] memory tokens, uint256 tokenCount) = _uniqueSourceTokens(account, ops);
        if (tokenCount == 0 || tokenCount != k) return false;

        for (uint256 i; i < k; ++i) {
            if (
                !_isApprove(calls[i], tokens[i], executor, type(uint256).max)
                    || !_isApprove(calls[k + 1 + i], tokens[i], executor, 0)
            ) return false;
        }

        return true;
    }

    /// @dev The operations of the batch's middle call, or an empty array if that call is not
    ///      exactly a zero-value, canonically encoded `executor.execute(ops)` with `1..MAX_OPS`
    ///      operations.
    function _executeOps(address account, address executor, Call memory call_)
        private
        pure
        returns (Operation[] memory)
    {
        bytes memory data = call_.data;
        if (
            call_.value != 0 || call_.target != executor || executor == account || data.length < 4
                || _selector(data) != IGrowYieldExecutor.execute.selector
        ) return new Operation[](0);

        Operation[] memory ops = abi.decode(_afterSelector(data), (Operation[]));
        if (ops.length == 0 || ops.length > MAX_OPS) return new Operation[](0);

        // The outer hash above reproduces `data` verbatim as opaque bytes, so the inner
        // encoding is canonicalized separately. This rejects oversized or offset-aliased
        // buffers that decode to `ops` but smuggle unvalidated bytes past the policy.
        if (!_isCanonical(data, abi.encodeCall(IGrowYieldExecutor.execute, (ops)))) {
            return new Operation[](0);
        }

        return ops;
    }

    /// @dev Unique source tokens in first-appearance order. Returns `count == 0` if any
    ///      operation is malformed, which fails the caller's `count == k` check.
    function _uniqueSourceTokens(address account, Operation[] memory ops)
        private
        pure
        returns (address[MAX_OPS] memory tokens, uint256 count)
    {
        for (uint256 i; i < ops.length; ++i) {
            address token = ops[i].sourceToken;
            // A zero `minAmountOut` is rejected by the executor too; catching it here keeps a
            // floorless operation out of a batch the sponsor would otherwise pay to submit.
            if (
                ops[i].vault == address(0) || token == address(0) || token == account
                    || ops[i].minAmountOut == 0
            ) return (tokens, 0);

            bool seen;
            for (uint256 j; j < count; ++j) {
                if (tokens[j] == token) {
                    seen = true;
                    break;
                }
            }
            if (!seen) tokens[count++] = token;
        }
    }

    /// @dev True if `call_` is exactly a zero-value `token.approve(spender, amount)`.
    function _isApprove(Call memory call_, address token, address spender, uint256 amount)
        private
        pure
        returns (bool)
    {
        return call_.value == 0 && call_.target == token
            && _isCanonical(call_.data, abi.encodeCall(IERC20.approve, (spender, amount)));
    }

    /// @dev Byte-exact match, which also pins length and rejects non-canonical encodings.
    function _isCanonical(bytes memory actual, bytes memory expected) private pure returns (bool) {
        return keccak256(actual) == keccak256(expected);
    }

    /// @dev First four bytes of `data`; callers must have checked `data.length >= 4`.
    function _selector(bytes memory data) private pure returns (bytes4 result) {
        assembly ("memory-safe") {
            result := mload(add(data, 32))
        }
    }

    /// @dev `data` without its 4-byte selector. The only memory slice in this library: the
    ///      middle call's payload is nested `bytes`, so it cannot be reached as calldata.
    ///      Copies whole words and may write up to 31 bytes past `out`'s length, which stays
    ///      inside the word-aligned allocation `new bytes` made for it.
    function _afterSelector(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);

        assembly ("memory-safe") {
            let source := add(data, 36)
            let destination := add(out, 32)
            let end := add(destination, mload(out))
            for {} lt(destination, end) {} {
                mstore(destination, mload(source))
                source := add(source, 32)
                destination := add(destination, 32)
            }
        }
    }
}
