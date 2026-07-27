// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {GrowYieldAdapterRegistry} from "./GrowYieldAdapterRegistry.sol";
import {IGrowYieldAdapterRegistry, Venue} from "./interfaces/IGrowYieldAdapterRegistry.sol";
// solhint-disable-next-line no-unused-import
import {
    AmountMode,
    IGrowYieldExecutor,
    MAX_OPS,
    Operation,
    OperationKind
} from "./interfaces/IGrowYieldExecutor.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

/// @title GrowYieldExecutor
/// @notice Routes a caller's own funds through venues this same contract has admitted.
/// @dev Admission and execution are one contract: this *is* the venue registry, inheriting
///      `GrowYieldAdapterRegistry`. Permissionless by construction — an operation pulls the
///      source token from `msg.sender` and credits every output back to `msg.sender`.
///
///      Two distinct authorities: the owner (`Ownable2Step`) admits venues and un-pauses; the
///      immutable risk guardian can only pause deposits. Neither can move funds or block a
///      redemption, and redemptions are never pausable.
/// @custom:security-contact security@getgrowapp.co
contract GrowYieldExecutor is
    GrowYieldAdapterRegistry,
    ReentrancyGuardTransient,
    IGrowYieldExecutor
{
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    /// @notice Hard ceiling on the constructor-set loss cap (1%).
    uint16 public constant MAX_LOSS_BPS_CEILING = 100;

    /// @inheritdoc IGrowYieldExecutor
    uint16 public immutable maxLossBps;

    /// @inheritdoc IGrowYieldExecutor
    address public immutable riskGuardian;

    /// @inheritdoc IGrowYieldExecutor
    mapping(address vault => bool) public depositsPaused;

    /// @param maxLossBps_ Maximum shortfall from preview, in basis points; must be nonzero so
    ///        venue rounding against the preview cannot brick operations.
    /// @param riskGuardian_ Address able to pause venue deposits; cannot un-pause, and must
    ///        differ from `owner_`.
    /// @param owner_ Address authorized to admit venues and un-pause; should be a Safe or
    ///        TimelockController.
    /// @param registrars_ Canonical protocol registrars pinned for this contract's lifetime.
    constructor(
        uint16 maxLossBps_,
        address riskGuardian_,
        address owner_,
        IGrowYieldAdapterRegistry.Registrars memory registrars_
    ) GrowYieldAdapterRegistry(owner_, registrars_) {
        if (
            maxLossBps_ == 0 || maxLossBps_ > MAX_LOSS_BPS_CEILING || riskGuardian_ == address(0)
                || riskGuardian_ == owner_
        ) revert Invalid();

        maxLossBps = maxLossBps_;
        riskGuardian = riskGuardian_;
    }

    /// @inheritdoc IGrowYieldExecutor
    function pauseVaultDeposits(address vault) external {
        // Either authority may protect; only the owner may re-expose.
        if (msg.sender != riskGuardian && msg.sender != owner()) revert NotAuthorizedToPause();
        // Reject a mistyped address instead of recording a pause that protects nothing.
        if (_venues[vault].adapter == address(0)) revert VenueNotAllowed();

        if (!depositsPaused[vault]) {
            depositsPaused[vault] = true;
            emit VaultDepositsPaused(vault, msg.sender);
        }
    }

    /// @inheritdoc IGrowYieldExecutor
    function unpauseVaultDeposits(address vault) external onlyOwner {
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
        Venue memory venue = _venues[vault];

        bool venuePermits = isDeposit ? venue.canDeposit : venue.canRedeem;
        if (venue.adapter == address(0) || !venuePermits) revert VenueNotAllowed();
        if (isDeposit && depositsPaused[vault]) revert DepositsPaused();

        // Blocks ERC-7928 adapter upgrades from causing loss of funds.
        if (venue.adapter.codehash != venue.adapterCodeHash) revert AdapterCodeChanged();

        IYieldAdapter adapter = IYieldAdapter(venue.adapter);
        // The admitted pair is the only binding between this vault and its tokens, so re-deriving
        // it fails closed when protocol governance re-points a venue after admission. Deposits
        // only: blocking a redemption on drift would trap the account in the bad venue.
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
        // Rebasing position tokens (aTokens) may settle one wei off; larger deviations are
        // fee-on-transfer behavior and unsupported.
        if (sent + 1 < amount || sent > amount + 1) revert UnsupportedToken();

        uint256 expected =
            isDeposit ? adapter.previewDeposit(vault, sent) : adapter.previewRedeem(vault, sent);
        if (expected == 0) revert InsufficientOutput();

        if (isDeposit) {
            adapter.deposit(vault, sent, msg.sender);
        } else {
            adapter.redeem(vault, sent, msg.sender);
        }

        // The adapter must consume exactly `sent`: too much left behind is a stranded residual,
        // too little is a donation swept from an unrelated balance. One wei either way is
        // rebasing-token rounding.
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
