// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {AaveV4ReserveVenue} from "../AaveV4ReserveVenue.sol";
import {IAaveV4Hub} from "../interfaces/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../interfaces/IAaveV4Spoke.sol";
import {IAaveV4SpokeAdapter} from "../interfaces/IAaveV4SpokeAdapter.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title AaveV4SpokeAdapter
/// @notice One adapter for every spoke on a single Aave V4 hub.
/// @dev The hub is pinned. A spoke is a venue only after the registry deploys its
///      `AaveV4ReserveVenue` and admits it. Supply credits shares to the account on the spoke;
///      nothing is minted. The account calls the spoke, so Aave sees that account as the caller.
///      This adapter quotes the reserve and reads share balances. It does not call the spoke.
///
///      The executor leaves the reserve enabled as collateral on deposit and turns collateral off
///      on a full redemption. Redemptions do not require the spoke to still be listed: the
///      executor blocks new deposits when the hub delists it, and still lets the account leave.
/// @custom:security-contact security@getgrowapp.co
contract AaveV4SpokeAdapter is IAaveV4SpokeAdapter {
    /// @notice Hub that must list every reserve this adapter touches.
    address public immutable hub;

    /// @notice Executor this adapter is bound to. The account, not this adapter, calls the spoke.
    address public immutable executor;

    error Invalid();
    error OnlyExecutor();
    error UnknownReserve();
    /// @notice `deposit` and `redeem` do not call the spoke. The account does.
    error AccountCallsSpoke();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @param hub_ Hub that must list every reserve this adapter touches.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(IAaveV4Hub hub_, address executor_) {
        if (address(hub_).code.length == 0 || executor_.code.length == 0) revert Invalid();
        hub = address(hub_);
        executor = executor_;
    }

    /// @inheritdoc IYieldAdapter
    function asset(address vault) external view returns (address) {
        return _reserve(vault).underlying;
    }

    /// @inheritdoc IYieldAdapter
    /// @dev The venue itself stands in for a position token. Share balances are not this token.
    function positionToken(address vault) external pure returns (address) {
        return vault;
    }

    /// @inheritdoc IAaveV4SpokeAdapter
    function spokeListed(address vault) external view returns (bool) {
        IAaveV4Spoke.Reserve memory reserve = _reserve(vault);
        return address(reserve.hub) == hub
            && IAaveV4Hub(hub).isSpokeListed(reserve.assetId, _spoke(vault));
    }

    /// @inheritdoc IAaveV4SpokeAdapter
    function suppliedShares(address vault, address user) external view returns (uint256) {
        return IAaveV4Spoke(_spoke(vault)).getUserSuppliedShares(_reserveId(vault), user);
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(address vault, uint256 assets) external view returns (uint256) {
        IAaveV4Spoke.Reserve memory reserve = _reserve(vault);
        if (assets == 0) return 0;
        return IAaveV4Hub(reserve.hub).previewAddByAssets(reserve.assetId, assets);
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(address vault, uint256 shares) external view returns (uint256) {
        IAaveV4Spoke.Reserve memory reserve = _reserve(vault);
        if (shares == 0) return 0;
        return IAaveV4Hub(reserve.hub).previewRemoveByShares(reserve.assetId, shares);
    }

    /// @inheritdoc IYieldAdapter
    /// @dev The account calls the spoke. Calling this would make the adapter the position manager.
    function deposit(address, uint256, address) external view onlyExecutor returns (uint256) {
        revert AccountCallsSpoke();
    }

    /// @inheritdoc IYieldAdapter
    /// @dev The account calls the spoke. The spoke pays the account, so there is nothing to forward.
    function redeem(address, uint256, address) external view onlyExecutor returns (uint256) {
        revert AccountCallsSpoke();
    }

    function _spoke(address vault) private view returns (address) {
        return AaveV4ReserveVenue(vault).spoke();
    }

    function _reserveId(address vault) private view returns (uint256) {
        return AaveV4ReserveVenue(vault).reserveId();
    }

    function _reserve(address vault) private view returns (IAaveV4Spoke.Reserve memory reserve) {
        address spoke = _spoke(vault);
        if (spoke.code.length == 0) revert UnknownReserve();
        reserve = IAaveV4Spoke(spoke).getReserve(_reserveId(vault));
        if (reserve.underlying.code.length == 0) revert UnknownReserve();
    }
}
