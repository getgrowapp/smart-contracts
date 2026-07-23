// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IEulerStrategyEligibility} from "../interfaces/IEulerStrategyEligibility.sol";

/// @title EulerStrategyEligibility
/// @notice Ownable allowlist for Euler child strategies checked by `EulerEarnAdapter`.
/// @dev Grow risk admission for the yield path inside a locked Earn wrapper. Updating
///      the allowlist does not change already-deployed adapter bindings.
contract EulerStrategyEligibility is IEulerStrategyEligibility, Ownable {
    mapping(address strategy => bool eligible) private _eligible;

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Allow or disallow a child strategy (Earn vault or EVault proxy).
    function setEligible(address strategy, bool eligible) external onlyOwner {
        _eligible[strategy] = eligible;
    }

    /// @inheritdoc IEulerStrategyEligibility
    function isEligibleStrategy(address strategy) external view returns (bool) {
        return _eligible[strategy];
    }
}
