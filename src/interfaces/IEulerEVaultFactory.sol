// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal EVK GenericFactory surface used to authenticate EVault proxies.
interface IEulerEVaultFactory {
    /// @notice True if `proxy` was created by this factory.
    function isProxy(address proxy) external view returns (bool);
}
