// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IEulerEVaultFactory} from "../interfaces/IEulerEVaultFactory.sol";
import {AbstractEulerAdapter} from "./AbstractEulerAdapter.sol";

/// @title EulerEVaultAdapter
/// @notice GrowYield adapter for every Euler EVK (EVault) market of one GenericFactory.
/// @dev Authenticity is proven by the pinned EVK GenericFactory's `isProxy` registry, re-checked
///      on every operation so a vault the factory no longer recognizes fails closed. The venue's
///      underlying is pinned by the registry and re-verified by the executor.
/// @custom:security-contact security@getgrowapp.co
contract EulerEVaultAdapter is AbstractEulerAdapter {
    /// @notice Canonical EVK GenericFactory used to authenticate vault proxies.
    IEulerEVaultFactory public immutable factory;

    /// @param factory_ Canonical EVK factory (e.g. Base `eVaultFactory`).
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(IEulerEVaultFactory factory_, address executor_) AbstractEulerAdapter(executor_) {
        if (address(factory_).code.length == 0) revert Invalid();
        factory = factory_;
    }

    /// @dev Requires a factory-registered proxy.
    function _assertCanonical(address vault) internal view override {
        if (!factory.isProxy(vault)) revert NonCanonical();
    }
}
