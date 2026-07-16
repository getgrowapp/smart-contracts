// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {
    IGrowYieldAdapterRegistry,
    IGrowYieldExecutor,
    IYieldAdapter,
    Operation,
    OperationKind
} from "./IGrowYield1271.sol";

/**
 * @notice Generic yield executor: routes caller funds through allowlisted venue
 *         adapters, enforcing quantitative safety invariants the EIP-1271 policy
 *         signer cannot (signature validation runs before execution and can only
 *         inspect calldata shape, never execution outcome).
 *
 * @dev Invariants enforced per operation, uniformly for every adapter:
 *      - The adapter is allowlisted in `registry` for the operation direction.
 *      - Output is always credited to `msg.sender`; no recipient parameter exists
 *        anywhere in the ABI, so authorized calldata cannot redirect funds.
 *      - The adapter receives exactly `amount` source tokens (fee-on-transfer and
 *        rebasing-transfer tokens fail closed).
 *      - The caller's output-token delta is at least `preview * (1 - maxLossBps)`
 *        and nonzero — the loss cap ERC-4626/Aave entrypoints don't natively offer.
 *      - The adapter retains no new source- or output-token balance afterwards.
 *      - The whole batch is non-reentrant (transient-storage guard), so tokens with
 *        transfer hooks cannot re-enter mid-operation.
 *
 *      The executor itself never holds funds: transfers go caller -> adapter and
 *      venue -> caller directly.
 *
 *      Why an executor at all (instead of the account approving venues and calling
 *      them directly): ERC-4626 `deposit`/`redeem` and Aave `supply`/`withdraw` have
 *      no min-output parameter, so a post-call balance check somewhere in the
 *      execution path is the only place a loss cap can live.
 */
contract GrowYieldExecutorV3 is ReentrancyGuardTransient, IGrowYieldExecutor {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    /// @notice Hard ceiling on the constructor-set loss cap.
    uint16 public constant MAX_LOSS_BPS_CEILING = 100;

    /// @inheritdoc IGrowYieldExecutor
    IGrowYieldAdapterRegistry public immutable registry;

    /// @inheritdoc IGrowYieldExecutor
    uint16 public immutable maxLossBps;

    event Executed(
        address indexed account,
        address indexed adapter,
        OperationKind kind,
        uint256 amountIn,
        uint256 amountOut
    );

    error Invalid();
    error EmptyBatch();
    error AdapterNotAllowed();
    error NoBalance();
    error UnsupportedToken();
    error InsufficientOutput();
    error ResidualBalance();

    constructor(IGrowYieldAdapterRegistry registry_, uint16 maxLossBps_) {
        if (address(registry_) == address(0) || maxLossBps_ > MAX_LOSS_BPS_CEILING) {
            revert Invalid();
        }

        registry = registry_;
        maxLossBps = maxLossBps_;
    }

    /// @inheritdoc IGrowYieldExecutor
    function execute(Operation[] calldata ops)
        external
        nonReentrant
        returns (uint256[] memory received)
    {
        uint256 count = ops.length;
        if (count == 0) revert EmptyBatch();

        received = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            received[i] = _run(ops[i]);
        }
    }

    function _run(Operation calldata op) private returns (uint256 receivedOut) {
        IYieldAdapter adapter = op.adapter;
        bool isDeposit = op.kind == OperationKind.DEPOSIT;

        if (isDeposit
                ? !registry.canDeposit(address(adapter))
                : !registry.canRedeem(address(adapter))) revert AdapterNotAllowed();

        IERC20 sourceToken;
        IERC20 outputToken;
        {
            address asset = adapter.asset();
            address position = adapter.positionToken();
            (sourceToken, outputToken) =
                isDeposit ? (IERC20(asset), IERC20(position)) : (IERC20(position), IERC20(asset));
        }

        uint256 amount =
            op.amount == type(uint256).max ? sourceToken.balanceOf(msg.sender) : op.amount;
        if (amount == 0) revert NoBalance();

        uint256 expected =
            isDeposit ? adapter.previewDeposit(amount) : adapter.previewRedeem(amount);
        if (expected == 0) revert InsufficientOutput();

        uint256 adapterSourceBefore = sourceToken.balanceOf(address(adapter));
        uint256 adapterOutputBefore = outputToken.balanceOf(address(adapter));
        uint256 outputBefore = outputToken.balanceOf(msg.sender);

        sourceToken.safeTransferFrom(msg.sender, address(adapter), amount);

        // Exact receipt required: fee-on-transfer / rebasing-transfer fail closed.
        if (sourceToken.balanceOf(address(adapter)) - adapterSourceBefore != amount) {
            revert UnsupportedToken();
        }

        if (isDeposit) {
            adapter.deposit(amount, msg.sender);
        } else {
            adapter.redeem(amount, msg.sender);
        }

        // Adapters must not accumulate funds (they may sweep pre-existing donations,
        // hence `>` rather than `!=`).
        if (
            sourceToken.balanceOf(address(adapter)) > adapterSourceBefore
                || outputToken.balanceOf(address(adapter)) > adapterOutputBefore
        ) revert ResidualBalance();

        receivedOut = outputToken.balanceOf(msg.sender) - outputBefore;

        if (receivedOut == 0 || receivedOut < (expected * (BPS - maxLossBps)) / BPS) {
            revert InsufficientOutput();
        }

        emit Executed(msg.sender, address(adapter), op.kind, amount, receivedOut);
    }
}
