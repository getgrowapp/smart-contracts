// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoVaultV1Adapter} from "vault-v2/adapters/interfaces/IMorphoVaultV1Adapter.sol";
import {
    IMorphoVaultV1AdapterFactory
} from "vault-v2/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";

import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {CapyFiAdapter} from "../../src/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../../src/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../../src/adapters/EulerEVaultAdapter.sol";
import {MorphoVaultV2Adapter} from "../../src/adapters/MorphoVaultV2Adapter.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {ICapyFiCaToken} from "../../src/interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "../../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../../src/interfaces/IEulerEVaultFactory.sol";
import {IMorphoVaultEligibility} from "../../src/interfaces/IMorphoVaultEligibility.sol";
import {AmountMode, Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";

interface IPoolAddressesProviderAllAdaptersFork {
    function getPool() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}

/// @dev Test-local policy oracle. Protocol provenance remains enforced by the live
///      Morpho factories; this contract admits exactly the live child used by the fixture.
contract ForkMorphoEligibility is IMorphoVaultEligibility {
    address internal immutable allowed;

    constructor(address allowed_) {
        allowed = allowed_;
    }

    function isEligibleVault(address vault) external view returns (bool) {
        return vault == allowed;
    }
}

/// @notice Base fork cycle through every production adapter implementation.
/// @dev Requires `BASE_RPC_URL`. Every rebalance is an atomic REDEEM followed by a
///      PREVIOUS_OUTPUT DEPOSIT, so unrelated idle USDC is never swept.
contract GrowYieldAllAdaptersForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant AAVE_ADDRESSES_PROVIDER = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address internal constant AAVE_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    address internal constant MORPHO_VAULT_V2_FACTORY = 0x4501125508079A99ebBebCE205DeC9593C2b5857;
    address internal constant MORPHO_V1_ADAPTER_FACTORY =
        0xF42D9c36b34c9c2CF3Bc30eD2a52a90eEB604642;
    address internal constant MORPHO_USDC_WRAPPER = 0xAB03BABdb85C80a77808dD6b2B3ce280cc225014;

    address internal constant EULER_EVAULT_FACTORY = 0x7F321498A801A191a93C840750ed637149dDf8D0;
    address internal constant EULER_EVAULT_USDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
    address internal constant EULER_EARN_FACTORY = 0x75F49a2621b6DeC6a5baB22ce961bF3e676EFAE6;
    address internal constant EULER_EARN_USDC = 0x347005f3C98c3cDEf1B6c6a876608C8a19F88083;

    address internal constant CAPY_COMPTROLLER = 0x00dc4965916e03A734190fA382633657c71f867E;
    address internal constant CAPY_USDC = 0x5aDb71adb317CE975A405e90335068F0aF9F26C7;

    // Keep the cycle below the live Euler Earn strategy's remaining supply capacity.
    uint256 internal constant REBALANCE_AMOUNT = 1e6;
    uint256 internal constant IDLE_AMOUNT = 17e6;
    GrowYieldExecutor internal executor;
    AaveV3Adapter internal aave;
    MorphoVaultV2Adapter internal morpho;
    EulerEVaultAdapter internal evault;
    EulerEarnAdapter internal earn;
    CapyFiAdapter internal capy;
    GrowYieldAdapterRegistry internal registry;
    address internal account;

    address[5] internal adapters;
    address[5] internal vaults;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        account = makeAddr("allAdaptersAccount");

        IPoolAddressesProviderAllAdaptersFork aaveProvider =
            IPoolAddressesProviderAllAdaptersFork(AAVE_ADDRESSES_PROVIDER);

        IVaultV2 wrapper0 = IVaultV2(MORPHO_USDC_WRAPPER);
        address child0 = IMorphoVaultV1Adapter(wrapper0.liquidityAdapter()).morphoVaultV1();
        ForkMorphoEligibility eligibility = new ForkMorphoEligibility(child0);

        // The executor deploys its registry; both are immutable and name each other.
        executor = new GrowYieldExecutor(
            50, address(this), address(this), _registrars(aaveProvider, address(eligibility))
        );
        registry = GrowYieldAdapterRegistry(address(executor.registry()));

        aave = new AaveV3Adapter(
            IAaveV3Pool(aaveProvider.getPool()),
            IAaveProtocolDataProvider(aaveProvider.getPoolDataProvider()),
            address(executor)
        );

        morpho = new MorphoVaultV2Adapter(eligibility, address(executor));
        evault =
            new EulerEVaultAdapter(IEulerEVaultFactory(EULER_EVAULT_FACTORY), address(executor));
        earn = new EulerEarnAdapter(IEulerEarnFactory(EULER_EARN_FACTORY), address(executor));
        capy = new CapyFiAdapter(address(executor), ICapyFiComptroller(CAPY_COMPTROLLER));

        adapters = [address(aave), address(morpho), address(evault), address(earn), address(capy)];
        // Aave's venue is its reserve asset; every other protocol's venue is its share token.
        vaults = [USDC, MORPHO_USDC_WRAPPER, EULER_EVAULT_USDC, EULER_EARN_USDC, CAPY_USDC];
        Protocol[5] memory protocols = [
            Protocol.AAVE, Protocol.MORPHO, Protocol.EULER_EVK, Protocol.EULER_EARN, Protocol.CAPYFI
        ];

        IGrowYieldAdapterRegistry.VaultConfig[] memory configs =
            new IGrowYieldAdapterRegistry.VaultConfig[](5);
        for (uint256 i; i < 5; ++i) {
            configs[i] = IGrowYieldAdapterRegistry.VaultConfig({
                adapter: adapters[i],
                vault: vaults[i],
                protocol: protocols[i],
                canDeposit: true,
                canRedeem: true
            });
        }
        registry.addVaults(configs);

        // Admission is the whole enablement: the account only approves its tokens.
        vm.startPrank(account);
        for (uint256 i; i < 5; ++i) {
            IERC20(registry.venue(vaults[i]).positionToken)
                .approve(address(executor), type(uint256).max);
        }
        IERC20(USDC).approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Exercises every protocol's registrar dispatch against live Base deployments.
    function _registrars(IPoolAddressesProviderAllAdaptersFork aaveProvider, address eligibility)
        internal
        view
        returns (IGrowYieldAdapterRegistry.Registrars memory)
    {
        return IGrowYieldAdapterRegistry.Registrars({
            aavePool: aaveProvider.getPool(),
            aaveDataProvider: aaveProvider.getPoolDataProvider(),
            morphoVaultFactory: MORPHO_VAULT_V2_FACTORY,
            morphoAdapterFactory: MORPHO_V1_ADAPTER_FACTORY,
            morphoEligibility: eligibility,
            eulerEVaultFactory: EULER_EVAULT_FACTORY,
            eulerEarnFactory: EULER_EARN_FACTORY,
            capyFiComptroller: CAPY_COMPTROLLER
        });
    }

    function test_fork_liveProtocolBindings_matchEveryAdapter() public view {
        IPoolAddressesProviderAllAdaptersFork provider =
            IPoolAddressesProviderAllAdaptersFork(AAVE_ADDRESSES_PROVIDER);
        assertEq(address(aave.pool()), provider.getPool());
        assertEq(address(aave.dataProvider()), provider.getPoolDataProvider());
        assertEq(aave.positionToken(USDC), AAVE_USDC);
        assertEq(aave.asset(USDC), USDC);

        IVaultV2 wrapper = IVaultV2(MORPHO_USDC_WRAPPER);
        address liquidityAdapter = wrapper.liquidityAdapter();
        assertTrue(IVaultV2Factory(MORPHO_VAULT_V2_FACTORY).isVaultV2(address(wrapper)));
        assertEq(wrapper.adaptersLength(), 1);
        assertEq(wrapper.adapters(0), liquidityAdapter);
        assertTrue(
            IMorphoVaultV1AdapterFactory(MORPHO_V1_ADAPTER_FACTORY)
                .isMorphoVaultV1Adapter(liquidityAdapter)
        );
        assertEq(IMorphoVaultV1Adapter(liquidityAdapter).parentVault(), address(wrapper));
        assertEq(IERC4626(IMorphoVaultV1Adapter(liquidityAdapter).morphoVaultV1()).asset(), USDC);

        assertTrue(IEulerEVaultFactory(EULER_EVAULT_FACTORY).isProxy(EULER_EVAULT_USDC));
        assertTrue(IEulerEarnFactory(EULER_EARN_FACTORY).isVault(EULER_EARN_USDC));
        assertEq(IERC4626(EULER_EVAULT_USDC).asset(), USDC);
        assertEq(IERC4626(EULER_EARN_USDC).asset(), USDC);

        assertEq(ICapyFiCaToken(CAPY_USDC).comptroller(), CAPY_COMPTROLLER);
        assertEq(ICapyFiCaToken(CAPY_USDC).underlying(), USDC);
        (bool listed,,) = ICapyFiComptroller(CAPY_COMPTROLLER).markets(CAPY_USDC);
        assertTrue(listed);
    }

    function test_fork_rebalanceCycle_throughEveryLiveAdapter() public {
        deal(USDC, account, REBALANCE_AMOUNT + IDLE_AMOUNT);

        Operation[] memory first = new Operation[](1);
        first[0] = _deposit(USDC, AmountMode.EXACT, REBALANCE_AMOUNT);
        vm.prank(account);
        executor.execute(first);
        assertEq(IERC20(USDC).balanceOf(account), IDLE_AMOUNT);

        _rebalance(USDC, MORPHO_USDC_WRAPPER);
        _rebalance(MORPHO_USDC_WRAPPER, EULER_EVAULT_USDC);
        _rebalance(EULER_EVAULT_USDC, EULER_EARN_USDC);
        _rebalance(EULER_EARN_USDC, CAPY_USDC);
        _rebalance(CAPY_USDC, USDC);

        Operation[] memory exit = new Operation[](1);
        exit[0] = _redeem(USDC);
        vm.prank(account);
        executor.execute(exit);

        for (uint256 i; i < 5; ++i) {
            assertEq(IERC20(_position(vaults[i])).balanceOf(account), 0);
        }
        assertGe(IERC20(USDC).balanceOf(account), IDLE_AMOUNT + (REBALANCE_AMOUNT * 97) / 100);
        _assertNoAdapterResiduals();
    }

    function _position(address vault) internal view returns (address) {
        return registry.venue(vault).positionToken;
    }

    function _rebalance(address from, address to) internal {
        Operation[] memory ops = new Operation[](2);
        ops[0] = _redeem(from);
        ops[1] = _deposit(to, AmountMode.PREVIOUS_OUTPUT, 0);

        vm.prank(account);
        executor.execute(ops);

        assertEq(IERC20(_position(from)).balanceOf(account), 0);
        assertGt(IERC20(_position(to)).balanceOf(account), 0);
        assertEq(IERC20(USDC).balanceOf(account), IDLE_AMOUNT);
    }

    function _deposit(address vault, AmountMode mode, uint256 amount)
        internal
        pure
        returns (Operation memory)
    {
        return Operation({
            vault: vault,
            kind: OperationKind.DEPOSIT,
            sourceToken: USDC,
            amount: amount,
            amountMode: mode,
            minAmountOut: 1
        });
    }

    function _redeem(address vault) internal view returns (Operation memory) {
        return Operation({
            vault: vault,
            kind: OperationKind.REDEEM,
            sourceToken: _position(vault),
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
    }

    function _assertNoAdapterResiduals() internal view {
        for (uint256 i; i < 5; ++i) {
            assertEq(IERC20(USDC).balanceOf(adapters[i]), 0);
            assertEq(IERC20(_position(vaults[i])).balanceOf(adapters[i]), 0);
        }
    }
}
