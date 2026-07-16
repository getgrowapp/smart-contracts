// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYieldAdapterRegistry} from "../../src/yield-1271/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutorV3} from "../../src/yield-1271/GrowYieldExecutorV3.sol";
import {GrowYield1271PolicySignerV4} from "../../src/yield-1271/GrowYield1271PolicySignerV4.sol";
import {AaveV3Adapter} from "../../src/yield-1271/adapters/AaveV3Adapter.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {Operation, OperationKind} from "../../src/yield-1271/IGrowYield1271.sol";

/// @dev Aave V3 address book root; resolves current pool + data provider on fork.
interface IPoolAddressesProvider {
    function getPool() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}

/**
 * @notice Base mainnet fork: fresh adapter stack against the real Aave V3 USDC reserve.
 * @dev Requires `BASE_RPC_URL`. Skips if unset.
 */
contract GrowYield1271ForkTest is Test {
    /// @dev Aave V3 PoolAddressesProvider on Base.
    address internal constant AAVE_ADDRESSES_PROVIDER = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    GrowYieldAdapterRegistry internal registry;
    GrowYieldExecutorV3 internal executor;
    GrowYield1271PolicySignerV4 internal signer;
    AaveV3Adapter internal adapter;

    address internal account;
    address internal module;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);

        account = makeAddr("account");
        module = makeAddr("module");

        IPoolAddressesProvider provider = IPoolAddressesProvider(AAVE_ADDRESSES_PROVIDER);

        registry = new GrowYieldAdapterRegistry(address(this));
        executor = new GrowYieldExecutorV3(registry, 50);
        signer = new GrowYield1271PolicySignerV4(address(executor), module);
        adapter = new AaveV3Adapter(
            IAaveV3Pool(provider.getPool()),
            IAaveProtocolDataProvider(provider.getPoolDataProvider()),
            USDC,
            address(executor)
        );
        registry.setAdapter(address(adapter), true, true);
    }

    function test_fork_depositAndRedeem_realAaveUsdc() public {
        uint256 amount = 10_000e6;
        deal(USDC, account, amount);

        IERC20 aToken = IERC20(adapter.positionToken());

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);

        Operation[] memory ops = new Operation[](1);
        ops[0] =
            Operation({adapter: adapter, kind: OperationKind.DEPOSIT, amount: type(uint256).max});
        uint256[] memory out = executor.execute(ops);

        assertGe(out[0], (amount * 9950) / 10_000);
        assertGe(aToken.balanceOf(account), out[0]);
        assertEq(IERC20(USDC).balanceOf(account), 0);

        IERC20(USDC).approve(address(executor), 0);
        aToken.approve(address(executor), type(uint256).max);

        ops[0] =
            Operation({adapter: adapter, kind: OperationKind.REDEEM, amount: type(uint256).max});
        out = executor.execute(ops);
        vm.stopPrank();

        assertGe(out[0], (amount * 9950) / 10_000);
        assertGe(IERC20(USDC).balanceOf(account), (amount * 9950) / 10_000);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(aToken.balanceOf(address(adapter)), 0);
    }

    function test_fork_signerModulePin_andNonRevertingInvalid() public {
        // Junk proof: INVALID (not revert) from the module; INVALID from anyone else.
        vm.prank(module);
        assertEq(signer.isValidSignature(bytes32(uint256(1)), hex"01"), bytes4(0xffffffff));

        vm.prank(makeAddr("stranger"));
        assertEq(signer.isValidSignature(bytes32(uint256(1)), hex"01"), bytes4(0xffffffff));
    }
}
