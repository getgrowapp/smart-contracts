// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IGrowYieldAdapterRegistry} from "./interfaces/IGrowYieldAdapterRegistry.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    Operation,
    OperationKind
} from "./interfaces/IGrowYieldExecutor.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

/// @title GrowYieldExecutor
/// @notice Routes caller funds through fixed-registry adapters explicitly enabled by that caller.
/// @dev Operations bind the source token, send output only to the caller, reject transfer-tax
///      tokens, enforce a loss-capped preview, and reject adapter code changes and residuals.
contract GrowYieldExecutor is ReentrancyGuardTransient, IGrowYieldExecutor {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    /// @notice Hard ceiling on the constructor-set loss cap (1%).
    uint16 public constant MAX_LOSS_BPS_CEILING = 100;

    struct AdapterPolicy {
        uint256 depositLimit;
        uint256 redeemLimit;
        uint256 depositSpent;
        uint256 redeemSpent;
        uint48 epochDuration;
        uint48 epochStart;
    }

    /// @inheritdoc IGrowYieldExecutor
    IGrowYieldAdapterRegistry public registry;

    /// @inheritdoc IGrowYieldExecutor
    address public immutable registryInitializer;

    /// @inheritdoc IGrowYieldExecutor
    uint16 public immutable maxLossBps;

    /// @inheritdoc IGrowYieldExecutor
    address public immutable riskGuardian;

    /// @inheritdoc IGrowYieldExecutor
    mapping(address adapter => bool) public depositsPaused;

    mapping(address account => mapping(address adapter => AdapterPolicy)) private _policies;

    /// @param maxLossBps_ Maximum shortfall from preview, in basis points.
    /// @param riskGuardian_ Address able to permanently pause adapter deposits.
    constructor(uint16 maxLossBps_, address riskGuardian_) {
        if (maxLossBps_ > MAX_LOSS_BPS_CEILING || riskGuardian_ == address(0)) revert Invalid();
        registryInitializer = msg.sender;
        maxLossBps = maxLossBps_;
        riskGuardian = riskGuardian_;
    }

    /// @inheritdoc IGrowYieldExecutor
    function initializeRegistry(IGrowYieldAdapterRegistry registry_) external {
        if (msg.sender != registryInitializer) revert OnlyRegistryInitializer();
        if (address(registry) != address(0)) revert RegistryAlreadyInitialized();
        if (address(registry_).code.length == 0 || registry_.executor() != address(this)) {
            revert Invalid();
        }

        registry = registry_;
        emit RegistryInitialized(address(registry_));
    }

    /// @inheritdoc IGrowYieldExecutor
    function setAdapterPolicy(
        address adapter,
        uint256 depositLimit_,
        uint256 redeemLimit_,
        uint48 epochDuration_
    ) external {
        _setAdapterPolicy(adapter, depositLimit_, redeemLimit_, epochDuration_, false);
    }

    /// @inheritdoc IGrowYieldExecutor
    function resetAdapterPolicy(
        address adapter,
        uint256 depositLimit_,
        uint256 redeemLimit_,
        uint48 epochDuration_
    ) external {
        _setAdapterPolicy(adapter, depositLimit_, redeemLimit_, epochDuration_, true);
    }

    /// @inheritdoc IGrowYieldExecutor
    function pauseAdapterDeposits(address adapter) external {
        if (msg.sender != riskGuardian) revert OnlyRiskGuardian();
        IGrowYieldAdapterRegistry registry_ = registry;
        if (
            address(registry_) == address(0) || registry_.adapterCodeHash(adapter) == bytes32(0)
                || !registry_.canDeposit(adapter)
        ) revert AdapterNotAllowed();

        if (!depositsPaused[adapter]) {
            depositsPaused[adapter] = true;
            emit AdapterDepositsPaused(adapter);
        }
    }

    /// @inheritdoc IGrowYieldExecutor
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
        )
    {
        AdapterPolicy storage policy = _policies[account][adapter];
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

        received = new uint256[](count);
        address previousOutputToken;
        uint256 previousOutputAmount;
        for (uint256 i; i < count; ++i) {
            (received[i], previousOutputToken) =
                _run(ops[i], previousOutputToken, previousOutputAmount, i != 0);
            previousOutputAmount = received[i];
        }
    }

    function _run(
        Operation calldata op,
        address previousOutputToken,
        uint256 previousOutputAmount,
        bool hasPreviousOutput
    ) private returns (uint256 receivedOut, address outputTokenAddress) {
        IYieldAdapter adapter = op.adapter;
        address adapterAddress = address(adapter);
        bool isDeposit = op.kind == OperationKind.DEPOSIT;
        IGrowYieldAdapterRegistry registry_ = registry;
        if (address(registry_) == address(0)) revert Invalid();
        AdapterPolicy storage accountPolicy = _policies[msg.sender][adapterAddress];

        bool fixedPermission =
            isDeposit ? registry_.canDeposit(adapterAddress) : registry_.canRedeem(adapterAddress);
        bool accountAllowed =
            isDeposit ? accountPolicy.depositLimit != 0 : accountPolicy.redeemLimit != 0;
        if (!fixedPermission || !accountAllowed) revert AdapterNotAllowed();
        if (isDeposit && depositsPaused[adapterAddress]) revert DepositsPaused();

        // this prevents ERC-7928 malicious contract upgrades from causing loss of funds.
        if (adapterAddress.codehash != registry_.adapterCodeHash(adapterAddress)) {
            revert AdapterCodeChanged();
        }

        IERC20 sourceToken;
        IERC20 outputToken;
        {
            address asset = adapter.asset();
            address position = adapter.positionToken();
            (sourceToken, outputToken) =
                isDeposit ? (IERC20(asset), IERC20(position)) : (IERC20(position), IERC20(asset));
        }
        if (address(sourceToken) != op.sourceToken) revert SourceTokenMismatch();
        if (op.minAmountOut == 0) revert InsufficientOutput();
        outputTokenAddress = address(outputToken);

        uint256 amount = _resolveAmount(
            op, sourceToken, previousOutputToken, previousOutputAmount, hasPreviousOutput
        );
        if (amount == 0) revert NoBalance();
        _consumeBudget(accountPolicy, isDeposit, amount);

        uint256 expected =
            isDeposit ? adapter.previewDeposit(amount) : adapter.previewRedeem(amount);
        if (expected == 0) revert InsufficientOutput();

        uint256 adapterSourceBefore = sourceToken.balanceOf(adapterAddress);
        uint256 adapterOutputBefore = outputToken.balanceOf(adapterAddress);
        uint256 outputBefore = outputToken.balanceOf(msg.sender);

        sourceToken.safeTransferFrom(msg.sender, adapterAddress, amount);
        if (sourceToken.balanceOf(adapterAddress) - adapterSourceBefore != amount) {
            revert UnsupportedToken();
        }

        if (isDeposit) {
            adapter.deposit(amount, msg.sender);
        } else {
            adapter.redeem(amount, msg.sender);
        }

        if (
            sourceToken.balanceOf(adapterAddress) > adapterSourceBefore
                || outputToken.balanceOf(adapterAddress) > adapterOutputBefore
        ) revert ResidualBalance();

        receivedOut = outputToken.balanceOf(msg.sender) - outputBefore;
        uint256 previewMinimum = Math.mulDiv(expected, BPS - maxLossBps, BPS, Math.Rounding.Ceil);
        uint256 minimumOut = Math.max(previewMinimum, op.minAmountOut);
        if (receivedOut == 0 || receivedOut < minimumOut) revert InsufficientOutput();

        emit Executed(msg.sender, adapterAddress, op.kind, amount, receivedOut);
    }

    function _setAdapterPolicy(
        address adapter,
        uint256 depositLimit_,
        uint256 redeemLimit_,
        uint48 epochDuration_,
        bool resetUsage
    ) private {
        IGrowYieldAdapterRegistry registry_ = registry;
        if (address(registry_) == address(0)) revert Invalid();
        if (depositLimit_ == type(uint256).max || redeemLimit_ == type(uint256).max) {
            revert UnboundedPolicy();
        }
        bool enabled = depositLimit_ != 0 || redeemLimit_ != 0;
        if (
            registry_.adapterCodeHash(adapter) == bytes32(0)
                || (depositLimit_ != 0 && !registry_.canDeposit(adapter))
                || (redeemLimit_ != 0 && !registry_.canRedeem(adapter))
                || (enabled && epochDuration_ == 0) || (!enabled && epochDuration_ != 0)
        ) revert AdapterNotAllowed();
        if (enabled && adapter.codehash != registry_.adapterCodeHash(adapter)) {
            revert AdapterCodeChanged();
        }

        AdapterPolicy storage policy = _policies[msg.sender][adapter];
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
            emit AdapterPolicyUsageReset(msg.sender, adapter);
        } else if (enabled) {
            policy.epochDuration = epochDuration_;
        } else if (resetUsage) {
            policy.depositSpent = 0;
            policy.redeemSpent = 0;
            policy.epochDuration = 0;
            policy.epochStart = 0;
            emit AdapterPolicyUsageReset(msg.sender, adapter);
        }

        emit AdapterPolicySet(
            msg.sender, adapter, depositLimit_, redeemLimit_, policy.epochDuration
        );
    }

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
    function _consumeBudget(AdapterPolicy storage policy, bool isDeposit, uint256 amount) private {
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
