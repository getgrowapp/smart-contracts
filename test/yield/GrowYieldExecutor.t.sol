// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {GrowYieldTestBase} from "./GrowYieldTestBase.sol";
import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../../src/adapters/MorphoVaultV2Adapter.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    Operation,
    OperationKind
} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
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

    function asset(address) external view returns (address) {
        return address(_asset);
    }

    function positionToken(address) external view returns (address) {
        return address(_position);
    }

    function previewDeposit(address, uint256) external pure returns (uint256) {
        return 1;
    }

    function previewRedeem(address, uint256) external pure returns (uint256) {
        return 1;
    }

    function deposit(address, uint256 assets, address receiver) external returns (uint256) {
        if (msg.sender != _executor) revert OnlyExecutor();
        _asset.safeTransfer(_recipient, assets);
        _position.mint(receiver, 1);
        return 1;
    }

    function redeem(address, uint256, address) external pure returns (uint256) {
        revert();
    }
}

/// @notice Executor correctness, venue gating, and quantitative invariants.
contract GrowYieldExecutorTest is GrowYieldTestBase {
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

    /// @dev A second registry over this executor admitting only `aaveVaultOther`, so an
    ///      account's registry choice observably changes which venues it may use.
    function _narrowRegistry() private returns (GrowYieldAdapterRegistry narrow) {
        narrow = _deployRegistry(address(this));
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(aaveAdapter), aaveVaultOther, Protocol.AAVE, true, true
        );
        narrow.addVaults(vaults);
    }

    function test_constructor_rejectsZeroMaxLossBps() public {
        vm.expectRevert(IGrowYieldExecutor.Invalid.selector);
        new GrowYieldExecutor(0, riskGuardian);
    }

    function test_execute_revertsWhenAccountRegistryUnset() public {
        address stranger = makeAddr("noRegistry");
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6));

        vm.prank(stranger);
        vm.expectRevert(IGrowYieldExecutor.RegistryNotSet.selector);
        executor.execute(ops);
    }

    function test_setAdapterPolicy_revertsWhenAccountRegistryUnset() public {
        address stranger = makeAddr("noRegistry");

        vm.prank(stranger);
        vm.expectRevert(IGrowYieldExecutor.RegistryNotSet.selector);
        executor.setVaultPolicy(aaveVault, 1 ether, 1 ether, 1 days);

        vm.prank(stranger);
        vm.expectRevert(IGrowYieldExecutor.RegistryNotSet.selector);
        executor.resetVaultPolicy(aaveVault, 1 ether, 1 ether, 1 days);
    }

    /// @dev The selection is keyed by `msg.sender`: no caller can retarget another account.
    function test_setAccountRegistry_isPerAccountAndSelfKeyed() public {
        GrowYieldAdapterRegistry narrow = _narrowRegistry();
        address other = makeAddr("otherAccount");

        vm.expectEmit(true, true, false, false, address(executor));
        emit IGrowYieldExecutor.AccountRegistrySet(other, address(narrow));
        vm.prank(other);
        executor.setAccountRegistry(narrow);

        assertEq(address(executor.accountRegistry(other)), address(narrow));
        assertEq(address(executor.accountRegistry(account)), address(registry), "unchanged");
    }

    function test_setAccountRegistry_rejectsNonRegistry() public {
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.Invalid.selector);
        executor.setAccountRegistry(GrowYieldAdapterRegistry(makeAddr("eoa")));

        // A registry that authorizes a different executor cannot be selected here.
        GrowYieldExecutor otherExecutor = new GrowYieldExecutor(MAX_LOSS_BPS, riskGuardian);
        GrowYieldAdapterRegistry foreign = new GrowYieldAdapterRegistry(
            address(otherExecutor),
            address(this),
            IGrowYieldAdapterRegistry.Registrars({
                aavePool: address(aavePool),
                aaveDataProvider: address(aaveDataProvider),
                morphoVaultFactory: address(0),
                morphoAdapterFactory: address(0),
                morphoEligibility: address(0),
                eulerEVaultFactory: address(0),
                eulerEarnFactory: address(0),
                capyFiComptroller: address(0)
            })
        );

        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.Invalid.selector);
        executor.setAccountRegistry(foreign);

        // An adapter also reports `executor() == executor`; the venue-count probe rejects it
        // here (reverting inside the probe, which has no registry interface) instead of
        // silently deferring the failure to the account's first operation.
        vm.prank(account);
        vm.expectRevert();
        executor.setAccountRegistry(GrowYieldAdapterRegistry(address(aaveAdapter)));

        // An empty registry is unusable, so selecting one fails loudly.
        GrowYieldAdapterRegistry empty = _deployRegistry(address(this));
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.Invalid.selector);
        executor.setAccountRegistry(empty);
    }

    /// @dev Reselecting a registry re-gates execution immediately; per-adapter limits the
    ///      account already signed for survive, because admission and limits are independent.
    function test_setAccountRegistry_reselectionRegatesVenues() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));

        GrowYieldAdapterRegistry narrow = _narrowRegistry();
        vm.prank(account);
        executor.setAccountRegistry(narrow);

        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 10e6));
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        executor.execute(ops);

        // The limits set under the original registry are intact once it is reselected.
        (uint256 depositLimit,,,,,) = executor.vaultPolicy(account, address(aaveAdapter));
        assertEq(depositLimit, DEFAULT_VOLUME_LIMIT);

        vm.prank(account);
        executor.setAccountRegistry(registry);
        _execute(ops);
        assertEq(aavePool.aToken().balanceOf(account), 10e6);
    }

    function test_pauseVaultDeposits_rejectsForeignRegistryOrUnknownVenue() public {
        // A registry that authorizes a different executor cannot be used to name a target.
        GrowYieldExecutor otherExecutor = new GrowYieldExecutor(MAX_LOSS_BPS, riskGuardian);
        vm.prank(riskGuardian);
        vm.expectRevert(IGrowYieldExecutor.Invalid.selector);
        otherExecutor.pauseVaultDeposits(registry, aaveVault);

        // A venue this registry never admitted fails loudly rather than recording a no-op pause.
        vm.prank(riskGuardian);
        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        executor.pauseVaultDeposits(registry, makeAddr("typo"));
    }

    /// @dev Pausing one venue must not affect other venues of the same protocol, which share
    ///      the adapter.
    function test_pauseVaultDeposits_isPerVenueNotPerProtocol() public {
        vm.prank(riskGuardian);
        executor.pauseVaultDeposits(registry, aaveVault);

        assertTrue(executor.depositsPaused(aaveVault));
        assertFalse(executor.depositsPaused(aaveVaultOther), "sibling venue unaffected");

        otherUnderlying.mint(account, 10e6);
        vm.prank(account);
        IERC20(address(otherUnderlying)).approve(address(executor), type(uint256).max);
        _execute(_ops1(_op(aaveVaultOther, OperationKind.DEPOSIT, 10e6)));

        underlying.mint(account, 10e6);
        _approveMax(address(underlying));
        Operation[] memory paused = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 10e6));
        vm.expectRevert(IGrowYieldExecutor.DepositsPaused.selector);
        _execute(paused);
    }

    // --- deposits ---

    function test_deposit_exactAmount_aave() public {
        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 400e6)));

        assertEq(out[0], 400e6);
        assertEq(aavePool.aToken().balanceOf(account), 400e6);
        assertEq(underlying.balanceOf(account), 600e6);
        _assertNoResiduals();
    }

    function test_deposit_fullBalanceMode_usesFullBalance() public {
        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, type(uint256).max)));

        assertEq(aavePool.aToken().balanceOf(account), 1_000e6);
        assertEq(underlying.balanceOf(account), 0);
        _assertNoResiduals();
    }

    function test_deposit_morphoWrapper() public {
        underlying.mint(account, 500e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(morphoVault, OperationKind.DEPOSIT, 500e6)));

        assertEq(out[0], morphoWrapper.balanceOf(account));
        assertGt(out[0], 0);
        _assertNoResiduals();
    }

    // --- redemptions ---

    function test_redeem_partial_aave() public {
        _seedAave(1_000e6);
        _approveMax(address(aavePool.aToken()));

        uint256[] memory out = _execute(_ops1(_op(aaveVault, OperationKind.REDEEM, 300e6)));

        assertEq(out[0], 300e6);
        assertEq(underlying.balanceOf(account), 300e6);
        assertEq(aavePool.aToken().balanceOf(account), 700e6);
        _assertNoResiduals();
    }

    function test_redeem_fullBalanceMode_exitsFullPosition() public {
        _seedAave(1_000e6);
        _approveMax(address(aavePool.aToken()));

        _execute(_ops1(_op(aaveVault, OperationKind.REDEEM, type(uint256).max)));

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

        _execute(_ops1(_op(aaveVault, OperationKind.REDEEM, type(uint256).max)));

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
                _op(aaveVault, OperationKind.REDEEM, type(uint256).max),
                _op(morphoVault, OperationKind.DEPOSIT, type(uint256).max)
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
                _op(aaveVault, OperationKind.REDEEM, type(uint256).max),
                _op(morphoVault, OperationKind.DEPOSIT, type(uint256).max)
            )
        );

        assertEq(underlying.balanceOf(account), 400e6);
        assertEq(morphoWrapper.balanceOf(account), 600e6);
    }

    // --- gating ---

    /// @dev A genuine reserve of the pinned pool, reachable by the very adapter the account
    ///      already uses, is still unusable until the registry admits it.
    function test_execute_revertsUnadmittedVenue() public {
        (address unadmitted,) = _addAaveReserve();
        MockUnderlying(unadmitted).mint(account, 1e6);
        vm.prank(account);
        IERC20(unadmitted).approve(address(executor), type(uint256).max);

        Operation memory op = Operation({
            vault: unadmitted,
            kind: OperationKind.DEPOSIT,
            sourceToken: unadmitted,
            amount: 1e6,
            amountMode: AmountMode.EXACT,
            minAmountOut: 1
        });

        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        _execute(_ops1(op));
    }

    function test_directionalGating_depositClosedExitOpen() public {
        _seedAave(100e6);
        vm.prank(account);
        executor.setVaultPolicy(aaveVault, 0, DEFAULT_VOLUME_LIMIT, 1 days);

        underlying.mint(account, 1e6);
        _approveMax(address(underlying));
        Operation[] memory depositOps = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6));
        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        _execute(depositOps);

        _approveMax(address(aavePool.aToken()));
        _execute(_ops1(_op(aaveVault, OperationKind.REDEEM, type(uint256).max)));
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
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, type(uint256).max));
        vm.expectRevert(IGrowYieldExecutor.NoBalance.selector);
        _execute(ops);
    }

    function test_execute_rejectsInvalidAmountModeParameters() public {
        underlying.mint(account, 1e6);
        _approveMax(address(underlying));

        Operation memory fullBalance =
            _opWithMode(aaveVault, OperationKind.DEPOSIT, AmountMode.FULL_BALANCE, 1, 1);
        vm.expectRevert(IGrowYieldExecutor.InvalidAmountMode.selector);
        _execute(_ops1(fullBalance));

        Operation memory previousOutput =
            _opWithMode(aaveVault, OperationKind.DEPOSIT, AmountMode.PREVIOUS_OUTPUT, 0, 1);
        vm.expectRevert(IGrowYieldExecutor.InvalidAmountMode.selector);
        _execute(_ops1(previousOutput));
    }

    function test_execute_revertsSourceTokenMismatch() public {
        underlying.mint(account, 1e6);
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6));
        ops[0].sourceToken = address(otherUnderlying);

        vm.expectRevert(IGrowYieldExecutor.SourceTokenMismatch.selector);
        _execute(ops);
    }

    function test_registryCannotAdmitMaliciousAdapterWithoutAdmission() public {
        address thief = makeAddr("thief");
        MaliciousYieldAdapter malicious =
            new MaliciousYieldAdapter(underlying, address(executor), thief);

        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        executor.setVaultPolicy(address(malicious), 1, 0, 1 days);
        assertEq(registry.adapterCodeHash(address(malicious)), bytes32(0));
    }

    // --- quantitative invariants ---

    function test_lossCap_revertsOnLossyVenue() public {
        morphoWrapper.setHaircutBps(200); // 2% > 0.5% cap

        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(morphoVault, OperationKind.DEPOSIT, 1_000e6));

        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(ops);
    }

    function test_lossCap_toleratesLossWithinCap() public {
        morphoWrapper.setHaircutBps(30); // 0.3% < 0.5% cap

        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(morphoVault, OperationKind.DEPOSIT, 1_000e6)));
        assertEq(out[0], 997e6);
    }

    function test_lossCap_roundsMinimumOutputUp() public {
        morphoWrapper.setHaircutBps(50);
        underlying.mint(account, 101);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(morphoVault, OperationKind.DEPOSIT, 101));

        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(ops);
    }

    function test_signedAbsoluteMinimumOutput_isEnforced() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation memory op =
            _opWithMode(aaveVault, OperationKind.DEPOSIT, AmountMode.EXACT, 100e6, 100e6 + 1);

        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(_ops1(op));
    }

    function test_zeroAbsoluteMinimumOutput_isRejected() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation memory op =
            _opWithMode(aaveVault, OperationKind.DEPOSIT, AmountMode.EXACT, 100e6, 0);

        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(_ops1(op));
    }

    function test_feeOnTransferSource_revertsUnsupportedToken() public {
        GrowYieldExecutor feeExecutor = new GrowYieldExecutor(MAX_LOSS_BPS, riskGuardian);
        MockFeeToken feeToken = new MockFeeToken();
        MockAavePool feePool = new MockAavePool(MockUnderlying(address(feeToken)));
        MockMutableAaveDataProvider feeProvider =
            new MockMutableAaveDataProvider(address(feeToken), address(feePool.aToken()));
        AaveV3Adapter feeAdapter = new AaveV3Adapter(
            IAaveV3Pool(address(feePool)),
            IAaveProtocolDataProvider(address(feeProvider)),
            address(feeExecutor)
        );
        GrowYieldAdapterRegistry feeRegistry = new GrowYieldAdapterRegistry(
            address(feeExecutor),
            address(this),
            IGrowYieldAdapterRegistry.Registrars({
                aavePool: address(feePool),
                aaveDataProvider: address(feeProvider),
                morphoVaultFactory: address(0),
                morphoAdapterFactory: address(0),
                morphoEligibility: address(0),
                eulerEVaultFactory: address(0),
                eulerEarnFactory: address(0),
                capyFiComptroller: address(0)
            })
        );
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(feeAdapter), address(feeToken), Protocol.AAVE, true, true
        );
        feeRegistry.addVaults(vaults);

        feeToken.mint(account, 1_000e6);
        vm.startPrank(account);
        feeExecutor.setAccountRegistry(feeRegistry);
        feeExecutor.setVaultPolicy(
            address(feeToken), DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days
        );
        feeToken.approve(address(feeExecutor), type(uint256).max);
        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            vault: address(feeToken),
            kind: OperationKind.DEPOSIT,
            sourceToken: address(feeToken),
            amount: 100e6,
            amountMode: AmountMode.EXACT,
            minAmountOut: 1
        });

        vm.expectRevert(IGrowYieldExecutor.UnsupportedToken.selector);
        feeExecutor.execute(ops);
        vm.stopPrank();
    }

    function test_accountMustExplicitlyEnableVenue() public {
        vm.prank(account);
        executor.setVaultPolicy(aaveVault, 0, 0, 0);
        underlying.mint(account, 1e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6));

        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        _execute(ops);
    }

    function test_epochBudgetBoundsCumulativeDepositVolume() public {
        vm.prank(account);
        executor.setVaultPolicy(aaveVault, 100e6, 0, 1 days);
        underlying.mint(account, 150e6);
        _approveMax(address(underlying));

        _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 60e6)));
        Operation[] memory exceeds = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 41e6));
        vm.expectRevert(IGrowYieldExecutor.BudgetExceeded.selector);
        _execute(exceeds);

        vm.warp(block.timestamp + 1 days);
        _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 41e6)));
    }

    function test_policyLimitUpdate_preservesConsumption() public {
        vm.prank(account);
        executor.setVaultPolicy(aaveVault, 100e6, 0, 1 days);
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 60e6)));

        vm.prank(account);
        executor.setVaultPolicy(aaveVault, 70e6, 0, 1 days);
        (,, uint256 spent,,,) = executor.vaultPolicy(account, address(aaveAdapter));
        assertEq(spent, 60e6);

        Operation[] memory exceeds = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 11e6));
        vm.expectRevert(IGrowYieldExecutor.BudgetExceeded.selector);
        _execute(exceeds);
    }

    function test_policyDurationChange_requiresExplicitReset() public {
        vm.prank(account);
        executor.setVaultPolicy(aaveVault, 100e6, 0, 1 days);
        underlying.mint(account, 160e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 60e6)));

        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.EpochDurationChangeRequiresReset.selector);
        executor.setVaultPolicy(aaveVault, 100e6, 0, 2 days);

        vm.prank(account);
        executor.resetVaultPolicy(aaveVault, 100e6, 0, 2 days);
        (,, uint256 spent,, uint48 duration,) = executor.vaultPolicy(account, address(aaveAdapter));
        assertEq(spent, 0);
        assertEq(duration, 2 days);
        _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 100e6)));
    }

    function test_unboundedAdapterPolicy_isRejected() public {
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.UnboundedPolicy.selector);
        executor.setVaultPolicy(aaveVault, type(uint256).max, 0, 1 days);
    }

    function test_riskGuardianPause_blocksDepositsButNotExits() public {
        _seedAave(100e6);

        vm.prank(makeAddr("notGuardian"));
        vm.expectRevert(IGrowYieldExecutor.OnlyRiskGuardian.selector);
        executor.pauseVaultDeposits(registry, aaveVault);

        vm.prank(riskGuardian);
        executor.pauseVaultDeposits(registry, aaveVault);
        assertTrue(executor.depositsPaused(aaveVault));

        underlying.mint(account, 1e6);
        _approveMax(address(underlying));
        Operation[] memory depositOps = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6));
        vm.expectRevert(IGrowYieldExecutor.DepositsPaused.selector);
        _execute(depositOps);

        _approveMax(address(aavePool.aToken()));
        _execute(_ops1(_op(aaveVault, OperationKind.REDEEM, type(uint256).max)));
        assertEq(aavePool.aToken().balanceOf(account), 0);
    }

    function test_revertedOperationDoesNotConsumeBudget() public {
        vm.prank(account);
        executor.setVaultPolicy(morphoVault, 100e6, 0, 1 days);
        morphoWrapper.setHaircutBps(200);
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));

        Operation[] memory ops = _ops1(_op(morphoVault, OperationKind.DEPOSIT, 100e6));
        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(ops);

        (,, uint256 depositSpent,,,) = executor.vaultPolicy(account, address(morphoAdapter));
        assertEq(depositSpent, 0);
    }

    // --- drift protection ---

    function test_morphoDrift_ineligibleChild_blocksDepositAllowsExit() public {
        underlying.mint(account, 200e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(morphoVault, OperationKind.DEPOSIT, 100e6)));

        morphoEligibility.set(address(morphoChild), false);
        Operation[] memory depositOps = _ops1(_op(morphoVault, OperationKind.DEPOSIT, 100e6));

        vm.expectRevert(MorphoVaultV2Adapter.VenueDrift.selector);
        _execute(depositOps);

        _approveMax(address(morphoWrapper));
        _execute(_ops1(_op(morphoVault, OperationKind.REDEEM, type(uint256).max)));
        assertEq(morphoWrapper.balanceOf(account), 0);
    }

    function test_morphoDrift_liquidityAdapterChanged_blocksDeposit() public {
        morphoWrapper.setLiquidityAdapter(makeAddr("newAdapter"));

        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(morphoVault, OperationKind.DEPOSIT, 100e6));
        vm.expectRevert(MorphoVaultV2Adapter.VenueDrift.selector);
        _execute(ops);
    }

    function test_morphoGate_blocksDepositWithoutCurrentRoundTripAccess() public {
        morphoWrapper.setGateBlocked(morphoWrapper.canSendShares.selector, account, true);
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(morphoVault, OperationKind.DEPOSIT, 100e6));

        vm.expectRevert(MorphoVaultV2Adapter.VenueGate.selector);
        _execute(ops);
    }

    function test_aaveDrift_reserveRepointed_blocksDepositAllowsExit() public {
        _seedAave(100e6);

        aaveDataProvider.setAToken(makeAddr("newAToken"));

        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory depositOps = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 100e6));
        vm.expectRevert(AaveV3Adapter.ReserveDrift.selector);
        _execute(depositOps);

        _approveMax(address(aavePool.aToken()));
        _execute(_ops1(_op(aaveVault, OperationKind.REDEEM, type(uint256).max)));
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
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.REDEEM, 100e6));
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

        _execute(_ops1(_op(aaveVault, OperationKind.REDEEM, type(uint256).max)));

        assertEq(underlying.balanceOf(stranger), strangerBefore);
        assertEq(underlying.balanceOf(account), 100e6);
    }

    // --- helpers ---

    function _seedAave(uint256 amount) internal {
        underlying.mint(account, amount);
        _approveMax(address(underlying));
        _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, type(uint256).max)));
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
