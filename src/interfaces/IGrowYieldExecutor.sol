// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGrowYieldAdapterRegistry} from "./IGrowYieldAdapterRegistry.sol";

/// @notice Direction of a yield operation.
enum OperationKind {
    DEPOSIT,
    REDEEM
}

/// @notice How an operation resolves its source amount.
enum AmountMode {
    EXACT,
    FULL_BALANCE,
    PREVIOUS_OUTPUT
}

/// @notice One operation against a venue admitted by the caller's selected registry.
/// @dev The venue names itself, not its adapter: the registry resolves `vault` to the protocol
///      adapter, the pinned token pair, and the permitted directions, so a signed operation
///      cannot pair a venue with an adapter the registry did not admit it under.
/// @param vault Venue identifier, as its protocol keys it (see `IYieldAdapter`).
/// @param kind Deposit or redeem direction.
/// @param sourceToken Token pulled from the caller and verified against the venue's pinned pair.
/// @param amount Exact source amount when `amountMode` is `EXACT`; otherwise it must be zero.
/// @param amountMode Explicit source-amount resolution strategy.
/// @param minAmountOut Owner-signed absolute floor for the output credited to the caller.
struct Operation {
    address vault;
    OperationKind kind;
    address sourceToken;
    uint256 amount;
    AmountMode amountMode;
    uint256 minAmountOut;
}

/// @title IGrowYieldExecutor
/// @notice Routes caller funds through venues admitted by the caller's chosen registry.
interface IGrowYieldExecutor {
    /// @notice Emitted once per successfully executed operation.
    event Executed(
        address indexed account,
        address indexed vault,
        address adapter,
        OperationKind kind,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when an account selects the venue registry its operations use.
    event AccountRegistrySet(address indexed account, address indexed registry);

    /// @notice Emitted when an account sets epoch volume limits for a venue.
    event VaultPolicySet(
        address indexed account,
        address indexed vault,
        uint256 depositLimit,
        uint256 redeemLimit,
        uint48 epochDuration
    );

    /// @notice Emitted when an account explicitly resets a venue's epoch usage.
    event VaultPolicyUsageReset(address indexed account, address indexed vault);

    /// @notice Emitted when the immutable risk guardian permanently pauses a venue's deposits.
    event VaultDepositsPaused(address indexed vault);

    /// @notice The calling account has not selected a venue registry.
    error RegistryNotSet();

    /// @notice Constructor or registry-selection configuration is invalid.
    error Invalid();

    /// @notice `execute` received no operations.
    error EmptyBatch();

    /// @notice The registry has not admitted this venue, or not in this direction, or the
    ///         account has set no limit for it.
    error VenueNotAllowed();

    /// @notice The adapter runtime no longer matches its admission-time code hash.
    error AdapterCodeChanged();

    /// @notice The adapter no longer derives the token pair pinned for this venue at admission.
    error VenueDrift();

    /// @notice The declared source token does not match the venue and direction.
    error SourceTokenMismatch();

    /// @notice The resolved source-token amount is zero.
    error NoBalance();

    /// @notice The adapter's received source amount deviated more than one wei from the transfer.
    error UnsupportedToken();

    /// @notice Output is zero or below the loss-capped adapter preview.
    error InsufficientOutput();

    /// @notice The operation left more than rounding-level residual balance on the adapter.
    error ResidualBalance();

    /// @notice The operation exceeds the account's remaining directional epoch volume.
    error BudgetExceeded();

    /// @notice A maximum-integer limit would disable meaningful quantitative protection.
    error UnboundedPolicy();

    /// @notice The amount mode or its associated amount is invalid for this operation.
    error InvalidAmountMode();

    /// @notice A policy duration change was attempted without an explicit usage reset.
    error EpochDurationChangeRequiresReset();

    /// @notice A caller other than the immutable risk guardian attempted a pause.
    error OnlyRiskGuardian();

    /// @notice New deposits into this venue have been permanently paused.
    error DepositsPaused();

    /// @notice Select the venue registry the calling account's operations are checked against.
    /// @dev Keyed by `msg.sender`, so only the smart account itself can change its own registry.
    ///      The Grow policy library accepts no batch containing this call, so a policy owner
    ///      (session key) can never reach it: the change requires the account's own
    ///      owner-authorized validation path. Registries may be reselected; every selection
    ///      must be a deployed registry that authorizes this executor and has admitted at
    ///      least one venue.
    function setAccountRegistry(IGrowYieldAdapterRegistry registry_) external;

    /// @notice Set the calling account's directional epoch limits for an admitted venue.
    /// @dev A zero directional limit disables that direction. Setting both to zero revokes the venue.
    function setVaultPolicy(
        address vault,
        uint256 depositLimit,
        uint256 redeemLimit,
        uint48 epochDuration
    ) external;

    /// @notice Set policy limits and explicitly begin a fresh usage epoch.
    /// @dev Use this path to change `epochDuration`; resetting restores the full limits.
    function resetVaultPolicy(
        address vault,
        uint256 depositLimit,
        uint256 redeemLimit,
        uint48 epochDuration
    ) external;

    /// @notice Permanently disable new deposits into a venue, for every account and registry.
    /// @dev Redemptions remain available so accounts can always exit supported positions. The
    ///      venue must be admitted by a registry that authorizes this executor, so a mistyped
    ///      address fails loudly rather than recording a pause that protects nothing. Pausing
    ///      one venue never affects other venues of the same protocol.
    /// @param registry_ Registry that admitted `vault`, used only to validate the target.
    /// @param vault Venue whose deposits are permanently disabled.
    function pauseVaultDeposits(IGrowYieldAdapterRegistry registry_, address vault) external;

    /// @notice Return an account's configured limits and current epoch consumption for a venue.
    function vaultPolicy(address account, address vault)
        external
        view
        returns (
            uint256 depositLimit,
            uint256 redeemLimit,
            uint256 depositSpent,
            uint256 redeemSpent,
            uint48 epochDuration,
            uint48 epochStart
        );

    /// @notice Venue registry consulted for `account`'s operations; zero until selected.
    function accountRegistry(address account) external view returns (IGrowYieldAdapterRegistry);

    /// @notice Maximum accepted shortfall vs. adapter preview, in basis points.
    function maxLossBps() external view returns (uint16);

    /// @notice Immutable address authorized to permanently pause venue deposits.
    function riskGuardian() external view returns (address);

    /// @notice Whether new deposits into a venue are permanently paused.
    function depositsPaused(address vault) external view returns (bool);

    /// @notice Execute operations and credit every output directly to `msg.sender`.
    function execute(Operation[] calldata ops) external returns (uint256[] memory received);
}
