// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveProtocolDataProvider} from "../../../src/interfaces/IAaveProtocolDataProvider.sol";
import {IAaveV3Pool} from "../../../src/interfaces/IAaveV3Pool.sol";

/// @dev Aave-accurate aToken. Holders keep a *scaled* balance and `balanceOf` reports that
///      balance times the reserve's normalized income, exactly as Aave V3's `AToken.balanceOf`
///      does. `MockAToken` mints 1:1 and cannot model this, which is why the executor's
///      rebasing tolerances need a venue of their own.
///
///      The load-bearing detail is that normalized income accrues **on read**, so within one
///      transaction it is constant: `updateState` only writes down the value the view already
///      returned. A holder's reported balance therefore never moves mid-operation, which is what
///      makes the executor's absolute residual bounds safe against donations into the adapter.
contract RebasingAToken is ERC20 {
    uint256 private constant RAY = 1e27;

    MockRebasingAavePool public immutable pool;

    mapping(address holder => uint256) public scaledBalanceOf;

    error OnlyPool();

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert OnlyPool();
        _;
    }

    constructor() ERC20("Rebasing aUSD", "raUSD") {
        pool = MockRebasingAavePool(msg.sender);
    }

    /// @dev Mirrors `AToken.balanceOf`: scaled balance times accrue-on-read normalized income.
    function balanceOf(address holder) public view override returns (uint256) {
        return (scaledBalanceOf[holder] * pool.normalizedIncome()) / RAY;
    }

    function mintScaled(address to, uint256 assets) external onlyPool {
        scaledBalanceOf[to] += (assets * RAY) / pool.normalizedIncome();
    }

    function burnScaled(address from, uint256 assets) external onlyPool {
        scaledBalanceOf[from] -= (assets * RAY) / pool.normalizedIncome();
    }

    function transferFrom(address from, address to, uint256 assets) public override returns (bool) {
        _spendAllowance(from, msg.sender, assets);
        uint256 scaled = (assets * RAY) / pool.normalizedIncome();
        scaledBalanceOf[from] -= scaled;
        scaledBalanceOf[to] += scaled;
        return true;
    }
}

/// @dev Aave-like pool whose liquidity index accrues on read and is persisted by interaction,
///      matching `ReserveLogic.getNormalizedIncome` / `updateState`. Interest accrues linearly
///      at `APY_BPS` so tests can dial drift with `skip`.
contract MockRebasingAavePool is IAaveV3Pool {
    using SafeERC20 for IERC20;

    uint256 private constant RAY = 1e27;
    uint256 private constant APY_BPS = 500;

    IERC20 public immutable asset;
    RebasingAToken public immutable aToken;

    uint256 public liquidityIndex = RAY;
    uint256 public lastUpdate;

    constructor(IERC20 asset_) {
        asset = asset_;
        lastUpdate = block.timestamp;
        aToken = new RebasingAToken();
    }

    /// @dev Accrues to `block.timestamp` on read, so it is constant within a transaction.
    function normalizedIncome() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0) return liquidityIndex;
        return liquidityIndex + (liquidityIndex * APY_BPS * elapsed) / (10_000 * 365 days);
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external override {
        _updateState();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        aToken.mintScaled(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external override returns (uint256) {
        _updateState();
        aToken.burnScaled(msg.sender, amount);
        asset.safeTransfer(to, amount);
        return amount;
    }

    /// @dev Writes down the value `normalizedIncome()` already reports; never changes it.
    function _updateState() private {
        liquidityIndex = normalizedIncome();
        lastUpdate = block.timestamp;
    }
}

/// @dev Fixed data provider for the single rebasing reserve.
contract MockRebasingDataProvider is IAaveProtocolDataProvider {
    address private immutable _aToken;

    constructor(address aToken_) {
        _aToken = aToken_;
    }

    function getReserveTokensAddresses(address) external view returns (address, address, address) {
        return (_aToken, address(0), address(0));
    }
}
