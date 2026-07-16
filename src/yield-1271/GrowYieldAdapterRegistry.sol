// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IGrowYieldAdapterRegistry, IYieldAdapter} from "./IGrowYield1271.sol";

/**
 * @notice Governance-owned venue adapter allowlist with directional gating.
 *
 * @dev Replaces the protocol-keyed venue registry (GrowYieldRegistryV6): all
 *      venue-specific validation now lives in the adapter contracts themselves
 *      (construction-time config checks plus deposit-time drift re-checks), so the
 *      registry reduces to "which adapter contracts has governance approved, and in
 *      which direction". Owner should be a Safe or TimelockController.
 *
 *      `canDeposit` and `canRedeem` are independent so governance can close a venue
 *      to new deposits while leaving exits open (wind-down mode).
 */
contract GrowYieldAdapterRegistry is Ownable2Step, IGrowYieldAdapterRegistry {
    struct AdapterPermissions {
        bool canDeposit;
        bool canRedeem;
    }

    mapping(address adapter => AdapterPermissions) public permissions;

    event AdapterSet(address indexed adapter, bool canDeposit, bool canRedeem);

    error Invalid();

    constructor(address owner_) Ownable(owner_) {}

    /**
     * @notice Set directional permissions for `adapter`.
     * @dev When enabling, the adapter must be a deployed contract exposing nonzero
     *      `asset()` / `positionToken()`; disabling has no preconditions so a broken
     *      adapter can always be delisted.
     */
    function setAdapter(address adapter, bool canDeposit_, bool canRedeem_) external onlyOwner {
        if (adapter == address(0)) revert Invalid();

        if (canDeposit_ || canRedeem_) {
            if (
                adapter.code.length == 0 || IYieldAdapter(adapter).asset() == address(0)
                    || IYieldAdapter(adapter).positionToken() == address(0)
            ) revert Invalid();
        }

        permissions[adapter] = AdapterPermissions({canDeposit: canDeposit_, canRedeem: canRedeem_});

        emit AdapterSet(adapter, canDeposit_, canRedeem_);
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function canDeposit(address adapter) external view returns (bool) {
        return permissions[adapter].canDeposit;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function canRedeem(address adapter) external view returns (bool) {
        return permissions[adapter].canRedeem;
    }
}
