// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IGetEquityMarket
/// @notice Buy spends settlement and receives the inventory token. Sell does the reverse.
interface IGetEquityMarket {
    function calculateBuyCost(address token, uint256 amount)
        external
        view
        returns (uint256 baseCost, uint256 fee, uint256 totalCost);

    function buy(address token, uint256 amount, uint256 maxCost) external;

    function calculateSellPayout(address token, uint256 amount)
        external
        view
        returns (uint256 grossPayout, uint256 fee, uint256 netPayout);

    function sell(address token, uint256 amount, uint256 minPayout) external;
}
