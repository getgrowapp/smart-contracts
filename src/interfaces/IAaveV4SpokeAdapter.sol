// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IYieldAdapter} from "./IYieldAdapter.sol";

/// @title IAaveV4SpokeAdapter
/// @notice Yield adapter for every spoke on one Aave V4 hub.
/// @dev `vault` is an `AaveV4ReserveVenue`. There is no position token: `positionToken` returns
///      that venue, and balances are `getUserSuppliedShares` on the spoke.
interface IAaveV4SpokeAdapter is IYieldAdapter {
    /// @notice Whether `vault`'s spoke is still listed on the pinned hub for that reserve.
    function spokeListed(address vault) external view returns (bool);

    /// @notice Supplied shares `user` holds on `vault`'s spoke reserve.
    function suppliedShares(address vault, address user) external view returns (uint256);
}
