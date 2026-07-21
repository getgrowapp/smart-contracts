// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IYieldAdapter
/// @notice Uniform interface for protocol-specific yield operations.
interface IYieldAdapter {
    /// @notice Executor authorized to call state-changing adapter methods.
    function executor() external view returns (address);

    /// @notice Underlying token deposited into the venue (e.g. USDC).
    /// @return The underlying ERC-20 token address.
    function asset() external view returns (address);

    /// @notice Token representing the venue position (e.g. aToken, ERC-4626 share).
    /// @return The position ERC-20 token address.
    function positionToken() external view returns (address);

    /// @notice Expected position tokens for depositing `assets`, at current venue state.
    /// @param assets Underlying amount to quote.
    /// @return shares Expected position tokens.
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Expected underlying for redeeming `shares`, at current venue state.
    /// @param shares Position-token amount to quote.
    /// @return assets Expected underlying.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    /// @notice Deposit `assets` (already held by the adapter) into the venue,
    ///         crediting position tokens directly to `receiver`.
    /// @param assets Underlying amount the caller transferred to the adapter.
    /// @param receiver Recipient of the minted position tokens.
    /// @return shares Position tokens credited to `receiver`.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Redeem `shares` (already held by the adapter) from the venue,
    ///         sending underlying directly to `receiver`.
    /// @param shares Position-token amount the caller transferred to the adapter.
    /// @param receiver Recipient of the withdrawn underlying.
    /// @return assets Underlying sent to `receiver`.
    function redeem(uint256 shares, address receiver) external returns (uint256 assets);
}
