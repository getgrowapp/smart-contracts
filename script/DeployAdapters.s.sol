// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {IMorphoVaultV1AdapterFactory} from
    "vault-v2/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AaveV3Adapter} from "../src/yield-module/adapters/AaveV3Adapter.sol";
import {CapyFiAdapter} from "../src/yield-module/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../src/yield-module/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../src/yield-module/adapters/EulerEVaultAdapter.sol";
import {MorphoVaultV2Adapter} from "../src/yield-module/adapters/MorphoVaultV2Adapter.sol";
import {GrowYieldAdapterRegistry} from "../src/yield-module/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutorV3} from "../src/yield-module/GrowYieldExecutorV3.sol";
import {IGrowYieldAdapterRegistry} from
    "../src/yield-module/interfaces/IGrowYieldAdapterRegistry.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../src/interfaces/IAaveProtocolDataProvider.sol";
import {ICapyFiCaToken} from "../src/interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../src/interfaces/IEulerEVaultFactory.sol";
import {IMorphoVaultEligibility} from "../src/interfaces/IMorphoVaultEligibility.sol";

/// @notice Deploys executor-pinned venue adapters (Aave, Morpho, Euler, CapyFi).
contract DeployAdapters is Script {
    function deployAave() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        AaveV3Adapter adapter = new AaveV3Adapter(
            IAaveV3Pool(vm.envAddress("AAVE_POOL")),
            IAaveProtocolDataProvider(vm.envAddress("AAVE_DATA_PROVIDER")),
            vm.envAddress("ASSET"),
            vm.envAddress("EXECUTOR")
        );
        vm.stopBroadcast();

        console2.log("AaveV3Adapter", address(adapter));
        console2.log("asset", adapter.asset());
        console2.log("positionToken", adapter.positionToken());
    }

    function deployMorpho() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        MorphoVaultV2Adapter adapter = new MorphoVaultV2Adapter(
            IVaultV2(vm.envAddress("MORPHO_WRAPPER")),
            IVaultV2Factory(vm.envAddress("MORPHO_FACTORY")),
            IMorphoVaultV1AdapterFactory(vm.envAddress("MORPHO_ADAPTER_FACTORY")),
            IMorphoVaultEligibility(vm.envAddress("MORPHO_ELIGIBILITY")),
            vm.envAddress("EXECUTOR")
        );
        vm.stopBroadcast();

        console2.log("MorphoVaultV2Adapter", address(adapter));
        console2.log("asset", adapter.asset());
        console2.log("positionToken", adapter.positionToken());
        console2.log("child", adapter.child());
    }

    function deployEulerEVault() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        EulerEVaultAdapter adapter = new EulerEVaultAdapter(
            IEulerEVaultFactory(vm.envAddress("EULER_EVAULT_FACTORY")),
            IERC4626(vm.envAddress("EULER_EVAULT")),
            vm.envAddress("ASSET"),
            vm.envAddress("EXECUTOR")
        );
        vm.stopBroadcast();

        console2.log("EulerEVaultAdapter", address(adapter));
        console2.log("asset", adapter.asset());
        console2.log("positionToken", adapter.positionToken());
        console2.log("factory", address(adapter.factory()));
    }

    function deployEulerEarn() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        EulerEarnAdapter adapter = new EulerEarnAdapter(
            IEulerEarnFactory(vm.envAddress("EULER_EARN_FACTORY")),
            IERC4626(vm.envAddress("EULER_EARN_VAULT")),
            vm.envAddress("ASSET"),
            vm.envAddress("EXECUTOR")
        );
        vm.stopBroadcast();

        console2.log("EulerEarnAdapter", address(adapter));
        console2.log("asset", adapter.asset());
        console2.log("positionToken", adapter.positionToken());
        console2.log("factory", address(adapter.factory()));
    }

    function deployCapyFi() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        CapyFiAdapter adapter = new CapyFiAdapter(
            vm.envAddress("EXECUTOR"),
            ICapyFiComptroller(vm.envAddress("CAPYFI_COMPTROLLER")),
            ICapyFiCaToken(vm.envAddress("CAPYFI_CATOKEN")),
            vm.envAddress("ASSET")
        );
        vm.stopBroadcast();

        console2.log("CapyFiAdapter", address(adapter));
        console2.log("asset", adapter.asset());
        console2.log("positionToken", adapter.positionToken());
        console2.log("comptroller", address(adapter.comptroller()));
    }

    /// @notice Deploys the complete fixed adapter set and attaches it once.
    function deployRegistry() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address executor = vm.envAddress("EXECUTOR");
        address[] memory adapters = vm.envAddress("ADAPTERS", ",");
        bool[] memory canDeposit = vm.envBool("CAN_DEPOSIT", ",");
        bool[] memory canRedeem = vm.envBool("CAN_REDEEM", ",");
        if (adapters.length != canDeposit.length || adapters.length != canRedeem.length) {
            revert("adapter config length mismatch");
        }

        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](adapters.length);
        for (uint256 i; i < adapters.length; ++i) {
            configs[i] =
                IGrowYieldAdapterRegistry.AdapterConfig(adapters[i], canDeposit[i], canRedeem[i]);
        }

        vm.startBroadcast(pk);
        GrowYieldAdapterRegistry registry = new GrowYieldAdapterRegistry(executor, configs);
        GrowYieldExecutorV3(executor).initializeRegistry(registry);
        vm.stopBroadcast();

        console2.log("GrowYieldAdapterRegistry", address(registry));
        console2.log("executor", executor);
        console2.log("adapterCount", adapters.length);
    }
}
