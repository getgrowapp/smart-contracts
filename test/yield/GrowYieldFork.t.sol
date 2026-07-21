// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYieldAdapterRegistry} from "../../src/yield-module/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutorV3} from "../../src/yield-module/GrowYieldExecutorV3.sol";
import {AaveV3Adapter} from "../../src/yield-module/adapters/AaveV3Adapter.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {
    AmountMode,
    Operation,
    OperationKind
} from "../../src/yield-module/interfaces/IGrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry
} from "../../src/yield-module/interfaces/IGrowYieldAdapterRegistry.sol";

/// @dev Aave V3 address book root; resolves current pool + data provider on fork.
interface IPoolAddressesProvider {
    function getPool() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}

/// @notice Base mainnet fork: fresh adapter stack against the real Aave V3 USDC reserve.
/// @dev Requires `BASE_RPC_URL`. Skips if unset.
contract GrowYieldForkTest is Test {
    /// @dev Aave V3 PoolAddressesProvider on Base.
    address internal constant AAVE_ADDRESSES_PROVIDER = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    GrowYieldAdapterRegistry internal registry;
    GrowYieldExecutorV3 internal executor;
    AaveV3Adapter internal adapter;

    address internal account;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);

        account = makeAddr("account");

        IPoolAddressesProvider provider = IPoolAddressesProvider(AAVE_ADDRESSES_PROVIDER);

        executor = new GrowYieldExecutorV3(50, address(this));
        adapter = new AaveV3Adapter(
            IAaveV3Pool(provider.getPool()),
            IAaveProtocolDataProvider(provider.getPoolDataProvider()),
            USDC,
            address(executor)
        );
        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](1);
        configs[0] = IGrowYieldAdapterRegistry.AdapterConfig(address(adapter), true, true);
        registry = new GrowYieldAdapterRegistry(address(executor), configs);
        executor.initializeRegistry(registry);
        vm.prank(account);
        executor.setAdapterPolicy(address(adapter), 1_000_000_000e6, 1_000_000_000e6, 1 days);
    }

    function test_fork_depositAndRedeem_realAaveUsdc() public {
        uint256 amount = 10_000e6;
        deal(USDC, account, amount);

        IERC20 aToken = IERC20(adapter.positionToken());

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);

        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            adapter: adapter,
            kind: OperationKind.DEPOSIT,
            sourceToken: USDC,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: (amount * 9950) / 10_000
        });
        uint256[] memory out = executor.execute(ops);

        assertGe(out[0], (amount * 9950) / 10_000);
        assertGe(aToken.balanceOf(account), out[0]);
        assertEq(IERC20(USDC).balanceOf(account), 0);

        IERC20(USDC).approve(address(executor), 0);
        aToken.approve(address(executor), type(uint256).max);

        ops[0] = Operation({
            adapter: adapter,
            kind: OperationKind.REDEEM,
            sourceToken: address(aToken),
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: (amount * 9950) / 10_000
        });
        out = executor.execute(ops);
        vm.stopPrank();

        assertGe(out[0], (amount * 9950) / 10_000);
        assertGe(IERC20(USDC).balanceOf(account), (amount * 9950) / 10_000);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(aToken.balanceOf(address(adapter)), 0);
    }

    function test_fork_registryRemainsFixed() public view {
        assertTrue(registry.canDeposit(address(adapter)));
        assertEq(registry.adapterCodeHash(address(adapter)), address(adapter).codehash);
    }
}
