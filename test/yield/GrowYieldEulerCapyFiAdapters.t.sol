// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Test} from "forge-std/Test.sol";

import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {AbstractEulerAdapter} from "../../src/adapters/AbstractEulerAdapter.sol";
import {CapyFiAdapter} from "../../src/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../../src/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../../src/adapters/EulerEVaultAdapter.sol";
import {ICapyFiCaToken} from "../../src/interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "../../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../../src/interfaces/IEulerEVaultFactory.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    IYieldAdapter,
    Operation,
    OperationKind
} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {IGrowYieldAdapterRegistry} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {MockUnderlying} from "../invariant/MockYieldVenues.sol";
import {
    MockCapyFiComptroller,
    MockCapyFiMarket,
    MockEulerEarnFactory,
    MockEulerEarnVault,
    MockEulerEVaultFactory,
    MockEulerVault
} from "./mocks/MockEulerCapyFiStack.sol";

/// @notice Construction, drift, Compound return-code, and executor integration coverage
///         for Euler EVK, Euler Earn, and CapyFi adapters.
contract GrowYieldEulerCapyFiAdaptersTest is Test {
    uint16 internal constant MAX_LOSS_BPS = 50;
    uint256 internal constant DEFAULT_VOLUME_LIMIT = 1e36;

    GrowYieldExecutor internal executor;
    GrowYieldAdapterRegistry internal registry;

    MockUnderlying internal underlying;
    MockUnderlying internal otherUnderlying;

    MockEulerEVaultFactory internal evkFactory;
    MockEulerEarnFactory internal earnFactory;
    MockEulerVault internal evault;
    MockEulerVault internal earnChild;
    MockEulerEarnVault internal earnVault;
    EulerEVaultAdapter internal evaultAdapter;
    EulerEarnAdapter internal earnAdapter;

    MockCapyFiMarket internal capyMarket;
    CapyFiAdapter internal capyAdapter;

    address internal account;
    address internal riskGuardian;

    function setUp() public {
        account = makeAddr("smartAccount");
        riskGuardian = makeAddr("riskGuardian");
        executor = new GrowYieldExecutor(MAX_LOSS_BPS, riskGuardian);
        underlying = new MockUnderlying();
        otherUnderlying = new MockUnderlying();

        evkFactory = new MockEulerEVaultFactory();
        earnFactory = new MockEulerEarnFactory();
        evault = new MockEulerVault(IERC20(address(underlying)), "eUSD", "eUSD");
        earnChild = new MockEulerVault(IERC20(address(underlying)), "child", "child");
        earnVault = new MockEulerEarnVault(
            IERC20(address(underlying)), IERC4626(address(earnChild)), "eeUSD", "eeUSD"
        );
        evkFactory.setProxy(address(evault), true);
        earnFactory.setVault(address(earnVault), true);
        earnFactory.setVault(address(earnChild), true);
        earnFactory.setStrategyAllowed(address(earnChild), true);

        evaultAdapter = new EulerEVaultAdapter(
            IEulerEVaultFactory(address(evkFactory)), IERC4626(address(evault)), address(executor)
        );
        earnAdapter = new EulerEarnAdapter(
            IEulerEarnFactory(address(earnFactory)),
            IERC4626(address(earnVault)),
            IERC4626(address(earnChild)),
            address(executor)
        );

        capyMarket = new MockCapyFiMarket(underlying);
        capyAdapter = new CapyFiAdapter(
            address(executor),
            ICapyFiComptroller(address(capyMarket.comptroller())),
            ICapyFiCaToken(address(capyMarket.caToken()))
        );

        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](3);
        configs[0] = IGrowYieldAdapterRegistry.AdapterConfig(address(evaultAdapter), true, true);
        configs[1] = IGrowYieldAdapterRegistry.AdapterConfig(address(earnAdapter), true, true);
        configs[2] = IGrowYieldAdapterRegistry.AdapterConfig(address(capyAdapter), true, true);
        registry = new GrowYieldAdapterRegistry(address(executor), configs);
        executor.initializeRegistry(registry);

        vm.startPrank(account);
        executor.setAdapterPolicy(
            address(evaultAdapter), DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days
        );
        executor.setAdapterPolicy(
            address(earnAdapter), DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days
        );
        executor.setAdapterPolicy(
            address(capyAdapter), DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days
        );
        vm.stopPrank();
    }

    function _approveMax(address token) internal {
        vm.prank(account);
        IERC20(token).approve(address(executor), type(uint256).max);
    }

    function _op(IYieldAdapter adapter, OperationKind kind, uint256 amount)
        internal
        view
        returns (Operation memory)
    {
        address sourceToken =
            kind == OperationKind.DEPOSIT ? adapter.asset() : adapter.positionToken();
        AmountMode amountMode =
            amount == type(uint256).max ? AmountMode.FULL_BALANCE : AmountMode.EXACT;
        return Operation({
            adapter: adapter,
            kind: kind,
            sourceToken: sourceToken,
            amount: amountMode == AmountMode.EXACT ? amount : 0,
            amountMode: amountMode,
            minAmountOut: 1
        });
    }

    function _execute(Operation[] memory ops) internal returns (uint256[] memory) {
        vm.prank(account);
        return executor.execute(ops);
    }

    function _ops1(Operation memory op) internal pure returns (Operation[] memory ops) {
        ops = new Operation[](1);
        ops[0] = op;
    }

    function _ops2(Operation memory a, Operation memory b)
        internal
        pure
        returns (Operation[] memory ops)
    {
        if (b.amountMode == AmountMode.FULL_BALANCE) {
            b.amountMode = AmountMode.PREVIOUS_OUTPUT;
        }
        ops = new Operation[](2);
        ops[0] = a;
        ops[1] = b;
    }

    // --- Euler construction / authenticity ---

    function test_evault_constructsWhenFactoryRecognizesProxy() public view {
        assertEq(evaultAdapter.asset(), address(underlying));
        assertEq(evaultAdapter.positionToken(), address(evault));
        assertEq(address(evaultAdapter.factory()), address(evkFactory));
    }

    function test_evault_rejectsNonCanonicalProxy() public {
        MockEulerVault rogue = new MockEulerVault(IERC20(address(underlying)), "r", "r");
        // factory.isProxy(rogue) defaults false
        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        new EulerEVaultAdapter(
            IEulerEVaultFactory(address(evkFactory)), IERC4626(address(rogue)), address(executor)
        );
    }

    function test_evault_rejectsZeroFactory() public {
        vm.expectRevert(AbstractEulerAdapter.Invalid.selector);
        new EulerEVaultAdapter(
            IEulerEVaultFactory(address(0)), IERC4626(address(evault)), address(executor)
        );
    }

    function test_earn_rejectsNonCanonicalVault() public {
        MockEulerEarnVault rogue = new MockEulerEarnVault(
            IERC20(address(underlying)), IERC4626(address(earnChild)), "r", "r"
        );
        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        new EulerEarnAdapter(
            IEulerEarnFactory(address(earnFactory)),
            IERC4626(address(rogue)),
            IERC4626(address(earnChild)),
            address(executor)
        );
    }

    function test_earn_rejectsUnlockedVault() public {
        MockEulerEarnVault unlocked = new MockEulerEarnVault(
            IERC20(address(underlying)), IERC4626(address(earnChild)), "u", "u"
        );
        unlocked.setUnlocked();
        earnFactory.setVault(address(unlocked), true);
        earnFactory.setStrategyAllowed(address(earnChild), true);
        vm.expectRevert(EulerEarnAdapter.VaultNotLocked.selector);
        new EulerEarnAdapter(
            IEulerEarnFactory(address(earnFactory)),
            IERC4626(address(unlocked)),
            IERC4626(address(earnChild)),
            address(executor)
        );
    }

    function test_earn_rejectsRoutingTargetNotFromFactory() public {
        MockEulerVault rogueChild =
            new MockEulerVault(IERC20(address(underlying)), "rogue", "rogue");
        MockEulerEarnVault vault = new MockEulerEarnVault(
            IERC20(address(underlying)), IERC4626(address(rogueChild)), "w", "w"
        );
        earnFactory.setVault(address(vault), true);
        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        new EulerEarnAdapter(
            IEulerEarnFactory(address(earnFactory)),
            IERC4626(address(vault)),
            IERC4626(address(rogueChild)),
            address(executor)
        );
    }

    function test_earn_rejectsRoutingTargetNotAllowedByFactory() public {
        MockEulerVault rogueChild =
            new MockEulerVault(IERC20(address(underlying)), "rogue", "rogue");
        MockEulerEarnVault vault = new MockEulerEarnVault(
            IERC20(address(underlying)), IERC4626(address(rogueChild)), "w", "w"
        );
        earnFactory.setVault(address(vault), true);
        earnFactory.setVault(address(rogueChild), true);
        vm.expectRevert(EulerEarnAdapter.RoutingTargetNotAllowed.selector);
        new EulerEarnAdapter(
            IEulerEarnFactory(address(earnFactory)),
            IERC4626(address(vault)),
            IERC4626(address(rogueChild)),
            address(executor)
        );
    }

    function test_earn_rejectsRoutingTargetMismatch() public {
        MockEulerVault otherChild =
            new MockEulerVault(IERC20(address(underlying)), "other", "other");
        MockEulerEarnVault vault = new MockEulerEarnVault(
            IERC20(address(underlying)), IERC4626(address(earnChild)), "m", "m"
        );
        earnFactory.setVault(address(vault), true);
        earnFactory.setStrategyAllowed(address(earnChild), true);
        vault.setSupplyQueueHead(IERC4626(address(otherChild)));
        vault.setWithdrawQueueHead(IERC4626(address(otherChild)));
        vm.expectRevert(EulerEarnAdapter.RoutingTargetMismatch.selector);
        new EulerEarnAdapter(
            IEulerEarnFactory(address(earnFactory)),
            IERC4626(address(vault)),
            IERC4626(address(earnChild)),
            address(executor)
        );
    }

    function test_earn_rejectsDisabledRoutingTarget() public {
        MockEulerEarnVault vault = new MockEulerEarnVault(
            IERC20(address(underlying)), IERC4626(address(earnChild)), "d", "d"
        );
        earnFactory.setVault(address(vault), true);
        earnFactory.setStrategyAllowed(address(earnChild), true);
        vault.setChildEnabled(false);
        vm.expectRevert(EulerEarnAdapter.RoutingTargetNotEnabled.selector);
        new EulerEarnAdapter(
            IEulerEarnFactory(address(earnFactory)),
            IERC4626(address(vault)),
            IERC4626(address(earnChild)),
            address(executor)
        );
    }

    // --- CapyFi construction / authenticity ---

    function test_capy_constructsWhenMarketListed() public view {
        assertEq(capyAdapter.asset(), address(underlying));
        assertEq(capyAdapter.positionToken(), address(capyMarket.caToken()));
    }

    function test_capy_rejectsWrongComptroller() public {
        MockCapyFiComptroller other = new MockCapyFiComptroller();
        address caToken = address(capyMarket.caToken());
        other.setListed(caToken, true);
        vm.expectRevert(CapyFiAdapter.VenueDrift.selector);
        new CapyFiAdapter(
            address(executor), ICapyFiComptroller(address(other)), ICapyFiCaToken(caToken)
        );
    }

    function test_capy_rejectsUnlistedMarket() public {
        MockCapyFiMarket market = new MockCapyFiMarket(underlying);
        address comptroller = address(market.comptroller());
        address caToken = address(market.caToken());
        market.comptroller().setListed(caToken, false);
        vm.expectRevert(CapyFiAdapter.VenueDrift.selector);
        new CapyFiAdapter(
            address(executor), ICapyFiComptroller(comptroller), ICapyFiCaToken(caToken)
        );
    }

    // --- protocol drift at runtime ---

    function test_evault_depositRevertsWhenFactoryDelistsProxy() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(evaultAdapter, OperationKind.DEPOSIT, 100e6));
        evkFactory.setProxy(address(evault), false);

        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        _execute(ops);
    }

    function test_evault_depositRevertsWhenAssetDrifts() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(evaultAdapter, OperationKind.DEPOSIT, 100e6));
        evault.setAssetOverride(address(otherUnderlying));

        vm.expectRevert(AbstractEulerAdapter.AssetMismatch.selector);
        _execute(ops);
    }

    function test_earn_redeemRevertsWhenFactoryDelistsVault() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(earnAdapter, OperationKind.DEPOSIT, 100e6)));

        _approveMax(address(earnVault));
        Operation[] memory ops = _ops1(_op(earnAdapter, OperationKind.REDEEM, type(uint256).max));
        earnFactory.setVault(address(earnVault), false);
        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        _execute(ops);
    }

    function test_capy_depositRevertsWhenMarketDelisted() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(capyAdapter, OperationKind.DEPOSIT, 100e6));
        capyMarket.comptroller().setListed(address(capyMarket.caToken()), false);

        vm.expectRevert(CapyFiAdapter.VenueDrift.selector);
        _execute(ops);
    }

    function test_capy_depositRevertsWhenComptrollerDrifts() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(capyAdapter, OperationKind.DEPOSIT, 100e6));
        capyMarket.caToken().setComptrollerOverride(makeAddr("rogueComptroller"));

        vm.expectRevert(CapyFiAdapter.VenueDrift.selector);
        _execute(ops);
    }

    function test_capy_depositRevertsWhenUnderlyingDrifts() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(capyAdapter, OperationKind.DEPOSIT, 100e6));
        capyMarket.caToken().setUnderlyingOverride(address(otherUnderlying));

        vm.expectRevert(CapyFiAdapter.VenueDrift.selector);
        _execute(ops);
    }

    // --- Compound return codes ---

    function test_capy_mintNonZeroReturnCodeReverts() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(capyAdapter, OperationKind.DEPOSIT, 100e6));
        capyMarket.caToken().setMintErrorCode(3);

        vm.expectRevert(abi.encodeWithSelector(CapyFiAdapter.MintFailed.selector, uint256(3)));
        _execute(ops);
    }

    function test_capy_redeemNonZeroReturnCodeReverts() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(capyAdapter, OperationKind.DEPOSIT, 100e6)));

        _approveMax(address(capyMarket.caToken()));
        Operation[] memory ops = _ops1(_op(capyAdapter, OperationKind.REDEEM, type(uint256).max));
        capyMarket.caToken().setRedeemErrorCode(14);

        vm.expectRevert(abi.encodeWithSelector(CapyFiAdapter.RedeemFailed.selector, uint256(14)));
        _execute(ops);
    }

    // --- allowance / residual cleanup ---

    function test_capy_clearsAllowanceAfterDeposit() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(capyAdapter, OperationKind.DEPOSIT, 100e6)));

        assertEq(
            IERC20(underlying).allowance(address(capyAdapter), address(capyMarket.caToken())), 0
        );
        assertEq(IERC20(underlying).balanceOf(address(capyAdapter)), 0);
        assertEq(IERC20(address(capyMarket.caToken())).balanceOf(address(capyAdapter)), 0);
    }

    function test_capy_redeemLeavesZeroBalancesAndAllowances() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(capyAdapter, OperationKind.DEPOSIT, 100e6)));

        uint256 shares = capyMarket.caToken().balanceOf(account);
        assertGt(shares, 0);

        _approveMax(address(capyMarket.caToken()));
        _execute(_ops1(_op(capyAdapter, OperationKind.REDEEM, shares)));

        assertEq(underlying.balanceOf(account), 100e6);
        assertEq(capyMarket.caToken().balanceOf(account), 0);
        assertEq(IERC20(underlying).balanceOf(address(capyAdapter)), 0);
        assertEq(IERC20(address(capyMarket.caToken())).balanceOf(address(capyAdapter)), 0);
        assertEq(
            IERC20(underlying).allowance(address(capyAdapter), address(capyMarket.caToken())), 0
        );
    }

    function test_evault_clearsAllowanceAfterDeposit() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(evaultAdapter, OperationKind.DEPOSIT, 100e6)));

        assertEq(IERC20(underlying).allowance(address(evaultAdapter), address(evault)), 0);
        assertEq(IERC20(underlying).balanceOf(address(evaultAdapter)), 0);
        assertEq(evault.balanceOf(address(evaultAdapter)), 0);
        assertEq(evault.balanceOf(account), 100e6);
    }

    function test_evault_redeemSendsUnderlyingDirectlyAndLeavesNoResidual() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(evaultAdapter, OperationKind.DEPOSIT, 100e6)));

        _approveMax(address(evault));
        _execute(_ops1(_op(evaultAdapter, OperationKind.REDEEM, 100e6)));

        assertEq(underlying.balanceOf(account), 100e6);
        assertEq(evault.balanceOf(account), 0);
        assertEq(IERC20(underlying).balanceOf(address(evaultAdapter)), 0);
        assertEq(evault.balanceOf(address(evaultAdapter)), 0);
        assertEq(IERC20(underlying).allowance(address(evaultAdapter), address(evault)), 0);
    }

    function test_earn_depositCreditsReceiverDirectly() public {
        underlying.mint(account, 75e6);
        _approveMax(address(underlying));
        uint256[] memory out = _execute(_ops1(_op(earnAdapter, OperationKind.DEPOSIT, 75e6)));

        assertEq(out[0], 75e6);
        assertEq(earnVault.balanceOf(account), 75e6);
        assertEq(earnVault.balanceOf(address(earnAdapter)), 0);
        assertEq(IERC20(underlying).allowance(address(earnAdapter), address(earnVault)), 0);
    }

    // --- exact source consumption / donation isolation ---

    function test_evault_redeemDoesNotSweepDonation() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(evaultAdapter, OperationKind.DEPOSIT, 100e6)));

        // Donate shares directly to the adapter.
        underlying.mint(address(this), 10e6);
        underlying.approve(address(evault), 10e6);
        evault.deposit(10e6, address(evaultAdapter));

        _approveMax(address(evault));
        uint256[] memory out =
            _execute(_ops1(_op(evaultAdapter, OperationKind.REDEEM, type(uint256).max)));

        assertEq(out[0], 100e6);
        assertEq(evault.balanceOf(address(evaultAdapter)), 10e6);
        assertEq(underlying.balanceOf(account), 100e6);
    }

    function test_capy_redeemDoesNotSweepDonation() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(capyAdapter, OperationKind.DEPOSIT, 100e6)));

        uint256 donated = 5e8;
        capyMarket.caToken().mintShares(address(capyAdapter), donated);

        _approveMax(address(capyMarket.caToken()));
        _execute(_ops1(_op(capyAdapter, OperationKind.REDEEM, type(uint256).max)));

        assertEq(capyMarket.caToken().balanceOf(address(capyAdapter)), donated);
        assertEq(IERC20(underlying).balanceOf(address(capyAdapter)), 0);
    }

    // --- previews ---

    function test_capy_previewDepositMatchesMintMath() public view {
        uint256 assets = 100e6;
        uint256 expected = (assets * 1e18) / capyMarket.caToken().exchangeRateStored();
        assertEq(capyAdapter.previewDeposit(assets), expected);
    }

    function test_evault_previewDelegatesToVault() public view {
        assertEq(evaultAdapter.previewDeposit(100e6), evault.previewDeposit(100e6));
        assertEq(evaultAdapter.previewRedeem(50e6), evault.previewRedeem(50e6));
    }

    // --- executor integration: deposit / redeem / floors / PREVIOUS_OUTPUT ---

    function test_executor_depositRedeem_evault() public {
        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(evaultAdapter, OperationKind.DEPOSIT, 400e6)));
        assertEq(out[0], 400e6);
        assertEq(evault.balanceOf(account), 400e6);

        _approveMax(address(evault));
        out = _execute(_ops1(_op(evaultAdapter, OperationKind.REDEEM, 200e6)));
        assertEq(out[0], 200e6);
        assertEq(underlying.balanceOf(account), 800e6);
    }

    function test_executor_depositRedeem_earn() public {
        underlying.mint(account, 500e6);
        _approveMax(address(underlying));
        uint256[] memory out = _execute(_ops1(_op(earnAdapter, OperationKind.DEPOSIT, 500e6)));
        assertEq(out[0], 500e6);

        _approveMax(address(earnVault));
        out = _execute(_ops1(_op(earnAdapter, OperationKind.REDEEM, type(uint256).max)));
        assertEq(out[0], 500e6);
        assertEq(underlying.balanceOf(account), 500e6);
    }

    function test_executor_depositRedeem_capy() public {
        underlying.mint(account, 200e6);
        _approveMax(address(underlying));
        uint256[] memory out = _execute(_ops1(_op(capyAdapter, OperationKind.DEPOSIT, 200e6)));
        assertGt(out[0], 0);
        assertEq(capyMarket.caToken().balanceOf(account), out[0]);

        _approveMax(address(capyMarket.caToken()));
        out = _execute(_ops1(_op(capyAdapter, OperationKind.REDEEM, type(uint256).max)));
        assertEq(out[0], 200e6);
        assertEq(underlying.balanceOf(account), 200e6);
    }

    function test_executor_outputFloor_enforcedOnCapy() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation memory op = Operation({
            adapter: capyAdapter,
            kind: OperationKind.DEPOSIT,
            sourceToken: address(underlying),
            amount: 100e6,
            amountMode: AmountMode.EXACT,
            minAmountOut: type(uint256).max
        });
        vm.expectRevert(IGrowYieldExecutor.InsufficientOutput.selector);
        _execute(_ops1(op));
    }

    function test_executor_previousOutput_rebalanceEvaultToCapy() public {
        underlying.mint(account, 800e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(evaultAdapter, OperationKind.DEPOSIT, 800e6)));

        // Idle underlying must not be swept by PREVIOUS_OUTPUT.
        underlying.mint(account, 250e6);
        _approveMax(address(evault));
        _approveMax(address(underlying));

        _execute(
            _ops2(
                _op(evaultAdapter, OperationKind.REDEEM, type(uint256).max),
                _op(capyAdapter, OperationKind.DEPOSIT, type(uint256).max)
            )
        );

        assertEq(underlying.balanceOf(account), 250e6);
        assertEq(evault.balanceOf(account), 0);
        assertGt(capyMarket.caToken().balanceOf(account), 0);
        assertEq(IERC20(underlying).balanceOf(address(evaultAdapter)), 0);
        assertEq(IERC20(underlying).balanceOf(address(capyAdapter)), 0);
    }

    function test_onlyExecutor_canDepositRedeem() public {
        underlying.mint(address(evaultAdapter), 1e6);
        vm.expectRevert(AbstractEulerAdapter.OnlyExecutor.selector);
        evaultAdapter.deposit(1e6, account);

        vm.expectRevert(CapyFiAdapter.OnlyExecutor.selector);
        capyAdapter.deposit(1e6, account);
    }

    function test_evault_rejectsMismatchedFactoryAtConstruction() public {
        MockEulerEVaultFactory otherFactory = new MockEulerEVaultFactory();
        // Vault is registered only on the original factory, not otherFactory.
        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        new EulerEVaultAdapter(
            IEulerEVaultFactory(address(otherFactory)), IERC4626(address(evault)), address(executor)
        );
    }

    function test_earn_rejectsMismatchedFactoryAtConstruction() public {
        MockEulerEarnFactory otherFactory = new MockEulerEarnFactory();
        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        new EulerEarnAdapter(
            IEulerEarnFactory(address(otherFactory)),
            IERC4626(address(earnVault)),
            IERC4626(address(earnChild)),
            address(executor)
        );
    }

    function test_earn_depositRevertsWhenRoutingTargetDelistedFromFactory() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(earnAdapter, OperationKind.DEPOSIT, 100e6));
        earnFactory.setVault(address(earnChild), false);
        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        _execute(ops);
    }

    function test_registry_enumeratesEulerAndCapyAdapters() public view {
        assertEq(registry.adapterCount(), 3);
        assertEq(registry.adapterAt(0), address(evaultAdapter));
        assertEq(registry.adapterAt(1), address(earnAdapter));
        assertEq(registry.adapterAt(2), address(capyAdapter));
        assertEq(registry.adapterCodeHash(address(evaultAdapter)), address(evaultAdapter).codehash);
        assertEq(registry.adapterCodeHash(address(earnAdapter)), address(earnAdapter).codehash);
        assertEq(registry.adapterCodeHash(address(capyAdapter)), address(capyAdapter).codehash);
    }
}
