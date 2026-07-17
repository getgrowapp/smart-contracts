// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Exact Aave V3 data-provider method used to resolve reserve tokens.
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
