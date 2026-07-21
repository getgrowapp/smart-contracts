// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowYieldAdapterRegistry} from "../../src/yield-module/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutorV3} from "../../src/yield-module/GrowYieldExecutorV3.sol";
import {AaveV3Adapter} from "../../src/yield-module/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../../src/yield-module/adapters/MorphoVaultV2Adapter.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    IYieldAdapter,
    Operation,
    OperationKind
} from "../../src/yield-module/interfaces/IGrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry
} from "../../src/yield-module/interfaces/IGrowYieldAdapterRegistry.sol";
import {MockAavePool, MockUnderlying} from "../invariant/MockYieldVenues.sol";
import {MockFeeToken, MockMutableAaveDataProvider} from "./mocks/MockVaultV2Stack.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";

/// @dev Lies about its preview and sends deposited assets to a third party.
contract MaliciousYieldAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    IERC20 private immutable _asset;
    MockUnderlying private immutable _position;
    address private immutable _executor;
    address private immutable _recipient;

    error OnlyExecutor();

    constructor(IERC20 asset_, address executor_, address recipient_) {
        _asset = asset_;
        _position = new MockUnderlying();
        _executor = executor_;
        _recipient = recipient_;
    }

    function executor() external view returns (address) {
        return _executor;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function positionToken() external view returns (address) {
        return address(_position);
    }

    function previewDeposit(uint256) external pure returns (uint256) {
        return 1;
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        return 1;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        if (msg.sender != _executor) revert OnlyExecutor();
        _asset.safeTransfer(_recipient, assets);
        _position.mint(receiver, 1);
        return 1;
    }

    function redeem(uint256, address) external pure returns (uint256) {
        revert();
    }
}

/// @notice Executor correctness, venue gating, and quantitative invariants.
contract GrowYieldExecutorV3Test is GrowYield1271TestBase {
    function setUp() public {
        _setUpBase();
    }

    function _approveMax(address token) internal {
        vm.prank(account);
        IERC20(token).approve(address(executor), type(uint256).max);
    }

    function _execute(Operation[] memory ops) internal returns (uint256[] memory) {
        vm.prank(account);
        return executor.execute(ops);
    }

    // --- deposits ---

    function test_deposit_exactAmount_aave() public {
        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 400e6)));

        assertEq(out[0], 400e6);
        assertEq(aavePool.aToken().balanceOf(account), 400e6);
        assertEq(underlying.balanceOf(account), 600e6);
        _assertNoResiduals();
    }

    function test_deposit_fullBalanceMode_usesFullBalance() public {
        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max)));

        assertEq(aavePool.aToken().balanceOf(account), 1_000e6);
        assertEq(underlying.balanceOf(account), 0);
        _assertNoResiduals();
    }

    function test_deposit_morphoWrapper() public {
        underlying.mint(account, 500e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 500e6)));

        assertEq(out[0], morphoWrapper.balanceOf(account));
        assertGt(out[0], 0);
        _assertNoResiduals();
    }

    // --- redemptions ---

    function test_redeem_partial_aave() public {
        _seedAave(1_000e6);
        _approveMax(address(aavePool.aToken()));

        uint256[] memory out = _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, 300e6)));

        assertEq(out[0], 300e6);
        assertEq(underlying.balanceOf(account), 300e6);
        assertEq(aavePool.aToken().balanceOf(account), 700e6);
        _assertNoResiduals();
    }

    function test_redeem_fullBalanceMode_exitsFullPosition() public {
        _seedAave(1_000e6);
        _approveMax(address(aavePool.aToken()));

        _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max)));

        assertEq(underlying.balanceOf(account), 1_000e6);
        assertEq(aavePool.aToken().balanceOf(account), 0);
        _assertNoResiduals();
    }

    function test_redeem_doesNotSweepPreExistingAdapterDonation() public {
        _seedAave(100e6);
        vm.startPrank(account);
        aavePool.aToken().transfer(address(aaveAdapter), 10e6);
        vm.stopPrank();
        _approveMax(address(aavePool.aToken()));

        _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max)));

        assertEq(underlying.balanceOf(account), 90e6);
        assertEq(aavePool.aToken().balanceOf(address(aaveAdapter)), 10e6);
    }

    // --- reallocation as a two-op batch ---

    function test_reallocate_aaveToMorpho_singleExecute() public {
        _seedAave(800e6);
        _approveMax(address(aavePool.aToken()));
        _approveMax(address(underlying));

        _execute(
            _ops2(
                _op(aaveAdapter, OperationKind.REDEEM, type(uint256).max),
                _op(morphoAdapter, OperationKind.DEPOSIT, type(uint256).max)
            )
        );

        assertEq(aavePool.aToken().balanceOf(account), 0);
        assertEq(underlying.balanceOf(account), 0);
        assertGt(morphoWrapper.balanceOf(account), 0);
        _assertNoResiduals();
    }

    function test_reallocate_previousOutput_doesNotSweepIdleUnderlying() public {
        _seedAave(600e6);
        underlying.mint(account, 400e6);
        _approveMax(address(aavePool.aToken()));
        _approveMax(address(underlying));

        _execute(
            _ops2(
                _op(aaveAdapter, OperationKind.REDEEM, type(uint256).max),
                _op(morphoAdapter, OperationKind.DEPOSIT, type(uint256).max)
            )
        );

        assertEq(underlying.balanceOf(account), 400e6);
        assertEq(morphoWrapper.balanceOf(account), 600e6);
    }

    // --- gating ---

    function test_execute_revertsUnknownAdapter() public {
        underlying.mint(account, 1e6);
        _approveMax(address(underlying));

        AaveV3Adapter rogue = new AaveV3Adapter(
            IAaveV3Pool(address(aavePool)),
            IAaveProtocolDataProvider(address(aaveDataProvider)),
            address(underlying),
            address(executor)
        );
        Operation[] memory ops = _ops1(_op(rogue, OperationKind.DEPOSIT, 1e6));

        vm.expectRevert(IGrowYieldExecutor.AdapterNotAllowed.selector);
        _execute(ops);
    }

    function test_directionalGating_depositClosedExitOpen() public {
        _seedAave(100e6);
        vm.prank(account);
        executor.setAdapterPolicy(address(aaveAdapter), 0, DEFAULT_VOLUME_LIMIT, 1 days);

        underlying.mint(account, 1e6);
        _approveMax(address(underlying));
        Operation[] memory depositOps = _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 1e6));
        vm.expectRevert(IGrowYieldExecutor.AdapterNotAllowed.selector);
        _execute(depositOps);

        _approveMax(address(aavePool.aToken()));
        _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max)));
        assertEq(aavePool.aToken().balanceOf(account), 0);
    }

    function test_execute_revertsEmptyBatch() public {
        Operation[] memory ops = new Operation[](0);
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.EmptyBatch.selector);
        executor.execute(ops);
    }

    function test_execute_revertsZeroAmount() public {
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max));
        vm.expectRevert(IGrowYieldExecutor.NoBalance.selector);
        _execute(ops);
    }

    function test_execute_rejectsInvalidAmountModeParameters() public {
        underlying.mint(account, 1e6);
        _approveMax(address(underlying));

        Operation memory fullBalance =
            _opWithMode(aaveAdapter, OperationKind.DEPOSIT, AmountMode.FULL_BALANCE, 1, 1);
        vm.expectRevert(IGrowYieldExecutor.InvalidAmountMode.selector);
        _execute(_ops1(fullBalance));

        Operation memory previousOutput =
            _opWithMode(aaveAdapter, OperationKind.DEPOSIT, AmountMode.PREVIOUS_OUTPUT, 0, 1);
        vm.expectRevert(IGrowYieldExecutor.InvalidAmountMode.selector);
        _execute(_ops1(previousOutput));
    }

    function test_execute_revertsSourceTokenMismatch() public {
        underlying.mint(account, 1e6);
        Operation[] memory ops = _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 1e6));
        ops[0].sourceToken = address(otherUnderlying);

        vm.expectRevert(IGrowYieldExecutor.SourceTokenMismatch.selector);
        _execute(ops);
    }

    function test_fixedRegistryCannotAdmitMaliciousAdapterAfterDeployment() public {
        address thief = makeAddr("thief");
        MaliciousYieldAdapter malicious =
            new MaliciousYieldAdapter(underlying, address(executor), thief);

        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.AdapterNotAllowed.selector);
        executor.setAdapterPolicy(address(malicious), 1, 0, 1 days);
        assertEq(registry.adapterCodeHash(address(malicious)), bytes32(0));
    }

    // --- quantitative invariants ---

    function test_lossCap_revertsOnLossyVenue() public {
        morphoWrapper.setHaircutBps(200); // 2% > 0.5% cap

        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 1_000e6));

        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(ops);
    }

    function test_lossCap_toleratesLossWithinCap() public {
        morphoWrapper.setHaircutBps(30); // 0.3% < 0.5% cap

        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 1_000e6)));
        assertEq(out[0], 997e6);
    }

    function test_lossCap_roundsMinimumOutputUp() public {
        morphoWrapper.setHaircutBps(50);
        underlying.mint(account, 101);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 101));

        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(ops);
    }

    function test_signedAbsoluteMinimumOutput_isEnforced() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation memory op =
            _opWithMode(aaveAdapter, OperationKind.DEPOSIT, AmountMode.EXACT, 100e6, 100e6 + 1);

        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(_ops1(op));
    }

    function test_zeroAbsoluteMinimumOutput_isRejected() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation memory op =
            _opWithMode(aaveAdapter, OperationKind.DEPOSIT, AmountMode.EXACT, 100e6, 0);

        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(_ops1(op));
    }

    function test_feeOnTransferSource_revertsUnsupportedToken() public {
        GrowYieldExecutorV3 feeExecutor = new GrowYieldExecutorV3(MAX_LOSS_BPS, riskGuardian);
        MockFeeToken feeToken = new MockFeeToken();
        MockAavePool feePool = new MockAavePool(MockUnderlying(address(feeToken)));
        MockMutableAaveDataProvider feeProvider =
            new MockMutableAaveDataProvider(address(feeToken), address(feePool.aToken()));
        AaveV3Adapter feeAdapter = new AaveV3Adapter(
            IAaveV3Pool(address(feePool)),
            IAaveProtocolDataProvider(address(feeProvider)),
            address(feeToken),
            address(feeExecutor)
        );
        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](1);
        configs[0] = IGrowYieldAdapterRegistry.AdapterConfig(address(feeAdapter), true, true);
        GrowYieldAdapterRegistry feeRegistry =
            new GrowYieldAdapterRegistry(address(feeExecutor), configs);
        feeExecutor.initializeRegistry(feeRegistry);

        feeToken.mint(account, 1_000e6);
        vm.startPrank(account);
        feeExecutor.setAdapterPolicy(
            address(feeAdapter), DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days
        );
        feeToken.approve(address(feeExecutor), type(uint256).max);
        Operation[] memory ops = _ops1(_op(feeAdapter, OperationKind.DEPOSIT, 100e6));

        vm.expectRevert(IGrowYieldExecutor.UnsupportedToken.selector);
        feeExecutor.execute(ops);
        vm.stopPrank();
    }

    function test_accountMustExplicitlyEnableFixedAdapter() public {
        vm.prank(account);
        executor.setAdapterPolicy(address(aaveAdapter), 0, 0, 0);
        underlying.mint(account, 1e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 1e6));

        vm.expectRevert(IGrowYieldExecutor.AdapterNotAllowed.selector);
        _execute(ops);
    }

    function test_registryCanOnlyBeInitializedOnce() public {
        vm.expectRevert(IGrowYieldExecutor.RegistryAlreadyInitialized.selector);
        executor.initializeRegistry(registry);
    }

    function test_epochBudgetBoundsCumulativeDepositVolume() public {
        vm.prank(account);
        executor.setAdapterPolicy(address(aaveAdapter), 100e6, 0, 1 days);
        underlying.mint(account, 150e6);
        _approveMax(address(underlying));

        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 60e6)));
        Operation[] memory exceeds = _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 41e6));
        vm.expectRevert(IGrowYieldExecutor.BudgetExceeded.selector);
        _execute(exceeds);

        vm.warp(block.timestamp + 1 days);
        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 41e6)));
    }

    function test_policyLimitUpdate_preservesConsumption() public {
        vm.prank(account);
        executor.setAdapterPolicy(address(aaveAdapter), 100e6, 0, 1 days);
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 60e6)));

        vm.prank(account);
        executor.setAdapterPolicy(address(aaveAdapter), 70e6, 0, 1 days);
        (,, uint256 spent,,,) = executor.adapterPolicy(account, address(aaveAdapter));
        assertEq(spent, 60e6);

        Operation[] memory exceeds = _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 11e6));
        vm.expectRevert(IGrowYieldExecutor.BudgetExceeded.selector);
        _execute(exceeds);
    }

    function test_policyDurationChange_requiresExplicitReset() public {
        vm.prank(account);
        executor.setAdapterPolicy(address(aaveAdapter), 100e6, 0, 1 days);
        underlying.mint(account, 160e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 60e6)));

        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.EpochDurationChangeRequiresReset.selector);
        executor.setAdapterPolicy(address(aaveAdapter), 100e6, 0, 2 days);

        vm.prank(account);
        executor.resetAdapterPolicy(address(aaveAdapter), 100e6, 0, 2 days);
        (,, uint256 spent,, uint48 duration,) =
            executor.adapterPolicy(account, address(aaveAdapter));
        assertEq(spent, 0);
        assertEq(duration, 2 days);
        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 100e6)));
    }

    function test_unboundedAdapterPolicy_isRejected() public {
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.UnboundedPolicy.selector);
        executor.setAdapterPolicy(address(aaveAdapter), type(uint256).max, 0, 1 days);
    }

    function test_riskGuardianPause_blocksDepositsButNotExits() public {
        _seedAave(100e6);

        vm.prank(makeAddr("notGuardian"));
        vm.expectRevert(IGrowYieldExecutor.OnlyRiskGuardian.selector);
        executor.pauseAdapterDeposits(address(aaveAdapter));

        vm.prank(riskGuardian);
        executor.pauseAdapterDeposits(address(aaveAdapter));
        assertTrue(executor.depositsPaused(address(aaveAdapter)));

        underlying.mint(account, 1e6);
        _approveMax(address(underlying));
        Operation[] memory depositOps = _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 1e6));
        vm.expectRevert(IGrowYieldExecutor.DepositsPaused.selector);
        _execute(depositOps);

        _approveMax(address(aavePool.aToken()));
        _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max)));
        assertEq(aavePool.aToken().balanceOf(account), 0);
    }

    function test_revertedOperationDoesNotConsumeBudget() public {
        vm.prank(account);
        executor.setAdapterPolicy(address(morphoAdapter), 100e6, 0, 1 days);
        morphoWrapper.setHaircutBps(200);
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));

        Operation[] memory ops = _ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 100e6));
        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(ops);

        (,, uint256 depositSpent,,,) = executor.adapterPolicy(account, address(morphoAdapter));
        assertEq(depositSpent, 0);
    }

    // --- drift protection ---

    function test_morphoDrift_ineligibleChild_blocksDepositAllowsExit() public {
        underlying.mint(account, 200e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 100e6)));

        morphoEligibility.set(address(morphoChild), false);
        Operation[] memory depositOps = _ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 100e6));

        vm.expectRevert(MorphoVaultV2Adapter.VenueDrift.selector);
        _execute(depositOps);

        _approveMax(address(morphoWrapper));
        _execute(_ops1(_op(morphoAdapter, OperationKind.REDEEM, type(uint256).max)));
        assertEq(morphoWrapper.balanceOf(account), 0);
    }

    function test_morphoDrift_liquidityAdapterChanged_blocksDeposit() public {
        morphoWrapper.setLiquidityAdapter(makeAddr("newAdapter"));

        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 100e6));
        vm.expectRevert(MorphoVaultV2Adapter.VenueDrift.selector);
        _execute(ops);
    }

    function test_morphoGate_blocksDepositWithoutCurrentRoundTripAccess() public {
        morphoWrapper.setGateBlocked(morphoWrapper.canSendShares.selector, account, true);
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 100e6));

        vm.expectRevert(MorphoVaultV2Adapter.VenueGate.selector);
        _execute(ops);
    }

    function test_aaveDrift_reserveRepointed_blocksDepositAllowsExit() public {
        _seedAave(100e6);

        aaveDataProvider.setAToken(makeAddr("newAToken"));

        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory depositOps = _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 100e6));
        vm.expectRevert(AaveV3Adapter.ReserveDrift.selector);
        _execute(depositOps);

        _approveMax(address(aavePool.aToken()));
        _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max)));
        assertEq(aavePool.aToken().balanceOf(account), 0);
    }

    // --- access ---

    function test_adapters_onlyExecutor() public {
        vm.expectRevert(AaveV3Adapter.OnlyExecutor.selector);
        aaveAdapter.deposit(1, account);

        vm.expectRevert(MorphoVaultV2Adapter.OnlyExecutor.selector);
        morphoAdapter.redeem(1, account);
    }

    function test_strangerCannotMoveAccountFunds() public {
        _seedAave(100e6);

        address stranger = makeAddr("stranger");
        Operation[] memory ops = _ops1(_op(aaveAdapter, OperationKind.REDEEM, 100e6));
        vm.prank(stranger);
        vm.expectRevert();
        executor.execute(ops);

        assertEq(aavePool.aToken().balanceOf(account), 100e6);
    }

    function test_receiverIsAlwaysCaller_noRecipientInAbi() public {
        // Operation has no recipient field; the executor hard-pins it to msg.sender.
        _seedAave(100e6);
        _approveMax(address(aavePool.aToken()));

        address stranger = makeAddr("stranger");
        uint256 strangerBefore = underlying.balanceOf(stranger);

        _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max)));

        assertEq(underlying.balanceOf(stranger), strangerBefore);
        assertEq(underlying.balanceOf(account), 100e6);
    }

    // --- helpers ---

    function _seedAave(uint256 amount) internal {
        underlying.mint(account, amount);
        _approveMax(address(underlying));
        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max)));
        vm.prank(account);
        underlying.approve(address(executor), 0);
    }

    function _assertNoResiduals() internal view {
        assertEq(underlying.balanceOf(address(executor)), 0);
        assertEq(underlying.balanceOf(address(aaveAdapter)), 0);
        assertEq(underlying.balanceOf(address(morphoAdapter)), 0);
        assertEq(aavePool.aToken().balanceOf(address(executor)), 0);
        assertEq(aavePool.aToken().balanceOf(address(aaveAdapter)), 0);
        assertEq(morphoWrapper.balanceOf(address(executor)), 0);
        assertEq(morphoWrapper.balanceOf(address(morphoAdapter)), 0);
    }
}
