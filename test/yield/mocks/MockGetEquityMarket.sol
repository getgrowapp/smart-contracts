// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IGetEquityMarket} from "../../../src/interfaces/IGetEquityMarket.sol";

contract MockCngn is ERC20 {
    constructor() ERC20("cNGN", "cNGN") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockGntb is ERC20 {
    constructor() ERC20("Nigerian Treasury Bills", "gNTB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev One listed token. Buy cost rounds up, sell payout rounds down, both plus a fee.
contract MockGetEquityMarket is IGetEquityMarket {
    using SafeERC20 for IERC20;

    IERC20 public immutable cngn;
    IERC20 public immutable gntb;

    /// @notice Settlement wei per 1e18 token, before the fee.
    uint256 public price;

    uint256 public feeBps;

    error Closed();
    error Inventory();
    error Cost();
    error Payout();

    constructor(IERC20 cngn_, IERC20 gntb_, uint256 price_, uint256 feeBps_) {
        cngn = cngn_;
        gntb = gntb_;
        price = price_;
        feeBps = feeBps_;
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function calculateBuyCost(address token, uint256 amount)
        public
        view
        returns (uint256 baseCost, uint256 fee, uint256 totalCost)
    {
        if (token != address(gntb) || amount == 0) return (0, 0, 0);
        baseCost = Math.mulDiv(amount, price, 1e18, Math.Rounding.Ceil);
        fee = Math.mulDiv(baseCost, feeBps, 10_000, Math.Rounding.Ceil);
        totalCost = baseCost + fee;
    }

    function calculateSellPayout(address token, uint256 amount)
        public
        view
        returns (uint256 grossPayout, uint256 fee, uint256 netPayout)
    {
        if (token != address(gntb) || amount == 0) return (0, 0, 0);
        grossPayout = Math.mulDiv(amount, price, 1e18);
        fee = Math.mulDiv(grossPayout, feeBps, 10_000, Math.Rounding.Ceil);
        netPayout = grossPayout > fee ? grossPayout - fee : 0;
    }

    function buy(address token, uint256 amount, uint256 maxCost) external {
        if (token != address(gntb)) revert Closed();
        (,, uint256 totalCost) = calculateBuyCost(token, amount);
        if (totalCost == 0 || totalCost > maxCost) revert Cost();
        if (gntb.balanceOf(address(this)) < amount) revert Inventory();

        cngn.safeTransferFrom(msg.sender, address(this), totalCost);
        gntb.safeTransfer(msg.sender, amount);
    }

    function sell(address token, uint256 amount, uint256 minPayout) external {
        if (token != address(gntb)) revert Closed();
        (,, uint256 net) = calculateSellPayout(token, amount);
        if (net == 0 || net < minPayout) revert Payout();

        gntb.safeTransferFrom(msg.sender, address(this), amount);
        cngn.safeTransfer(msg.sender, net);
    }
}
