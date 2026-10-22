// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    Operation,
    OperationKind
} from "../../src/interfaces/IGrowYieldExecutor.sol";

import {MockUnderlying} from "../invariant/MockYieldVenues.sol";
import {
    MockRebasingAavePool,
    MockRebasingDataProvider,
    RebasingAToken
} from "./mocks/MockRebasingAave.sol";

/// @notice Coverage for venues whose position token rebases.
/// @dev The executor bounds an adapter's residual with *absolute* before/after balances, and the
///      only rebasing position token in the stack is the aToken. One adapter serves every Aave
///      reserve and must hold aTokens to burn them, so it is a permanent shared sink anyone can
///      donate into — which would be a cheap denial of service if a donated balance could grow
///      mid-operation and get blamed on the caller.
///
///      It cannot. Aave's normalized income accrues on read, so it is constant within a
///      transaction and `updateState` only writes down what the view already returned. These
///      tests pin that down with an accrue-on-read mock, because `MockAToken` mints 1:1 and
///      cannot exercise the tolerances at all.
contract GrowYieldRebasingVenueTest is Test {
    uint16 internal constant MAX_LOSS_BPS = 50;

    MockUnderlying internal underlying;
    MockRebasingAavePool internal pool;
    RebasingAToken internal aToken;
    GrowYieldExecutor internal executor;
    AaveV3Adapter internal adapter;

    address internal user = makeAddr("user");
    address internal donor = makeAddr("donor");
    address internal riskGuardian = makeAddr("riskGuardian");

    function setUp() public {
        vm.warp(1_700_000_000);

        underlying = new MockUnderlying();
        pool = new MockRebasingAavePool(IERC20(address(underlying)));
        aToken = pool.aToken();
        MockRebasingDataProvider provider = new MockRebasingDataProvider(address(aToken));

        executor = new GrowYieldExecutor(
            MAX_LOSS_BPS,
            riskGuardian,
            address(this),
            IGrowYieldAdapterRegistry.Registrars({
                aavePool: address(pool),
                aaveDataProvider: address(provider),
                morphoVaultFactory: address(0),
                morphoAdapterFactory: address(0),
                morphoEligibility: address(0),
                eulerEVaultFactory: address(0),
                eulerEarnFactory: address(0),
                capyFiComptroller: address(0),
                getEquityMarket: address(0)
            })
        );
        adapter = new AaveV3Adapter(
            IAaveV3Pool(address(pool)),
            IAaveProtocolDataProvider(address(provider)),
            address(executor)
        );

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(adapter), address(underlying), Protocol.AAVE, true, true
        );
        executor.addVaults(vaults);

        underlying.mint(user, 10_000e6);
        vm.startPrank(user);
        underlying.approve(address(executor), type(uint256).max);
        aToken.approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    function test_depositAndRedeemWithoutDonation() public {
        skip(30 days);
        _deposit(1_000e6);
        assertGt(aToken.balanceOf(user), 0, "user holds aTokens");

        skip(30 days);
        _redeem(500e6);
        assertGt(underlying.balanceOf(user), 9_000e6, "user got underlying back");
    }

    /// @dev A donation into the shared adapter must not block anyone's deposit.
    function test_donationDoesNotBlockDeposits() public {
        _donate(100e6);
        skip(1 hours);

        _deposit(1_000e6);
        assertGt(aToken.balanceOf(user), 0, "deposit still credited");
    }

    /// @dev Redemptions are never pausable by design; a donation must not pause them either.
    function test_donationDoesNotBlockRedemptions() public {
        _deposit(1_000e6);
        _donate(100e6);
        skip(1 hours);

        uint256 before = underlying.balanceOf(user);
        _redeem(500e6);
        assertEq(underlying.balanceOf(user) - before, 500e6, "user exited");
    }

    /// @dev Sweep donation sizes across nine orders of magnitude, each with a full year of
    ///      unaccrued drift, so no donation can be sized to trip the residual bounds.
    function test_donationOfAnySizeDoesNotBlockOperations() public {
        uint256[5] memory donations = [uint256(1), 175_201, 1e6, 100e6, 10_000e6];

        for (uint256 i; i < donations.length; ++i) {
            uint256 snapshot = vm.snapshotState();

            _donate(donations[i]);
            skip(365 days); // a full year of unaccrued index drift

            _deposit(1_000e6);
            _redeem(500e6);

            vm.revertToState(snapshot);
        }
    }

    /// @dev The anti-sweep bound is the half that protects other people's balances, so it stays
    ///      exact: the adapter may never end up holding less than it started with.
    function test_adapterNeverConsumesDonatedBalance() public {
        _donate(100e6);
        uint256 donatedBefore = aToken.balanceOf(address(adapter));

        _deposit(1_000e6);
        _redeem(500e6);

        assertGe(
            aToken.balanceOf(address(adapter)), donatedBefore, "donation was not swept into an op"
        );
    }

    function _donate(uint256 amount) private {
        underlying.mint(donor, amount);
        vm.startPrank(donor);
        underlying.approve(address(pool), amount);
        pool.supply(address(underlying), amount, address(adapter), 0);
        vm.stopPrank();
    }

    function _deposit(uint256 amount) private {
        _run(OperationKind.DEPOSIT, address(underlying), amount);
    }

    function _redeem(uint256 amount) private {
        _run(OperationKind.REDEEM, address(aToken), amount);
    }

    function _run(OperationKind kind, address sourceToken, uint256 amount) private {
        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            vault: address(underlying),
            kind: kind,
            sourceToken: sourceToken,
            amount: amount,
            amountMode: AmountMode.EXACT,
            minAmountOut: 1
        });
        vm.prank(user);
        executor.execute(ops);
    }
}
