// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IGetEquityMarket} from "../interfaces/IGetEquityMarket.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title GetEquityMarketAdapter
/// @notice One adapter for every 18-decimal token on a single GetEquity market.
/// @dev The venue is the inventory token. Settlement (cNGN) is the underlying. `buy` and `sell`
///      pay the caller, so this adapter forwards both legs to the account. A deposit spends the
///      settlement it was sent and returns whatever the market's rounding did not take.
///
///      `maxFeeBps` is pinned at construction. The market fee is already inside the preview, so
///      the executor's loss cap does not see it. A fee above this cap reverts.
/// @custom:security-contact security@getgrowapp.co
contract GetEquityMarketAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10_000;

    /// @notice Market every admitted token is bought and sold through.
    IGetEquityMarket public immutable market;

    /// @notice Settlement token paid in and received out. cNGN on Base.
    address public immutable settlement;

    /// @notice Maximum market fee, in basis points of the gross amount.
    uint16 public immutable maxFeeBps;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    error Invalid();
    error OnlyExecutor();
    error FeeTooHigh();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @param market_ GetEquity market serving every token this adapter transacts with.
    /// @param settlement_ Settlement token that market charges and pays.
    /// @param maxFeeBps_ Maximum fee, in basis points of the gross. 100 bps is the live Dangote
    ///        fee. gNTB charges none. A later increase above this cap reverts.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(
        IGetEquityMarket market_,
        address settlement_,
        uint16 maxFeeBps_,
        address executor_
    ) {
        if (
            address(market_).code.length == 0 || settlement_.code.length == 0
                || executor_.code.length == 0 || maxFeeBps_ > BPS
        ) revert Invalid();

        market = market_;
        settlement = settlement_;
        maxFeeBps = maxFeeBps_;
        executor = executor_;
    }

    /// @inheritdoc IYieldAdapter
    function asset(address) external view returns (address) {
        return settlement;
    }

    /// @inheritdoc IYieldAdapter
    function positionToken(address vault) external pure returns (address) {
        return vault;
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(address vault, uint256 assets) external view returns (uint256) {
        return _tokenForAssets(vault, assets);
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(address vault, uint256 shares) external view returns (uint256) {
        if (shares == 0) return 0;
        (uint256 gross, uint256 fee, uint256 net) = market.calculateSellPayout(vault, shares);
        _requireFee(gross, fee);
        return net;
    }

    /// @inheritdoc IYieldAdapter
    function deposit(address vault, uint256 assets, address receiver)
        external
        onlyExecutor
        returns (uint256 shares)
    {
        shares = _tokenForAssets(vault, assets);

        IERC20 pay = IERC20(settlement);
        IERC20 token = IERC20(vault);
        uint256 payBefore = pay.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));

        pay.forceApprove(address(market), assets);
        market.buy(vault, shares, assets);
        pay.forceApprove(address(market), 0);

        uint256 unspent = assets - (payBefore - pay.balanceOf(address(this)));
        if (unspent != 0) pay.safeTransfer(receiver, unspent);
        shares = token.balanceOf(address(this)) - tokenBefore;
        token.safeTransfer(receiver, shares);
    }

    /// @inheritdoc IYieldAdapter
    function redeem(address vault, uint256 shares, address receiver)
        external
        onlyExecutor
        returns (uint256 assets)
    {
        (uint256 gross, uint256 fee, uint256 net) = market.calculateSellPayout(vault, shares);
        _requireFee(gross, fee);

        IERC20 pay = IERC20(settlement);
        uint256 payBefore = pay.balanceOf(address(this));
        IERC20(vault).forceApprove(address(market), shares);
        market.sell(vault, shares, net);
        IERC20(vault).forceApprove(address(market), 0);

        assets = pay.balanceOf(address(this)) - payBefore;
        pay.safeTransfer(receiver, assets);
    }

    /// @dev The market rounds its fee up. The cap allows that rounding and nothing above it.
    function _requireFee(uint256 gross, uint256 fee) private view {
        uint256 allowed = Math.mulDiv(gross, maxFeeBps, BPS, Math.Rounding.Ceil);
        if (fee > allowed) revert FeeTooHigh();
    }

    /// @dev Token amount whose all-in cost fits in `assets`. One correction covers the market
    ///      rounding a linear inversion up by a settlement unit.
    function _tokenForAssets(address vault, uint256 assets)
        private
        view
        returns (uint256 tokenWei)
    {
        if (assets == 0) return 0;
        (,, uint256 unitCost) = market.calculateBuyCost(vault, ONE);
        if (unitCost == 0) return 0;

        tokenWei = Math.mulDiv(assets, ONE, unitCost);
        if (tokenWei == 0) return 0;

        (uint256 baseCost, uint256 fee, uint256 cost) = market.calculateBuyCost(vault, tokenWei);
        if (cost > assets) {
            uint256 reduction = (cost - assets) * ((ONE + unitCost - 1) / unitCost);
            if (reduction >= tokenWei) return 0;
            tokenWei -= reduction;
            (baseCost, fee,) = market.calculateBuyCost(vault, tokenWei);
        }
        _requireFee(baseCost, fee);
    }
}
