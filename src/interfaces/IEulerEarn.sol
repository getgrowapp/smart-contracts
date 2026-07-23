// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Minimal Euler Earn vault surface used to prove permanent governance lock
///         and a single pinned child strategy.
interface IEulerEarn is IERC4626 {
    struct MarketConfig {
        uint112 balance;
        uint136 cap;
        bool enabled;
        uint64 removableAt;
    }

    function owner() external view returns (address);

    function pendingOwner() external view returns (address);

    function curator() external view returns (address);

    function supplyQueue(uint256 index) external view returns (IERC4626);

    function supplyQueueLength() external view returns (uint256);

    function withdrawQueue(uint256 index) external view returns (IERC4626);

    function withdrawQueueLength() external view returns (uint256);

    function config(IERC4626 id) external view returns (MarketConfig memory);
}
