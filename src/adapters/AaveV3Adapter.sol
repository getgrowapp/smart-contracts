// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../interfaces/IAaveProtocolDataProvider.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title AaveV3Adapter
/// @notice Aave V3 adapter serving every reserve of one pool.
/// @dev Aave keys reserves by underlying asset and shares a single pool across all of them, so
///      `vault` is the reserve's underlying asset and the position token is resolved from the
///      pinned data provider on demand. Only the executor may deposit or redeem. Previews are
///      identity because Aave mints and burns aTokens at par. Withdrawals remain subject to
///      Aave liquidity and governance controls.
///
///      The adapter pins no reserve, so it cannot detect a reserve whose aToken was re-pointed.
///      That binding lives in the registry, which pins each venue's `(asset, positionToken)`
///      pair at admission; the executor re-derives it here and fails closed on drift.
/// @custom:security-contact security@getgrowapp.co
contract AaveV3Adapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice Aave V3 pool this adapter supplies to / withdraws from.
    IAaveV3Pool public immutable pool;

    /// @notice Aave data provider used to resolve a reserve's aToken.
    IAaveProtocolDataProvider public immutable dataProvider;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    error Invalid();
    error OnlyExecutor();
    error UnknownReserve();
    error ResidualBalance();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @param pool_ Aave V3 pool serving every reserve this adapter transacts with.
    /// @param dataProvider_ Aave data provider used to resolve reserve aTokens.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(IAaveV3Pool pool_, IAaveProtocolDataProvider dataProvider_, address executor_) {
        if (
            address(pool_).code.length == 0 || address(dataProvider_).code.length == 0
                || executor_.code.length == 0
        ) revert Invalid();

        pool = pool_;
        dataProvider = dataProvider_;
        executor = executor_;
    }

    /// @inheritdoc IYieldAdapter
    /// @dev An Aave reserve is identified by its underlying asset, so the venue is the asset.
    function asset(address vault) external pure returns (address) {
        return vault;
    }

    /// @inheritdoc IYieldAdapter
    function positionToken(address vault) external view returns (address) {
        return _aToken(vault);
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(address, uint256 assets) external pure returns (uint256) {
        return assets;
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(address, uint256 shares) external pure returns (uint256) {
        return shares;
    }

    /// @inheritdoc IYieldAdapter
    function deposit(address vault, uint256 assets, address receiver)
        external
        onlyExecutor
        returns (uint256)
    {
        uint256 balanceBefore = IERC20(vault).balanceOf(address(this));

        IERC20(vault).forceApprove(address(pool), assets);
        pool.supply(vault, assets, receiver, 0);
        IERC20(vault).forceApprove(address(pool), 0);

        // Exactly `assets` consumed; anything else means the pool misbehaved.
        if (IERC20(vault).balanceOf(address(this)) != balanceBefore - assets) {
            revert ResidualBalance();
        }

        return assets;
    }

    /// @inheritdoc IYieldAdapter
    function redeem(address vault, uint256 shares, address receiver)
        external
        onlyExecutor
        returns (uint256)
    {
        IERC20 aToken = IERC20(_aToken(vault));
        uint256 sharesBefore = aToken.balanceOf(address(this));
        uint256 withdrawn = pool.withdraw(vault, shares, receiver);

        // Consume the caller-attributed position amount. aToken burns settle in scaled
        // units, so allow one wei of rounding; donations are still never swept.
        uint256 consumed = sharesBefore - aToken.balanceOf(address(this));
        if (consumed + 1 < shares || consumed > shares + 1) revert ResidualBalance();

        return withdrawn;
    }

    /// @dev The reserve's current aToken; reverts if the pool lists no reserve for `vault`.
    function _aToken(address vault) private view returns (address aToken) {
        (aToken,,) = dataProvider.getReserveTokensAddresses(vault);
        if (aToken == address(0)) revert UnknownReserve();
    }
}
