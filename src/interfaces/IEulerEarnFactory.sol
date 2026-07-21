// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal EulerEarnFactory surface used to authenticate Earn vaults.
interface IEulerEarnFactory {
    /// @notice True if `vault` was created by this factory.
    function isVault(address vault) external view returns (bool);
}
