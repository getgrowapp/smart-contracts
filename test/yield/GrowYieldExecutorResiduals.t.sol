// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
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
import {MockEulerEVaultFactory, MockEulerVault} from "./mocks/MockEulerCapyFiStack.sol";
import {MockLeakyAdapter} from "./mocks/MockLeakyAdapter.sol";

/// @notice The executor is the single enforcement point for adapter residuals.
/// @dev Residual accounting used to run in the executor *and* in three of the four adapters, an
///      invariant duplicated in four places that could drift apart — and applied inconsistently,
///      since `AaveV3Adapter` never had it. The adapters now keep no accounting of their own, so
///      these tests exist to prove the remaining copy actually catches every case the adapter
///      checks did: stranded source, retained output, and swept donations.
contract GrowYieldExecutorResidualsTest is Test {
    uint16 internal constant MAX_LOSS_BPS = 50;

    MockUnderlying internal underlying;
    MockEulerVault internal vault;
    GrowYieldExecutor internal executor;
    MockLeakyAdapter internal adapter;

    address internal account = makeAddr("account");

    function setUp() public {
        underlying = new MockUnderlying();
        vault = new MockEulerVault(IERC20(address(underlying)), "eUSD", "eUSD");

        MockEulerEVaultFactory factory = new MockEulerEVaultFactory();
        factory.setProxy(address(vault), true);

        executor = new GrowYieldExecutor(
            MAX_LOSS_BPS,
            makeAddr("riskGuardian"),
            address(this),
            IGrowYieldAdapterRegistry.Registrars({
                aavePool: address(0),
                aaveDataProvider: address(0),
                morphoVaultFactory: address(0),
                morphoAdapterFactory: address(0),
                morphoEligibility: address(0),
                eulerEVaultFactory: address(factory),
                eulerEarnFactory: address(0),
                capyFiComptroller: address(0)
            })
        );
        adapter = new MockLeakyAdapter(address(executor), address(factory));

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(adapter), address(vault), Protocol.EULER_EVK, true, true
        );
        executor.addVaults(vaults);

        underlying.mint(account, 1_000e6);
        vm.startPrank(account);
        underlying.approve(address(executor), type(uint256).max);
        IERC20(address(vault)).approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    function test_wellBehavedAdapterRoundTrips() public {
        _deposit(100e6);
        assertGt(IERC20(address(vault)).balanceOf(account), 0, "shares credited");
        assertEq(IERC20(address(underlying)).balanceOf(address(adapter)), 0, "nothing stranded");

        _redeem(50e6);
        assertEq(underlying.balanceOf(account), 950e6, "exited");
    }

    /// @dev Half the transferred underlying is never deposited and sits on the adapter.
    function test_strandedSourceIsRejected() public {
        adapter.setMode(MockLeakyAdapter.Misbehavior.STRAND_SOURCE);

        Operation[] memory ops = _ops(OperationKind.DEPOSIT, address(underlying), 100e6);
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.ResidualBalance.selector);
        executor.execute(ops);
    }

    /// @dev Shares are minted to the adapter instead of the caller.
    function test_retainedOutputIsRejected() public {
        adapter.setMode(MockLeakyAdapter.Misbehavior.RETAIN_OUTPUT);

        Operation[] memory ops = _ops(OperationKind.DEPOSIT, address(underlying), 100e6);
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.ResidualBalance.selector);
        executor.execute(ops);

        assertEq(IERC20(address(vault)).balanceOf(account), 0, "caller credited nothing");
    }

    /// @dev A donated share balance must never be redeemed on some other account's behalf.
    function test_sweptDonationIsRejected() public {
        _deposit(100e6);

        // Someone donates shares to the shared adapter.
        vm.prank(account);
        IERC20(address(vault)).transfer(address(adapter), 10e6);

        adapter.setMode(MockLeakyAdapter.Misbehavior.SWEEP_DONATION);
        Operation[] memory ops = _ops(OperationKind.REDEEM, address(vault), 10e6);
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.ResidualBalance.selector);
        executor.execute(ops);

        assertEq(
            IERC20(address(vault)).balanceOf(address(adapter)), 10e6, "donation still untouched"
        );
    }

    function _deposit(uint256 amount) private {
        Operation[] memory ops = _ops(OperationKind.DEPOSIT, address(underlying), amount);
        vm.prank(account);
        executor.execute(ops);
    }

    function _redeem(uint256 shares) private {
        Operation[] memory ops = _ops(OperationKind.REDEEM, address(vault), shares);
        vm.prank(account);
        executor.execute(ops);
    }

    function _ops(OperationKind kind, address sourceToken, uint256 amount)
        private
        view
        returns (Operation[] memory ops)
    {
        ops = new Operation[](1);
        ops[0] = Operation({
            vault: address(vault),
            kind: kind,
            sourceToken: sourceToken,
            amount: amount,
            amountMode: AmountMode.EXACT,
            minAmountOut: 1
        });
    }
}
