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

import {GrowYieldAdapterRegistry} from "../../src/yield-module/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutorV3} from "../../src/yield-module/GrowYieldExecutorV3.sol";
import {AaveV3Adapter} from "../../src/yield-module/adapters/AaveV3Adapter.sol";
import {CapyFiAdapter} from "../../src/yield-module/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../../src/yield-module/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../../src/yield-module/adapters/EulerEVaultAdapter.sol";
import {MorphoVaultV2Adapter} from "../../src/yield-module/adapters/MorphoVaultV2Adapter.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {ICapyFiCaToken} from "../../src/interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "../../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../../src/interfaces/IEulerEVaultFactory.sol";
import {IMorphoVaultEligibility} from "../../src/interfaces/IMorphoVaultEligibility.sol";
import {
    AmountMode,
    Operation,
    OperationKind
} from "../../src/yield-module/interfaces/IGrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry
} from "../../src/yield-module/interfaces/IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "../../src/yield-module/interfaces/IYieldAdapter.sol";

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
    // Position-token decimals differ (for example Morpho V2 uses 18 and caUSDC uses 8),
    // so the test policy must bound raw units above every fixture's full-balance amount.
    uint256 internal constant VOLUME_LIMIT = 1e36;

    GrowYieldExecutorV3 internal executor;
    AaveV3Adapter internal aave;
    MorphoVaultV2Adapter internal morpho;
    EulerEVaultAdapter internal evault;
    EulerEarnAdapter internal earn;
    CapyFiAdapter internal capy;
    address internal account;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        account = makeAddr("allAdaptersAccount");
        executor = new GrowYieldExecutorV3(50, address(this));

        IPoolAddressesProviderAllAdaptersFork aaveProvider =
            IPoolAddressesProviderAllAdaptersFork(AAVE_ADDRESSES_PROVIDER);
        aave = new AaveV3Adapter(
            IAaveV3Pool(aaveProvider.getPool()),
            IAaveProtocolDataProvider(aaveProvider.getPoolDataProvider()),
            USDC,
            address(executor)
        );

        IVaultV2 wrapper = IVaultV2(MORPHO_USDC_WRAPPER);
        address liquidityAdapter = wrapper.liquidityAdapter();
        address child = IMorphoVaultV1Adapter(liquidityAdapter).morphoVaultV1();
        ForkMorphoEligibility eligibility = new ForkMorphoEligibility(child);
        morpho = new MorphoVaultV2Adapter(
            wrapper,
            IVaultV2Factory(MORPHO_VAULT_V2_FACTORY),
            IMorphoVaultV1AdapterFactory(MORPHO_V1_ADAPTER_FACTORY),
            eligibility,
            address(executor)
        );

        evault = new EulerEVaultAdapter(
            IEulerEVaultFactory(EULER_EVAULT_FACTORY),
            IERC4626(EULER_EVAULT_USDC),
            USDC,
            address(executor)
        );
        earn = new EulerEarnAdapter(
            IEulerEarnFactory(EULER_EARN_FACTORY),
            IERC4626(EULER_EARN_USDC),
            USDC,
            address(executor)
        );
        capy = new CapyFiAdapter(
            address(executor), ICapyFiComptroller(CAPY_COMPTROLLER), ICapyFiCaToken(CAPY_USDC), USDC
        );

        IYieldAdapter[5] memory adapters = [
            IYieldAdapter(address(aave)),
            IYieldAdapter(address(morpho)),
            IYieldAdapter(address(evault)),
            IYieldAdapter(address(earn)),
            IYieldAdapter(address(capy))
        ];
        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](adapters.length);
        for (uint256 i; i < adapters.length; ++i) {
            configs[i] = IGrowYieldAdapterRegistry.AdapterConfig({
                adapter: address(adapters[i]), canDeposit: true, canRedeem: true
            });
        }
        GrowYieldAdapterRegistry registry = new GrowYieldAdapterRegistry(address(executor), configs);
        executor.initializeRegistry(registry);

        vm.startPrank(account);
        for (uint256 i; i < adapters.length; ++i) {
            executor.setAdapterPolicy(
                address(adapters[i]), VOLUME_LIMIT, VOLUME_LIMIT, uint48(1 days)
            );
            IERC20(adapters[i].positionToken()).approve(address(executor), type(uint256).max);
        }
        IERC20(USDC).approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    function test_fork_liveProtocolBindings_matchEveryAdapter() public view {
        IPoolAddressesProviderAllAdaptersFork provider =
            IPoolAddressesProviderAllAdaptersFork(AAVE_ADDRESSES_PROVIDER);
        assertEq(address(aave.pool()), provider.getPool());
        assertEq(address(aave.dataProvider()), provider.getPoolDataProvider());
        assertEq(aave.positionToken(), AAVE_USDC);

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
        assertEq(IERC4626(morpho.child()).asset(), USDC);

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
        first[0] = _deposit(aave, AmountMode.EXACT, REBALANCE_AMOUNT);
        vm.prank(account);
        executor.execute(first);
        assertEq(IERC20(USDC).balanceOf(account), IDLE_AMOUNT);

        _rebalance(aave, morpho);
        _rebalance(morpho, evault);
        _rebalance(evault, earn);
        _rebalance(earn, capy);
        _rebalance(capy, aave);

        Operation[] memory exit = new Operation[](1);
        exit[0] = _redeem(aave);
        vm.prank(account);
        executor.execute(exit);

        assertEq(IERC20(aave.positionToken()).balanceOf(account), 0);
        assertEq(IERC20(morpho.positionToken()).balanceOf(account), 0);
        assertEq(IERC20(evault.positionToken()).balanceOf(account), 0);
        assertEq(IERC20(earn.positionToken()).balanceOf(account), 0);
        assertEq(IERC20(capy.positionToken()).balanceOf(account), 0);
        assertGe(IERC20(USDC).balanceOf(account), IDLE_AMOUNT + (REBALANCE_AMOUNT * 97) / 100);
        _assertNoAdapterResiduals();
    }

    function _rebalance(IYieldAdapter from, IYieldAdapter to) internal {
        Operation[] memory ops = new Operation[](2);
        ops[0] = _redeem(from);
        ops[1] = _deposit(to, AmountMode.PREVIOUS_OUTPUT, 0);

        vm.prank(account);
        executor.execute(ops);

        assertEq(IERC20(from.positionToken()).balanceOf(account), 0);
        assertGt(IERC20(to.positionToken()).balanceOf(account), 0);
        assertEq(IERC20(USDC).balanceOf(account), IDLE_AMOUNT);
    }

    function _deposit(IYieldAdapter adapter, AmountMode mode, uint256 amount)
        internal
        pure
        returns (Operation memory)
    {
        return Operation({
            adapter: adapter,
            kind: OperationKind.DEPOSIT,
            sourceToken: USDC,
            amount: amount,
            amountMode: mode,
            minAmountOut: 1
        });
    }

    function _redeem(IYieldAdapter adapter) internal view returns (Operation memory) {
        return Operation({
            adapter: adapter,
            kind: OperationKind.REDEEM,
            sourceToken: adapter.positionToken(),
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
    }

    function _assertNoAdapterResiduals() internal view {
        IYieldAdapter[5] memory adapters = [
            IYieldAdapter(address(aave)),
            IYieldAdapter(address(morpho)),
            IYieldAdapter(address(evault)),
            IYieldAdapter(address(earn)),
            IYieldAdapter(address(capy))
        ];
        for (uint256 i; i < adapters.length; ++i) {
            address adapter = address(adapters[i]);
            assertEq(IERC20(USDC).balanceOf(adapter), 0);
            assertEq(IERC20(adapters[i].positionToken()).balanceOf(adapter), 0);
        }
    }
}
