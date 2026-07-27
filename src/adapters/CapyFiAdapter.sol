// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICapyFiCaToken} from "../interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../interfaces/ICapyFiComptroller.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title CapyFiAdapter
/// @notice GrowYield adapter for every Compound-v2-style CapyFi caToken market of one Comptroller.
/// @dev `vault` is the caToken market, which is also its own position token. Every operation
///      re-checks that the market still belongs to the pinned Comptroller and is still listed, so
///      delisting fails closed. That proves CapyFi authenticity only — Grow risk approval is
///      registry admission, which also pins the underlying. Non-zero mint/redeem codes revert.
/// @custom:security-contact security@getgrowapp.co
contract CapyFiAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    uint256 private constant EXP_SCALE = 1e18;

    /// @notice Canonical CapyFi Comptroller (Unitroller proxy) every market must belong to.
    ICapyFiComptroller public immutable comptroller;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    error Invalid();
    error OnlyExecutor();
    error VenueDrift();
    error MintFailed(uint256 errorCode);
    error RedeemFailed(uint256 errorCode);

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @param executor_ GrowYield executor authorized to call this adapter.
    /// @param comptroller_ Canonical CapyFi Comptroller / Unitroller.
    constructor(address executor_, ICapyFiComptroller comptroller_) {
        if (executor_.code.length == 0 || address(comptroller_).code.length == 0) {
            revert Invalid();
        }

        comptroller = comptroller_;
        executor = executor_;
    }

    /// @inheritdoc IYieldAdapter
    function asset(address vault) external view returns (address) {
        return ICapyFiCaToken(vault).underlying();
    }

    /// @inheritdoc IYieldAdapter
    /// @dev A caToken market is its own share token.
    function positionToken(address vault) external pure returns (address) {
        return vault;
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(address vault, uint256 assets) external view returns (uint256) {
        uint256 rate = _exchangeRate(vault);
        if (rate == 0) return 0;
        return Math.mulDiv(assets, EXP_SCALE, rate);
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(address vault, uint256 shares) external view returns (uint256) {
        return Math.mulDiv(shares, _exchangeRate(vault), EXP_SCALE);
    }

    /// @inheritdoc IYieldAdapter
    function deposit(address vault, uint256 assets, address receiver)
        external
        onlyExecutor
        returns (uint256)
    {
        _assertCanonical(vault);

        address underlying = ICapyFiCaToken(vault).underlying();
        // Compound mints to `msg.sender`, so the adapter must measure its own mint and forward
        // it. This delta is a transfer amount, not an assertion; the executor bounds residuals.
        uint256 sharesBefore = IERC20(vault).balanceOf(address(this));

        IERC20(underlying).forceApprove(vault, assets);
        uint256 mintError = ICapyFiCaToken(vault).mint(assets);
        if (mintError != 0) revert MintFailed(mintError);
        IERC20(underlying).forceApprove(vault, 0);

        uint256 minted = IERC20(vault).balanceOf(address(this)) - sharesBefore;
        IERC20(vault).safeTransfer(receiver, minted);

        return minted;
    }

    /// @inheritdoc IYieldAdapter
    function redeem(address vault, uint256 shares, address receiver)
        external
        onlyExecutor
        returns (uint256)
    {
        _assertCanonical(vault);

        address underlying = ICapyFiCaToken(vault).underlying();
        // Compound redeems to `msg.sender`, so the adapter must measure its own proceeds and
        // forward them. A delta, not an assertion; the executor bounds residuals.
        uint256 assetBefore = IERC20(underlying).balanceOf(address(this));

        uint256 redeemError = ICapyFiCaToken(vault).redeem(shares);
        if (redeemError != 0) revert RedeemFailed(redeemError);

        uint256 assetsOut = IERC20(underlying).balanceOf(address(this)) - assetBefore;
        IERC20(underlying).safeTransfer(receiver, assetsOut);

        return assetsOut;
    }

    /// @dev The rate `mint` and `redeem` will actually use, which is not `exchangeRateStored`:
    ///      Compound accrues interest first, and accrual raises the rate. Quoting the stale rate
    ///      overstates deposit output, and the executor's loss cap then rejects the very deposit
    ///      the preview described. `exchangeRateCurrent` accrues correctly but writes state, so a
    ///      view cannot call it — hence replaying `accrueInterest` here.
    ///
    ///      Interest is driven entirely by borrows, so with none outstanding, no supply, or no
    ///      elapsed blocks, accrual is a no-op and the stored rate is already exact.
    function _exchangeRate(address vault) private view returns (uint256) {
        ICapyFiCaToken market = ICapyFiCaToken(vault);
        uint256 supply = market.totalSupply();
        uint256 borrows = market.totalBorrows();
        uint256 blocks = block.number - market.accrualBlockNumber();
        if (supply == 0 || borrows == 0 || blocks == 0) return market.exchangeRateStored();

        uint256 interest = Math.mulDiv(market.borrowRatePerBlock() * blocks, borrows, EXP_SCALE);
        uint256 reserves = market.totalReserves()
            + Math.mulDiv(market.reserveFactorMantissa(), interest, EXP_SCALE);
        return Math.mulDiv(market.getCash() + borrows + interest - reserves, EXP_SCALE, supply);
    }

    /// @dev Fails closed if the market is delisted or no longer belongs to the pinned Comptroller.
    function _assertCanonical(address vault) private view {
        if (ICapyFiCaToken(vault).comptroller() != address(comptroller)) revert VenueDrift();
        (bool isListed,,) = comptroller.markets(vault);
        if (!isListed) revert VenueDrift();
    }
}
