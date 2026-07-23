// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IEulerEarn} from "../interfaces/IEulerEarn.sol";
import {IEulerEarnFactory} from "../interfaces/IEulerEarnFactory.sol";
import {AbstractEulerAdapter} from "./AbstractEulerAdapter.sol";

/// @title EulerEarnAdapter
/// @notice Immutable GrowYield adapter for one Euler Earn vault (direct or wrapped).
/// @dev Authenticity is proven by the pinned EulerEarnFactory's `isVault` registry.
///      When `routingTarget` is set, the vault must be locked and route only through
///      that factory-registered strategy. Underlying is read from `vault.asset()`.
///      Grow risk approval is registry inclusion.
/// @custom:security-contact security@getgrowapp.co
contract EulerEarnAdapter is AbstractEulerAdapter {
    /// @notice Canonical EulerEarnFactory used to authenticate vault and routing target.
    IEulerEarnFactory public immutable factory;

    /// @notice Optional yield venue for wrapped mode; zero for direct Earn deposits.
    IERC4626 public immutable routingTarget;

    error VaultNotLocked();
    error RoutingTargetMismatch();
    error RoutingTargetNotEnabled();
    error RoutingTargetNotAllowed();

    /// @param factory_ Canonical Euler Earn factory (e.g. Base `eulerEarnFactory`).
    /// @param vault_ Factory-created Earn vault (position token).
    /// @param routingTarget_ Expected `supplyQueue(0)` / `withdrawQueue(0)` when wrapped;
    ///        `address(0)` for direct deposits into `vault_`.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(
        IEulerEarnFactory factory_,
        IERC4626 vault_,
        IERC4626 routingTarget_,
        address executor_
    ) AbstractEulerAdapter(vault_, vault_.asset(), executor_) {
        if (address(factory_).code.length == 0) revert Invalid();
        factory = factory_;
        routingTarget = routingTarget_;
        _assertCanonical();
    }

    /// @dev Re-validates factory authenticity, optional wrapped routing, and asset binding.
    function _assertCanonical() internal view override {
        if (!factory.isVault(address(vault))) revert NonCanonical();
        if (vault.asset() != asset) revert AssetMismatch();
        if (address(routingTarget) != address(0)) {
            if (!factory.isVault(address(routingTarget))) revert NonCanonical();
            if (!factory.isStrategyAllowed(address(routingTarget))) revert RoutingTargetNotAllowed();
            _assertWrappedRouting(IEulerEarn(address(vault)));
        }
    }

    /// @dev Requires renounced governance and a single pinned routing target.
    function _assertWrappedRouting(IEulerEarn earn) internal view {
        if (earn.owner() != address(0) || earn.pendingOwner() != address(0)) {
            revert VaultNotLocked();
        }
        if (earn.curator() != address(0)) revert VaultNotLocked();

        if (earn.supplyQueueLength() != 1 || earn.withdrawQueueLength() != 1) {
            revert VaultNotLocked();
        }
        if (
            address(earn.supplyQueue(0)) != address(routingTarget)
                || address(earn.withdrawQueue(0)) != address(routingTarget)
        ) revert RoutingTargetMismatch();

        if (!earn.config(routingTarget).enabled) revert RoutingTargetNotEnabled();
    }
}
