// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICapyFiCaToken} from "../interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../interfaces/ICapyFiComptroller.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title CapyFiAdapter
/// @notice Immutable GrowYield adapter for one Compound-v2-style CapyFi caToken market.
/// @dev Pins the executor, Comptroller, caToken, and underlying. Comptroller/listing
///      checks prove CapyFi protocol authenticity only; Grow risk approval is registry
///      inclusion. Every operation re-checks comptroller binding, listing, and
///      underlying. Compound return codes are enforced; non-zero mint/redeem revert.
///
///      Deposit: forceApprove → mint (credits adapter) → clear allowance → transfer
///      minted caTokens to `receiver`.
///      Redeem: executor transfers exact caTokens here → `redeem(shares)` → transfer
///      all resulting underlying to `receiver`. A clean operation (no prior donations)
///      finishes with zero caToken, underlying, and caToken allowances on the adapter.
contract CapyFiAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    uint256 private constant EXP_SCALE = 1e18;

    /// @notice Canonical CapyFi Comptroller (Unitroller proxy).
    ICapyFiComptroller public immutable comptroller;

    /// @notice CapyFi caToken market this adapter supplies to / redeems from.
    ICapyFiCaToken public immutable caToken;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    /// @inheritdoc IYieldAdapter
    address public immutable asset;

    error Invalid();
    error OnlyExecutor();
    error VenueDrift();
    error MintFailed(uint256 errorCode);
    error RedeemFailed(uint256 errorCode);
    error ResidualBalance();
    error ResidualAllowance();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @param executor_ GrowYield executor authorized to call this adapter.
    /// @param comptroller_ Canonical CapyFi Comptroller / Unitroller.
    /// @param caToken_ Listed caToken market for `asset_`.
    /// @param asset_ Underlying ERC-20 expected by the caToken.
    constructor(
        address executor_,
        ICapyFiComptroller comptroller_,
        ICapyFiCaToken caToken_,
        address asset_
    ) {
        if (
            executor_.code.length == 0 || address(comptroller_).code.length == 0
                || address(caToken_).code.length == 0 || asset_.code.length == 0
        ) {
            revert Invalid();
        }
        if (address(caToken_) == asset_) revert Invalid();

        comptroller = comptroller_;
        caToken = caToken_;
        executor = executor_;
        asset = asset_;

        _assertCanonical();
    }

    /// @inheritdoc IYieldAdapter
    function positionToken() external view returns (address) {
        return address(caToken);
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(uint256 assets) external view returns (uint256) {
        uint256 rate = caToken.exchangeRateStored();
        if (rate == 0) return 0;
        return Math.mulDiv(assets, EXP_SCALE, rate);
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return Math.mulDiv(shares, caToken.exchangeRateStored(), EXP_SCALE);
    }

    /// @inheritdoc IYieldAdapter
    function deposit(uint256 assets, address receiver) external onlyExecutor returns (uint256) {
        _assertCanonical();

        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        uint256 sharesBefore = IERC20(address(caToken)).balanceOf(address(this));

        IERC20(asset).forceApprove(address(caToken), assets);
        uint256 mintError = caToken.mint(assets);
        if (mintError != 0) revert MintFailed(mintError);
        IERC20(asset).forceApprove(address(caToken), 0);
        if (IERC20(asset).allowance(address(this), address(caToken)) != 0) {
            revert ResidualAllowance();
        }

        uint256 minted = IERC20(address(caToken)).balanceOf(address(this)) - sharesBefore;
        if (minted == 0) revert ResidualBalance();
        IERC20(address(caToken)).safeTransfer(receiver, minted);

        if (IERC20(asset).balanceOf(address(this)) != assetBefore - assets) {
            revert ResidualBalance();
        }
        if (IERC20(address(caToken)).balanceOf(address(this)) != sharesBefore) {
            revert ResidualBalance();
        }

        return minted;
    }

    /// @inheritdoc IYieldAdapter
    function redeem(uint256 shares, address receiver) external onlyExecutor returns (uint256) {
        _assertCanonical();

        uint256 sharesBefore = IERC20(address(caToken)).balanceOf(address(this));
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));

        uint256 redeemError = caToken.redeem(shares);
        if (redeemError != 0) revert RedeemFailed(redeemError);

        // Consume exactly the caller-attributed caToken amount. Pre-existing donations
        // are deliberately not swept into an unrelated account's redemption.
        if (IERC20(address(caToken)).balanceOf(address(this)) != sharesBefore - shares) {
            revert ResidualBalance();
        }

        uint256 assetsOut = IERC20(asset).balanceOf(address(this)) - assetBefore;
        if (assetsOut == 0) revert ResidualBalance();
        IERC20(asset).safeTransfer(receiver, assetsOut);

        if (IERC20(asset).balanceOf(address(this)) != assetBefore) {
            revert ResidualBalance();
        }

        return assetsOut;
    }

    /// @dev Fails closed if the caToken is delisted, re-pointed, or asset-mismatched.
    function _assertCanonical() private view {
        if (caToken.comptroller() != address(comptroller)) revert VenueDrift();
        (bool isListed,,) = comptroller.markets(address(caToken));
        if (!isListed) revert VenueDrift();
        if (caToken.underlying() != asset) revert VenueDrift();
    }
}
