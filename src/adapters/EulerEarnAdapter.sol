// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IEulerEarn} from "../interfaces/IEulerEarn.sol";
import {IEulerEarnFactory} from "../interfaces/IEulerEarnFactory.sol";
import {AbstractEulerAdapter} from "./AbstractEulerAdapter.sol";

/// @title EulerEarnAdapter
/// @notice Immutable GrowYield adapter for one permanently locked Euler Earn vault.
/// @dev Authenticity is proven by the pinned EulerEarnFactory's `isVault` registry.
///      The vault must have renounced governance and route deposits/redemptions only
///      through the pinned `childStrategy`, whose underlying matches `vault.asset()`.
///      Grow risk approval is registry inclusion.
/// @custom:security-contact security@getgrowapp.co
contract EulerEarnAdapter is AbstractEulerAdapter {
    /// @notice Canonical EulerEarnFactory used to authenticate the vault.
    IEulerEarnFactory public immutable factory;

    /// @notice Sole child strategy the locked vault may route through.
    IERC4626 public immutable childStrategy;

    error VaultNotLocked();
    error ChildStrategyMismatch();
    error ChildAssetMismatch();
    error ChildNotEnabled();

    /// @param factory_ Canonical Euler Earn factory (e.g. Base `eulerEarnFactory`).
    /// @param vault_ Factory-created, permanently locked Earn vault (position token).
    /// @param childStrategy_ Expected `supplyQueue(0)` / `withdrawQueue(0)` strategy.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(
        IEulerEarnFactory factory_,
        IERC4626 vault_,
        IERC4626 childStrategy_,
        address executor_
    ) AbstractEulerAdapter(vault_, vault_.asset(), executor_) {
        if (address(factory_).code.length == 0 || address(childStrategy_).code.length == 0) {
            revert Invalid();
        }
        factory = factory_;
        childStrategy = childStrategy_;
        _assertCanonical();
    }

    /// @dev Re-validates factory authenticity, lock state, and child binding before each op.
    function _assertCanonical() internal view override {
        if (!factory.isVault(address(vault))) revert NonCanonical();
        if (vault.asset() != asset) revert AssetMismatch();
        _assertLocked(IEulerEarn(address(vault)));
    }

    /// @dev Requires renounced governance and a single pinned child with matching underlying.
    function _assertLocked(IEulerEarn earn) internal view {
        if (earn.owner() != address(0) || earn.pendingOwner() != address(0)) {
            revert VaultNotLocked();
        }
        if (earn.curator() != address(0)) revert VaultNotLocked();

        if (earn.supplyQueueLength() != 1 || earn.withdrawQueueLength() != 1) {
            revert VaultNotLocked();
        }
        if (
            address(earn.supplyQueue(0)) != address(childStrategy)
                || address(earn.withdrawQueue(0)) != address(childStrategy)
        ) revert ChildStrategyMismatch();

        if (childStrategy.asset() != asset) revert ChildAssetMismatch();

        if (!earn.config(childStrategy).enabled) revert ChildNotEnabled();
    }
}
