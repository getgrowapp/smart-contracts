// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEulerEarnFactory} from "../interfaces/IEulerEarnFactory.sol";
import {AbstractEulerAdapter} from "./AbstractEulerAdapter.sol";

/// @title EulerEarnAdapter
/// @notice GrowYield adapter for every Euler Earn vault of one EulerEarnFactory.
/// @dev Authenticity is proven by the pinned EulerEarnFactory's `isVault` registry, re-checked on
///      every operation so a vault the factory no longer recognizes fails closed. The venue's
///      underlying is pinned by the registry and re-verified by the executor.
/// @custom:security-contact security@getgrowapp.co
contract EulerEarnAdapter is AbstractEulerAdapter {
    /// @notice Canonical EulerEarnFactory used to authenticate vaults.
    IEulerEarnFactory public immutable factory;

    /// @param factory_ Canonical Euler Earn factory (e.g. Base `eulerEarnFactory`).
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(IEulerEarnFactory factory_, address executor_) AbstractEulerAdapter(executor_) {
        if (address(factory_).code.length == 0) revert Invalid();
        factory = factory_;
    }

    /// @dev Requires a factory-registered Earn vault.
    function _assertCanonical(address vault) internal view override {
        if (!factory.isVault(vault)) revert NonCanonical();
    }
}
