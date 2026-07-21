// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IEulerEarnFactory} from "../interfaces/IEulerEarnFactory.sol";
import {AbstractEulerAdapter} from "./AbstractEulerAdapter.sol";

/// @title EulerEarnAdapter
/// @author 0xOsiris, Grow
/// @notice Immutable GrowYield adapter for one Euler Earn vault.
/// @dev Authenticity is proven by the pinned EulerEarnFactory's `isVault` registry.
///      The vault's `asset()` is re-checked on every operation against the pinned
///      underlying so a miswired or drifted vault cannot be used silently.
contract EulerEarnAdapter is AbstractEulerAdapter {
    /// @notice Canonical EulerEarnFactory used to authenticate the vault.
    IEulerEarnFactory public immutable factory;

    /// @param factory_ Canonical Euler Earn factory (e.g. Base `eulerEarnFactory`).
    /// @param vault_ Factory-created Earn vault for `asset_`.
    /// @param asset_ Underlying ERC-20 expected by the vault.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(IEulerEarnFactory factory_, IERC4626 vault_, address asset_, address executor_)
        AbstractEulerAdapter(vault_, asset_, executor_)
    {
        if (address(factory_).code.length == 0) revert Invalid();
        factory = factory_;
        _assertCanonical();
    }

    /// @dev Requires a factory-registered Earn vault whose underlying still matches `asset`.
    function _assertCanonical() internal view override {
        if (!factory.isVault(address(vault))) revert NonCanonical();
        if (vault.asset() != asset) revert AssetMismatch();
    }
}
