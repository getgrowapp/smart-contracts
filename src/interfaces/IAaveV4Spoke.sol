// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IAaveV4Spoke
/// @notice Spoke calls the account makes. Supply shares live on the spoke for `onBehalfOf`.
/// @dev `supply`, `withdraw`, and `setUsingAsCollateral` succeed when the caller is `onBehalfOf`.
///      The yield path has the account make the call, so the spoke sees the account.
interface IAaveV4Spoke {
    /// @notice Reserve fields the adapter reads. Field order matches the spoke's return tuple.
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    /// @notice Pull `amount` of the reserve's underlying from the caller and credit shares to
    ///         `onBehalfOf`.
    /// @return shares Shares credited.
    /// @return assets Underlying taken.
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 shares, uint256 assets);

    /// @notice Burn supply from `onBehalfOf` and send the underlying to the caller.
    ///         `amount` above the supplied balance withdraws the whole position.
    /// @return shares Shares burned.
    /// @return assets Underlying sent to the caller.
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 shares, uint256 assets);

    /// @notice Turn collateral on or off for `onBehalfOf`. A repeat of the current flag is a no-op.
    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf)
        external;

    /// @notice Reserve data for `reserveId`.
    function getReserve(uint256 reserveId) external view returns (Reserve memory);

    /// @notice Shares `user` has supplied to `reserveId`.
    function getUserSuppliedShares(uint256 reserveId, address user)
        external
        view
        returns (uint256);

    /// @notice Whether `user` is using `reserveId` as collateral, and whether they are borrowing it.
    function getUserReserveStatus(uint256 reserveId, address user)
        external
        view
        returns (bool usingAsCollateral, bool borrowing);
}
