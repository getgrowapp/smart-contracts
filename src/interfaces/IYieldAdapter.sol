// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IYieldAdapter
/// @notice Uniform interface for protocol-specific yield operations, parameterized by venue.
/// @dev One adapter serves every venue of a single protocol and holds no per-venue state. `vault`
///      is the identifier that protocol keys its own API by — the share token for ERC-4626 venues
///      (Euler EVault, Euler Earn, Morpho VaultV2 wrapper), the caToken for Compound-style markets
///      (CapyFi), and the reserve's underlying for Aave V3.
///
///      Adapters answer only "how do I transact with this venue" and "is it genuine". Which venues
///      Grow permits, and each pinned `(asset, positionToken)` pair, live in the registry.
interface IYieldAdapter {
    /// @notice Executor authorized to call state-changing adapter methods.
    function executor() external view returns (address);

    /// @notice Underlying token deposited into `vault` (e.g. USDC).
    /// @param vault Venue identifier.
    /// @return The underlying ERC-20 token address.
    function asset(address vault) external view returns (address);

    /// @notice Token representing a position in `vault` (e.g. aToken, ERC-4626 share).
    /// @param vault Venue identifier.
    /// @return The position ERC-20 token address.
    function positionToken(address vault) external view returns (address);

    /// @notice Expected position tokens for depositing `assets`, at current venue state.
    /// @param vault Venue identifier.
    /// @param assets Underlying amount to quote.
    /// @return shares Expected position tokens.
    function previewDeposit(address vault, uint256 assets) external view returns (uint256 shares);

    /// @notice Expected underlying for redeeming `shares`, at current venue state.
    /// @param vault Venue identifier.
    /// @param shares Position-token amount to quote.
    /// @return assets Expected underlying.
    function previewRedeem(address vault, uint256 shares) external view returns (uint256 assets);

    /// @notice Deposit `assets` (already held by the adapter) into `vault`, crediting position
    ///         tokens directly to `receiver`.
    /// @param vault Venue identifier.
    /// @param assets Underlying amount the caller transferred to the adapter.
    /// @param receiver Recipient of the minted position tokens.
    /// @return shares Position tokens credited to `receiver`.
    function deposit(address vault, uint256 assets, address receiver)
        external
        returns (uint256 shares);

    /// @notice Redeem `shares` (already held by the adapter) from `vault`, sending underlying
    ///         directly to `receiver`.
    /// @param vault Venue identifier.
    /// @param shares Position-token amount the caller transferred to the adapter.
    /// @param receiver Recipient of the withdrawn underlying.
    /// @return assets Underlying sent to `receiver`.
    function redeem(address vault, uint256 shares, address receiver)
        external
        returns (uint256 assets);
}
