// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IGrowYieldAccountCall
/// @notice Spoke calls the yield executor asks the account to make.
/// @dev Aave V4 credits and debits `onBehalfOf` only when the caller is that address. These
///      functions run as the account, so the spoke's caller and `onBehalfOf` are both the account.
///      The yield plugin performs them only for a venue its executor has admitted, and only when
///      that executor is the caller.
interface IGrowYieldAccountCall {
    /// @notice Approve the reserve's underlying to `spoke`, supply `amount` for this account,
    ///         then clear the allowance.
    function supplyOnSpoke(address spoke, uint256 reserveId, uint256 amount) external;

    /// @notice Withdraw `amount` of underlying from this account's supply on `spoke`. The spoke
    ///         pays this account. `type(uint256).max` withdraws the whole reserve.
    function withdrawOnSpoke(address spoke, uint256 reserveId, uint256 amount) external;

    /// @notice Set whether this account uses `reserveId` as collateral.
    function setSpokeCollateral(address spoke, uint256 reserveId, bool usingAsCollateral)
        external;
}
