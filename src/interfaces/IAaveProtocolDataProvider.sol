// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Exact subset of Aave V3 IPoolDataProvider used for onboarding.
 * @dev Signature matches aave-v3-origin v3.3.0 `IPoolDataProvider.getReserveTokensAddresses`
 *      (Base: AaveV3Base.AAVE_PROTOCOL_DATA_PROVIDER).
 */
interface IAaveProtocolDataProvider {
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        );
}
