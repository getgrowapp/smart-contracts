// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title AbstractEulerAdapter
/// @notice Shared ERC-4626 deposit/redeem path for Euler EVK and Euler Earn vaults.
/// @dev Subclasses supply only protocol-specific authenticity checks (factory proofs).
///      Factory validation proves a genuine Euler deployment; Grow risk approval is
///      registry inclusion. Deposit/redeem credit `receiver` directly via ERC-4626
///      receiver parameters — the adapter never retains newly minted shares. It holds
///      shares only when the executor has transferred them in for redemption, then
///      consumes exactly that attributed amount.
abstract contract AbstractEulerAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice The Euler ERC-4626 vault (also the position token).
    IERC4626 public immutable vault;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    /// @inheritdoc IYieldAdapter
    address public immutable asset;

    error Invalid();
    error OnlyExecutor();
    error NonCanonical();
    error AssetMismatch();
    error NonCompliantVault();
    error ResidualBalance();
    error ResidualAllowance();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @param vault_ Euler vault (EVault or Earn) used as the position token.
    /// @param asset_ Expected underlying; must equal `vault.asset()`.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(IERC4626 vault_, address asset_, address executor_) {
        if (
            address(vault_).code.length == 0 || asset_.code.length == 0
                || executor_.code.length == 0
        ) {
            revert Invalid();
        }
        if (vault_.asset() != asset_) revert AssetMismatch();

        vault = vault_;
        asset = asset_;
        executor = executor_;
    }

    /// @inheritdoc IYieldAdapter
    function positionToken() external view returns (address) {
        return address(vault);
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return vault.previewDeposit(assets);
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return vault.previewRedeem(shares);
    }

    /// @inheritdoc IYieldAdapter
    function deposit(uint256 assets, address receiver) external onlyExecutor returns (uint256) {
        _assertCanonical();

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 adapterSharesBefore = IERC20(address(vault)).balanceOf(address(this));
        uint256 sharesBefore = IERC20(address(vault)).balanceOf(receiver);

        IERC20(asset).forceApprove(address(vault), assets);
        uint256 shares = vault.deposit(assets, receiver);
        IERC20(asset).forceApprove(address(vault), 0);
        if (IERC20(asset).allowance(address(this), address(vault)) != 0) {
            revert ResidualAllowance();
        }

        // Shares must credit `receiver` directly — adapter must not retain the mint.
        if (IERC20(address(vault)).balanceOf(receiver) - sharesBefore != shares) {
            revert NonCompliantVault();
        }
        if (IERC20(address(vault)).balanceOf(address(this)) != adapterSharesBefore) {
            revert ResidualBalance();
        }
        if (IERC20(asset).balanceOf(address(this)) != balanceBefore - assets) {
            revert ResidualBalance();
        }

        return shares;
    }

    /// @inheritdoc IYieldAdapter
    function redeem(uint256 shares, address receiver) external onlyExecutor returns (uint256) {
        _assertCanonical();

        // Shares are held only because the executor transferred the attributed amount
        // here; `redeem(..., receiver, address(this))` sends underlying to `receiver`.
        uint256 sharesBefore = IERC20(address(vault)).balanceOf(address(this));
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        uint256 assetsOut = vault.redeem(shares, receiver, address(this));

        // Consume exactly the caller-attributed share amount. Pre-existing donations
        // are deliberately not swept into an unrelated account's redemption.
        if (IERC20(address(vault)).balanceOf(address(this)) != sharesBefore - shares) {
            revert ResidualBalance();
        }
        // Underlying must go to `receiver`; adapter must not retain the redeem output.
        if (IERC20(asset).balanceOf(address(this)) != assetBefore) {
            revert ResidualBalance();
        }

        return assetsOut;
    }

    /// @dev Re-validates factory authenticity and underlying binding before each op.
    function _assertCanonical() internal view virtual;
}
