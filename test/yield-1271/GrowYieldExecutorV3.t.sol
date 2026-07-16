// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowYieldExecutorV3} from "../../src/yield-1271/GrowYieldExecutorV3.sol";
import {AaveV3Adapter} from "../../src/yield-1271/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../../src/yield-1271/adapters/MorphoVaultV2Adapter.sol";
import {IYieldAdapter, Operation, OperationKind} from "../../src/yield-1271/IGrowYield1271.sol";
import {MockAavePool, MockUnderlying} from "../invariant/MockYieldVenues.sol";
import {MockFeeToken, MockMutableAaveDataProvider} from "./mocks/MockVaultV2Stack.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";

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

    function test_deposit_maxSentinel_sweepsFullBalance() public {
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

    function test_redeem_maxSentinel_exitsFullPosition() public {
        _seedAave(1_000e6);
        _approveMax(address(aavePool.aToken()));

        _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max)));

        assertEq(underlying.balanceOf(account), 1_000e6);
        assertEq(aavePool.aToken().balanceOf(account), 0);
        _assertNoResiduals();
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

        vm.expectRevert(GrowYieldExecutorV3.AdapterNotAllowed.selector);
        _execute(_ops1(_op(rogue, OperationKind.DEPOSIT, 1e6)));
    }

    function test_directionalGating_depositClosedExitOpen() public {
        _seedAave(100e6);
        registry.setAdapter(address(aaveAdapter), false, true);

        underlying.mint(account, 1e6);
        _approveMax(address(underlying));
        vm.expectRevert(GrowYieldExecutorV3.AdapterNotAllowed.selector);
        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 1e6)));

        _approveMax(address(aavePool.aToken()));
        _execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max)));
        assertEq(aavePool.aToken().balanceOf(account), 0);
    }

    function test_execute_revertsEmptyBatch() public {
        Operation[] memory ops = new Operation[](0);
        vm.prank(account);
        vm.expectRevert(GrowYieldExecutorV3.EmptyBatch.selector);
        executor.execute(ops);
    }

    function test_execute_revertsZeroAmount() public {
        _approveMax(address(underlying));
        vm.expectRevert(GrowYieldExecutorV3.NoBalance.selector);
        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max)));
    }

    // --- quantitative invariants ---

    function test_lossCap_revertsOnLossyVenue() public {
        morphoWrapper.setHaircutBps(200); // 2% > 0.5% cap

        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        vm.expectRevert(GrowYieldExecutorV3.InsufficientOutput.selector);
        _execute(_ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 1_000e6)));
    }

    function test_lossCap_toleratesLossWithinCap() public {
        morphoWrapper.setHaircutBps(30); // 0.3% < 0.5% cap

        underlying.mint(account, 1_000e6);
        _approveMax(address(underlying));

        uint256[] memory out = _execute(_ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 1_000e6)));
        assertEq(out[0], 997e6);
    }

    function test_feeOnTransferSource_revertsUnsupportedToken() public {
        MockFeeToken feeToken = new MockFeeToken();
        MockAavePool feePool = new MockAavePool(MockUnderlying(address(feeToken)));
        MockMutableAaveDataProvider feeProvider =
            new MockMutableAaveDataProvider(address(feeToken), address(feePool.aToken()));
        AaveV3Adapter feeAdapter = new AaveV3Adapter(
            IAaveV3Pool(address(feePool)),
            IAaveProtocolDataProvider(address(feeProvider)),
            address(feeToken),
            address(executor)
        );
        registry.setAdapter(address(feeAdapter), true, true);

        feeToken.mint(account, 1_000e6);
        vm.prank(account);
        feeToken.approve(address(executor), type(uint256).max);

        vm.expectRevert(GrowYieldExecutorV3.UnsupportedToken.selector);
        _execute(_ops1(_op(feeAdapter, OperationKind.DEPOSIT, 100e6)));
    }

    // --- drift protection ---

    function test_morphoDrift_ineligibleChild_blocksDepositAllowsExit() public {
        underlying.mint(account, 200e6);
        _approveMax(address(underlying));
        _execute(_ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 100e6)));

        morphoEligibility.set(address(morphoChild), false);

        vm.expectRevert(MorphoVaultV2Adapter.VenueDrift.selector);
        _execute(_ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 100e6)));

        _approveMax(address(morphoWrapper));
        _execute(_ops1(_op(morphoAdapter, OperationKind.REDEEM, type(uint256).max)));
        assertEq(morphoWrapper.balanceOf(account), 0);
    }

    function test_morphoDrift_liquidityAdapterChanged_blocksDeposit() public {
        morphoWrapper.setLiquidityAdapter(makeAddr("newAdapter"));

        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        vm.expectRevert(MorphoVaultV2Adapter.VenueDrift.selector);
        _execute(_ops1(_op(morphoAdapter, OperationKind.DEPOSIT, 100e6)));
    }

    function test_aaveDrift_reserveRepointed_blocksDepositAllowsExit() public {
        _seedAave(100e6);

        aaveDataProvider.setAToken(makeAddr("newAToken"));

        underlying.mint(account, 100e6);
        _approveMax(address(underlying));
        vm.expectRevert(AaveV3Adapter.ReserveDrift.selector);
        _execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, 100e6)));

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
        vm.prank(stranger);
        vm.expectRevert();
        executor.execute(_ops1(_op(aaveAdapter, OperationKind.REDEEM, 100e6)));

        assertEq(aavePool.aToken().balanceOf(account), 100e6);
    }

    function test_receiverIsAlwaysCaller_noRecipientInAbi() public {
        // The Operation struct is (adapter, kind, amount): no recipient field exists,
        // and the executor hard-pins receiver to msg.sender.
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
