// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {GrowYieldAdapterRegistry} from "./GrowYieldAdapterRegistry.sol";
import {IGrowYieldAdapterRegistry, Venue} from "./interfaces/IGrowYieldAdapterRegistry.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    MAX_OPS,
    Operation,
    OperationKind
} from "./interfaces/IGrowYieldExecutor.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

/// @title GrowYieldExecutor
/// @notice Routes a caller's own funds through venues admitted by this executor's registry.
/// @dev The executor and its registry are one unit: the constructor deploys the registry, so the
///      registry names this executor and this executor names that registry, both immutably and
///      with nothing settable afterwards. Which venues exist is therefore a single governance
///      decision made by the registry owner, not a per-account configuration.
///
///      The executor holds no per-account state and no per-account permission. It is
///      permissionless by construction: an operation pulls the source token from `msg.sender` and
///      credits every output back to `msg.sender`, so a caller can only ever move their own
///      funds, and only into or out of an admitted venue.
///
///      What still constrains an operation: the venue must be admitted and permit the direction,
///      the adapter's runtime code must match the hash pinned at admission, a deposit's adapter
///      must still derive the pinned `(asset, positionToken)` pair, the source token must match
///      the venue and direction, output must clear both the caller's signed floor and a
///      loss-capped preview, and no residual may be left on the adapter.
///
///      Deposit-side wind-down is reversible on purpose: the risk guardian or the registry owner
///      may pause a venue's deposits, and only the registry owner may re-enable them. Protecting
///      is fast and unilateral; re-exposing accounts is a governance decision. Redemptions are
///      never pausable, so a paused venue is one nobody can enter and everybody can leave.
/// @custom:security-contact security@getgrowapp.co
contract GrowYieldExecutor is ReentrancyGuardTransient, IGrowYieldExecutor {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    /// @notice Hard ceiling on the constructor-set loss cap (1%).
    uint16 public constant MAX_LOSS_BPS_CEILING = 100;

    /// @inheritdoc IGrowYieldExecutor
    IGrowYieldAdapterRegistry public immutable registry;

    /// @inheritdoc IGrowYieldExecutor
    uint16 public immutable maxLossBps;

    /// @inheritdoc IGrowYieldExecutor
    address public immutable riskGuardian;

    /// @inheritdoc IGrowYieldExecutor
    mapping(address vault => bool) public depositsPaused;

    /// @param maxLossBps_ Maximum shortfall from preview, in basis points; must be nonzero so
    ///        venue rounding against the preview cannot brick operations.
    /// @param riskGuardian_ Address able to pause venue deposits; cannot un-pause.
    /// @param registryOwner_ Initial owner of the registry this constructor deploys; should be a
    ///        Safe or TimelockController, or a deployer that hands over in the same transaction.
    /// @param registrars_ Canonical protocol registrars pinned for the registry's lifetime.
    constructor(
        uint16 maxLossBps_,
        address riskGuardian_,
        address registryOwner_,
        IGrowYieldAdapterRegistry.Registrars memory registrars_
    ) {
        if (maxLossBps_ == 0 || maxLossBps_ > MAX_LOSS_BPS_CEILING || riskGuardian_ == address(0)) {
            revert Invalid();
        }
        maxLossBps = maxLossBps_;
        riskGuardian = riskGuardian_;

        // Deployed here, not passed in: CREATE2 cannot resolve a mutual pin, because each
        // contract's init code would have to contain the other's address. Creating the registry
        // from the constructor makes both directions immutable with no initializer window.
        registry = new GrowYieldAdapterRegistry(address(this), registryOwner_, registrars_);
    }

    /// @inheritdoc IGrowYieldExecutor
    function pauseVaultDeposits(address vault) external {
        // Either authority may protect. Only governance may re-expose (see `unpause`).
        if (msg.sender != riskGuardian && msg.sender != registry.owner()) {
            revert NotAuthorizedToPause();
        }
        // Reject a mistyped address instead of recording a pause that protects nothing.
        if (registry.vaultAdapter(vault) == address(0)) revert VenueNotAllowed();

        if (!depositsPaused[vault]) {
            depositsPaused[vault] = true;
            emit VaultDepositsPaused(vault, msg.sender);
        }
    }

    /// @inheritdoc IGrowYieldExecutor
    function unpauseVaultDeposits(address vault) external {
        if (msg.sender != registry.owner()) revert NotAuthorizedToPause();

        if (depositsPaused[vault]) {
            depositsPaused[vault] = false;
            emit VaultDepositsUnpaused(vault);
        }
    }

    /// @inheritdoc IGrowYieldExecutor
    function execute(Operation[] calldata ops)
        external
        nonReentrant
        returns (uint256[] memory received)
    {
        uint256 count = ops.length;
        if (count == 0) revert EmptyBatch();
        if (count > MAX_OPS) revert BatchTooLarge();

        received = new uint256[](count);
        address previousOutputToken;
        uint256 previousOutputAmount;
        for (uint256 i; i < count; ++i) {
            (received[i], previousOutputToken) =
                _run(ops[i], previousOutputToken, previousOutputAmount, i != 0);
            previousOutputAmount = received[i];
        }
    }

    /// @dev Validates, funds, and executes one operation; enforces the output floor.
    function _run(
        Operation calldata op,
        address previousOutputToken,
        uint256 previousOutputAmount,
        bool hasPreviousOutput
    ) private returns (uint256 receivedOut, address outputTokenAddress) {
        address vault = op.vault;
        bool isDeposit = op.kind == OperationKind.DEPOSIT;
        Venue memory venue = registry.venue(vault);

        bool venuePermits = isDeposit ? venue.canDeposit : venue.canRedeem;
        if (venue.adapter == address(0) || !venuePermits) revert VenueNotAllowed();
        if (isDeposit && depositsPaused[vault]) revert DepositsPaused();

        // this prevents ERC-7928 malicious contract upgrades from causing loss of funds.
        // The hash is carried in the venue record, so resolving a venue costs one call.
        if (venue.adapter.codehash != venue.adapterCodeHash) revert AdapterCodeChanged();

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

        // The adapter received exactly `sent` and must consume exactly `sent`: too much left
        // behind is a stranded residual, too little is a donation swept out of an unrelated
        // balance. One wei either way is rebasing-token rounding (aTokens burn in scaled
        // units). Checking both directions here, on the registry-pinned token, is what lets
        // the adapters stay venue-agnostic instead of re-deriving a token to measure.
        uint256 sourceAfter = sourceToken.balanceOf(venue.adapter);
        if (
            sourceAfter + 1 < adapterSourceBefore || sourceAfter > adapterSourceBefore + 1
                || outputToken.balanceOf(venue.adapter) > adapterOutputBefore
        ) revert ResidualBalance();

        receivedOut = outputToken.balanceOf(msg.sender) - outputBefore;
        uint256 previewMinimum = Math.mulDiv(expected, BPS - maxLossBps, BPS, Math.Rounding.Ceil);
        uint256 minimumOut = Math.max(previewMinimum, op.minAmountOut);
        if (receivedOut == 0 || receivedOut < minimumOut) revert InsufficientOutput();

        emit Executed(msg.sender, vault, venue.adapter, op.kind, sent, receivedOut);
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
}
