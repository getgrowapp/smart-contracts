// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoVaultV1Adapter} from "vault-v2/adapters/interfaces/IMorphoVaultV1Adapter.sol";
import {
    IMorphoVaultV1AdapterFactory
} from "vault-v2/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";

import {IMorphoVaultEligibility} from "../interfaces/IMorphoVaultEligibility.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title MorphoVaultV2Adapter
/// @author 0xOsiris, Grow
/// @notice Morpho VaultV2 venue adapter for one wrapper vault.
/// @dev The wrapper must have one factory-authenticated Morpho VaultV1 adapter, a
///      matching asset, and an immutable adapter set. Deposits re-check child
///      eligibility, liquidity routing, and the caller's current round-trip gates.
///      Later gate changes, liquidity, or venue governance can still impair exits.
contract MorphoVaultV2Adapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice The VaultV2 wrapper this adapter deposits into (also the position token).
    IVaultV2 public immutable wrapper;

    /// @notice The Morpho VaultV1 child the wrapper's liquidity adapter routes into.
    address public immutable child;

    /// @notice The wrapper's single designated liquidity adapter, fixed at validation.
    address public immutable liquidityAdapter;

    /// @notice External eligibility oracle re-checked on every deposit (drift check).
    IMorphoVaultEligibility public immutable eligibility;

    /// @notice Sole authorized caller of `deposit` / `redeem`.
    address public immutable executor;

    /// @inheritdoc IYieldAdapter
    address public immutable asset;

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

    /// @param wrapper_ VaultV2 wrapper used as the position token.
    /// @param factory_ Canonical VaultV2 factory authenticating the wrapper.
    /// @param adapterFactory_ Factory authenticating the wrapper's VaultV1 liquidity adapter.
    /// @param eligibility_ Eligibility oracle for the Morpho VaultV1 child.
    /// @param executor_ GrowYield executor authorized to call this adapter.
    constructor(
        IVaultV2 wrapper_,
        IVaultV2Factory factory_,
        IMorphoVaultV1AdapterFactory adapterFactory_,
        IMorphoVaultEligibility eligibility_,
        address executor_
    ) {
        if (
            address(wrapper_).code.length == 0 || address(factory_).code.length == 0
                || address(adapterFactory_).code.length == 0
                || address(eligibility_).code.length == 0 || executor_.code.length == 0
        ) revert Invalid();

        if (!factory_.isVaultV2(address(wrapper_))) revert Invalid();
        if (wrapper_.adaptersLength() != 1) revert Invalid();

        address liquidityAdapter_ = wrapper_.adapters(0);
        if (
            !adapterFactory_.isMorphoVaultV1Adapter(liquidityAdapter_)
                || !wrapper_.isAdapter(liquidityAdapter_)
                || wrapper_.liquidityAdapter() != liquidityAdapter_
                || wrapper_.liquidityData().length != 0
        ) revert Invalid();

        IMorphoVaultV1Adapter morphoAdapter = IMorphoVaultV1Adapter(liquidityAdapter_);
        if (
            morphoAdapter.factory() != address(adapterFactory_)
                || morphoAdapter.parentVault() != address(wrapper_)
        ) revert Invalid();

        address child_ = morphoAdapter.morphoVaultV1();
        if (child_.code.length == 0 || !eligibility_.isEligibleVault(child_)) {
            revert Invalid();
        }

        address asset_ = IERC4626(address(wrapper_)).asset();
        if (
            asset_.code.length == 0 || asset_ != IERC4626(child_).asset()
                || !wrapper_.abdicated(IVaultV2.addAdapter.selector)
                || !wrapper_.abdicated(IVaultV2.removeAdapter.selector)
        ) revert Invalid();

        wrapper = wrapper_;
        child = child_;
        liquidityAdapter = liquidityAdapter_;
        eligibility = eligibility_;
        executor = executor_;
        asset = asset_;
    }

    /// @inheritdoc IYieldAdapter
    function positionToken() external view returns (address) {
        return address(wrapper);
    }

    /// @inheritdoc IYieldAdapter
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return IERC4626(address(wrapper)).previewDeposit(assets);
    }

    /// @inheritdoc IYieldAdapter
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return IERC4626(address(wrapper)).previewRedeem(shares);
    }

    /// @inheritdoc IYieldAdapter
    function deposit(uint256 assets, address receiver) external onlyExecutor returns (uint256) {
        _checkDeposit(receiver);

        IERC4626 vault = IERC4626(address(wrapper));
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 sharesBefore = IERC20(address(wrapper)).balanceOf(receiver);

        IERC20(asset).forceApprove(address(wrapper), assets);
        uint256 shares = vault.deposit(assets, receiver);
        IERC20(asset).forceApprove(address(wrapper), 0);

        // Strict ERC-4626 conformance: reported shares must equal the receiver's delta.
        if (IERC20(address(wrapper)).balanceOf(receiver) - sharesBefore != shares) {
            revert NonCompliantVault();
        }

        // Exactly `assets` consumed; anything else means the vault misbehaved.
        if (IERC20(asset).balanceOf(address(this)) != balanceBefore - assets) {
            revert ResidualBalance();
        }

        return shares;
    }

    /// @inheritdoc IYieldAdapter
    function redeem(uint256 shares, address receiver) external onlyExecutor returns (uint256) {
        if (!wrapper.canSendShares(address(this)) || !wrapper.canReceiveAssets(receiver)) {
            revert VenueGate();
        }
        uint256 sharesBefore = IERC20(address(wrapper)).balanceOf(address(this));

        uint256 assetsOut = IERC4626(address(wrapper)).redeem(shares, receiver, address(this));

        // Exactly `shares` consumed; anything else means the vault misbehaved.
        if (IERC20(address(wrapper)).balanceOf(address(this)) != sharesBefore - shares) {
            revert ResidualBalance();
        }

        return assetsOut;
    }

    /// @dev Re-checks mutable eligibility and liquidity routing before deposits.
    function _checkDeposit(address receiver) private view {
        if (
            !eligibility.isEligibleVault(child) || wrapper.liquidityAdapter() != liquidityAdapter
                || wrapper.liquidityData().length != 0
        ) revert VenueDrift();
        if (
            !wrapper.canReceiveShares(receiver) || !wrapper.canSendAssets(address(this))
                || !wrapper.canSendShares(receiver) || !wrapper.canReceiveShares(address(this))
                || !wrapper.canSendShares(address(this)) || !wrapper.canReceiveAssets(receiver)
        ) revert VenueGate();
    }
}
