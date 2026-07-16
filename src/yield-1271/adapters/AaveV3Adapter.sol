// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool} from "../../interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../interfaces/IAaveProtocolDataProvider.sol";
import {IYieldAdapter} from "../IGrowYield1271.sol";

/**
 * @notice Aave V3 venue adapter for one (pool, asset) reserve.
 *
 * @dev aTokens are 1:1 with underlying at mint/burn time, so previews are identity;
 *      interest accrual only ever increases balances. Small mint/burn rounding on the
 *      rebasing aToken is absorbed by the executor's loss cap.
 *
 *      Only the pinned executor may call state-changing methods: the adapter holds
 *      funds transiently mid-call and its accounting assumes the executor's exact
 *      push-then-call sequence.
 *
 *      Reserve drift (Aave governance replacing the reserve's aToken) is re-checked on
 *      every deposit and fails closed. Redemptions intentionally skip the drift check:
 *      exits must remain possible even if the reserve is later reconfigured, and a
 *      stale aToken makes `withdraw` fail on its own.
 */
contract AaveV3Adapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable pool;
    IAaveProtocolDataProvider public immutable dataProvider;
    address public immutable executor;
    address public immutable asset;
    address public immutable positionToken;

    error Invalid();
    error OnlyExecutor();
    error ReserveDrift();
    error ResidualBalance();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    constructor(
        IAaveV3Pool pool_,
        IAaveProtocolDataProvider dataProvider_,
        address asset_,
        address executor_
    ) {
        if (
            address(pool_) == address(0) || address(dataProvider_) == address(0)
                || asset_ == address(0) || executor_ == address(0)
        ) revert Invalid();

        (address aToken,,) = dataProvider_.getReserveTokensAddresses(asset_);
        if (aToken == address(0)) revert Invalid();

        pool = pool_;
        dataProvider = dataProvider_;
        executor = executor_;
        asset = asset_;
        positionToken = aToken;
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    /// @inheritdoc IYieldAdapter
    function deposit(uint256 assets, address receiver) external onlyExecutor returns (uint256) {
        _checkReserve();

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        IERC20(asset).forceApprove(address(pool), assets);
        pool.supply(asset, assets, receiver, 0);
        IERC20(asset).forceApprove(address(pool), 0);

        // Exactly `assets` consumed; anything else means the pool misbehaved.
        if (IERC20(asset).balanceOf(address(this)) != balanceBefore - assets) {
            revert ResidualBalance();
        }

        return assets;
    }

    /// @inheritdoc IYieldAdapter
    function redeem(uint256, address receiver) external onlyExecutor returns (uint256) {
        // Withdraw the adapter's entire aToken balance (the executor pushed exactly the
        // redeem amount). `type(uint256).max` is Aave's full-balance sentinel; it avoids
        // 1-wei index-rounding dust sticking to the adapter and sweeps any aToken
        // donations out instead of bricking on a strict residual check.
        uint256 withdrawn = pool.withdraw(asset, type(uint256).max, receiver);

        if (IERC20(positionToken).balanceOf(address(this)) != 0) revert ResidualBalance();

        return withdrawn;
    }

    /// @dev Fails closed if Aave governance re-points the reserve's aToken.
    function _checkReserve() private view {
        (address aToken,,) = dataProvider.getReserveTokensAddresses(asset);
        if (aToken != positionToken) revert ReserveDrift();
    }
}
