// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IGrowYieldAdapterRegistry, Venue} from "./interfaces/IGrowYieldAdapterRegistry.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    Operation,
    OperationKind
} from "./interfaces/IGrowYieldExecutor.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

/// @title GrowYieldExecutor
/// @notice Routes caller funds through venues admitted by the caller's chosen registry and
///         explicitly enabled by that caller.
/// @dev Operations bind the source token, send output only to the caller, reject transfer-tax
///      tokens, enforce a loss-capped preview, and reject adapter code changes and residuals.
///      Adapters are protocol-wide and venue-agnostic, so a venue's identity is the registry's
///      admitted record: it supplies the adapter, the pinned `(asset, positionToken)` pair, and
///      the permitted directions, and the executor rejects an operation whose adapter no longer
///      derives that same pair.
///      The executor is ownerless: every configuration decision belongs either to the account
///      (its registry and its directional limits) or to the immutable risk guardian.
contract GrowYieldExecutor is ReentrancyGuardTransient, IGrowYieldExecutor {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    /// @notice Hard ceiling on the constructor-set loss cap (1%).
    uint16 public constant MAX_LOSS_BPS_CEILING = 100;

    /// @dev Per-account directional volume limits and usage for one venue epoch.
    struct VaultPolicy {
        uint256 depositLimit;
        uint256 redeemLimit;
        uint256 depositSpent;
        uint256 redeemSpent;
        uint48 epochDuration;
        uint48 epochStart;
    }

    /// @inheritdoc IGrowYieldExecutor
    mapping(address account => IGrowYieldAdapterRegistry) public accountRegistry;

    /// @inheritdoc IGrowYieldExecutor
    uint16 public immutable maxLossBps;

    /// @inheritdoc IGrowYieldExecutor
    address public immutable riskGuardian;

    /// @inheritdoc IGrowYieldExecutor
    mapping(address vault => bool) public depositsPaused;

    mapping(address account => mapping(address vault => VaultPolicy)) private _policies;

    /// @param maxLossBps_ Maximum shortfall from preview, in basis points; must be nonzero so
    ///        venue rounding against the preview cannot brick operations.
    /// @param riskGuardian_ Address able to permanently pause venue deposits.
    constructor(uint16 maxLossBps_, address riskGuardian_) {
        if (maxLossBps_ == 0 || maxLossBps_ > MAX_LOSS_BPS_CEILING || riskGuardian_ == address(0)) {
            revert Invalid();
        }
        maxLossBps = maxLossBps_;
        riskGuardian = riskGuardian_;
    }

    /// @inheritdoc IGrowYieldExecutor
    function setAccountRegistry(IGrowYieldAdapterRegistry registry_) external {
        // `executor()` alone would also accept an adapter address, which would only fail at the
        // first operation. Requiring an admitted venue distinguishes a real registry and rejects
        // an empty one, which no operation could use anyway. Registries are append-only, so a
        // registry that satisfies this can never become unusable.
        if (
            address(registry_).code.length == 0 || registry_.executor() != address(this)
                || registry_.vaultCount() == 0
        ) revert Invalid();

        accountRegistry[msg.sender] = registry_;

        emit AccountRegistrySet(msg.sender, address(registry_));
    }

    /// @inheritdoc IGrowYieldExecutor
    function setVaultPolicy(
        address vault,
        uint256 depositLimit_,
        uint256 redeemLimit_,
        uint48 epochDuration_
    ) external {
        _setVaultPolicy(vault, depositLimit_, redeemLimit_, epochDuration_, false);
    }

    /// @inheritdoc IGrowYieldExecutor
    function resetVaultPolicy(
        address vault,
        uint256 depositLimit_,
        uint256 redeemLimit_,
        uint48 epochDuration_
    ) external {
        _setVaultPolicy(vault, depositLimit_, redeemLimit_, epochDuration_, true);
    }

    /// @inheritdoc IGrowYieldExecutor
    function pauseVaultDeposits(IGrowYieldAdapterRegistry registry_, address vault) external {
        if (msg.sender != riskGuardian) revert OnlyRiskGuardian();
        // Registries are per-account, so the guardian names one that admitted the venue. This
        // rejects a mistyped address instead of recording a pause that protects nothing.
        if (address(registry_).code.length == 0 || registry_.executor() != address(this)) {
            revert Invalid();
        }
        if (registry_.vaultAdapter(vault) == address(0)) revert VenueNotAllowed();

        if (!depositsPaused[vault]) {
            depositsPaused[vault] = true;
            emit VaultDepositsPaused(vault);
        }
    }

    /// @inheritdoc IGrowYieldExecutor
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
        )
    {
        VaultPolicy storage policy = _policies[account][vault];
        return (
            policy.depositLimit,
            policy.redeemLimit,
            policy.depositSpent,
            policy.redeemSpent,
            policy.epochDuration,
            policy.epochStart
        );
    }

    /// @inheritdoc IGrowYieldExecutor
    function execute(Operation[] calldata ops)
        external
        nonReentrant
        returns (uint256[] memory received)
    {
        uint256 count = ops.length;
        if (count == 0) revert EmptyBatch();

        // Resolved once: the whole batch is checked against the registry selected when it
        // started, so a mid-batch reselection cannot change the rules being enforced.
        IGrowYieldAdapterRegistry registry_ = _requireAccountRegistry();

        received = new uint256[](count);
        address previousOutputToken;
        uint256 previousOutputAmount;
        for (uint256 i; i < count; ++i) {
            (received[i], previousOutputToken) =
                _run(registry_, ops[i], previousOutputToken, previousOutputAmount, i != 0);
            previousOutputAmount = received[i];
        }
    }

    /// @dev Validates, funds, and executes one operation; enforces budget and output floors.
    function _run(
        IGrowYieldAdapterRegistry registry_,
        Operation calldata op,
        address previousOutputToken,
        uint256 previousOutputAmount,
        bool hasPreviousOutput
    ) private returns (uint256 receivedOut, address outputTokenAddress) {
        address vault = op.vault;
        bool isDeposit = op.kind == OperationKind.DEPOSIT;
        Venue memory venue = registry_.venue(vault);
        VaultPolicy storage accountPolicy = _policies[msg.sender][vault];

        bool venuePermits = isDeposit ? venue.canDeposit : venue.canRedeem;
        bool accountAllowed =
            isDeposit ? accountPolicy.depositLimit != 0 : accountPolicy.redeemLimit != 0;
        if (venue.adapter == address(0) || !venuePermits || !accountAllowed) {
            revert VenueNotAllowed();
        }
        if (isDeposit && depositsPaused[vault]) revert DepositsPaused();

        // this prevents ERC-7928 malicious contract upgrades from causing loss of funds.
        if (venue.adapter.codehash != registry_.adapterCodeHash(venue.adapter)) {
            revert AdapterCodeChanged();
        }

        IYieldAdapter adapter = IYieldAdapter(venue.adapter);
        // The adapter serves every venue of its protocol and pins none of them, so the admitted
        // pair is the only binding between this vault and its tokens. Re-deriving and comparing
        // fails closed when protocol governance re-points a venue (an Aave reserve's aToken, a
        // drifted `asset()`) after admission.
        //
        // Deposits only, deliberately. A deposit must never create a position in a token the
        // registry did not admit, but a redemption operates on the pinned position token the
        // account already holds and returns the pinned asset — blocking it on drift would trap
        // the account in the very venue that just went bad. Exits stay open for as long as the
        // venue itself permits them.
        if (
            isDeposit
                && (adapter.asset(vault) != venue.asset
                    || adapter.positionToken(vault) != venue.positionToken)
        ) revert VenueDrift();

        (IERC20 sourceToken, IERC20 outputToken) = isDeposit
            ? (IERC20(venue.asset), IERC20(venue.positionToken))
            : (IERC20(venue.positionToken), IERC20(venue.asset));
        if (address(sourceToken) != op.sourceToken) revert SourceTokenMismatch();
        if (op.minAmountOut == 0) revert InsufficientOutput();
        outputTokenAddress = address(outputToken);

        uint256 amount = _resolveAmount(
            op, sourceToken, previousOutputToken, previousOutputAmount, hasPreviousOutput
        );
        if (amount == 0) revert NoBalance();
        _consumeBudget(accountPolicy, isDeposit, amount);

        uint256 adapterSourceBefore = sourceToken.balanceOf(venue.adapter);
        uint256 adapterOutputBefore = outputToken.balanceOf(venue.adapter);
        uint256 outputBefore = outputToken.balanceOf(msg.sender);

        sourceToken.safeTransferFrom(msg.sender, venue.adapter, amount);
        uint256 sent = sourceToken.balanceOf(venue.adapter) - adapterSourceBefore;
        // Rebasing position tokens (aTokens) settle transfers in scaled units and may
        // deliver one wei off the requested amount; larger deviations are fee-on-transfer
        // behavior and unsupported. The adapter operates on the measured amount.
        if (sent + 1 < amount || sent > amount + 1) revert UnsupportedToken();

        uint256 expected =
            isDeposit ? adapter.previewDeposit(vault, sent) : adapter.previewRedeem(vault, sent);
        if (expected == 0) revert InsufficientOutput();

        if (isDeposit) {
            adapter.deposit(vault, sent, msg.sender);
        } else {
            adapter.redeem(vault, sent, msg.sender);
        }

        // A rebasing burn that rounds up may strand one wei of source on the adapter.
        if (
            sourceToken.balanceOf(venue.adapter) > adapterSourceBefore + 1
                || outputToken.balanceOf(venue.adapter) > adapterOutputBefore
        ) revert ResidualBalance();

        receivedOut = outputToken.balanceOf(msg.sender) - outputBefore;
        uint256 previewMinimum = Math.mulDiv(expected, BPS - maxLossBps, BPS, Math.Rounding.Ceil);
        uint256 minimumOut = Math.max(previewMinimum, op.minAmountOut);
        if (receivedOut == 0 || receivedOut < minimumOut) revert InsufficientOutput();

        emit Executed(msg.sender, vault, venue.adapter, op.kind, sent, receivedOut);
    }

    /// @dev Shared policy-write path; `resetUsage` starts a fresh epoch.
    function _setVaultPolicy(
        address vault,
        uint256 depositLimit_,
        uint256 redeemLimit_,
        uint48 epochDuration_,
        bool resetUsage
    ) private {
        IGrowYieldAdapterRegistry registry_ = _requireAccountRegistry();
        if (depositLimit_ == type(uint256).max || redeemLimit_ == type(uint256).max) {
            revert UnboundedPolicy();
        }
        bool enabled = depositLimit_ != 0 || redeemLimit_ != 0;
        Venue memory venue = registry_.venue(vault);
        if (
            venue.adapter == address(0) || (depositLimit_ != 0 && !venue.canDeposit)
                || (redeemLimit_ != 0 && !venue.canRedeem) || (enabled && epochDuration_ == 0)
                || (!enabled && epochDuration_ != 0)
        ) revert VenueNotAllowed();
        if (enabled && venue.adapter.codehash != registry_.adapterCodeHash(venue.adapter)) {
            revert AdapterCodeChanged();
        }

        VaultPolicy storage policy = _policies[msg.sender][vault];
        bool firstConfiguration = policy.epochStart == 0;
        if (enabled && !resetUsage && !firstConfiguration && epochDuration_ != policy.epochDuration)
        {
            revert EpochDurationChangeRequiresReset();
        }

        policy.depositLimit = depositLimit_;
        policy.redeemLimit = redeemLimit_;

        if (enabled && (resetUsage || firstConfiguration)) {
            policy.depositSpent = 0;
            policy.redeemSpent = 0;
            policy.epochDuration = epochDuration_;
            policy.epochStart = SafeCast.toUint48(block.timestamp);
            emit VaultPolicyUsageReset(msg.sender, vault);
        } else if (enabled) {
            policy.epochDuration = epochDuration_;
        } else if (resetUsage) {
            policy.depositSpent = 0;
            policy.redeemSpent = 0;
            policy.epochDuration = 0;
            policy.epochStart = 0;
            emit VaultPolicyUsageReset(msg.sender, vault);
        }

        emit VaultPolicySet(msg.sender, vault, depositLimit_, redeemLimit_, policy.epochDuration);
    }

    /// @dev The caller's selected registry; accounts must select one before configuring or
    ///      executing anything.
    function _requireAccountRegistry() private view returns (IGrowYieldAdapterRegistry registry_) {
        registry_ = accountRegistry[msg.sender];
        if (address(registry_) == address(0)) revert RegistryNotSet();
    }

    /// @dev Resolves the source amount for the operation's declared amount mode.
    function _resolveAmount(
        Operation calldata op,
        IERC20 sourceToken,
        address previousOutputToken,
        uint256 previousOutputAmount,
        bool hasPreviousOutput
    ) private view returns (uint256 amount) {
        if (op.amountMode == AmountMode.EXACT) {
            if (op.amount == 0) revert InvalidAmountMode();
            return op.amount;
        }

        if (op.amount != 0) revert InvalidAmountMode();
        if (op.amountMode == AmountMode.FULL_BALANCE) {
            return sourceToken.balanceOf(msg.sender);
        }
        if (
            op.amountMode != AmountMode.PREVIOUS_OUTPUT || !hasPreviousOutput
                || previousOutputToken != address(sourceToken)
        ) revert InvalidAmountMode();

        return previousOutputAmount;
    }

    /// @dev Resets an elapsed epoch, then accounts source volume before external calls.
    function _consumeBudget(VaultPolicy storage policy, bool isDeposit, uint256 amount) private {
        // Epoch accounting runs only during execution and intentionally follows chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= uint256(policy.epochStart) + policy.epochDuration) {
            policy.epochStart = SafeCast.toUint48(block.timestamp);
            policy.depositSpent = 0;
            policy.redeemSpent = 0;
        }

        uint256 limit = isDeposit ? policy.depositLimit : policy.redeemLimit;
        uint256 spent = isDeposit ? policy.depositSpent : policy.redeemSpent;
        if (spent > limit || amount > limit - spent) revert BudgetExceeded();

        if (isDeposit) {
            policy.depositSpent = spent + amount;
        } else {
            policy.redeemSpent = spent + amount;
        }
    }
}
