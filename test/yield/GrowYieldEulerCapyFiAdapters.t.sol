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
    Operation,
    OperationKind
} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol,
    Venue
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {MockUnderlying} from "../invariant/MockYieldVenues.sol";
import {
    MockCapyFiComptroller,
    MockCapyFiMarket,
    MockEulerEarnFactory,
    MockEulerEVaultFactory,
    MockEulerVault
} from "./mocks/MockEulerCapyFiStack.sol";

/// @notice Construction, drift, Compound return-code, and executor integration coverage
///         for Euler EVK, Euler Earn, and CapyFi adapters.
contract GrowYieldEulerCapyFiAdaptersTest is Test {
    uint16 internal constant MAX_LOSS_BPS = 50;

    GrowYieldExecutor internal executor;

    MockUnderlying internal underlying;
    MockUnderlying internal otherUnderlying;

    MockEulerEVaultFactory internal evkFactory;
    MockEulerEarnFactory internal earnFactory;
    MockEulerVault internal evault;
    MockEulerVault internal earnVault;
    EulerEVaultAdapter internal evaultAdapter;
    EulerEarnAdapter internal earnAdapter;

    MockCapyFiMarket internal capyMarket;
    CapyFiAdapter internal capyAdapter;

    address internal evaultVault;
    address internal earnVaultAddr;
    address internal capyVault;

    address internal account;
    address internal riskGuardian;

    function setUp() public {
        account = makeAddr("smartAccount");
        riskGuardian = makeAddr("riskGuardian");
        underlying = new MockUnderlying();
        otherUnderlying = new MockUnderlying();

        evkFactory = new MockEulerEVaultFactory();
        earnFactory = new MockEulerEarnFactory();
        evault = new MockEulerVault(IERC20(address(underlying)), "eUSD", "eUSD");
        earnVault = new MockEulerVault(IERC20(address(underlying)), "eeUSD", "eeUSD");
        evkFactory.setProxy(address(evault), true);
        earnFactory.setVault(address(earnVault), true);

        capyMarket = new MockCapyFiMarket(underlying);

        // The executor deploys its registry; both are immutable and name each other.
        executor = new GrowYieldExecutor(
            MAX_LOSS_BPS,
            riskGuardian,
            address(this),
            IGrowYieldAdapterRegistry.Registrars({
                aavePool: address(0),
                aaveDataProvider: address(0),
                morphoVaultFactory: address(0),
                morphoAdapterFactory: address(0),
                morphoEligibility: address(0),
                eulerEVaultFactory: address(evkFactory),
                eulerEarnFactory: address(earnFactory),
                capyFiComptroller: address(capyMarket.comptroller()),
                getEquityMarket: address(0)
            })
        );

        evaultAdapter =
            new EulerEVaultAdapter(IEulerEVaultFactory(address(evkFactory)), address(executor));
        earnAdapter =
            new EulerEarnAdapter(IEulerEarnFactory(address(earnFactory)), address(executor));

        capyAdapter = new CapyFiAdapter(
            address(executor), ICapyFiComptroller(address(capyMarket.comptroller()))
        );

        evaultVault = address(evault);
        earnVaultAddr = address(earnVault);
        capyVault = address(capyMarket.caToken());

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](3);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(evaultAdapter), evaultVault, Protocol.EULER_EVK, true, true
        );
        vaults[1] = IGrowYieldAdapterRegistry.VaultConfig(
            address(earnAdapter), earnVaultAddr, Protocol.EULER_EARN, true, true
        );
        vaults[2] = IGrowYieldAdapterRegistry.VaultConfig(
            address(capyAdapter), capyVault, Protocol.CAPYFI, true, true
        );
        executor.addVaults(vaults);
    }

    function _approveMax(address token) internal {
        vm.prank(account);
        IERC20(token).approve(address(executor), type(uint256).max);
    }

    function _op(address vault, OperationKind kind, uint256 amount)
        internal
        view
        returns (Operation memory)
    {
        Venue memory venue = executor.venue(vault);
        address sourceToken = kind == OperationKind.DEPOSIT ? venue.asset : venue.positionToken;
        AmountMode amountMode =
            amount == type(uint256).max ? AmountMode.FULL_BALANCE : AmountMode.EXACT;
        return Operation({
            vault: vault,
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

    // --- CapyFi construction / authenticity ---

    // --- protocol drift at runtime ---

    function test_evault_depositRevertsWhenFactoryDelistsProxy() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(evaultVault, OperationKind.DEPOSIT, 100e6));
        evkFactory.setProxy(address(evault), false);

        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        _execute(ops);
    }

    function test_earn_redeemRevertsWhenFactoryDelistsVault() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(earnVaultAddr, OperationKind.DEPOSIT, 100e6)));

        _approveMax(address(earnVault));
        Operation[] memory ops = _ops1(_op(earnVaultAddr, OperationKind.REDEEM, type(uint256).max));
        earnFactory.setVault(address(earnVault), false);
        vm.expectRevert(AbstractEulerAdapter.NonCanonical.selector);
        _execute(ops);
    }

    function test_capy_depositRevertsWhenMarketDelisted() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(capyVault, OperationKind.DEPOSIT, 100e6));
        capyMarket.comptroller().setListed(address(capyMarket.caToken()), false);

        vm.expectRevert(CapyFiAdapter.VenueDrift.selector);
        _execute(ops);
    }

    function test_capy_depositRevertsWhenComptrollerDrifts() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(capyVault, OperationKind.DEPOSIT, 100e6));
        capyMarket.caToken().setComptrollerOverride(makeAddr("rogueComptroller"));

        vm.expectRevert(CapyFiAdapter.VenueDrift.selector);
        _execute(ops);
    }

    // --- Compound return codes ---

    function test_capy_mintNonZeroReturnCodeReverts() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation[] memory ops = _ops1(_op(capyVault, OperationKind.DEPOSIT, 100e6));
        capyMarket.caToken().setMintErrorCode(3);

        vm.expectRevert(abi.encodeWithSelector(CapyFiAdapter.MintFailed.selector, uint256(3)));
        _execute(ops);
    }

    function test_capy_redeemNonZeroReturnCodeReverts() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(capyVault, OperationKind.DEPOSIT, 100e6)));

        _approveMax(address(capyMarket.caToken()));
        Operation[] memory ops = _ops1(_op(capyVault, OperationKind.REDEEM, type(uint256).max));
        capyMarket.caToken().setRedeemErrorCode(14);

        vm.expectRevert(abi.encodeWithSelector(CapyFiAdapter.RedeemFailed.selector, uint256(14)));
        _execute(ops);
    }

    // --- allowance / residual cleanup ---

    function test_capy_clearsAllowanceAfterDeposit() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(capyVault, OperationKind.DEPOSIT, 100e6)));

        assertEq(
            IERC20(underlying).allowance(address(capyAdapter), address(capyMarket.caToken())), 0
        );
        assertEq(IERC20(underlying).balanceOf(address(capyAdapter)), 0);
        assertEq(IERC20(address(capyMarket.caToken())).balanceOf(address(capyAdapter)), 0);
    }

    function test_capy_redeemLeavesZeroBalancesAndAllowances() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(capyVault, OperationKind.DEPOSIT, 100e6)));

        uint256 shares = capyMarket.caToken().balanceOf(account);
        assertGt(shares, 0);

        _approveMax(address(capyMarket.caToken()));
        _execute(_ops1(_op(capyVault, OperationKind.REDEEM, shares)));

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
        _execute(_ops1(_op(evaultVault, OperationKind.DEPOSIT, 100e6)));

        assertEq(IERC20(underlying).allowance(address(evaultAdapter), address(evault)), 0);
        assertEq(IERC20(underlying).balanceOf(address(evaultAdapter)), 0);
        assertEq(evault.balanceOf(address(evaultAdapter)), 0);
        assertEq(evault.balanceOf(account), 100e6);
    }

    function test_evault_redeemSendsUnderlyingDirectlyAndLeavesNoResidual() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(evaultVault, OperationKind.DEPOSIT, 100e6)));

        _approveMax(address(evault));
        _execute(_ops1(_op(evaultVault, OperationKind.REDEEM, 100e6)));

        assertEq(underlying.balanceOf(account), 100e6);
        assertEq(evault.balanceOf(account), 0);
        assertEq(IERC20(underlying).balanceOf(address(evaultAdapter)), 0);
        assertEq(evault.balanceOf(address(evaultAdapter)), 0);
        assertEq(IERC20(underlying).allowance(address(evaultAdapter), address(evault)), 0);
    }

    function test_earn_depositCreditsReceiverDirectly() public {
        underlying.mint(account, 75e6);
        _approveMax(address(underlying));
        uint256[] memory out = _execute(_ops1(_op(earnVaultAddr, OperationKind.DEPOSIT, 75e6)));

        assertEq(out[0], 75e6);
        assertEq(earnVault.balanceOf(account), 75e6);
        assertEq(earnVault.balanceOf(address(earnAdapter)), 0);
        assertEq(IERC20(underlying).allowance(address(earnAdapter), address(earnVault)), 0);
    }

    // --- exact source consumption / donation isolation ---

    function test_evault_redeemDoesNotSweepDonation() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(evaultVault, OperationKind.DEPOSIT, 100e6)));

        // Donate shares directly to the adapter.
        underlying.mint(address(this), 10e6);
        underlying.approve(address(evault), 10e6);
        evault.deposit(10e6, address(evaultAdapter));

        _approveMax(address(evault));
        uint256[] memory out =
            _execute(_ops1(_op(evaultVault, OperationKind.REDEEM, type(uint256).max)));

        assertEq(out[0], 100e6);
        assertEq(evault.balanceOf(address(evaultAdapter)), 10e6);
        assertEq(underlying.balanceOf(account), 100e6);
    }

    function test_capy_redeemDoesNotSweepDonation() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(capyVault, OperationKind.DEPOSIT, 100e6)));

        uint256 donated = 5e8;
        capyMarket.caToken().mintShares(address(capyAdapter), donated);

        _approveMax(address(capyMarket.caToken()));
        _execute(_ops1(_op(capyVault, OperationKind.REDEEM, type(uint256).max)));

        assertEq(capyMarket.caToken().balanceOf(address(capyAdapter)), donated);
        assertEq(IERC20(underlying).balanceOf(address(capyAdapter)), 0);
    }

    // --- previews ---

    function test_capy_previewDepositMatchesMintMath() public view {
        uint256 assets = 100e6;
        uint256 expected = (assets * 1e18) / capyMarket.caToken().exchangeRateStored();
        assertEq(capyAdapter.previewDeposit(capyVault, assets), expected);
    }

    /// @dev Compound accrues interest inside `mint`, and accrual only ever raises the exchange
    ///      rate, so quoting `exchangeRateStored` on a market that has not been touched lately
    ///      promises more shares than the mint delivers. Past `maxLossBps` of drift the executor
    ///      rejects the deposit outright — a dormant market that silently stops accepting
    ///      deposits. The preview must therefore replay accrual.
    function test_capy_previewAccruesInterestLikeMint() public {
        // An existing supply base, then 50% utilisation at a deliberately brisk per-block rate.
        capyMarket.caToken().mintShares(makeAddr("existingSupplier"), 1e13);
        capyMarket.caToken().setBorrowState(100_000e6, 100_000e6, 1e11, 0.15e18);
        uint256 staleRate = capyMarket.caToken().exchangeRateStored();

        vm.roll(block.number + 2_000_000);

        uint256 assets = 100e6;
        uint256 stalePreview = (assets * 1e18) / staleRate;
        uint256 accruedPreview = capyAdapter.previewDeposit(capyVault, assets);

        assertLt(accruedPreview, stalePreview, "accrual reduces the shares a deposit earns");
        // The drift is wider than the loss cap, so the stale preview would have failed closed.
        assertLt(
            accruedPreview * 10_000 / stalePreview,
            10_000 - MAX_LOSS_BPS,
            "stale preview would breach the loss cap"
        );

        underlying.mint(account, assets);
        _approveMax(address(underlying));
        uint256[] memory received = _execute(_ops1(_op(capyVault, OperationKind.DEPOSIT, assets)));

        assertEq(received[0], accruedPreview, "preview matched what mint actually paid");
    }

    /// @dev A market with no borrows cannot accrue, so the stored rate is already exact and the
    ///      replay must not perturb it.
    function test_capy_previewMatchesStoredRateWithoutBorrows() public {
        vm.roll(block.number + 1_000_000);

        uint256 assets = 100e6;
        uint256 expected = (assets * 1e18) / capyMarket.caToken().exchangeRateStored();
        assertEq(capyAdapter.previewDeposit(capyVault, assets), expected);
    }

    function test_evault_previewDelegatesToVault() public view {
        assertEq(evaultAdapter.previewDeposit(evaultVault, 100e6), evault.previewDeposit(100e6));
        assertEq(evaultAdapter.previewRedeem(evaultVault, 50e6), evault.previewRedeem(50e6));
    }

    // --- executor integration: deposit / redeem / floors / PREVIOUS_OUTPUT ---

    function test_executor_depositRedeem_evault() public {
        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(evaultVault, OperationKind.DEPOSIT, 400e6)));
        assertEq(out[0], 400e6);
        assertEq(evault.balanceOf(account), 400e6);

        _approveMax(address(evault));
        out = _execute(_ops1(_op(evaultVault, OperationKind.REDEEM, 200e6)));
        assertEq(out[0], 200e6);
        assertEq(underlying.balanceOf(account), 800e6);
    }

    function test_executor_depositRedeem_earn() public {
        underlying.mint(account, 500e6);
        _approveMax(address(underlying));
        uint256[] memory out = _execute(_ops1(_op(earnVaultAddr, OperationKind.DEPOSIT, 500e6)));
        assertEq(out[0], 500e6);

        _approveMax(address(earnVault));
        out = _execute(_ops1(_op(earnVaultAddr, OperationKind.REDEEM, type(uint256).max)));
        assertEq(out[0], 500e6);
        assertEq(underlying.balanceOf(account), 500e6);
    }

    function test_executor_depositRedeem_capy() public {
        underlying.mint(account, 200e6);
        _approveMax(address(underlying));
        uint256[] memory out = _execute(_ops1(_op(capyVault, OperationKind.DEPOSIT, 200e6)));
        assertGt(out[0], 0);
        assertEq(capyMarket.caToken().balanceOf(account), out[0]);

        _approveMax(address(capyMarket.caToken()));
        out = _execute(_ops1(_op(capyVault, OperationKind.REDEEM, type(uint256).max)));
        assertEq(out[0], 200e6);
        assertEq(underlying.balanceOf(account), 200e6);
    }

    function test_executor_outputFloor_enforcedOnCapy() public {
        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        Operation memory op = Operation({
            vault: capyVault,
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
        _execute(_ops1(_op(evaultVault, OperationKind.DEPOSIT, 800e6)));

        // Idle underlying must not be swept by PREVIOUS_OUTPUT.
        underlying.mint(account, 250e6);
        _approveMax(address(evault));
        _approveMax(address(underlying));

        _execute(
            _ops2(
                _op(evaultVault, OperationKind.REDEEM, type(uint256).max),
                _op(capyVault, OperationKind.DEPOSIT, type(uint256).max)
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
        evaultAdapter.deposit(evaultVault, 1e6, account);

        vm.expectRevert(CapyFiAdapter.OnlyExecutor.selector);
        capyAdapter.deposit(capyVault, 1e6, account);
    }

    function test_registry_enumeratesEulerAndCapyVenues() public view {
        assertEq(executor.vaultCount(), 3);
        assertEq(executor.vaultAt(0), evaultVault);
        assertEq(executor.vaultAt(1), earnVaultAddr);
        assertEq(executor.vaultAt(2), capyVault);
        assertEq(executor.adapterCodeHash(address(evaultAdapter)), address(evaultAdapter).codehash);
        assertEq(executor.adapterCodeHash(address(earnAdapter)), address(earnAdapter).codehash);
        assertEq(executor.adapterCodeHash(address(capyAdapter)), address(capyAdapter).codehash);
    }
}
