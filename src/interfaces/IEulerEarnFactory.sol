// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal EulerEarnFactory surface used to authenticate Earn vaults.
interface IEulerEarnFactory {
    /// @notice True if `vault` was created by this factory.
    function isVault(address vault) external view returns (bool);

    /// @notice True if `strategy` is admitted by Euler's factory policy.
    function isStrategyAllowed(address strategy) external view returns (bool);
}
