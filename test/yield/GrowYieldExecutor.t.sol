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
    MAX_OPS,
    Operation,
    OperationKind
} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {MockAToken, MockAavePool, MockUnderlying} from "../invariant/MockYieldVenues.sol";
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

    function test_constructor_rejectsZeroMaxLossBps() public {
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldExecutor(0, riskGuardian, address(this), _mockRegistrars());
    }

    function test_constructor_rejectsLossCapAboveCeiling() public {
        uint16 overCeiling = executor.MAX_LOSS_BPS_CEILING() + 1;
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldExecutor(overCeiling, riskGuardian, address(this), _mockRegistrars());
    }

    function test_constructor_rejectsZeroRiskGuardian() public {
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldExecutor(MAX_LOSS_BPS, address(0), address(this), _mockRegistrars());
    }

    /// @dev Admission and execution are one contract, so there is no pointer to keep in sync
    ///      and no per-account registry selection to get wrong.
    function test_executorIsItsOwnRegistry() public {
        assertEq(executor.vaultCount(), 3);
        assertEq(executor.venue(aaveVault).adapter, address(aaveAdapter));

        // A second executor is a second, independent venue set over the same infrastructure.
        GrowYieldExecutor other = _deployExecutor(address(this));
        assertEq(other.vaultCount(), 0);
        assertNotEq(address(other), address(executor));
    }

    /// @dev The two authorities must be distinct: one key that could both pause and un-pause
    ///      would collapse the separation the reversible pause depends on.
    function test_constructor_rejectsGuardianEqualToOwner() public {
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldExecutor(MAX_LOSS_BPS, address(this), address(this), _mockRegistrars());
    }

    function test_addVaults_isOwnerOnly() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector, makeAddr("stranger")
            )
        );
        executor.addVaults(_defaultVaults());

        vm.prank(riskGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, riskGuardian)
        );
        executor.addVaults(_defaultVaults());
    }

    /// @dev No account opt-in exists on the executor: admission alone makes a venue usable, and
    ///      any caller may move their own funds through it.
    function test_execute_needsNoPerAccountEnablement() public {
        address stranger = makeAddr("stranger");
        underlying.mint(stranger, 10e6);

        vm.prank(stranger);
        underlying.approve(address(executor), type(uint256).max);

        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 10e6));
        vm.prank(stranger);
        executor.execute(ops);

        assertEq(aavePool.aToken().balanceOf(stranger), 10e6);
        assertEq(aavePool.aToken().balanceOf(account), 0, "no other account touched");
    }

    /// @dev An executor bound to a registry that never admitted the venue rejects it, which is
    ///      what makes the executor choice — made once on the policy module — meaningful.
    function test_execute_rejectsVenueAdmittedOnlyByAnotherExecutorsRegistry() public {
        GrowYieldExecutor other = _deployExecutor(address(this));
        underlying.mint(account, 10e6);

        vm.prank(account);
        underlying.approve(address(other), type(uint256).max);

        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 10e6));
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        other.execute(ops);
    }

    function test_pauseVaultDeposits_rejectsUnknownVenueAndUnauthorizedCaller() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IGrowYieldExecutor.NotAuthorizedToPause.selector);
        executor.pauseVaultDeposits(aaveVault);

        // A venue this registry never admitted fails loudly rather than recording a no-op pause.
        vm.prank(riskGuardian);
        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        executor.pauseVaultDeposits(makeAddr("typo"));
    }

    /// @dev A false-positive pause must not be an unrecoverable state. The guardian protects
    ///      unilaterally; only the registry owner may re-expose accounts to the venue.
    function test_pauseIsReversibleByGovernanceOnly() public {
        vm.prank(riskGuardian);
        executor.pauseVaultDeposits(aaveVault);
        assertTrue(executor.depositsPaused(aaveVault));

        // The guardian can protect but cannot re-expose.
        vm.prank(riskGuardian);
        vm.expectRevert(IGrowYieldExecutor.NotAuthorizedToPause.selector);
        executor.unpauseVaultDeposits(aaveVault);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IGrowYieldExecutor.NotAuthorizedToPause.selector);
        executor.unpauseVaultDeposits(aaveVault);

        // The registry owner (governance for this executor) can.
        vm.expectEmit(true, false, false, false, address(executor));
        emit IGrowYieldExecutor.VaultDepositsUnpaused(aaveVault);
        executor.unpauseVaultDeposits(aaveVault);
        assertFalse(executor.depositsPaused(aaveVault));

        underlying.mint(account, 10e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(aaveVault, OperationKind.DEPOSIT, 10e6)));
        assertEq(aavePool.aToken().balanceOf(account), 10e6, "deposits work again");
    }

    /// @dev Governance can also pause directly, so protection does not depend on one hot key.
    function test_registryOwnerCanAlsoPause() public {
        executor.pauseVaultDeposits(aaveVault);
        assertTrue(executor.depositsPaused(aaveVault));
    }

    function test_execute_rejectsOverlongBatch() public {
        Operation[] memory ops = new Operation[](MAX_OPS + 1);
        for (uint256 i; i < ops.length; ++i) {
            ops[i] = _op(aaveVault, OperationKind.DEPOSIT, 1e6);
        }
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.BatchTooLarge.selector);
        executor.execute(ops);
    }

    /// @dev Pausing one venue must not affect other venues of the same protocol, which share
    ///      the adapter.
    function test_pauseVaultDeposits_isPerVenueNotPerProtocol() public {
        vm.prank(riskGuardian);
        executor.pauseVaultDeposits(aaveVault);

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

    /// @dev Direction is fixed at admission, not per account: a redeem-only venue is one the
    ///      registry owner admitted with `canDeposit == false`.
    function test_directionalGating_depositClosedExitOpen() public {
        (address exitOnlyVault, MockAToken exitOnlyAToken) = _addAaveReserve();
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(aaveAdapter), exitOnlyVault, Protocol.AAVE, false, true
        );
        executor.addVaults(vaults);

        MockUnderlying(exitOnlyVault).mint(account, 1e6);
        vm.prank(account);
        IERC20(exitOnlyVault).approve(address(executor), type(uint256).max);

        Operation[] memory depositOps = _ops1(_op(exitOnlyVault, OperationKind.DEPOSIT, 1e6));
        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        _execute(depositOps);

        // The exit direction stays open: seed a position around the closed deposit path.
        MockUnderlying(exitOnlyVault).mint(address(aavePool), 1e6);
        vm.prank(address(aavePool));
        exitOnlyAToken.mint(account, 1e6);
        vm.prank(account);
        IERC20(address(exitOnlyAToken)).approve(address(executor), type(uint256).max);
        _execute(_ops1(_op(exitOnlyVault, OperationKind.REDEEM, 1e6)));
        // 1e6 held from the rejected deposit, plus the 1e6 just redeemed.
        assertEq(MockUnderlying(exitOnlyVault).balanceOf(account), 2e6);
        assertEq(exitOnlyAToken.balanceOf(account), 0);
    }

    function test_execute_revertsEmptyBatch() public {
        Operation[] memory ops = new Operation[](0);
        vm.prank(account);
        vm.expectRevert(IGrowYieldAdapterRegistry.EmptyBatch.selector);
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

        // Never admitted, so it has no pinned code hash and no venue routes through it.
        underlying.mint(account, 1e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 1e6));
        ops[0].vault = address(malicious);

        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.VenueNotAllowed.selector);
        executor.execute(ops);
        assertEq(executor.adapterCodeHash(address(malicious)), bytes32(0));
        assertEq(underlying.balanceOf(thief), 0);
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
        MockFeeToken feeToken = new MockFeeToken();
        MockAavePool feePool = new MockAavePool(MockUnderlying(address(feeToken)));
        MockMutableAaveDataProvider feeProvider =
            new MockMutableAaveDataProvider(address(feeToken), address(feePool.aToken()));

        GrowYieldExecutor feeExecutor = new GrowYieldExecutor(
            MAX_LOSS_BPS,
            riskGuardian,
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
        AaveV3Adapter feeAdapter = new AaveV3Adapter(
            IAaveV3Pool(address(feePool)),
            IAaveProtocolDataProvider(address(feeProvider)),
            address(feeExecutor)
        );

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(feeAdapter), address(feeToken), Protocol.AAVE, true, true
        );
        feeExecutor.addVaults(vaults);

        feeToken.mint(account, 1_000e6);
        vm.startPrank(account);
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

    function test_riskGuardianPause_blocksDepositsButNotExits() public {
        _seedAave(100e6);

        vm.prank(riskGuardian);
        executor.pauseVaultDeposits(aaveVault);
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

    /// @dev A reverted operation must leave no partial state: the source stays with the
    ///      account and nothing lands on the adapter.
    function test_revertedOperationLeavesNoPartialState() public {
        morphoWrapper.setHaircutBps(200);
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));

        Operation[] memory ops = _ops1(_op(morphoVault, OperationKind.DEPOSIT, 100e6));
        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(ops);

        assertEq(underlying.balanceOf(account), 100e6);
        assertEq(morphoWrapper.balanceOf(account), 0);
        _assertNoResiduals();
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

    /// @dev Aave re-points a reserve's aToken only by dropping and re-initializing the reserve
    ///      (`updateAToken` upgrades the proxy behind a fixed address). Grow blocks the deposit
    ///      on drift, because a deposit must never create a position in a token the registry
    ///      never admitted. The exit stays open on Grow's side: the executor measures the
    ///      pinned position token and the adapter derives nothing of its own, so whether the
    ///      redemption succeeds is left entirely to the protocol. Drift is per-venue, so
    ///      sibling reserves of the same pool and adapter are unaffected.
    function test_aaveDrift_reserveRepointed_blocksDepositButNotExit() public {
        _seedAave(100e6);

        aaveDataProvider.setAToken(makeAddr("newAToken"));

        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory depositOps = _ops1(_op(aaveVault, OperationKind.DEPOSIT, 100e6));
        vm.expectRevert(IGrowYieldExecutor.VenueDrift.selector);
        _execute(depositOps);

        // Grow does not add a second reason for the exit to fail.
        _approveMax(address(aavePool.aToken()));
        _execute(_ops1(_op(aaveVault, OperationKind.REDEEM, 100e6)));
        assertEq(aavePool.aToken().balanceOf(account), 0, "position exited");
        assertEq(underlying.balanceOf(account), 200e6, "deposit funds plus redemption");

        // A sibling reserve served by the same pool and adapter still round-trips.
        otherUnderlying.mint(account, 50e6);
        _approveMax(address(otherUnderlying));
        _execute(_ops1(_op(aaveVaultOther, OperationKind.DEPOSIT, 50e6)));

        _approveMax(address(aavePool.aTokens(aaveVaultOther)));
        _execute(_ops1(_op(aaveVaultOther, OperationKind.REDEEM, type(uint256).max)));
        assertEq(otherUnderlying.balanceOf(account), 50e6);
    }

    // --- access ---

    function test_adapters_onlyExecutor() public {
        vm.expectRevert(AaveV3Adapter.OnlyExecutor.selector);
        aaveAdapter.deposit(aaveVault, 1, account);

        vm.expectRevert(MorphoVaultV2Adapter.OnlyExecutor.selector);
        morphoAdapter.redeem(morphoVault, 1, account);
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
