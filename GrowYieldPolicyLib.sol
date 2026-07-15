// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Call, IModularAccount} from
    "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {
    IGrowYieldExecutor,
    IGrowYieldRegistry,
    IGrowYieldTypes
} from "../yield-v6/IGrowYieldSystem.sol";

/**
 * @notice Static policy for Grow yield automation batches.
 * @dev Approve token must equal the operation's actual source token:
 *      - depositAll → entry venue underlying (must match registry `asset`)
 *      - withdrawAll → exit venue position token
 *      - reallocateAll → source exit venue position token
 *
 *      Callers should wrap in try/catch — malformed calldata or unknown venues
 *      can revert; the policy signer maps reverts → EIP-1271 invalid.
 */
library GrowYieldPolicyLib {
    bytes4 private constant APPROVE =
        bytes4(keccak256("approve(address,uint256)"));

    bytes4 private constant REALLOCATE =
        bytes4(
            keccak256(
                "reallocateAll(uint8,address,address,uint8,address,address)"
            )
        );

    function isAllowed(
        address account,
        address executor,
        IGrowYieldRegistry registry,
        bytes memory callData
    ) internal view returns (bool) {
        if (
            callData.length < 4
                || _selector(callData) != IModularAccount.executeBatch.selector
        ) return false;

        Call[] memory calls = abi.decode(_args(callData), (Call[]));

        if (calls.length != 3) return false;

        Call memory approveMax = calls[0];
        Call memory operation = calls[1];
        Call memory approveZero = calls[2];

        if (
            !_basic(account, approveMax) || !_basic(account, operation)
                || !_basic(account, approveZero) || operation.target != executor
                || approveMax.target != approveZero.target
                || !_approval(approveMax, executor, type(uint256).max)
                || !_approval(approveZero, executor, 0)
        ) return false;

        address expectedToken = _sourceToken(registry, operation.data);
        return expectedToken != address(0) && approveMax.target == expectedToken;
    }

    function _sourceToken(IGrowYieldRegistry registry, bytes memory data)
        private
        view
        returns (address)
    {
        bytes4 selector = _selector(data);

        if (selector == IGrowYieldExecutor.depositAll.selector) {
            if (data.length != 100) return address(0);
            (
                IGrowYieldTypes.Protocol protocol,
                address target,
                address asset
            ) = abi.decode(
                _args(data),
                (IGrowYieldTypes.Protocol, address, address)
            );
            IGrowYieldTypes.Venue memory venue =
                registry.entryVenue(protocol, target, asset);
            return venue.asset == asset ? asset : address(0);
        }

        if (selector == IGrowYieldExecutor.withdrawAll.selector) {
            if (data.length != 100) return address(0);
            (
                IGrowYieldTypes.Protocol protocol,
                address target,
                address assetHint
            ) = abi.decode(
                _args(data),
                (IGrowYieldTypes.Protocol, address, address)
            );
            return registry.exitVenue(protocol, target, assetHint).positionToken;
        }

        if (selector == REALLOCATE) {
            if (data.length != 196) return address(0);
            (
                IGrowYieldTypes.Protocol sourceProtocol,
                address sourceTarget,
                address sourceAssetHint,
                ,
                ,
            ) = abi.decode(
                _args(data),
                (
                    IGrowYieldTypes.Protocol,
                    address,
                    address,
                    IGrowYieldTypes.Protocol,
                    address,
                    address
                )
            );
            return registry.exitVenue(
                sourceProtocol, sourceTarget, sourceAssetHint
            ).positionToken;
        }

        return address(0);
    }

    function _approval(
        Call memory call_,
        address executor,
        uint256 amount
    ) private pure returns (bool) {
        if (call_.data.length != 68 || _selector(call_.data) != APPROVE) {
            return false;
        }

        (address spender, uint256 actualAmount) =
            abi.decode(_args(call_.data), (address, uint256));

        return spender == executor && actualAmount == amount;
    }

    function _basic(
        address account,
        Call memory call_
    ) private pure returns (bool) {
        return call_.value == 0 && call_.target != address(0)
            && call_.target != account && call_.data.length >= 4;
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
