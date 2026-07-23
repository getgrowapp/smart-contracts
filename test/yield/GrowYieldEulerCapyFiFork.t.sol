// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {CapyFiAdapter} from "../../src/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../../src/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../../src/adapters/EulerEVaultAdapter.sol";
import {ICapyFiCaToken} from "../../src/interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "../../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../../src/interfaces/IEulerEVaultFactory.sol";
import {IEulerStrategyEligibility} from "../../src/interfaces/IEulerStrategyEligibility.sol";
import {AmountMode, Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {IGrowYieldAdapterRegistry} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";

contract ForkEulerStrategyEligibility is IEulerStrategyEligibility {
    address internal immutable allowed;

    constructor(address allowed_) {
        allowed = allowed_;
    }

    function isEligibleStrategy(address strategy) external view returns (bool) {
        return strategy == allowed;
    }
}

/// @notice Optional Base mainnet fork coverage for Euler EVK, Euler Earn, and CapyFi.
/// @dev Requires `BASE_RPC_URL`. Skips if unset.
contract GrowYieldEulerCapyFiForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant EVAULT_FACTORY = 0x7F321498A801A191a93C840750ed637149dDf8D0;
    address internal constant EARN_FACTORY = 0x75F49a2621b6DeC6a5baB22ce961bF3e676EFAE6;
    /// @dev Factory-registered EVK USDC vault on Base.
    address internal constant EVAULT_USDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
    /// @dev Permanently locked Grow gbyUSD Euler Earn wrapper on Base.
    address internal constant EARN_GBY_USDC = 0x1c66B3A163e1998D9235E24e782d3d54aDEa094E;
    /// @dev Clearstar Earn USDC child strategy pinned by `EARN_GBY_USDC`.
    address internal constant EARN_CHILD_USDC = 0x8bF41Ad2b816F7c220b22F4BCD63fC2A35Ab4247;
    address internal constant CAPY_COMPTROLLER = 0x00dc4965916e03A734190fA382633657c71f867E;
    address internal constant CAPY_USDC = 0x5aDb71adb317CE975A405e90335068F0aF9F26C7;

    GrowYieldExecutor internal executor;
    address internal account;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);
        account = makeAddr("account");
        executor = new GrowYieldExecutor(50, address(this));
    }

    function _enable(address adapter) internal {
        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](1);
        configs[0] = IGrowYieldAdapterRegistry.AdapterConfig(adapter, true, true);
        GrowYieldAdapterRegistry registry = new GrowYieldAdapterRegistry(address(executor), configs);
        // Fresh executor per adapter suite below when registry already set.
        if (address(executor.registry()) == address(0)) {
            executor.initializeRegistry(registry);
        }
        vm.prank(account);
        executor.setAdapterPolicy(adapter, 1_000_000_000e6, 1_000_000_000e6, 1 days);
    }

    function _freshExecutor() internal {
        executor = new GrowYieldExecutor(50, address(this));
    }

    function _depositRedeem(address adapterAddr, address position) internal {
        uint256 amount = 5_000e6;
        deal(USDC, account, amount);

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);

        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            adapter: EulerEVaultAdapter(adapterAddr),
            kind: OperationKind.DEPOSIT,
            sourceToken: USDC,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
        uint256[] memory out = executor.execute(ops);
        assertGt(out[0], 0);
        assertGe(IERC20(position).balanceOf(account), out[0]);
        assertEq(IERC20(USDC).balanceOf(account), 0);
        assertEq(IERC20(USDC).balanceOf(adapterAddr), 0);
        assertEq(IERC20(USDC).allowance(adapterAddr, position), 0);

        IERC20(position).approve(address(executor), type(uint256).max);
        ops[0] = Operation({
            adapter: EulerEVaultAdapter(adapterAddr),
            kind: OperationKind.REDEEM,
            sourceToken: position,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: (amount * 9900) / 10_000
        });
        out = executor.execute(ops);
        vm.stopPrank();

        assertGe(out[0], (amount * 9900) / 10_000);
        assertGe(IERC20(USDC).balanceOf(account), (amount * 9900) / 10_000);
        assertEq(IERC20(USDC).balanceOf(adapterAddr), 0);
        assertEq(IERC20(position).balanceOf(adapterAddr), 0);
    }

    function test_fork_evault_depositAndRedeem_realUsdc() public {
        _freshExecutor();
        EulerEVaultAdapter adapter = new EulerEVaultAdapter(
            IEulerEVaultFactory(EVAULT_FACTORY), IERC4626(EVAULT_USDC), address(executor)
        );
        _enable(address(adapter));
        _depositRedeem(address(adapter), EVAULT_USDC);
    }

    function test_fork_earn_depositAndRedeem_realUsdc() public {
        _freshExecutor();
        ForkEulerStrategyEligibility eligibility =
            new ForkEulerStrategyEligibility(EARN_CHILD_USDC);
        EulerEarnAdapter adapter = new EulerEarnAdapter(
            IEulerEarnFactory(EARN_FACTORY),
            IERC4626(EARN_GBY_USDC),
            IERC4626(EARN_CHILD_USDC),
            IEulerStrategyEligibility(address(eligibility)),
            address(executor)
        );
        _enable(address(adapter));

        // Earn vaults can hit strategy supply caps; size the deposit to remaining capacity.
        uint256 maxDeposit = IERC4626(EARN_GBY_USDC).maxDeposit(address(adapter));
        if (maxDeposit < 1e6) {
            vm.skip(true);
        }
        uint256 amount = maxDeposit < 1_000e6 ? maxDeposit : 1_000e6;
        deal(USDC, account, amount);

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);
        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            adapter: adapter,
            kind: OperationKind.DEPOSIT,
            sourceToken: USDC,
            amount: amount,
            amountMode: AmountMode.EXACT,
            minAmountOut: 1
        });
        uint256[] memory out = executor.execute(ops);
        assertGt(out[0], 0);

        IERC20(EARN_GBY_USDC).approve(address(executor), type(uint256).max);
        ops[0] = Operation({
            adapter: adapter,
            kind: OperationKind.REDEEM,
            sourceToken: EARN_GBY_USDC,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
        out = executor.execute(ops);
        vm.stopPrank();

        assertGt(out[0], 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(EARN_GBY_USDC).balanceOf(address(adapter)), 0);
    }

    function test_fork_capy_depositAndRedeem_realUsdc() public {
        _freshExecutor();
        CapyFiAdapter adapter = new CapyFiAdapter(
            address(executor), ICapyFiComptroller(CAPY_COMPTROLLER), ICapyFiCaToken(CAPY_USDC)
        );
        _enable(address(adapter));

        uint256 amount = 5_000e6;
        deal(USDC, account, amount);

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);

        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            adapter: adapter,
            kind: OperationKind.DEPOSIT,
            sourceToken: USDC,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
        uint256[] memory out = executor.execute(ops);
        assertGt(out[0], 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).allowance(address(adapter), CAPY_USDC), 0);

        IERC20(CAPY_USDC).approve(address(executor), type(uint256).max);
        ops[0] = Operation({
            adapter: adapter,
            kind: OperationKind.REDEEM,
            sourceToken: CAPY_USDC,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: (amount * 9900) / 10_000
        });
        out = executor.execute(ops);
        vm.stopPrank();

        assertGe(out[0], (amount * 9900) / 10_000);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(CAPY_USDC).balanceOf(address(adapter)), 0);
    }

    function test_fork_evault_rejectsFakeVault() public {
        _freshExecutor();
        // Arbitrary EOA-like address with no factory registration.
        address fake = makeAddr("fakeVault");
        vm.expectRevert();
        new EulerEVaultAdapter(
            IEulerEVaultFactory(EVAULT_FACTORY), IERC4626(fake), address(executor)
        );
    }

    function test_fork_capy_rejectsUnlistedOrWrongComptroller() public {
        _freshExecutor();
        address wrongComptroller = EVAULT_FACTORY;
        vm.expectRevert();
        new CapyFiAdapter(
            address(executor), ICapyFiComptroller(wrongComptroller), ICapyFiCaToken(CAPY_USDC)
        );
    }
}
