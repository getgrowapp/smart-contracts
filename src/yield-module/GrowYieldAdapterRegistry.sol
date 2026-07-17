// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGrowYieldAdapterRegistry} from "./interfaces/IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

/// @title GrowYieldAdapterRegistry
/// @notice Immutable-by-design adapter set extended only by deploying a new registry.
/// @dev Configuration is written only in the constructor. Adapters must be direct,
///      non-upgradeable deployments because the executor pins their code hashes.
contract GrowYieldAdapterRegistry is IGrowYieldAdapterRegistry {
    /// @notice Maximum adapters in one fixed registry.
    uint256 public constant MAX_ADAPTERS = 16;

    struct AdapterPermissions {
        bool canDeposit;
        bool canRedeem;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    address public immutable executor;

    mapping(address adapter => AdapterPermissions) private _permissions;

    address[] private _adapters;

    /// @inheritdoc IGrowYieldAdapterRegistry
    mapping(address adapter => bytes32) public adapterCodeHash;

    constructor(address executor_, AdapterConfig[] memory adapters) {
        if (executor_.code.length == 0 || adapters.length == 0 || adapters.length > MAX_ADAPTERS) {
            revert Invalid();
        }
        executor = executor_;

        for (uint256 i; i < adapters.length; ++i) {
            AdapterConfig memory config = adapters[i];
            address adapter = config.adapter;
            if (
                adapter.code.length == 0 || (!config.canDeposit && !config.canRedeem)
                    || adapterCodeHash[adapter] != bytes32(0)
                    || IYieldAdapter(adapter).executor() != executor_
            ) revert Invalid();

            address asset = IYieldAdapter(adapter).asset();
            address position = IYieldAdapter(adapter).positionToken();
            if (asset.code.length == 0 || position.code.length == 0 || asset == position) {
                revert Invalid();
            }

            bytes32 codeHash = adapter.codehash;
            _permissions[adapter] = AdapterPermissions(config.canDeposit, config.canRedeem);
            adapterCodeHash[adapter] = codeHash;
            _adapters.push(adapter);
            emit AdapterConfigured(adapter, config.canDeposit, config.canRedeem, codeHash);
        }
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function canDeposit(address adapter) external view returns (bool) {
        return _permissions[adapter].canDeposit;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function canRedeem(address adapter) external view returns (bool) {
        return _permissions[adapter].canRedeem;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function adapterCount() external view returns (uint256) {
        return _adapters.length;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function adapterAt(uint256 index) external view returns (address) {
        return _adapters[index];
    }
}
