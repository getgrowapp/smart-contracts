// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GetEquityMarketAdapter} from "../../src/adapters/GetEquityMarketAdapter.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {AmountMode, Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {IGetEquityMarket} from "../../src/interfaces/IGetEquityMarket.sol";
import {
    IGrowYieldAdapterRegistry, Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {MockCngn, MockGetEquityMarket, MockGntb} from "./mocks/MockGetEquityMarket.sol";

/// @notice GetEquity: a full cNGN balance converts, and a fee above the cap reverts.
contract GrowYieldGetEquityTest is Test {
    uint16 internal constant MAX_LOSS_BPS = 50;
    uint16 internal constant MAX_FEE_BPS = 100;
    uint256 internal constant PRICE = 100_000_000; // 100 cNGN per token

    GrowYieldExecutor internal executor;
    GetEquityMarketAdapter internal adapter;
    MockGetEquityMarket internal market;
    MockCngn internal cngn;
    MockGntb internal gntb;

    address internal account = makeAddr("account");

    function setUp() public {
        cngn = new MockCngn();
        gntb = new MockGntb();
        market = new MockGetEquityMarket(
            IERC20(address(cngn)), IERC20(address(gntb)), PRICE, MAX_FEE_BPS
        );
        gntb.mint(address(market), 1_000_000e18);

        executor = new GrowYieldExecutor(
            MAX_LOSS_BPS, makeAddr("riskGuardian"), address(this), _registrars(address(market))
        );
        adapter = new GetEquityMarketAdapter(
            IGetEquityMarket(address(market)), address(cngn), MAX_FEE_BPS, address(executor)
        );

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig({
            adapter: address(adapter),
            vault: address(gntb),
            protocol: Protocol.GETEQUITY,
            canDeposit: true,
            canRedeem: true
        });
        executor.addVaults(vaults);

        vm.startPrank(account);
        cngn.approve(address(executor), type(uint256).max);
        gntb.approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    function test_fullBalance_convertsAllSpendableCngnAndLeavesTheAdapterEmpty() public {
        uint256 budget = 1_000_000e6;
        cngn.mint(account, budget);

        vm.prank(account);
        executor.execute(_ops(_deposit()));

        uint256 dust = cngn.balanceOf(account);
        uint256 bought = gntb.balanceOf(account);
        assertGt(bought, 0);
        assertLt(dust, 1e6, "leftover is under 1 cNGN");
        assertEq(cngn.balanceOf(address(adapter)), 0);
        assertEq(gntb.balanceOf(address(adapter)), 0);
        assertEq(cngn.balanceOf(account) + cngn.balanceOf(address(market)), budget);

        vm.prank(account);
        executor.execute(_ops(_redeem()));

        assertEq(gntb.balanceOf(account), 0);
        assertGt(cngn.balanceOf(account), budget - budget / 50, "round trip keeps the fee");
        assertEq(cngn.balanceOf(address(adapter)), 0);
        assertEq(gntb.balanceOf(address(adapter)), 0);
    }

    function test_feeAboveCap_revertsDepositAndRedeem() public {
        cngn.mint(account, 10_000e6);
        vm.prank(account);
        executor.execute(_ops(_deposit()));

        market.setFeeBps(MAX_FEE_BPS + 1);
        cngn.mint(account, 10_000e6);

        vm.prank(account);
        vm.expectRevert(GetEquityMarketAdapter.FeeTooHigh.selector);
        executor.execute(_ops(_deposit()));

        vm.prank(account);
        vm.expectRevert(GetEquityMarketAdapter.FeeTooHigh.selector);
        executor.execute(_ops(_redeem()));
    }

    function _deposit() private view returns (Operation memory) {
        return Operation({
            vault: address(gntb),
            kind: OperationKind.DEPOSIT,
            sourceToken: address(cngn),
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
    }

    function _redeem() private view returns (Operation memory) {
        return Operation({
            vault: address(gntb),
            kind: OperationKind.REDEEM,
            sourceToken: address(gntb),
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
    }

    function _ops(Operation memory op) private pure returns (Operation[] memory ops) {
        ops = new Operation[](1);
        ops[0] = op;
    }

    function _registrars(address market_)
        private
        pure
        returns (IGrowYieldAdapterRegistry.Registrars memory)
    {
        return IGrowYieldAdapterRegistry.Registrars({
            aavePool: address(0),
            aaveDataProvider: address(0),
            morphoVaultFactory: address(0),
            morphoAdapterFactory: address(0),
            morphoEligibility: address(0),
            eulerEVaultFactory: address(0),
            eulerEarnFactory: address(0),
            capyFiComptroller: address(0),
            getEquityMarket: market_
        });
    }
}
