// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Protocol a venue is admitted under, selecting which pinned registrar authenticates it.
/// @dev Closed for the registry's lifetime; a new protocol requires a new registry deployment.
///      ABI decoding rejects out-of-range values.
enum Protocol {
    AAVE,
    MORPHO,
    EULER_EVK,
    EULER_EARN,
    CAPYFI,
    GETEQUITY
}

/// @notice Everything the executor needs to run an operation against an admitted venue.
/// @dev A zero `adapter` means the venue is not admitted. The executor derives its source and
///      output tokens from the pinned `asset` / `positionToken`, not from the adapter, and
///      rejects an operation whose adapter has drifted away from them.
/// @param adapter Protocol adapter that transacts with this venue.
/// @param adapterCodeHash Adapter runtime code hash pinned when it first admitted a venue,
///        carried here so resolving a venue costs one call instead of two.
/// @param asset Underlying token pinned for this venue at admission.
/// @param positionToken Position token pinned for this venue at admission.
/// @param canDeposit Whether new deposits may be routed into this venue.
/// @param canRedeem Whether redemptions may be routed out of this venue.
struct Venue {
    address adapter;
    bytes32 adapterCodeHash;
    address asset;
    address positionToken;
    bool canDeposit;
    bool canRedeem;
}

/// @title IGrowYieldAdapterRegistry
/// @notice Append-only directional permissions for factory-authenticated venues.
/// @dev Implemented by `GrowYieldExecutor` itself — admission and execution are one contract.
interface IGrowYieldAdapterRegistry {
    /// @notice Canonical protocol registrars pinned for this registry's lifetime.
    /// @dev A zero address marks the protocol unsupported by this registry; `addVaults`
    ///      then rejects it. Aave requires both fields; Morpho requires all three.
    /// @param aavePool Aave V3 pool every Aave adapter must supply to.
    /// @param aaveDataProvider Aave V3 data provider that resolves a reserve's aToken.
    /// @param morphoVaultFactory Canonical VaultV2 factory that must have created the wrapper.
    /// @param morphoAdapterFactory Factory that must have created the wrapper's liquidity adapter.
    /// @param morphoEligibility Eligibility oracle that must admit the VaultV1 child.
    /// @param eulerEVaultFactory EVK GenericFactory that must have created the EVault proxy.
    /// @param eulerEarnFactory EulerEarnFactory that must have created the Earn vault.
    /// @param capyFiComptroller CapyFi Comptroller that must list the caToken market.
    /// @param getEquityMarket GetEquity market the adapter buys and sells through. Zero means
    ///        GetEquity is unsupported. Each listed token is another venue.
    struct Registrars {
        address aavePool;
        address aaveDataProvider;
        address morphoVaultFactory;
        address morphoAdapterFactory;
        address morphoEligibility;
        address eulerEVaultFactory;
        address eulerEarnFactory;
        address capyFiComptroller;
        address getEquityMarket;
    }

    /// @notice One venue admission request.
    /// @param adapter Protocol adapter that will transact with `vault`.
    /// @param vault Venue identifier, as the protocol keys it (see `IYieldAdapter`).
    /// @param protocol Protocol whose pinned registrar must authenticate `vault`.
    /// @param canDeposit Whether new deposits may be routed into `vault`.
    /// @param canRedeem Whether redemptions may be routed out of `vault`.
    struct VaultConfig {
        address adapter;
        address vault;
        Protocol protocol;
        bool canDeposit;
        bool canRedeem;
    }

    /// @notice Emitted once for each venue admitted; entries are never mutated.
    event VaultAdded(
        address indexed vault,
        address indexed adapter,
        Protocol protocol,
        address asset,
        address positionToken,
        bool canDeposit,
        bool canRedeem
    );

    /// @notice Emitted the first time an adapter's runtime code hash is pinned.
    event AdapterPinned(address indexed adapter, bytes32 codeHash);

    /// @notice The executor, registrar, adapter, or venue configuration is invalid.
    error Invalid();

    /// @notice `addVaults` or `execute` received no entries.
    error EmptyBatch();

    /// @notice This registry pins no registrar for the declared protocol.
    error UnsupportedProtocol();

    /// @notice The adapter is wired to protocol infrastructure this registry does not pin.
    error RegistrarMismatch();

    /// @notice The protocol's registrar does not recognize the venue.
    error NotCanonicalVenue();

    /// @notice The venue is already admitted; entries are append-only.
    error VaultAlreadyRegistered();

    /// @notice Another admitted venue already holds this venue's position token.
    error DuplicateVenue();

    /// @notice The adapter's runtime code no longer matches the hash pinned on first admission,
    ///         which in practice means an EIP-7702 delegated EOA re-pointed itself. Checked at
    ///         admission and again on every operation.
    error AdapterCodeChanged();

    /// @notice Admit venues authenticated by this registry's pinned registrars.
    /// @dev Append-only: an admitted venue's adapter, directions, and token pair are never
    ///      mutated or removed. Deposit-side wind-down uses the executor's risk guardian.
    /// @param vaults Venues to admit, each with its adapter, protocol, and permissions.
    function addVaults(VaultConfig[] calldata vaults) external;

    /// @notice Resolved venue record for `vault`; `adapter` is zero if it is not admitted.
    /// @dev Carries `canDeposit` and `canRedeem`, so there are no separate direction getters.
    function venue(address vault) external view returns (Venue memory);

    /// @notice Adapter admitted for `vault`; zero if it is not admitted.
    function vaultAdapter(address vault) external view returns (address);

    /// @notice Protocol `vault` was admitted under; meaningless unless it is admitted.
    function vaultProtocol(address vault) external view returns (Protocol);

    /// @notice Runtime code hash pinned for `adapter`; zero if it has admitted no venue.
    function adapterCodeHash(address adapter) external view returns (bytes32);

    /// @notice Number of admitted venues.
    function vaultCount() external view returns (uint256);

    /// @notice Venue at `index` in admission order.
    function vaultAt(uint256 index) external view returns (address);
}
