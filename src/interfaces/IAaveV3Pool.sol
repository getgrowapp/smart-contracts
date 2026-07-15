// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Exact subset of Aave V3 IPool used by GrowAllocationControllerV8.
 * @dev Signatures match aave-v3-origin v3.3.0 `IPool.supply` / `IPool.withdraw`
 *      (same selectors as Base Pool `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`).
 */
interface IAaveV3Pool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}
