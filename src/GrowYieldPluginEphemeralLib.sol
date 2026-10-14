// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPluginExecutor} from "@alchemy/msca/interfaces/IPluginExecutor.sol";

import {Protocol} from "./interfaces/IGrowYieldAdapterRegistry.sol";
import {IGrowYieldExecutor, MAX_OPS, Operation} from "./interfaces/IGrowYieldExecutor.sol";

/// @title GrowYieldPluginEphemeralLib
/// @notice Per-batch ERC20 approve → executor.execute → revoke via `executeFromPluginExternal`.
/// @dev Spender is always the account's configured executor; no standing allowances remain.
library GrowYieldPluginEphemeralLib {
    function executeWithEphemeralAllowance(address executor, Operation[] calldata ops)
        internal
        returns (bytes memory result)
    {
        address[MAX_OPS] memory tokens;
        uint256 tokenCount = _uniqueSourceTokens(executor, ops, tokens);

        IPluginExecutor pluginExecutor = IPluginExecutor(msg.sender);

        for (uint256 i; i < tokenCount; ++i) {
            _pluginApprove(pluginExecutor, tokens[i], executor, type(uint256).max);
        }

        result = pluginExecutor.executeFromPluginExternal(
            executor, 0, abi.encodeCall(IGrowYieldExecutor.execute, (ops))
        );

        for (uint256 i; i < tokenCount; ++i) {
            _pluginApprove(pluginExecutor, tokens[i], executor, 0);
        }
    }

    /// @dev Aave V4 source tokens are not pulled by the executor. The account calls the spoke, and
    ///      the spoke pulls the underlying. Approving the venue on a redeem would call a contract
    ///      that is not a token.
    function _uniqueSourceTokens(
        address executor,
        Operation[] calldata ops,
        address[MAX_OPS] memory tokens
    ) private view returns (uint256 tokenCount) {
        uint256 count = ops.length;
        for (uint256 i; i < count; ++i) {
            if (IGrowYieldExecutor(executor).vaultProtocol(ops[i].vault) == Protocol.AAVE_V4) {
                continue;
            }
            address token = ops[i].sourceToken;
            bool seen;
            for (uint256 j; j < tokenCount; ++j) {
                if (tokens[j] == token) {
                    seen = true;
                    break;
                }
            }
            if (!seen) tokens[tokenCount++] = token;
        }
    }

    function _pluginApprove(
        IPluginExecutor pluginExecutor,
        address token,
        address spender,
        uint256 amount
    ) private {
        pluginExecutor.executeFromPluginExternal(
            token, 0, abi.encodeCall(IERC20.approve, (spender, amount))
        );
    }
}
