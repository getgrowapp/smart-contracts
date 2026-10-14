// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockUnderlying} from "../invariant/MockYieldVenues.sol";
import {AaveV4SpokeAdapter} from "../../src/adapters/AaveV4SpokeAdapter.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {GrowYieldPlugin} from "../../src/GrowYieldPlugin.sol";
import {IAaveV4Hub} from "../../src/interfaces/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/IAaveV4Spoke.sol";
import {
    IGrowYieldExecutor,
    AmountMode,
    Operation,
    OperationKind
} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {IGrowYieldPolicyModule} from "../../src/interfaces/IGrowYieldPolicyModule.sol";
import {
    IGrowYieldAdapterRegistry, Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";

interface IHubAsset {
    function getAsset(uint256 assetId)
        external
        view
        returns (
            uint120 liquidity,
            uint120 realizedFees,
            uint8 decimals,
            uint120 addedShares,
            uint120 swept,
            int200 premiumOffsetRay,
            uint120 drawnShares,
            uint120 premiumShares,
            uint16 liquidityFee,
            uint120 drawnIndex,
            uint96 drawnRate,
            uint40 lastUpdateTimestamp,
            address underlying,
            address irStrategy,
            address reinvestmentController,
            address feeReceiver,
            uint200 deficitRay
        );
}

/// @notice Base fork: Aave V4 Coinbase Stocks spoke through the yield executor.
/// @dev Requires `BASE_RPC_URL`. Skips if unset. Does not broadcast.
///      AAPLc is a B20 precompile (`eth_getCode` is `0xef`). Foundry cannot execute that, so the
///      supply and redeem test etches an ERC-20 at the same address. The spoke and hub stay live.
contract GrowYieldAaveV4ForkTest is Test {
    address internal constant HUB = 0xa4d5947Eb727A052bae69C593FfC84247EC9864E;
    address internal constant SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;
    address internal constant AAPL = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    uint256 internal constant AAPL_RESERVE_ID = 0;

    GrowYieldExecutor internal executor;
    GrowYieldPlugin internal plugin;
    AaveV4SpokeAdapter internal adapter;
    address internal venue;
    address internal account;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        executor = new GrowYieldExecutor(
            50,
            makeAddr("riskGuardian"),
            address(this),
            IGrowYieldAdapterRegistry.Registrars({
                aavePool: address(0),
                aaveDataProvider: address(0),
                morphoVaultFactory: address(0),
                morphoAdapterFactory: address(0),
                morphoEligibility: address(0),
                eulerEVaultFactory: address(0),
                eulerEarnFactory: address(0),
                capyFiComptroller: address(0),
                aaveV4Hub: HUB
            })
        );
        plugin = new GrowYieldPlugin(500_000, 2_000_000, 150_000, 200_000, 200_000, 2 gwei, 2 gwei);
        account = address(new AaveV4ForkAccount(address(executor), plugin));
        adapter = new AaveV4SpokeAdapter(IAaveV4Hub(HUB), address(executor));
        venue = executor.deployAaveV4ReserveVenue(SPOKE, AAPL_RESERVE_ID);
    }

    function test_fork_rejectsSpokeTheHubDoesNotList() public {
        vm.mockCall(
            HUB, abi.encodeWithSelector(IAaveV4Hub.isSpokeListed.selector), abi.encode(false)
        );

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig({
            adapter: address(adapter),
            vault: venue,
            protocol: Protocol.AAVE_V4,
            canDeposit: true,
            canRedeem: true
        });
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        executor.addVaults(vaults);
    }

    function test_fork_depositRevertsWhenSpokeIsDelisted() public {
        _admit();

        vm.mockCall(
            HUB, abi.encodeWithSelector(IAaveV4Hub.isSpokeListed.selector), abi.encode(false)
        );
        vm.prank(account);
        vm.expectRevert(IGrowYieldExecutor.VenueDrift.selector);
        executor.execute(_depositOps(1));
    }

    function test_fork_depositAndRedeem_aaplCollateral() public {
        _admit();
        _installAccount();

        uint256 amount = 1e8;
        _mintAapl(account, amount);
        uint256 expectedShares = adapter.previewDeposit(venue, amount);
        uint256 minShares = expectedShares * 9950 / 10_000;
        if (minShares == 0) minShares = 1;

        vm.prank(account);
        uint256[] memory deposited = executor.execute(_depositOps(minShares));

        assertGe(deposited[0], minShares);
        assertEq(adapter.suppliedShares(venue, account), deposited[0]);
        assertEq(IERC20(AAPL).balanceOf(account), 0);
        assertEq(IERC20(AAPL).allowance(account, SPOKE), 0);
        assertEq(adapter.suppliedShares(venue, address(adapter)), 0);
        (bool collateral,) = IAaveV4Spoke(SPOKE).getUserReserveStatus(AAPL_RESERVE_ID, account);
        assertTrue(collateral);

        uint256 shares = adapter.suppliedShares(venue, account);
        uint256 expectedAssets = adapter.previewRedeem(venue, shares);
        Operation[] memory redeemOps = new Operation[](1);
        redeemOps[0] = Operation({
            vault: venue,
            kind: OperationKind.REDEEM,
            sourceToken: venue,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: expectedAssets * 9950 / 10_000 == 0 ? 1 : expectedAssets * 9950 / 10_000
        });

        vm.prank(account);
        uint256[] memory redeemed = executor.execute(redeemOps);

        assertGe(redeemed[0], expectedAssets * 9950 / 10_000);
        assertEq(adapter.suppliedShares(venue, account), 0);
        assertEq(IERC20(AAPL).balanceOf(account), redeemed[0]);
        assertEq(IERC20(AAPL).balanceOf(address(adapter)), 0);
        (bool stillCollateral,) = IAaveV4Spoke(SPOKE).getUserReserveStatus(AAPL_RESERVE_ID, account);
        assertFalse(stillCollateral);
    }

    /// @dev `isSpokeListed` is our deposit gate. The hub's remove path keys off the spoke's active
    ///      flag, not that view, so flipping the view must not trap an exit.
    function test_fork_redeemSucceedsAfterSpokeListingViewFlips() public {
        _admit();
        _installAccount();
        _mintAapl(account, 1e8);

        uint256 minShares = adapter.previewDeposit(venue, 1e8) * 9950 / 10_000;
        if (minShares == 0) minShares = 1;
        vm.prank(account);
        executor.execute(_depositOps(minShares));

        vm.mockCall(
            HUB, abi.encodeWithSelector(IAaveV4Hub.isSpokeListed.selector), abi.encode(false)
        );
        uint256 shares = adapter.suppliedShares(venue, account);
        uint256 minAssets = adapter.previewRedeem(venue, shares) * 9950 / 10_000;
        if (minAssets == 0) minAssets = 1;
        Operation[] memory redeemOps = new Operation[](1);
        redeemOps[0] = Operation({
            vault: venue,
            kind: OperationKind.REDEEM,
            sourceToken: venue,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: minAssets
        });

        vm.prank(account);
        uint256[] memory redeemed = executor.execute(redeemOps);

        assertGe(redeemed[0], minAssets);
        assertEq(adapter.suppliedShares(venue, account), 0);
        (bool stillCollateral,) = IAaveV4Spoke(SPOKE).getUserReserveStatus(AAPL_RESERVE_ID, account);
        assertFalse(stillCollateral);
    }

    function test_fork_pluginRejectsPausedDepositAndUnknownSpoke() public {
        _admit();
        _installAccount();

        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.UnauthorizedExecutor.selector);
        plugin.supplyOnSpoke(SPOKE, AAPL_RESERVE_ID, 1);

        vm.prank(makeAddr("riskGuardian"));
        executor.pauseVaultDeposits(venue);
        vm.prank(address(executor));
        vm.expectRevert(IGrowYieldExecutor.DepositsPaused.selector);
        AaveV4ForkAccount(account).supplyOnSpoke(SPOKE, AAPL_RESERVE_ID, 1);

        vm.prank(address(executor));
        vm.expectRevert(GrowYieldPlugin.SpokeNotAdmitted.selector);
        AaveV4ForkAccount(account).supplyOnSpoke(makeAddr("evil"), 0, 1);
    }

    function _admit() internal {
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig({
            adapter: address(adapter),
            vault: venue,
            protocol: Protocol.AAVE_V4,
            canDeposit: true,
            canRedeem: true
        });
        executor.addVaults(vaults);
    }

    /// @dev The plugin refuses an executor with no admitted venues, so this follows `_admit`.
    function _installAccount() internal {
        address[] memory owners = new address[](1);
        owners[0] = address(this);
        vm.prank(account);
        plugin.onInstall(abi.encode(uint32(1), owners, address(executor), address(plugin)));
    }

    /// @dev B20 assets have no bytecode Foundry can run. Etch an ERC-20 at the token address and
    ///      seed the hub with its already-accounted liquidity. `Hub.add` requires
    ///      `balanceOf(hub) >= liquidity + amount`.
    function _mintAapl(address to, uint256 amount) internal {
        (uint120 liquidity,,,,,,,,,,,,,,,,) = IHubAsset(HUB).getAsset(0);
        MockUnderlying impl = new MockUnderlying();
        vm.etch(AAPL, address(impl).code);
        MockUnderlying(AAPL).mint(HUB, uint256(liquidity) + 1_000_000e8);
        MockUnderlying(AAPL).mint(to, amount);
    }

    function _depositOps(uint256 minShares) internal view returns (Operation[] memory ops) {
        ops = new Operation[](1);
        ops[0] = Operation({
            vault: venue,
            kind: OperationKind.DEPOSIT,
            sourceToken: AAPL,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: minShares
        });
    }
}

/// @dev Stand-in for the modular account. On a real account, runtime validation only lets the
///      executor reach the spoke selectors. This contract does that check, then the plugin makes
///      this account call the spoke.
contract AaveV4ForkAccount {
    address public immutable executor;
    GrowYieldPlugin public immutable plugin;

    error OnlyExecutor();
    error OnlyPlugin();

    constructor(address executor_, GrowYieldPlugin plugin_) {
        executor = executor_;
        plugin = plugin_;
    }

    function supplyOnSpoke(address spoke, uint256 reserveId, uint256 amount) external {
        _openSpokeCall();
        plugin.supplyOnSpoke(spoke, reserveId, amount);
    }

    function withdrawOnSpoke(address spoke, uint256 reserveId, uint256 amount) external {
        _openSpokeCall();
        plugin.withdrawOnSpoke(spoke, reserveId, amount);
    }

    function setSpokeCollateral(address spoke, uint256 reserveId, bool usingAsCollateral)
        external
    {
        _openSpokeCall();
        plugin.setSpokeCollateral(spoke, reserveId, usingAsCollateral);
    }

    /// @dev The modular account runs this hook itself before the execution function. The hook
    ///      records the account only when `sender` is the configured executor.
    function _openSpokeCall() private {
        if (msg.sender != executor) revert OnlyExecutor();
        (bool ok, bytes memory ret) = address(plugin).call(
            abi.encodeWithSelector(
                bytes4(keccak256("preExecutionHook(uint8,address,uint256,bytes)")),
                plugin.SPOKE_CALL_FUNCTION_ID(),
                msg.sender,
                uint256(0),
                bytes("")
            )
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function execute(address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory result)
    {
        if (msg.sender != address(plugin)) revert OnlyPlugin();
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function executeFromPluginExternal(address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory result)
    {
        if (msg.sender != address(plugin)) revert OnlyPlugin();
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}
