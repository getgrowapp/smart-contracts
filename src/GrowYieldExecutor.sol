// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AaveV4ReserveVenue} from "./AaveV4ReserveVenue.sol";
import {GrowYieldAdapterRegistry} from "./GrowYieldAdapterRegistry.sol";
import {IAaveV4SpokeAdapter} from "./interfaces/IAaveV4SpokeAdapter.sol";
import {IGrowYieldAccountCall} from "./interfaces/IGrowYieldAccountCall.sol";
import {
    IGrowYieldAdapterRegistry, Protocol, Venue
} from "./interfaces/IGrowYieldAdapterRegistry.sol";
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
///      Two disjoint authorities: the owner (`Ownable2Step`) admits venues and nothing else; the
///      immutable risk guardian owns the deposit-pause lifecycle and nothing else. Neither can
///      move funds or block a redemption, and redemptions are never pausable.
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
    /// @dev Rotatable by the owner. A guardian that cannot be replaced turns a lost key into a
    ///      deployment with no incident response for the rest of its life.
    address public riskGuardian;

    /// @inheritdoc IGrowYieldExecutor
    bool public allDepositsPaused;

    /// @inheritdoc IGrowYieldExecutor
    mapping(address vault => bool) public depositsPaused;

    modifier onlyGuardian() {
        if (msg.sender != riskGuardian) revert NotAuthorizedToPause();
        _;
    }

    /// @param maxLossBps_ Maximum shortfall from preview, in basis points; must be nonzero so
    ///        venue rounding against the preview cannot brick operations.
    /// @param riskGuardian_ Sole address able to pause and un-pause venue deposits; must differ
    ///        from `owner_` so the two authorities stay disjoint.
    /// @param owner_ Address authorized to admit venues and rotate the guardian; should be a
    ///        Safe or TimelockController.
    /// @param registrars_ Canonical protocol registrars pinned for this contract's lifetime.
    constructor(
        uint16 maxLossBps_,
        address riskGuardian_,
        address owner_,
        IGrowYieldAdapterRegistry.Registrars memory registrars_
    ) GrowYieldAdapterRegistry(owner_, registrars_) {
        if (maxLossBps_ == 0 || maxLossBps_ > MAX_LOSS_BPS_CEILING) revert Invalid();

        maxLossBps = maxLossBps_;
        _setRiskGuardian(riskGuardian_);
    }

    /// @inheritdoc IGrowYieldExecutor
    function setRiskGuardian(address guardian) external onlyOwner {
        _setRiskGuardian(guardian);
    }

    /// @inheritdoc IGrowYieldExecutor
    function pauseAllDeposits() external onlyGuardian {
        if (!allDepositsPaused) {
            allDepositsPaused = true;
            emit AllDepositsPaused(msg.sender);
        }
    }

    /// @inheritdoc IGrowYieldExecutor
    function unpauseAllDeposits() external onlyGuardian {
        if (allDepositsPaused) {
            allDepositsPaused = false;
            emit AllDepositsUnpaused(msg.sender);
        }
    }

    /// @inheritdoc IGrowYieldExecutor
    function pauseVaultDeposits(address vault) external onlyGuardian {
        // Reject a mistyped address instead of recording a pause that protects nothing.
        if (_venues[vault].adapter == address(0)) revert VenueNotAllowed();

        if (!depositsPaused[vault]) {
            depositsPaused[vault] = true;
            emit VaultDepositsPaused(vault, msg.sender);
        }
    }

    /// @inheritdoc IGrowYieldExecutor
    function unpauseVaultDeposits(address vault) external onlyGuardian {
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
        return _executeOps(ops);
    }

    function _executeOps(Operation[] calldata ops) private returns (uint256[] memory received) {
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
        if (isDeposit && (allDepositsPaused || depositsPaused[vault])) revert DepositsPaused();

        // Catches the one way an admitted address's code can still change: an EIP-7702 delegated
        // EOA, whose code is a delegation indicator it can re-sign at will. A contract's code is
        // immutable, and EIP-6780 ended metamorphic redeploys, so nothing else moves this hash.
        // A proxy is not covered — its own code never changes when the implementation does.
        if (venue.adapter.codehash != venue.adapterCodeHash) revert AdapterCodeChanged();

        if (_protocols[vault] == Protocol.AAVE_V4) {
            return _runAaveV4(
                op, venue, isDeposit, previousOutputToken, previousOutputAmount, hasPreviousOutput
            );
        }

        IYieldAdapter adapter = IYieldAdapter(venue.adapter);
        // The admitted pair is the only binding between this vault and its tokens, so re-deriving
        // it fails closed when protocol governance re-points a venue after admission. Deposits
        // only: blocking a redemption on drift would trap the account in the bad venue.
        if (
            isDeposit
                && (
                    adapter.asset(vault) != venue.asset
                        || adapter.positionToken(vault) != venue.positionToken
                )
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
        // rebasing-token rounding. Absolute bounds are safe even for aTokens, whose normalized
        // income accrues on read and is therefore constant within a transaction.
        uint256 sourceAfter = sourceToken.balanceOf(venue.adapter);
        if (
            sourceAfter + 1 < adapterSourceBefore || sourceAfter > adapterSourceBefore + 1
                || outputToken.balanceOf(venue.adapter) > adapterOutputBefore
        ) revert ResidualBalance();

        receivedOut = outputToken.balanceOf(msg.sender) - outputBefore;
        uint256 previewMinimum = Math.mulDiv(expected, BPS - maxLossBps, BPS, Math.Rounding.Ceil);
        // `op.minAmountOut` is already nonzero, so this also rejects a zero output.
        uint256 minimumOut = Math.max(previewMinimum, op.minAmountOut);
        if (receivedOut < minimumOut) revert InsufficientOutput();

        emit Executed(msg.sender, vault, venue.adapter, op.kind, sent, receivedOut);
    }

    /// @dev Aave V4 keeps supply shares on the spoke. The account calls the spoke, so the spoke's
    ///      caller is the account. Deposit output is the share increase. Redeem input is shares
    ///      and output is underlying paid to the account. A spoke the hub no longer lists fails
    ///      closed on deposit. Redeem still asks the hub to remove. The hub itself rejects an
    ///      inactive or halted spoke, and the spoke rejects a withdraw that would break the
    ///      account's health factor, which is what holds a position that is backing a borrow.
    function _runAaveV4(
        Operation calldata op,
        Venue memory venue,
        bool isDeposit,
        address previousOutputToken,
        uint256 previousOutputAmount,
        bool hasPreviousOutput
    ) private returns (uint256 receivedOut, address outputTokenAddress) {
        address vault = op.vault;
        IAaveV4SpokeAdapter adapter = IAaveV4SpokeAdapter(venue.adapter);
        if (adapter.executor() != address(this)) revert Invalid();
        if (
            isDeposit
                && (
                    !adapter.spokeListed(vault) || adapter.asset(vault) != venue.asset
                        || adapter.positionToken(vault) != venue.positionToken
                )
        ) revert VenueDrift();

        address expectedSource = isDeposit ? venue.asset : venue.positionToken;
        if (op.sourceToken != expectedSource) revert SourceTokenMismatch();
        if (op.minAmountOut == 0) revert InsufficientOutput();
        outputTokenAddress = isDeposit ? venue.positionToken : venue.asset;

        IERC20 underlying = IERC20(venue.asset);
        uint256 amount = isDeposit
            ? _resolveAmount(
                op, underlying, previousOutputToken, previousOutputAmount, hasPreviousOutput
            )
            : _resolveAaveV4Shares(
                op, adapter, vault, previousOutputToken, previousOutputAmount, hasPreviousOutput
            );
        if (amount == 0) revert NoBalance();

        uint256 sharesBefore = adapter.suppliedShares(vault, msg.sender);
        uint256 adapterSharesBefore = adapter.suppliedShares(vault, venue.adapter);
        uint256 adapterUnderlyingBefore = underlying.balanceOf(venue.adapter);
        uint256 userUnderlyingBefore = underlying.balanceOf(msg.sender);
        address spoke = AaveV4ReserveVenue(vault).spoke();
        uint256 reserveId = AaveV4ReserveVenue(vault).reserveId();
        IGrowYieldAccountCall account = IGrowYieldAccountCall(msg.sender);

        uint256 expected;
        if (isDeposit) {
            expected = adapter.previewDeposit(vault, amount);
            if (expected == 0) revert InsufficientOutput();
            account.supplyOnSpoke(spoke, reserveId, amount);
            account.setSpokeCollateral(spoke, reserveId, true);
            uint256 spent = userUnderlyingBefore - underlying.balanceOf(msg.sender);
            if (spent + 1 < amount || spent > amount + 1) revert UnsupportedToken();
        } else {
            expected = adapter.previewRedeem(vault, amount);
            if (expected == 0) revert InsufficientOutput();
            account.withdrawOnSpoke(
                spoke, reserveId, amount == sharesBefore ? type(uint256).max : expected
            );
            if (adapter.suppliedShares(vault, msg.sender) == 0) {
                account.setSpokeCollateral(spoke, reserveId, false);
            }
        }

        uint256 adapterUnderlyingAfter = underlying.balanceOf(venue.adapter);
        if (
            adapterUnderlyingAfter + 1 < adapterUnderlyingBefore
                || adapterUnderlyingAfter > adapterUnderlyingBefore + 1
                || adapter.suppliedShares(vault, venue.adapter) != adapterSharesBefore
        ) revert ResidualBalance();

        if (isDeposit) {
            uint256 sharesAfter = adapter.suppliedShares(vault, msg.sender);
            if (sharesAfter < sharesBefore) revert InsufficientOutput();
            receivedOut = sharesAfter - sharesBefore;
        } else {
            uint256 userUnderlyingAfter = underlying.balanceOf(msg.sender);
            if (userUnderlyingAfter < userUnderlyingBefore) revert InsufficientOutput();
            receivedOut = userUnderlyingAfter - userUnderlyingBefore;
        }

        uint256 previewMinimum = Math.mulDiv(expected, BPS - maxLossBps, BPS, Math.Rounding.Ceil);
        uint256 minimumOut = Math.max(previewMinimum, op.minAmountOut);
        if (receivedOut < minimumOut) revert InsufficientOutput();

        emit Executed(msg.sender, vault, venue.adapter, op.kind, amount, receivedOut);
    }

    /// @dev Redeem amounts are spoke shares. `FULL_BALANCE` reads the caller's share balance,
    ///      because the position token is only the venue id.
    function _resolveAaveV4Shares(
        Operation calldata op,
        IAaveV4SpokeAdapter adapter,
        address vault,
        address previousOutputToken,
        uint256 previousOutputAmount,
        bool hasPreviousOutput
    ) private view returns (uint256) {
        if (op.amountMode == AmountMode.EXACT) {
            if (op.amount == 0) revert InvalidAmountMode();
            return op.amount;
        }
        if (op.amount != 0) revert InvalidAmountMode();
        if (op.amountMode == AmountMode.FULL_BALANCE) {
            return adapter.suppliedShares(vault, msg.sender);
        }
        if (
            op.amountMode != AmountMode.PREVIOUS_OUTPUT || !hasPreviousOutput
                || previousOutputToken != op.sourceToken
        ) revert InvalidAmountMode();
        return previousOutputAmount;
    }

    /// @dev Keeps the two authorities disjoint. Reads `owner()` rather than a constructor
    ///      argument so a rotation is held to exactly the same rule as the initial assignment.
    function _setRiskGuardian(address guardian) private {
        if (guardian == address(0) || guardian == owner()) revert Invalid();

        emit RiskGuardianSet(riskGuardian, guardian);
        riskGuardian = guardian;
    }

    /// @dev Enforces disjointness from the other direction: ownership can never land on the
    ///      guardian, which would silently collapse the two roles into one key. Renouncing is
    ///      unaffected, because the guardian is never the zero address.
    function _transferOwnership(address newOwner) internal override {
        if (newOwner == riskGuardian) revert Invalid();
        super._transferOwnership(newOwner);
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
