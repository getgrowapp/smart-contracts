// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IMorphoVaultV1Adapter} from
    "vault-v2/adapters/interfaces/IMorphoVaultV1Adapter.sol";

import {IMorphoVaultEligibility} from "../interfaces/IMorphoVaultEligibility.sol";
import {IAaveProtocolDataProvider} from "../interfaces/IAaveProtocolDataProvider.sol";
import {IGrowYieldRegistry, IGrowYieldTypes} from "./IGrowYieldSystem.sol";

/// @notice Morpho/Aave venue allowlist. Owner should be a Safe or TimelockController.
contract GrowYieldRegistryV6 is Ownable2Step, IGrowYieldRegistry {
    struct MorphoRecord {
        address child;
        Venue venue;
    }

    IVaultV2Factory public immutable morphoFactory;
    IMorphoVaultEligibility public immutable morphoEligibility;
    address public immutable morphoAdapterFactory;
    address public immutable aavePool;
    IAaveProtocolDataProvider public immutable aaveDataProvider;

    mapping(address => bool) public supportedAsset;
    mapping(address => bool) public enabledMorphoChild;
    mapping(address => MorphoRecord) private morpho;
    mapping(address => Venue) private aave;

    error Invalid();
    error UnknownVenue();

    constructor(
        address owner_,
        IVaultV2Factory morphoFactory_,
        IMorphoVaultEligibility morphoEligibility_,
        address morphoAdapterFactory_,
        address aavePool_,
        IAaveProtocolDataProvider aaveDataProvider_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) ||
            address(morphoFactory_) == address(0) ||
            address(morphoEligibility_) == address(0) ||
            morphoAdapterFactory_ == address(0) ||
            aavePool_ == address(0) ||
            address(aaveDataProvider_) == address(0)
        ) revert Invalid();

        morphoFactory = morphoFactory_;
        morphoEligibility = morphoEligibility_;
        morphoAdapterFactory = morphoAdapterFactory_;
        aavePool = aavePool_;
        aaveDataProvider = aaveDataProvider_;
    }

    function setAsset(
        address asset,
        bool enabled
    ) external onlyOwner {
        if (asset == address(0)) revert Invalid();
        supportedAsset[asset] = enabled;
    }

    function setMorphoChild(
        address child,
        bool enabled
    ) external onlyOwner {
        if (
            !morphoFactory.isVaultV2(child) ||
            (
                enabled &&
                (
                    !morphoEligibility.isEligibleVault(child) ||
                    !supportedAsset[IERC4626(child).asset()]
                )
            )
        ) revert Invalid();

        enabledMorphoChild[child] = enabled;
    }

    function setMorphoVenue(
        address wrapper,
        bool canEnter,
        bool canExit
    ) external onlyOwner {
        (address child, address asset) = (address(0), address(0));

        if (canEnter || canExit) {
            (child, asset) = _validateWrapper(wrapper);
        } else {
            MorphoRecord memory existing = morpho[wrapper];
            child = existing.child;
            asset = existing.venue.asset;
        }

        morpho[wrapper] = MorphoRecord({
            child: child,
            venue: Venue(
                asset,
                wrapper,
                canEnter,
                canExit
            )
        });
    }

    function setAaveVenue(
        address asset,
        bool canEnter,
        bool canExit
    ) external onlyOwner {
        if (
            asset == address(0) ||
            ((canEnter || canExit) && !supportedAsset[asset])
        ) revert Invalid();

        (address aToken,,) =
            aaveDataProvider.getReserveTokensAddresses(asset);

        if (aToken == address(0)) revert Invalid();

        aave[asset] = Venue(
            asset,
            aToken,
            canEnter,
            canExit
        );
    }

    function entryVenue(
        Protocol protocol,
        address target,
        address assetHint
    ) external view returns (Venue memory venue_) {
        if (protocol == Protocol.MORPHO) {
            MorphoRecord memory record = morpho[target];
            venue_ = record.venue;

            if (
                !venue_.canEnter ||
                !supportedAsset[venue_.asset] ||
                !enabledMorphoChild[record.child] ||
                !morphoEligibility.isEligibleVault(record.child)
            ) revert UnknownVenue();

            (address child, address asset) =
                _validateWrapper(target);

            if (
                child != record.child ||
                asset != venue_.asset
            ) revert Invalid();

            return venue_;
        }

        if (protocol == Protocol.AAVE) {
            if (target != aavePool) revert UnknownVenue();

            venue_ = aave[assetHint];

            if (
                !venue_.canEnter ||
                !supportedAsset[assetHint] ||
                venue_.asset != assetHint
            ) revert UnknownVenue();

            (address aToken,,) =
                aaveDataProvider.getReserveTokensAddresses(assetHint);

            if (aToken != venue_.positionToken) revert Invalid();

            return venue_;
        }

        revert UnknownVenue();
    }

    function exitVenue(
        Protocol protocol,
        address target,
        address assetHint
    ) external view returns (Venue memory venue_) {
        if (protocol == Protocol.MORPHO) {
            venue_ = morpho[target].venue;

            if (
                !venue_.canExit ||
                venue_.positionToken != target
            ) revert UnknownVenue();

            return venue_;
        }

        if (protocol == Protocol.AAVE) {
            venue_ = aave[assetHint];

            if (
                target != aavePool ||
                !venue_.canExit ||
                venue_.asset != assetHint ||
                venue_.positionToken == address(0)
            ) revert UnknownVenue();

            return venue_;
        }

        revert UnknownVenue();
    }

    function _validateWrapper(
        address wrapper
    ) private view returns (address child, address asset) {
        if (!morphoFactory.isVaultV2(wrapper)) revert Invalid();

        IVaultV2 vault = IVaultV2(wrapper);

        if (vault.adaptersLength() != 1) revert Invalid();

        address adapter = vault.adapters(0);

        if (
            !vault.isAdapter(adapter) ||
            vault.liquidityAdapter() != adapter ||
            vault.liquidityData().length != 0
        ) revert Invalid();

        IMorphoVaultV1Adapter adapter_ =
            IMorphoVaultV1Adapter(adapter);

        if (
            adapter_.factory() != morphoAdapterFactory ||
            adapter_.parentVault() != wrapper
        ) revert Invalid();

        child = adapter_.morphoVaultV1();

        if (
            !morphoFactory.isVaultV2(child) ||
            !enabledMorphoChild[child] ||
            !morphoEligibility.isEligibleVault(child)
        ) revert Invalid();

        asset = IERC4626(wrapper).asset();

        if (
            asset != IERC4626(child).asset() ||
            !supportedAsset[asset] ||
            !vault.abdicated(
                IVaultV2.addAdapter.selector
            ) ||
            !vault.abdicated(
                IVaultV2.removeAdapter.selector
            )
        ) revert Invalid();
    }
}
