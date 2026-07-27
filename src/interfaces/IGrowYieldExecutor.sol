// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGrowYieldAdapterRegistry} from "./IGrowYieldAdapterRegistry.sol";

/// @notice Direction of a yield operation.
enum OperationKind {
    DEPOSIT,
    REDEEM
}

// Maximum operations in one `execute` batch. Single source of truth: the executor enforces it
// directly and the policy library derives its calldata ceiling from it.
uint256 constant MAX_OPS = 4;

/// @notice How an operation resolves its source amount.
enum AmountMode {
    EXACT,
    FULL_BALANCE,
    PREVIOUS_OUTPUT
}

/// @notice One operation against a venue admitted by this executor's registry.
/// @dev The venue names itself, not its adapter: the registry resolves `vault` to the adapter,
///      the pinned token pair, and the permitted directions, so a signed operation cannot pair a
///      venue with an adapter the registry did not admit it under.
/// @param vault Venue identifier, as its protocol keys it (see `IYieldAdapter`).
/// @param kind Deposit or redeem direction.
/// @param sourceToken Token pulled from the caller and verified against the venue's pinned pair.
/// @param amount Exact source amount when `amountMode` is `EXACT`; otherwise it must be zero.
/// @param amountMode Explicit source-amount resolution strategy.
/// @param minAmountOut Absolute floor for the output credited to the caller. Signed by whoever
///        authorized the operation — for automation a policy owner, not the account owner — so it
///        bounds an honest signer's slippage only. `maxLossBps` does not depend on the signer.
struct Operation {
    address vault;
    OperationKind kind;
    address sourceToken;
    uint256 amount;
    AmountMode amountMode;
    uint256 minAmountOut;
}

/// @title IGrowYieldExecutor
/// @notice Routes a caller's own funds through venues this same contract has admitted.
/// @dev Extends the registry interface because they are one contract: `GrowYieldExecutor`
///      inherits `GrowYieldAdapterRegistry`.
interface IGrowYieldExecutor is IGrowYieldAdapterRegistry {
    /// @notice Emitted once per successfully executed operation.
    event Executed(
        address indexed account,
        address indexed vault,
        address adapter,
        OperationKind kind,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when a venue's deposits are paused.
    event VaultDepositsPaused(address indexed vault, address indexed by);

    /// @notice Emitted when a paused venue's deposits are re-enabled.
    event VaultDepositsUnpaused(address indexed vault);

    /// @notice Emitted when deposits are paused across every venue at once.
    event AllDepositsPaused(address indexed by);

    /// @notice Emitted when the blanket deposit pause is lifted.
    event AllDepositsUnpaused(address indexed by);

    /// @notice Emitted whenever the risk guardian is assigned or rotated.
    event RiskGuardianSet(address indexed previousGuardian, address indexed newGuardian);

    /// @notice `execute` received more than `MAX_OPS` operations.
    error BatchTooLarge();

    /// @notice The registry has not admitted this venue, or not in this direction.
    error VenueNotAllowed();

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

    /// @notice The caller is not the risk guardian.
    error NotAuthorizedToPause();

    /// @notice New deposits into this venue are paused.
    error DepositsPaused();

    /// @notice Disable new deposits into a venue, for every caller.
    /// @dev Risk guardian only; the registry owner cannot pause. Redemptions remain available.
    ///      The venue must already be admitted, so a mistyped address fails loudly rather than
    ///      recording a pause that protects nothing. Pausing one venue never affects siblings.
    /// @param vault Venue whose deposits are disabled.
    function pauseVaultDeposits(address vault) external;

    /// @notice Re-enable deposits into a paused venue.
    /// @dev Risk guardian only. The pause lifecycle belongs entirely to the guardian, disjoint
    ///      from the owner's authority over the venue set.
    /// @param vault Venue whose deposits are re-enabled.
    function unpauseVaultDeposits(address vault) external;

    /// @notice Disable new deposits into every venue at once.
    /// @dev Risk guardian only. An incident that implicates the stack rather than one venue
    ///      should not cost one transaction per venue. Redemptions stay available everywhere,
    ///      and per-venue pauses are independent of this flag — lifting one does not lift both.
    function pauseAllDeposits() external;

    /// @notice Lift the blanket deposit pause.
    /// @dev Risk guardian only. Venues paused individually remain paused.
    function unpauseAllDeposits() external;

    /// @notice Replace the risk guardian.
    /// @dev Registry owner only, and the new guardian may be neither zero nor the owner, so the
    ///      two authorities can never collapse into one key. Rotation exists because an
    ///      unreplaceable guardian turns one lost key into a deployment that can never respond
    ///      to an incident again.
    /// @param guardian Address that takes over the deposit-pause lifecycle.
    function setRiskGuardian(address guardian) external;

    /// @notice Whether deposits are currently paused across every venue.
    function allDepositsPaused() external view returns (bool);

    /// @notice Maximum accepted shortfall vs. adapter preview, in basis points.
    function maxLossBps() external view returns (uint16);

    /// @notice Immutable address authorized to pause and un-pause venue deposits.
    function riskGuardian() external view returns (address);

    /// @notice Whether new deposits into a venue are currently paused.
    function depositsPaused(address vault) external view returns (bool);

    /// @notice Execute operations and credit every output directly to `msg.sender`.
    function execute(Operation[] calldata ops) external returns (uint256[] memory received);
}
