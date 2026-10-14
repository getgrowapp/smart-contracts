// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IAaveV4Hub
/// @notice Hub calls the yield adapter needs. Listing is per asset, and share conversion is how
///         a spoke position accrues without minting a token.
interface IAaveV4Hub {
    /// @notice Whether `spoke` is listed for `assetId`.
    function isSpokeListed(uint256 assetId, address spoke) external view returns (bool);

    /// @notice Shares minted by adding `assets` of `assetId` at the current exchange rate.
    function previewAddByAssets(uint256 assetId, uint256 assets) external view returns (uint256);

    /// @notice Assets returned by removing `shares` of `assetId` at the current exchange rate.
    function previewRemoveByShares(uint256 assetId, uint256 shares)
        external
        view
        returns (uint256);
}
