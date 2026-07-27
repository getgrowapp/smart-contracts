// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title AbstractEulerAdapter
/// @notice Shared ERC-4626 deposit/redeem path for every Euler EVK or Euler Earn vault of one
///         factory.
/// @dev `vault` is the ERC-4626 vault, which is also its own position token. Subclasses supply
///      only the factory-membership check; Grow risk approval is registry admission, which also
///      pins the underlying.
///
///      The adapter keeps no accounting of its own. The executor measures its balance of the
///      registry-pinned source and output tokens on both sides of the call and requires it to
///      consume exactly what it was sent, so residuals and donation-sweeping are caught once,
///      against the token actually transferred, rather than re-derived here.
/// @custom:security-contact security@getgrowapp.co
abstract contract AbstractEulerAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    error Invalid();
    error OnlyExecutor();
    error NonCanonical();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(address executor_) {
        if (executor_.code.length == 0) revert Invalid();
        executor = executor_;
    }

    /// @inheritdoc IYieldAdapter
    function asset(address vault) external view returns (address) {
        return IERC4626(vault).asset();
    }

    /// @inheritdoc IYieldAdapter
    /// @dev An Euler vault is its own share token.
    function positionToken(address vault) external pure returns (address) {
        return vault;
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(address vault, uint256 assets) external view returns (uint256) {
        return IERC4626(vault).previewDeposit(assets);
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(address vault, uint256 shares) external view returns (uint256) {
        return IERC4626(vault).previewRedeem(shares);
    }

    /// @inheritdoc IYieldAdapter
    function deposit(address vault, uint256 assets, address receiver)
        external
        onlyExecutor
        returns (uint256)
    {
        _assertCanonical(vault);

        address underlying = IERC4626(vault).asset();

        IERC20(underlying).forceApprove(vault, assets);
        uint256 shares = IERC4626(vault).deposit(assets, receiver);
        IERC20(underlying).forceApprove(vault, 0);

        return shares;
    }

    /// @inheritdoc IYieldAdapter
    function redeem(address vault, uint256 shares, address receiver)
        external
        onlyExecutor
        returns (uint256)
    {
        _assertCanonical(vault);

        return IERC4626(vault).redeem(shares, receiver, address(this));
    }

    /// @dev Re-validates that `vault` is a genuine venue of this adapter's protocol.
    function _assertCanonical(address vault) internal view virtual;
}
