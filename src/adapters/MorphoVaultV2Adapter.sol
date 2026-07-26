// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IMorphoVaultV1Adapter} from "vault-v2/adapters/interfaces/IMorphoVaultV1Adapter.sol";

import {IMorphoVaultEligibility} from "../interfaces/IMorphoVaultEligibility.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title MorphoVaultV2Adapter
/// @notice GrowYield adapter for every Morpho VaultV2 wrapper gated by one eligibility oracle.
/// @dev `vault` is the VaultV2 wrapper, which is also its own position token.
///
///      Registry admission proves the wrapper's full shape once: created by the canonical VaultV2
///      factory, exactly one adapter, that adapter created by the canonical VaultV1 adapter
///      factory and parented to this wrapper, `addAdapter` and `removeAdapter` both abdicated,
///      liquidity routed to it with empty data, and an eligible child on a matching asset.
///
///      Abdication is irreversible in VaultV2 and the `adapters` array changes only through
///      `addAdapter` / `removeAdapter`, so that single-entry adapter set is frozen for the
///      wrapper's lifetime. Every operation therefore only needs to re-check what an allocator
///      can still move: that liquidity still routes to `adapters(0)` with empty data, that the
///      child is still eligible, and the caller's current round-trip gates. Later gate changes,
///      liquidity, or venue governance can still impair exits.
/// @custom:security-contact security@getgrowapp.co
contract MorphoVaultV2Adapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice Eligibility oracle re-checked on every operation for the wrapper's child.
    IMorphoVaultEligibility public immutable eligibility;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    error Invalid();
    error OnlyExecutor();
    error VenueDrift();
    error VenueGate();
    error NonCompliantVault();
    error ResidualBalance();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @param eligibility_ Eligibility oracle for wrappers' Morpho VaultV1 children.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(IMorphoVaultEligibility eligibility_, address executor_) {
        if (address(eligibility_).code.length == 0 || executor_.code.length == 0) {
            revert Invalid();
        }

        eligibility = eligibility_;
        executor = executor_;
    }

    /// @inheritdoc IYieldAdapter
    function asset(address vault) external view returns (address) {
        return IERC4626(vault).asset();
    }

    /// @inheritdoc IYieldAdapter
    /// @dev A VaultV2 wrapper is its own share token.
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
        _checkRouting(vault);
        _checkDepositGates(vault, receiver);

        address underlying = IERC4626(vault).asset();
        uint256 balanceBefore = IERC20(underlying).balanceOf(address(this));
        uint256 sharesBefore = IERC20(vault).balanceOf(receiver);

        IERC20(underlying).forceApprove(vault, assets);
        uint256 shares = IERC4626(vault).deposit(assets, receiver);
        IERC20(underlying).forceApprove(vault, 0);

        // Strict ERC-4626 conformance: reported shares must equal the receiver's delta.
        if (IERC20(vault).balanceOf(receiver) - sharesBefore != shares) {
            revert NonCompliantVault();
        }

        // Exactly `assets` consumed; anything else means the vault misbehaved.
        if (IERC20(underlying).balanceOf(address(this)) != balanceBefore - assets) {
            revert ResidualBalance();
        }

        return shares;
    }

    /// @inheritdoc IYieldAdapter
    function redeem(address vault, uint256 shares, address receiver)
        external
        onlyExecutor
        returns (uint256)
    {
        IVaultV2 wrapper = IVaultV2(vault);
        if (!wrapper.canSendShares(address(this)) || !wrapper.canReceiveAssets(receiver)) {
            revert VenueGate();
        }
        uint256 sharesBefore = IERC20(vault).balanceOf(address(this));

        uint256 assetsOut = IERC4626(vault).redeem(shares, receiver, address(this));

        // Exactly `shares` consumed; anything else means the vault misbehaved.
        if (IERC20(vault).balanceOf(address(this)) != sharesBefore - shares) {
            revert ResidualBalance();
        }

        return assetsOut;
    }

    /// @dev Re-checks the mutable half of admission: liquidity must still route to the wrapper's
    ///      frozen single adapter with empty data, and that adapter's child must still be
    ///      eligible. Factory provenance of `adapters(0)` was proven at admission and cannot
    ///      change, because the adapter set is frozen by irreversible abdication.
    function _checkRouting(address vault) private view {
        IVaultV2 wrapper = IVaultV2(vault);
        address liquidityAdapter = wrapper.adapters(0);
        if (wrapper.liquidityAdapter() != liquidityAdapter || wrapper.liquidityData().length != 0) {
            revert VenueDrift();
        }

        address child = IMorphoVaultV1Adapter(liquidityAdapter).morphoVaultV1();
        if (!eligibility.isEligibleVault(child)) revert VenueDrift();
    }

    /// @dev Requires every gate the deposit round trip depends on.
    function _checkDepositGates(address vault, address receiver) private view {
        IVaultV2 wrapper = IVaultV2(vault);
        if (
            !wrapper.canReceiveShares(receiver) || !wrapper.canSendAssets(address(this))
                || !wrapper.canSendShares(receiver) || !wrapper.canReceiveShares(address(this))
                || !wrapper.canSendShares(address(this)) || !wrapper.canReceiveAssets(receiver)
        ) revert VenueGate();
    }
}
