// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGrowYieldAdapterRegistry} from "./IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "./IYieldAdapter.sol";

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

/// @notice One operation against a fixed-registry yield adapter.
/// @param adapter Adapter used for the operation.
/// @param kind Deposit or redeem direction.
/// @param sourceToken Token pulled from the caller and verified against the adapter.
/// @param amount Exact source amount when `amountMode` is `EXACT`; otherwise it must be zero.
/// @param amountMode Explicit source-amount resolution strategy.
/// @param minAmountOut Owner-signed absolute floor for the output credited to the caller.
struct Operation {
    IYieldAdapter adapter;
    OperationKind kind;
    address sourceToken;
    uint256 amount;
    AmountMode amountMode;
    uint256 minAmountOut;
}

/// @title IGrowYieldExecutor
/// @notice Routes caller funds through account-enabled, deployment-fixed adapters.
interface IGrowYieldExecutor {
    /// @notice Emitted once per successfully executed operation.
    event Executed(
        address indexed account,
        address indexed adapter,
        OperationKind kind,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Emitted when the deployment-fixed registry is attached.
    event RegistryInitialized(address indexed registry);

    /// @notice Emitted when an account sets epoch volume limits for an adapter.
    event AdapterPolicySet(
        address indexed account,
        address indexed adapter,
        uint256 depositLimit,
        uint256 redeemLimit,
        uint48 epochDuration
    );

    /// @notice Emitted when an account explicitly resets an adapter's epoch usage.
    event AdapterPolicyUsageReset(address indexed account, address indexed adapter);

    /// @notice Emitted when the immutable risk guardian permanently pauses deposits.
    event AdapterDepositsPaused(address indexed adapter);

    /// @notice Constructor, registry, or initialization configuration is invalid.
    error Invalid();

    /// @notice `execute` received no operations.
    error EmptyBatch();

    /// @notice The registry direction or account policy does not permit the adapter.
    error AdapterNotAllowed();

    /// @notice The adapter runtime no longer matches its deployment-time code hash.
    error AdapterCodeChanged();

    /// @notice The declared source token does not match the adapter and direction.
    error SourceTokenMismatch();

    /// @notice The resolved source-token amount is zero.
    error NoBalance();

    /// @notice The adapter did not receive the exact source amount transferred.
    error UnsupportedToken();

    /// @notice Output is zero or below the loss-capped adapter preview.
    error InsufficientOutput();

    /// @notice The operation increased an adapter's source or output residual balance.
    error ResidualBalance();

    /// @notice A caller other than the executor deployer attempted registry attachment.
    error OnlyRegistryInitializer();

    /// @notice The executor already has its lifetime registry.
    error RegistryAlreadyInitialized();

    /// @notice The operation exceeds the account's remaining directional epoch volume.
    error BudgetExceeded();

    /// @notice A maximum-integer limit would disable meaningful quantitative protection.
    error UnboundedPolicy();

    /// @notice The amount mode or its associated amount is invalid for this operation.
    error InvalidAmountMode();

    /// @notice A policy duration change was attempted without an explicit usage reset.
    error EpochDurationChangeRequiresReset();

    /// @notice A caller other than the immutable risk guardian attempted a global pause.
    error OnlyRiskGuardian();

    /// @notice New deposits through this adapter have been permanently paused.
    error DepositsPaused();

    /// @notice Attach the one registry accepted for the lifetime of this executor.
    function initializeRegistry(IGrowYieldAdapterRegistry registry_) external;

    /// @notice Set the calling account's directional epoch limits for a fixed adapter.
    /// @dev A zero directional limit disables that direction. Setting both to zero revokes the adapter.
    function setAdapterPolicy(
        address adapter,
        uint256 depositLimit,
        uint256 redeemLimit,
        uint48 epochDuration
    ) external;

    /// @notice Set policy limits and explicitly begin a fresh usage epoch.
    /// @dev Use this path to change `epochDuration`; resetting restores the full limits.
    function resetAdapterPolicy(
        address adapter,
        uint256 depositLimit,
        uint256 redeemLimit,
        uint48 epochDuration
    ) external;

    /// @notice Permanently disable new deposits through a registered adapter deployment-wide.
    /// @dev Redemptions remain available so accounts can always exit supported positions.
    function pauseAdapterDeposits(address adapter) external;

    /// @notice Return an account's configured limits and current epoch consumption.
    function adapterPolicy(address account, address adapter)
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

    /// @notice Adapter registry consulted for every operation.
    function registry() external view returns (IGrowYieldAdapterRegistry);

    /// @notice Address permitted to perform the one-time registry attachment.
    function registryInitializer() external view returns (address);

    /// @notice Maximum accepted shortfall vs. adapter preview, in basis points.
    function maxLossBps() external view returns (uint16);

    /// @notice Immutable address authorized to permanently pause adapter deposits.
    function riskGuardian() external view returns (address);

    /// @notice Whether new deposits through an adapter are permanently paused.
    function depositsPaused(address adapter) external view returns (bool);

    /// @notice Execute operations and credit every output directly to `msg.sender`.
    function execute(Operation[] calldata ops) external returns (uint256[] memory received);
}
