// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";
import {
    IGrowYieldRegistry,
    IGrowYieldTypes
} from "../yield-v6/IGrowYieldSystem.sol";

/// @notice Runtime full-balance executor with single-call reallocateAll.
contract GrowYieldExecutor1271V2 is ReentrancyGuard, IGrowYieldTypes {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint16 public constant MAX_LOSS_BPS = 100;

    IGrowYieldRegistry public immutable registry;
    uint16 public immutable maxLossBps;

    error Invalid();
    error NoBalance();
    error UnsupportedToken();
    error InsufficientOutput();
    error ResidualBalance();
    error AssetMismatch();

    constructor(IGrowYieldRegistry registry_, uint16 maxLossBps_) {
        if (address(registry_) == address(0) || maxLossBps_ > MAX_LOSS_BPS) {
            revert Invalid();
        }

        registry = registry_;
        maxLossBps = maxLossBps_;
    }

    function withdrawAll(
        Protocol protocol,
        address target,
        address assetHint
    ) external nonReentrant {
        Venue memory source = registry.exitVenue(protocol, target, assetHint);
        _withdraw(msg.sender, protocol, target, source);
    }

    function depositAll(
        Protocol protocol,
        address target,
        address asset
    ) external nonReentrant returns (uint256) {
        Venue memory destination = registry.entryVenue(protocol, target, asset);

        IERC20 underlying = IERC20(destination.asset);
        uint256 amount = underlying.balanceOf(msg.sender);

        if (amount == 0) revert NoBalance();

        uint256 beforeBalance = underlying.balanceOf(address(this));

        underlying.safeTransferFrom(msg.sender, address(this), amount);

        uint256 received =
            underlying.balanceOf(address(this)) - beforeBalance;

        if (received != amount) revert UnsupportedToken();

        uint256 output =
            _deposit(msg.sender, protocol, target, destination, received);

        if (underlying.balanceOf(address(this)) != beforeBalance) {
            revert ResidualBalance();
        }

        return output;
    }

    function reallocateAll(
        Protocol sourceProtocol,
        address sourceTarget,
        address sourceAssetHint,
        Protocol destinationProtocol,
        address destinationTarget,
        address destinationAsset
    ) external nonReentrant returns (uint256) {
        Venue memory source = registry.exitVenue(
            sourceProtocol, sourceTarget, sourceAssetHint
        );

        Venue memory destination = registry.entryVenue(
            destinationProtocol, destinationTarget, destinationAsset
        );

        if (source.asset != destination.asset) revert AssetMismatch();

        IERC20 underlying = IERC20(source.asset);
        uint256 beforeBalance = underlying.balanceOf(address(this));

        _withdraw(address(this), sourceProtocol, sourceTarget, source);

        uint256 recovered =
            underlying.balanceOf(address(this)) - beforeBalance;

        if (recovered == 0) revert NoBalance();

        uint256 output = _deposit(
            msg.sender,
            destinationProtocol,
            destinationTarget,
            destination,
            recovered
        );

        if (underlying.balanceOf(address(this)) != beforeBalance) {
            revert ResidualBalance();
        }

        return output;
    }

    function _withdraw(
        address recipient,
        Protocol protocol,
        address target,
        Venue memory source
    ) private {
        IERC20 position = IERC20(source.positionToken);
        IERC20 underlying = IERC20(source.asset);

        uint256 amount = position.balanceOf(msg.sender);
        if (amount == 0) revert NoBalance();

        uint256 positionBefore = position.balanceOf(address(this));
        uint256 assetBefore = underlying.balanceOf(address(this));

        position.safeTransferFrom(msg.sender, address(this), amount);

        if (position.balanceOf(address(this)) - positionBefore != amount) {
            revert UnsupportedToken();
        }

        if (protocol == Protocol.MORPHO) {
            IERC4626(target).redeem(amount, recipient, address(this));
        } else {
            IAaveV3Pool(target).withdraw(source.asset, amount, recipient);
        }

        if (position.balanceOf(address(this)) != positionBefore) {
            revert ResidualBalance();
        }

        if (
            recipient != address(this)
                && underlying.balanceOf(address(this)) != assetBefore
        ) revert ResidualBalance();
    }

    function _deposit(
        address recipient,
        Protocol protocol,
        address target,
        Venue memory destination,
        uint256 assets
    ) private returns (uint256 receivedPosition) {
        IERC20 underlying = IERC20(destination.asset);
        IERC20 position = IERC20(destination.positionToken);

        uint256 positionBefore = position.balanceOf(recipient);

        underlying.forceApprove(target, assets);

        uint256 expected;
        uint256 returned;

        if (protocol == Protocol.MORPHO) {
            expected = IERC4626(target).previewDeposit(assets);
            if (expected == 0) revert InsufficientOutput();

            returned = IERC4626(target).deposit(assets, recipient);
        } else {
            expected = assets;
            IAaveV3Pool(target).supply(destination.asset, assets, recipient, 0);
        }

        underlying.forceApprove(target, 0);

        receivedPosition = position.balanceOf(recipient) - positionBefore;

        uint256 minimum = (expected * (BPS - maxLossBps)) / BPS;

        if (
            receivedPosition == 0 || receivedPosition < minimum
                || (protocol == Protocol.MORPHO && returned != receivedPosition)
        ) revert InsufficientOutput();
    }
}
