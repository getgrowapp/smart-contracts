// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoVaultV1Adapter} from "vault-v2/adapters/interfaces/IMorphoVaultV1Adapter.sol";

import {IMorphoVaultEligibility} from "../../interfaces/IMorphoVaultEligibility.sol";
import {IYieldAdapter} from "../IGrowYield1271.sol";

/**
 * @notice Morpho VaultV2 venue adapter for one wrapper vault.
 *
 * @dev The wrapper must be a factory-deployed VaultV2 whose single, liquidity-designated
 *      adapter routes into an eligible Morpho VaultV1 child of the same asset, with
 *      `addAdapter`/`removeAdapter` abdicated so the adapter set can never change.
 *      All of that is validated at construction (ported from GrowYieldRegistryV6's
 *      wrapper validation).
 *
 *      Deposits additionally re-check the mutable subset on every call — child
 *      eligibility (external oracle) and the liquidity-adapter designation — so config
 *      drift after allowlisting fails closed. Redemptions intentionally skip drift
 *      checks: exiting an ineligible venue must always remain possible.
 *
 *      Only the pinned executor may call state-changing methods: the adapter holds
 *      funds transiently mid-call and its accounting assumes the executor's exact
 *      push-then-call sequence.
 */
contract MorphoVaultV2Adapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    IVaultV2 public immutable wrapper;
    address public immutable child;
    address public immutable liquidityAdapter;
    IMorphoVaultEligibility public immutable eligibility;
    address public immutable executor;
    address public immutable asset;

    error Invalid();
    error OnlyExecutor();
    error VenueDrift();
    error NonCompliantVault();
    error ResidualBalance();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    constructor(
        IVaultV2 wrapper_,
        IVaultV2Factory factory_,
        address adapterFactory_,
        IMorphoVaultEligibility eligibility_,
        address executor_
    ) {
        if (
            address(wrapper_) == address(0) || address(factory_) == address(0)
                || adapterFactory_ == address(0) || address(eligibility_) == address(0)
                || executor_ == address(0)
        ) revert Invalid();

        if (!factory_.isVaultV2(address(wrapper_))) revert Invalid();
        if (wrapper_.adaptersLength() != 1) revert Invalid();

        address liquidityAdapter_ = wrapper_.adapters(0);
        if (
            !wrapper_.isAdapter(liquidityAdapter_)
                || wrapper_.liquidityAdapter() != liquidityAdapter_
                || wrapper_.liquidityData().length != 0
        ) revert Invalid();

        IMorphoVaultV1Adapter morphoAdapter = IMorphoVaultV1Adapter(liquidityAdapter_);
        if (
            morphoAdapter.factory() != adapterFactory_
                || morphoAdapter.parentVault() != address(wrapper_)
        ) revert Invalid();

        address child_ = morphoAdapter.morphoVaultV1();
        if (!factory_.isVaultV2(child_) || !eligibility_.isEligibleVault(child_)) {
            revert Invalid();
        }

        address asset_ = IERC4626(address(wrapper_)).asset();
        if (
            asset_ != IERC4626(child_).asset() || !wrapper_.abdicated(IVaultV2.addAdapter.selector)
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
        _checkDrift();

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
        uint256 sharesBefore = IERC20(address(wrapper)).balanceOf(address(this));

        uint256 assetsOut = IERC4626(address(wrapper)).redeem(shares, receiver, address(this));

        // Exactly `shares` consumed; anything else means the vault misbehaved.
        if (IERC20(address(wrapper)).balanceOf(address(this)) != sharesBefore - shares) {
            revert ResidualBalance();
        }

        return assetsOut;
    }

    /**
     * @dev Re-checks the post-construction-mutable venue config on deposit. The adapter
     *      set itself cannot change (add/removeAdapter abdicated, verified in the
     *      constructor), but the liquidity designation and external eligibility can.
     */
    function _checkDrift() private view {
        if (
            !eligibility.isEligibleVault(child) || wrapper.liquidityAdapter() != liquidityAdapter
                || wrapper.liquidityData().length != 0
        ) revert VenueDrift();
    }
}
