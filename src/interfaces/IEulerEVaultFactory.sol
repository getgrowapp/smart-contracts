// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal EVK GenericFactory surface used to authenticate EVault proxies.
interface IEulerEVaultFactory {
    /// @notice Proxy metadata tracked by the factory.
    struct ProxyConfig {
        bool upgradeable;
        address implementation;
        bytes trailingData;
    }

    /// @notice True if `proxy` was created by this factory.
    function isProxy(address proxy) external view returns (bool);

    /// @notice Current proxy configuration, including live implementation for upgradeable vaults.
    function getProxyConfig(address proxy) external view returns (ProxyConfig memory);
}
