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
import {AmountMode, Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";

/// @notice Optional Base mainnet fork coverage for Euler EVK, Euler Earn, and CapyFi.
/// @dev Requires `BASE_RPC_URL`. Skips if unset.
contract GrowYieldEulerCapyFiForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant EVAULT_FACTORY = 0x7F321498A801A191a93C840750ed637149dDf8D0;
    address internal constant EARN_FACTORY = 0x75F49a2621b6DeC6a5baB22ce961bF3e676EFAE6;
    /// @dev Factory-registered EVK USDC vault on Base.
    address internal constant EVAULT_USDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
    /// @dev Factory-registered Earn USDC vault on Base.
    address internal constant EARN_USDC = 0x347005f3C98c3cDEf1B6c6a876608C8a19F88083;
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
        _freshExecutor();
    }

    /// @dev Admission is the whole enablement; there is no per-account configuration left.
    function _enable(address adapter, address vault, Protocol protocol) internal {
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(adapter, vault, protocol, true, true);
        executor.addVaults(vaults);
    }

    function _adapterOf(address vault) internal view returns (address) {
        return executor.vaultAdapter(vault);
    }

    /// @dev A new executor also means a new, empty registry: the two are deployed together and
    ///      permanently bound.
    function _freshExecutor() internal {
        executor = new GrowYieldExecutor(50, address(this), address(this), _forkRegistrars());
    }

    function _depositRedeem(address vault, address position) internal {
        uint256 amount = 5_000e6;
        deal(USDC, account, amount);

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);

        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            vault: vault,
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
        assertEq(IERC20(USDC).balanceOf(_adapterOf(vault)), 0);
        assertEq(IERC20(USDC).allowance(_adapterOf(vault), position), 0);

        IERC20(position).approve(address(executor), type(uint256).max);
        ops[0] = Operation({
            vault: vault,
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
        assertEq(IERC20(USDC).balanceOf(_adapterOf(vault)), 0);
        assertEq(IERC20(position).balanceOf(_adapterOf(vault)), 0);
    }

    function test_fork_evault_depositAndRedeem_realUsdc() public {
        _freshExecutor();
        EulerEVaultAdapter adapter =
            new EulerEVaultAdapter(IEulerEVaultFactory(EVAULT_FACTORY), address(executor));
        _enable(address(adapter), EVAULT_USDC, Protocol.EULER_EVK);
        _depositRedeem(EVAULT_USDC, EVAULT_USDC);
    }

    function test_fork_earn_depositAndRedeem_realUsdc() public {
        _freshExecutor();
        EulerEarnAdapter adapter =
            new EulerEarnAdapter(IEulerEarnFactory(EARN_FACTORY), address(executor));
        _enable(address(adapter), EARN_USDC, Protocol.EULER_EARN);

        // Earn vaults can hit strategy supply caps; size the deposit to remaining capacity.
        uint256 maxDeposit = IERC4626(EARN_USDC).maxDeposit(address(adapter));
        if (maxDeposit < 1e6) {
            vm.skip(true);
        }
        uint256 amount = maxDeposit < 1_000e6 ? maxDeposit : 1_000e6;
        deal(USDC, account, amount);

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);
        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            vault: EARN_USDC,
            kind: OperationKind.DEPOSIT,
            sourceToken: USDC,
            amount: amount,
            amountMode: AmountMode.EXACT,
            minAmountOut: 1
        });
        uint256[] memory out = executor.execute(ops);
        assertGt(out[0], 0);

        IERC20(EARN_USDC).approve(address(executor), type(uint256).max);
        ops[0] = Operation({
            vault: EARN_USDC,
            kind: OperationKind.REDEEM,
            sourceToken: EARN_USDC,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
        out = executor.execute(ops);
        vm.stopPrank();

        assertGt(out[0], 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(EARN_USDC).balanceOf(address(adapter)), 0);
    }

    function test_fork_capy_depositAndRedeem_realUsdc() public {
        _freshExecutor();
        CapyFiAdapter adapter =
            new CapyFiAdapter(address(executor), ICapyFiComptroller(CAPY_COMPTROLLER));
        _enable(address(adapter), CAPY_USDC, Protocol.CAPYFI);

        uint256 amount = 5_000e6;
        deal(USDC, account, amount);

        vm.startPrank(account);
        IERC20(USDC).approve(address(executor), type(uint256).max);

        Operation[] memory ops = new Operation[](1);
        ops[0] = Operation({
            vault: CAPY_USDC,
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
            vault: CAPY_USDC,
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

    /// @dev Venue authenticity is now proven at admission against the live factory, not in the
    ///      adapter constructor, so a vault the factory never created cannot be admitted.
    function test_fork_evault_registryRejectsFakeVault() public {
        _freshExecutor();
        EulerEVaultAdapter adapter =
            new EulerEVaultAdapter(IEulerEVaultFactory(EVAULT_FACTORY), address(executor));
        GrowYieldExecutor r = executor;

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(adapter), EARN_USDC, Protocol.EULER_EVK, true, true
        );

        // A real Earn vault is not an EVK proxy: the pinned EVK factory does not recognize it.
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        r.addVaults(vaults);
    }

    /// @dev An adapter wired to a Comptroller the registry does not pin cannot admit a venue,
    ///      even a genuine one.
    function test_fork_capy_registryRejectsWrongComptroller() public {
        _freshExecutor();
        CapyFiAdapter adapter =
            new CapyFiAdapter(address(executor), ICapyFiComptroller(EVAULT_FACTORY));
        GrowYieldExecutor r = executor;

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(adapter), CAPY_USDC, Protocol.CAPYFI, true, true
        );

        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        r.addVaults(vaults);
    }

    /// @dev The live Euler and CapyFi registrars this suite pins.
    function _forkRegistrars() internal pure returns (IGrowYieldAdapterRegistry.Registrars memory) {
        return IGrowYieldAdapterRegistry.Registrars({
            aavePool: address(0),
            aaveDataProvider: address(0),
            morphoVaultFactory: address(0),
            morphoAdapterFactory: address(0),
            morphoEligibility: address(0),
            eulerEVaultFactory: EVAULT_FACTORY,
            eulerEarnFactory: EARN_FACTORY,
            capyFiComptroller: CAPY_COMPTROLLER
        });
    }
}
