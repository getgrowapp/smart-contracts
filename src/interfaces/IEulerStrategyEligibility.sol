// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice External policy for approved Euler Earn child strategies and EVK markets.
interface IEulerStrategyEligibility {
    /// @notice True if `strategy` is an approved Euler yield venue (Earn vault or EVault).
    function isEligibleStrategy(address strategy) external view returns (bool);
}
