// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {AmountMode, Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";

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
    GrowYieldExecutor internal executor;
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

        // The executor deploys its registry; both are immutable and name each other.
        executor = new GrowYieldExecutor(
            50,
            address(this),
            address(this),
            IGrowYieldAdapterRegistry.Registrars({
                aavePool: provider.getPool(),
                aaveDataProvider: provider.getPoolDataProvider(),
                morphoVaultFactory: address(0),
                morphoAdapterFactory: address(0),
                morphoEligibility: address(0),
                eulerEVaultFactory: address(0),
                eulerEarnFactory: address(0),
                capyFiComptroller: address(0)
            })
        );
        registry = GrowYieldAdapterRegistry(address(executor.registry()));

        adapter = new AaveV3Adapter(
            IAaveV3Pool(provider.getPool()),
            IAaveProtocolDataProvider(provider.getPoolDataProvider()),
            address(executor)
        );
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(adapter), USDC, Protocol.AAVE, true, true
        );
        registry.addVaults(vaults);
    }

    function test_fork_depositAndRedeem_realAaveUsdc() public {
        uint256 amount = 10_000e6;
        deal(USDC, account, amount);

        IERC20 aToken = IERC20(adapter.positionToken(USDC));

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);

        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            vault: USDC,
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
            vault: USDC,
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

    /// @dev Regression: aToken transfers and burns operate in scaled units while the
    ///      executor (`UnsupportedToken`) and adapter (`ResidualBalance`) enforce exact
    ///      1-wei deltas. Odd amounts at a live, accruing liquidity index must not
    ///      spuriously revert.
    function test_fork_aTokenRounding_oddWeiRedeemExactness() public {
        deal(USDC, account, 10_000e6);
        IERC20 aToken = IERC20(adapter.positionToken(USDC));

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);

        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            vault: USDC,
            kind: OperationKind.DEPOSIT,
            sourceToken: USDC,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
        executor.execute(ops);

        aToken.approve(address(executor), type(uint256).max);

        uint256[7] memory redeems = [uint256(1), 3, 7, 101, 999_983, 1_000_003, 123_456_789];
        for (uint256 i; i < redeems.length; ++i) {
            // Accrue interest between redeems so the index lands on awkward values.
            vm.warp(block.timestamp + 13 hours + i * 7 hours);

            ops[0] = Operation({
                vault: USDC,
                kind: OperationKind.REDEEM,
                sourceToken: address(aToken),
                amount: redeems[i],
                amountMode: AmountMode.EXACT,
                minAmountOut: 1
            });
            uint256[] memory out = executor.execute(ops);
            assertGe(out[0], (redeems[i] * 9950) / 10_000);
            assertEq(aToken.balanceOf(address(adapter)), 0);
        }
        vm.stopPrank();
    }

    function test_fork_registryRemainsFixed() public view {
        assertTrue(registry.canDeposit(USDC));
        assertEq(registry.adapterCodeHash(address(adapter)), address(adapter).codehash);
    }
}
