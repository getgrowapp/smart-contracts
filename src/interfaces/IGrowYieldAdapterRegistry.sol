// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IGrowYieldAdapterRegistry
/// @notice Deployment-fixed directional permissions for a bounded set of adapters.
interface IGrowYieldAdapterRegistry {
    /// @notice Constructor configuration for one adapter.
    struct AdapterConfig {
        address adapter;
        bool canDeposit;
        bool canRedeem;
    }

    /// @notice Emitted once for each adapter fixed into the registry.
    event AdapterConfigured(
        address indexed adapter, bool canDeposit, bool canRedeem, bytes32 codeHash
    );

    /// @notice The executor, adapter, or token configuration is invalid.
    error Invalid();

    /// @notice Executor every registered adapter must authorize.
    function executor() external view returns (address);

    /// @notice True if new deposits may be routed through `adapter`.
    function canDeposit(address adapter) external view returns (bool);

    /// @notice True if redemptions may be routed through `adapter`.
    function canRedeem(address adapter) external view returns (bool);

    /// @notice Deployment-time code hash for `adapter`.
    function adapterCodeHash(address adapter) external view returns (bytes32);

    /// @notice Number of deployment-fixed adapters.
    function adapterCount() external view returns (uint256);

    /// @notice Adapter at `index` in constructor order.
    function adapterAt(uint256 index) external view returns (address);
}
