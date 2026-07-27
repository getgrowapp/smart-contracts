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

/// @notice One operation against a venue admitted by this executor's registry.
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
/// @notice Routes a caller's own funds through venues admitted by this executor's registry.
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

    /// @notice Emitted when the immutable risk guardian permanently pauses a venue's deposits.
    event VaultDepositsPaused(address indexed vault);

    /// @notice Constructor configuration is invalid.
    error Invalid();

    /// @notice `execute` received no operations.
    error EmptyBatch();

    /// @notice The registry has not admitted this venue, or not in this direction.
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

    /// @notice The amount mode or its associated amount is invalid for this operation.
    error InvalidAmountMode();

    /// @notice A caller other than the immutable risk guardian attempted a pause.
    error OnlyRiskGuardian();

    /// @notice New deposits into this venue have been permanently paused.
    error DepositsPaused();

    /// @notice Permanently disable new deposits into a venue, for every caller.
    /// @dev Redemptions remain available so callers can always exit supported positions. The
    ///      venue must be admitted by this executor's registry, so a mistyped address fails
    ///      loudly rather than recording a pause that protects nothing. Pausing one venue never
    ///      affects other venues of the same protocol. There is no unpause.
    /// @param vault Venue whose deposits are permanently disabled.
    function pauseVaultDeposits(address vault) external;

    /// @notice Venue registry this executor deployed and is permanently bound to.
    function registry() external view returns (IGrowYieldAdapterRegistry);

    /// @notice Maximum accepted shortfall vs. adapter preview, in basis points.
    function maxLossBps() external view returns (uint16);

    /// @notice Immutable address authorized to permanently pause venue deposits.
    function riskGuardian() external view returns (address);

    /// @notice Whether new deposits into a venue are permanently paused.
    function depositsPaused(address vault) external view returns (bool);

    /// @notice Execute operations and credit every output directly to `msg.sender`.
    function execute(Operation[] calldata ops) external returns (uint256[] memory received);
}
