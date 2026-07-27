// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Compound-v2 CErc20 / CapyFi caToken surface.
interface ICapyFiCaToken is IERC20 {
    /// @notice Comptroller that lists and gates this market.
    function comptroller() external view returns (address);

    /// @notice Underlying ERC-20 supplied to this market.
    function underlying() external view returns (address);

    /// @notice Exchange rate mantissa (scaled by 1e18) as of the last accrual.
    /// @dev Stale between interactions. `exchangeRateCurrent` accrues first but writes state, so
    ///      a `view` caller cannot reach it; the fields below let one replay `accrueInterest`.
    function exchangeRateStored() external view returns (uint256);

    /// @notice Block height at which interest was last accrued.
    function accrualBlockNumber() external view returns (uint256);

    /// @notice Per-block borrow rate mantissa (scaled by 1e18).
    function borrowRatePerBlock() external view returns (uint256);

    /// @notice Total outstanding borrows as of the last accrual.
    function totalBorrows() external view returns (uint256);

    /// @notice Protocol reserves as of the last accrual.
    function totalReserves() external view returns (uint256);

    /// @notice Share of accrued interest routed to reserves (scaled by 1e18).
    function reserveFactorMantissa() external view returns (uint256);

    /// @notice Underlying held by the market.
    function getCash() external view returns (uint256);

    /// @notice Supply `mintAmount` of underlying; credits caTokens to `msg.sender`.
    /// @return errorCode Compound-style error code; `0` means success.
    function mint(uint256 mintAmount) external returns (uint256 errorCode);

    /// @notice Redeem `redeemTokens` caTokens for underlying sent to `msg.sender`.
    /// @return errorCode Compound-style error code; `0` means success.
    function redeem(uint256 redeemTokens) external returns (uint256 errorCode);
}
