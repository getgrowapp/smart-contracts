// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IEulerEVaultFactory} from "../interfaces/IEulerEVaultFactory.sol";
import {AbstractEulerAdapter} from "./AbstractEulerAdapter.sol";

/// @title EulerEVaultAdapter
/// @notice Immutable GrowYield adapter for one Euler EVK (EVault) market.
/// @dev Authenticity is proven by the pinned EVK GenericFactory's `isProxy` registry.
///      Underlying is read from `vault.asset()` at construction and re-checked on
///      every operation. Grow risk approval is registry inclusion.
/// @custom:security-contact security@getgrowapp.co
contract EulerEVaultAdapter is AbstractEulerAdapter {
    /// @notice Canonical EVK GenericFactory used to authenticate the vault proxy.
    IEulerEVaultFactory public immutable factory;

    /// @param factory_ Canonical EVK factory (e.g. Base `eVaultFactory`).
    /// @param vault_ Factory-created EVault used as the position token.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(IEulerEVaultFactory factory_, IERC4626 vault_, address executor_)
        AbstractEulerAdapter(vault_, vault_.asset(), executor_)
    {
        if (address(factory_).code.length == 0) revert Invalid();
        factory = factory_;
        _assertCanonical();
    }

    /// @dev Requires a factory-registered proxy whose underlying has not drifted.
    function _assertCanonical() internal view override {
        if (!factory.isProxy(address(vault))) revert NonCanonical();
        if (vault.asset() != asset) revert AssetMismatch();
    }
}
