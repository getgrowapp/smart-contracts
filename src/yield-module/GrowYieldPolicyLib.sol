// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    Call,
    IModularAccount
} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";

import {IGrowYieldExecutor, Operation} from "./interfaces/IGrowYieldExecutor.sol";

/// @notice Static calldata policy for Grow yield automation batches.
/// @dev Accepts only the canonical form:
///
///          [approve(token_1, max) ... approve(token_k, max),
///           executor.execute(ops),
///           approve(token_1, 0) ... approve(token_k, 0)]
///
///      Tokens are the unique declared operation source tokens in first-appearance
///      order. The executor verifies each declaration before transferring funds.
///      Malformed ABI reverts; the validation module contains it with a self-call.
library GrowYieldPolicyLib {
    /// @dev Validation-phase gas bound; covers deposit, withdraw, reallocate, and
    ///      small multi-venue rebalances.
    uint256 internal constant MAX_OPS = 4;

    uint256 private constant MAX_CALLDATA_LENGTH = 7_000;

    bytes4 private constant APPROVE = bytes4(keccak256("approve(address,uint256)"));

    function isAllowed(address account, address executor, bytes memory callData)
        internal
        pure
        returns (bool)
    {
        if (
            callData.length < 4 || callData.length > MAX_CALLDATA_LENGTH
                || _selector(callData) != IModularAccount.executeBatch.selector
        ) return false;

        Call[] memory calls = abi.decode(_args(callData), (Call[]));
        if (keccak256(callData) != keccak256(abi.encodeCall(IModularAccount.executeBatch, (calls))))
        {
            return false;
        }

        // Shape: k approve-max calls, one execute call, k approve-zero calls.
        if (calls.length < 3 || calls.length % 2 == 0) return false;
        uint256 approvals = (calls.length - 1) / 2;
        if (approvals > MAX_OPS) return false;

        Operation[] memory ops = _decodeExecute(account, executor, calls[approvals]);
        if (ops.length == 0) return false;

        address[] memory tokens = _sourceTokens(ops);
        if (tokens.length == 0 || tokens.length != approvals) return false;

        for (uint256 i; i < approvals; ++i) {
            Call memory maxCall = calls[i];
            Call memory zeroCall = calls[approvals + 1 + i];

            if (
                !_basic(account, maxCall) || !_basic(account, zeroCall)
                    || maxCall.target != tokens[i] || zeroCall.target != tokens[i]
                    || !_approval(maxCall, executor, type(uint256).max)
                    || !_approval(zeroCall, executor, 0)
            ) return false;
        }

        return true;
    }

    /// @dev Validates the middle call and decodes its operations; empty array = reject.
    function _decodeExecute(address account, address executor, Call memory call_)
        private
        pure
        returns (Operation[] memory ops)
    {
        if (
            !_basic(account, call_) || call_.target != executor
                || _selector(call_.data) != IGrowYieldExecutor.execute.selector
        ) return new Operation[](0);

        bytes memory args = _args(call_.data);
        ops = abi.decode(args, (Operation[]));

        // Canonical ABI encoding only: offset word + length word + n static tuples.
        // Rejects oversized buffers that could smuggle unvalidated bytes.
        if (ops.length == 0 || ops.length > MAX_OPS || args.length != 64 + ops.length * 192) {
            return new Operation[](0);
        }
    }

    /// @dev Returns unique source tokens in first-appearance order, or an empty array
    ///      if an operation has a zero adapter or source token.
    function _sourceTokens(Operation[] memory ops) private pure returns (address[] memory tokens) {
        tokens = new address[](ops.length);
        uint256 unique;

        for (uint256 i; i < ops.length; ++i) {
            Operation memory op = ops[i];
            address token = op.sourceToken;
            if (address(op.adapter) == address(0) || token == address(0) || op.minAmountOut == 0) {
                return new address[](0);
            }

            bool seen;
            for (uint256 j; j < unique; ++j) {
                if (tokens[j] == token) {
                    seen = true;
                    break;
                }
            }
            if (!seen) tokens[unique++] = token;
        }

        assembly ("memory-safe") {
            mstore(tokens, unique)
        }
    }

    function _approval(Call memory call_, address executor, uint256 amount)
        private
        pure
        returns (bool)
    {
        if (call_.data.length != 68 || _selector(call_.data) != APPROVE) {
            return false;
        }

        (address spender, uint256 actualAmount) = abi.decode(_args(call_.data), (address, uint256));

        return spender == executor && actualAmount == amount;
    }

    function _basic(address account, Call memory call_) private pure returns (bool) {
        return call_.value == 0 && call_.target != address(0) && call_.target != account
            && call_.data.length >= 4;
    }

    function _selector(bytes memory data) private pure returns (bytes4 result) {
        if (data.length < 4) return bytes4(0);

        assembly ("memory-safe") {
            result := mload(add(data, 32))
        }
    }

    function _args(bytes memory data) private pure returns (bytes memory out) {
        if (data.length < 4) return bytes("");

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
