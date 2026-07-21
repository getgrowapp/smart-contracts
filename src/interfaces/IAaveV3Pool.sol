// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Exact subset of Aave V3 IPool used by AaveV3Adapter.
/// @dev Matches `IPool.supply` and `IPool.withdraw`.
interface IAaveV3Pool {
    /// @notice Supplies `amount` of `asset`, crediting aTokens to `onBehalfOf`.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Burns aTokens and sends `amount` of `asset` to `to`; returns the amount withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
