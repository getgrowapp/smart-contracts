// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../interfaces/IAaveProtocolDataProvider.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title AaveV3Adapter
/// @notice Aave V3 venue adapter for one (pool, asset) reserve.
/// @dev Only the executor may deposit or redeem. Deposits verify the reserve's current
///      aToken; redemptions use the pinned pool and token without that drift check.
///      Previews are identity because Aave mints and burns aTokens at par. Withdrawals
///      remain subject to Aave liquidity and governance controls.
contract AaveV3Adapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice Aave V3 pool this adapter supplies to / withdraws from.
    IAaveV3Pool public immutable pool;

    /// @notice Aave data provider used to re-derive the reserve's aToken (drift check).
    IAaveProtocolDataProvider public immutable dataProvider;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    /// @inheritdoc IYieldAdapter
    address public immutable asset;

    /// @inheritdoc IYieldAdapter
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
            address(pool_).code.length == 0 || address(dataProvider_).code.length == 0
                || asset_.code.length == 0 || executor_.code.length == 0
        ) revert Invalid();

        (address aToken,,) = dataProvider_.getReserveTokensAddresses(asset_);
        if (aToken.code.length == 0 || aToken == asset_) revert Invalid();

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
    function redeem(uint256 shares, address receiver) external onlyExecutor returns (uint256) {
        uint256 sharesBefore = IERC20(positionToken).balanceOf(address(this));
        uint256 withdrawn = pool.withdraw(asset, shares, receiver);

        // Consume exactly the caller-attributed position amount. Pre-existing donations
        // are deliberately not swept into an unrelated account's redemption.
        if (IERC20(positionToken).balanceOf(address(this)) != sharesBefore - shares) {
            revert ResidualBalance();
        }

        return withdrawn;
    }

    /// @dev Fails closed if Aave governance re-points the reserve's aToken.
    function _checkReserve() private view {
        (address aToken,,) = dataProvider.getReserveTokensAddresses(asset);
        if (aToken != positionToken) revert ReserveDrift();
    }
}
