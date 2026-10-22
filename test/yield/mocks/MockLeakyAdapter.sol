// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAdapterVenue} from "../../../src/interfaces/IAdapterVenue.sol";
import {IYieldAdapter} from "../../../src/interfaces/IYieldAdapter.sol";

/// @dev A structurally valid Euler EVK adapter that misbehaves in exactly one way, chosen per
///      test. Residual accounting used to run in both the adapter and the executor; now only the
///      executor enforces it, so it needs an adapter that actually strands or sweeps funds.
contract MockLeakyAdapter is IYieldAdapter, IAdapterVenue {
    using SafeERC20 for IERC20;

    enum Misbehavior {
        NONE,
        STRAND_SOURCE, // keeps part of what it was sent instead of depositing it
        RETAIN_OUTPUT, // mints to itself rather than the receiver
        SWEEP_DONATION // redeems more than it was attributed
    }

    address public immutable executor;
    address public immutable factory;

    Misbehavior public mode;

    // Unused by the EVK admission path, present to satisfy IAdapterVenue.
    address public pool;
    address public dataProvider;
    address public comptroller;
    address public eligibility;
    address public market;

    constructor(address executor_, address factory_) {
        executor = executor_;
        factory = factory_;
    }

    function setMode(Misbehavior mode_) external {
        mode = mode_;
    }

    function asset(address vault) external view returns (address) {
        return IERC4626(vault).asset();
    }

    function positionToken(address vault) external pure returns (address) {
        return vault;
    }

    function previewDeposit(address vault, uint256 assets) external view returns (uint256) {
        return IERC4626(vault).previewDeposit(assets);
    }

    function previewRedeem(address vault, uint256 shares) external view returns (uint256) {
        return IERC4626(vault).previewRedeem(shares);
    }

    function deposit(address vault, uint256 assets, address receiver) external returns (uint256) {
        address underlying = IERC4626(vault).asset();
        uint256 toDeposit = mode == Misbehavior.STRAND_SOURCE ? assets / 2 : assets;
        address creditTo = mode == Misbehavior.RETAIN_OUTPUT ? address(this) : receiver;

        IERC20(underlying).forceApprove(vault, toDeposit);
        return IERC4626(vault).deposit(toDeposit, creditTo);
    }

    function redeem(address vault, uint256 shares, address receiver) external returns (uint256) {
        uint256 toRedeem =
            mode == Misbehavior.SWEEP_DONATION ? IERC20(vault).balanceOf(address(this)) : shares;
        return IERC4626(vault).redeem(toRedeem, receiver, address(this));
    }
}
