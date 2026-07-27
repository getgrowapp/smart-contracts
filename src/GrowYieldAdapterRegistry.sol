// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoVaultV1Adapter} from "vault-v2/adapters/interfaces/IMorphoVaultV1Adapter.sol";
import {
    IMorphoVaultV1AdapterFactory
} from "vault-v2/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";

import {IAaveProtocolDataProvider} from "./interfaces/IAaveProtocolDataProvider.sol";
import {IAdapterVenue} from "./interfaces/IAdapterVenue.sol";
import {ICapyFiCaToken} from "./interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "./interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "./interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "./interfaces/IEulerEVaultFactory.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol,
    Venue
} from "./interfaces/IGrowYieldAdapterRegistry.sol";
import {IMorphoVaultEligibility} from "./interfaces/IMorphoVaultEligibility.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

/// @title GrowYieldAdapterRegistry
/// @notice Append-only venue set whose members must be authenticated by deployment-pinned
///         protocol registrars.
/// @dev Abstract: this is the admission half of `GrowYieldExecutor`, which inherits it. They are
///      one contract because they were never separable — every operation resolves a venue from
///      this state on the same call, and an executor pointed at a registry that did not name it
///      back was a class of misconfiguration that simply cannot be expressed now. `address(this)`
///      is the executor every admitted adapter must authorize.
///
///      One adapter serves every venue of its protocol, so this registry — not the adapter — is
///      where a venue becomes usable. `addVaults` is the only writer: an admitted venue's
///      adapter, protocol, directions, and `(asset, positionToken)` pair are fixed for the
///      registry's lifetime. The supported protocol set and its canonical registrars are
///      constructor-pinned, so supporting a new protocol requires deploying a new registry.
///      Nothing on-chain iterates the admitted set, so the venue count is bounded only by
///      governance intent.
///
///      Two distinct questions are answered in two distinct places. The registrar checks here
///      answer "is this a genuine venue of the named protocol?" from the registry's own pinned
///      registrars and from the venue's own state — never from the adapter's account of the
///      venue — so the owner cannot admit a venue the protocol never created. Whether that
///      authentic venue is an acceptable Grow risk remains the owner's decision, expressed by
///      calling `addVaults` at all.
///
///      Because adapters are venue-agnostic, admission also pins each venue's token pair. The
///      executor derives its source and output tokens from that pinned pair and rejects an
///      operation whose adapter no longer derives the same, which is what makes protocol-level
///      re-pointing (an Aave reserve's aToken, a drifted `asset()`) fail closed.
///
///      Adapters must be direct, non-upgradeable deployments because their runtime code hash is
///      pinned on first admission. Once the intended venue set is final the owner may renounce
///      ownership, freezing the venue set forever.
///
///      Admitting a venue is the single governance decision that makes it usable: there is no
///      per-account opt-in on the execution side.
/// @custom:security-contact security@getgrowapp.co
abstract contract GrowYieldAdapterRegistry is Ownable2Step, IGrowYieldAdapterRegistry {
    /// @notice Aave V3 pool every admitted Aave adapter must supply to.
    address public immutable aavePool;

    /// @notice Aave V3 data provider that must resolve an admitted reserve's aToken.
    address public immutable aaveDataProvider;

    /// @notice Canonical VaultV2 factory that must have created an admitted Morpho wrapper.
    address public immutable morphoVaultFactory;

    /// @notice Factory that must have created an admitted wrapper's liquidity adapter.
    address public immutable morphoAdapterFactory;

    /// @notice Eligibility oracle that must admit an admitted wrapper's VaultV1 child.
    address public immutable morphoEligibility;

    /// @notice EVK GenericFactory that must have created an admitted EVault proxy.
    address public immutable eulerEVaultFactory;

    /// @notice EulerEarnFactory that must have created an admitted Earn vault.
    address public immutable eulerEarnFactory;

    /// @notice CapyFi Comptroller that must list an admitted caToken market.
    address public immutable capyFiComptroller;

    /// @dev Read directly by the inherited execution path; `venue()` is the external view.
    mapping(address vault => Venue) internal _venues;

    mapping(address vault => Protocol) private _protocols;

    /// @dev Position tokens already claimed by an admitted venue, to reject duplicates.
    mapping(address positionToken => bool) private _positionClaimed;

    address[] private _vaults;

    /// @inheritdoc IGrowYieldAdapterRegistry
    mapping(address adapter => bytes32) public adapterCodeHash;

    /// @param owner_ Address authorized to admit venues; should be a Safe or TimelockController.
    /// @param registrars_ Canonical registrars pinned for this contract's lifetime. A zero
    ///        address marks that protocol unsupported here.
    constructor(address owner_, Registrars memory registrars_) Ownable(owner_) {
        // A protocol is either fully pinned or absent. A half-configured protocol would
        // otherwise skip part of its authenticity proof at admission time.
        bool aave = registrars_.aavePool != address(0);
        if (aave != (registrars_.aaveDataProvider != address(0))) revert Invalid();

        bool morpho = registrars_.morphoVaultFactory != address(0);
        if (
            morpho != (registrars_.morphoAdapterFactory != address(0))
                || morpho != (registrars_.morphoEligibility != address(0))
        ) revert Invalid();

        _requireContractOrUnset(registrars_.aavePool);
        _requireContractOrUnset(registrars_.aaveDataProvider);
        _requireContractOrUnset(registrars_.morphoVaultFactory);
        _requireContractOrUnset(registrars_.morphoAdapterFactory);
        _requireContractOrUnset(registrars_.morphoEligibility);
        _requireContractOrUnset(registrars_.eulerEVaultFactory);
        _requireContractOrUnset(registrars_.eulerEarnFactory);
        _requireContractOrUnset(registrars_.capyFiComptroller);

        aavePool = registrars_.aavePool;
        aaveDataProvider = registrars_.aaveDataProvider;
        morphoVaultFactory = registrars_.morphoVaultFactory;
        morphoAdapterFactory = registrars_.morphoAdapterFactory;
        morphoEligibility = registrars_.morphoEligibility;
        eulerEVaultFactory = registrars_.eulerEVaultFactory;
        eulerEarnFactory = registrars_.eulerEarnFactory;
        capyFiComptroller = registrars_.capyFiComptroller;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function addVaults(VaultConfig[] calldata vaults) external onlyOwner {
        uint256 count = vaults.length;
        if (count == 0) revert EmptyBatch();

        for (uint256 i; i < count; ++i) {
            _addVault(vaults[i]);
        }
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function venue(address vault) external view returns (Venue memory) {
        return _venues[vault];
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function canDeposit(address vault) external view returns (bool) {
        return _venues[vault].canDeposit;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function canRedeem(address vault) external view returns (bool) {
        return _venues[vault].canRedeem;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function vaultAdapter(address vault) external view returns (address) {
        return _venues[vault].adapter;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function vaultProtocol(address vault) external view returns (Protocol) {
        return _protocols[vault];
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    /// @inheritdoc IGrowYieldAdapterRegistry
    function vaultAt(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    /// @dev Admits one venue after protocol-independent and registrar checks.
    function _addVault(VaultConfig calldata config) private {
        address adapter = config.adapter;
        address vault = config.vault;
        if (
            adapter.code.length == 0 || vault.code.length == 0
                || (!config.canDeposit && !config.canRedeem)
        ) revert Invalid();
        if (_venues[vault].adapter != address(0)) revert VaultAlreadyRegistered();
        // The adapter must authorize this very contract; there is no separate executor to name.
        if (IYieldAdapter(adapter).executor() != address(this)) revert Invalid();

        address asset = IYieldAdapter(adapter).asset(vault);
        address position = IYieldAdapter(adapter).positionToken(vault);
        if (asset.code.length == 0 || position.code.length == 0 || asset == position) {
            revert Invalid();
        }

        // One position token may back one venue. A second venue reporting the same position
        // would double-count an account's directional budget over a single balance.
        if (_positionClaimed[position]) revert DuplicateVenue();

        _requireCanonicalVenue(config.protocol, adapter, vault, asset, position);
        bytes32 codeHash = _pinAdapter(adapter);

        _venues[vault] =
            Venue(adapter, codeHash, asset, position, config.canDeposit, config.canRedeem);
        _protocols[vault] = config.protocol;
        _positionClaimed[position] = true;
        _vaults.push(vault);

        emit VaultAdded(
            vault, adapter, config.protocol, asset, position, config.canDeposit, config.canRedeem
        );
    }

    /// @dev Pins an adapter's runtime code hash on first admission and enforces it afterwards.
    function _pinAdapter(address adapter) private returns (bytes32 current) {
        bytes32 pinned = adapterCodeHash[adapter];
        current = adapter.codehash;
        if (pinned == bytes32(0)) {
            adapterCodeHash[adapter] = current;
            emit AdapterPinned(adapter, current);
        } else if (pinned != current) {
            revert AdapterCodeChanged();
        }
    }

    /// @dev Reads an `address` getter from an adapter. An adapter of a different protocol simply
    ///      has no such getter, so a mis-declared protocol surfaces as `RegistrarMismatch`
    ///      instead of an undiagnosable decode revert in a governance transaction.
    function _adapterWiring(address adapter, bytes4 selector) private view returns (address) {
        (bool ok, bytes memory returned) = adapter.staticcall(abi.encodeWithSelector(selector));
        if (!ok || returned.length != 32) revert RegistrarMismatch();

        // Decoded as a word so dirty upper bits are rejected rather than silently masked.
        uint256 word = abi.decode(returned, (uint256));
        if (word > type(uint160).max) revert RegistrarMismatch();
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    /// @dev Proves `vault` is a genuine venue of `protocol` using this registry's pinned
    ///      registrars and the venue's own state, and that `adapter` is wired to exactly those
    ///      registrars. Facts read from `adapter` are protocol-wide only.
    function _requireCanonicalVenue(
        Protocol protocol,
        address adapter,
        address vault,
        address asset,
        address position
    ) private view {
        if (protocol == Protocol.AAVE) {
            _requireCanonicalAave(adapter, vault, asset, position);
        } else if (protocol == Protocol.MORPHO) {
            _requireCanonicalMorpho(adapter, vault, asset, position);
        } else if (protocol == Protocol.EULER_EVK) {
            address factory = eulerEVaultFactory;
            if (factory == address(0)) revert UnsupportedProtocol();
            if (_adapterWiring(adapter, IAdapterVenue.factory.selector) != factory) {
                revert RegistrarMismatch();
            }
            if (!IEulerEVaultFactory(factory).isProxy(vault)) revert NotCanonicalVenue();
            _requireErc4626Venue(vault, asset, position);
        } else if (protocol == Protocol.EULER_EARN) {
            address factory = eulerEarnFactory;
            if (factory == address(0)) revert UnsupportedProtocol();
            if (_adapterWiring(adapter, IAdapterVenue.factory.selector) != factory) {
                revert RegistrarMismatch();
            }
            if (!IEulerEarnFactory(factory).isVault(vault)) revert NotCanonicalVenue();
            _requireErc4626Venue(vault, asset, position);
        } else {
            // Protocol.CAPYFI: ABI decoding rejects any value outside the enum.
            _requireCanonicalCapyFi(adapter, vault, asset, position);
        }
    }

    /// @dev Aave keys reserves by underlying asset and shares one pool across every reserve, so
    ///      the venue identifier is the asset and the position token is the reserve's aToken.
    function _requireCanonicalAave(address adapter, address vault, address asset, address position)
        private
        view
    {
        address pool = aavePool;
        address provider = aaveDataProvider;
        if (pool == address(0)) revert UnsupportedProtocol();
        if (
            _adapterWiring(adapter, IAdapterVenue.pool.selector) != pool
                || _adapterWiring(adapter, IAdapterVenue.dataProvider.selector) != provider
        ) revert RegistrarMismatch();

        if (asset != vault) revert NotCanonicalVenue();
        (address aToken,,) = IAaveProtocolDataProvider(provider).getReserveTokensAddresses(vault);
        if (aToken != position) revert NotCanonicalVenue();
    }

    /// @dev Proves the full wrapper shape once. VaultV2 abdication is irreversible and the
    ///      `adapters` array only changes through `addAdapter` / `removeAdapter`, so a
    ///      single-entry adapter set verified here stays frozen for the wrapper's lifetime. The
    ///      adapter's per-operation check that liquidity still routes to `adapters(0)` is then
    ///      sufficient, without re-proving factory provenance on every operation.
    function _requireCanonicalMorpho(
        address adapter,
        address vault,
        address asset,
        address position
    ) private view {
        address vaultFactory = morphoVaultFactory;
        address eligibility = morphoEligibility;
        if (vaultFactory == address(0)) revert UnsupportedProtocol();
        if (_adapterWiring(adapter, IAdapterVenue.eligibility.selector) != eligibility) {
            revert RegistrarMismatch();
        }

        if (!IVaultV2Factory(vaultFactory).isVaultV2(vault)) revert NotCanonicalVenue();

        IVaultV2 wrapper = IVaultV2(vault);
        if (
            position != vault || wrapper.adaptersLength() != 1
                || !wrapper.abdicated(IVaultV2.addAdapter.selector)
                || !wrapper.abdicated(IVaultV2.removeAdapter.selector)
        ) revert NotCanonicalVenue();

        address liquidityAdapter = wrapper.adapters(0);
        if (
            !IMorphoVaultV1AdapterFactory(morphoAdapterFactory)
                    .isMorphoVaultV1Adapter(liquidityAdapter)
                || !wrapper.isAdapter(liquidityAdapter)
                || wrapper.liquidityAdapter() != liquidityAdapter
                || wrapper.liquidityData().length != 0
        ) revert NotCanonicalVenue();

        IMorphoVaultV1Adapter morphoAdapter = IMorphoVaultV1Adapter(liquidityAdapter);
        if (morphoAdapter.factory() != morphoAdapterFactory || morphoAdapter.parentVault() != vault)
        {
            revert NotCanonicalVenue();
        }

        address child = morphoAdapter.morphoVaultV1();
        if (
            child.code.length == 0 || asset != IERC4626(vault).asset()
                || asset != IERC4626(child).asset()
                || !IMorphoVaultEligibility(eligibility).isEligibleVault(child)
        ) revert NotCanonicalVenue();
    }

    /// @dev CapyFi markets are Compound-v2 caTokens, which are their own position token.
    function _requireCanonicalCapyFi(
        address adapter,
        address vault,
        address asset,
        address position
    ) private view {
        address comptroller = capyFiComptroller;
        if (comptroller == address(0)) revert UnsupportedProtocol();
        if (_adapterWiring(adapter, IAdapterVenue.comptroller.selector) != comptroller) {
            revert RegistrarMismatch();
        }

        (bool isListed,,) = ICapyFiComptroller(comptroller).markets(vault);
        if (
            !isListed || position != vault || ICapyFiCaToken(vault).comptroller() != comptroller
                || ICapyFiCaToken(vault).underlying() != asset
        ) revert NotCanonicalVenue();
    }

    /// @dev An ERC-4626 venue is its own position token and must report the pinned underlying.
    function _requireErc4626Venue(address vault, address asset, address position) private view {
        if (position != vault || IERC4626(vault).asset() != asset) revert NotCanonicalVenue();
    }

    /// @dev A pinned registrar must be a deployed contract; zero means protocol unsupported.
    function _requireContractOrUnset(address registrar) private view {
        if (registrar != address(0) && registrar.code.length == 0) revert Invalid();
    }
}
