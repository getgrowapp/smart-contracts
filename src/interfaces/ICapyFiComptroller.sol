// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal Compound-v2 Comptroller surface used by CapyFi.
interface ICapyFiComptroller {
    /// @notice Market metadata for a caToken.
    /// @return isListed Whether the market is admitted by the Comptroller.
    /// @return collateralFactorMantissa Collateral factor scaled by 1e18.
    /// @return isComped Whether suppliers/borrowers earn incentive rewards.
    function markets(address caToken)
        external
        view
        returns (bool isListed, uint256 collateralFactorMantissa, bool isComped);
}
