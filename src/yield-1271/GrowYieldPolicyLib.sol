// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    Call,
    IERC6900Account
} from "@erc6900/reference-implementation/interfaces/IERC6900Account.sol";

import {
    IGrowYieldAdapterRegistry,
    IGrowYieldExecutor,
    IYieldAdapter,
    Operation,
    OperationKind
} from "./IGrowYield1271.sol";

/**
 * @notice Static calldata policy for Grow yield automation batches.
 *
 * @dev Because every venue hides behind the uniform `IYieldAdapter` interface, one
 *      decode routine validates every flow (deposit, redeem, reallocation, multi-venue
 *      rebalance) — there is no per-protocol branch.
 *
 *      The only batch shape accepted is the canonical form
 *
 *          [approve(token_1, max) ... approve(token_k, max),
 *           executor.execute(ops),
 *           approve(token_1, 0) ... approve(token_k, 0)]
 *
 *      where `token_1..token_k` are exactly the unique source tokens of `ops` in order
 *      of first appearance (deposit -> `adapter.asset()`, redeem ->
 *      `adapter.positionToken()`). Every approval names the executor as spender; the
 *      trailing zero-approvals guarantee no standing allowance survives the batch.
 *
 *      Adapters are checked against the executor's registry *before* any staticcall
 *      into them, so only governance-approved code is ever consulted during signature
 *      validation. Adapter `asset()`/`positionToken()` are immutables, keeping
 *      validation-phase state access minimal (ERC-7562-friendly).
 *
 *      Amounts inside `ops` are intentionally unconstrained: the executor pins the
 *      output receiver to the account and enforces the loss cap, so amount choice
 *      cannot redirect or burn funds (granular partial deposits are a feature).
 *
 *      Callers must wrap in try/catch — malformed calldata reverts on `abi.decode`;
 *      the policy signer maps reverts to EIP-1271 invalid.
 */
library GrowYieldPolicyLib {
    /// @dev Validation-phase gas bound; covers deposit, withdraw, reallocate, and
    ///      small multi-venue rebalances.
    uint256 internal constant MAX_OPS = 4;

    bytes4 private constant APPROVE = bytes4(keccak256("approve(address,uint256)"));

    function isAllowed(
        address account,
        address executor,
        IGrowYieldAdapterRegistry registry,
        bytes memory callData
    ) internal view returns (bool) {
        if (callData.length < 4 || _selector(callData) != IERC6900Account.executeBatch.selector) return false;

        Call[] memory calls = abi.decode(_args(callData), (Call[]));

        // Shape: k approve-max calls, one execute call, k approve-zero calls.
        if (calls.length < 3 || calls.length % 2 == 0) return false;
        uint256 approvals = (calls.length - 1) / 2;

        Operation[] memory ops = _decodeExecute(account, executor, calls[approvals]);
        if (ops.length == 0) return false;

        address[] memory tokens = _sourceTokens(registry, ops);
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
        if (ops.length == 0 || ops.length > MAX_OPS || args.length != 64 + ops.length * 96) {
            return new Operation[](0);
        }
    }

    /**
     * @dev Unique source tokens of `ops` in order of first appearance. Returns an
     *      empty array if any adapter is not registry-approved for its direction —
     *      checked before any staticcall into the adapter.
     */
    function _sourceTokens(IGrowYieldAdapterRegistry registry, Operation[] memory ops)
        private
        view
        returns (address[] memory tokens)
    {
        tokens = new address[](ops.length);
        uint256 unique;

        for (uint256 i; i < ops.length; ++i) {
            Operation memory op = ops[i];
            bool isDeposit = op.kind == OperationKind.DEPOSIT;

            if (isDeposit
                    ? !registry.canDeposit(address(op.adapter))
                    : !registry.canRedeem(address(op.adapter))) return new address[](0);

            address token = isDeposit ? op.adapter.asset() : op.adapter.positionToken();
            if (token == address(0)) return new address[](0);

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

        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }
}
