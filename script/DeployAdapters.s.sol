// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {
    IMorphoVaultV1AdapterFactory
} from "vault-v2/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";

import {AaveV3Adapter} from "../src/yield-module/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../src/yield-module/adapters/MorphoVaultV2Adapter.sol";
import {GrowYieldAdapterRegistry} from "../src/yield-module/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutorV3} from "../src/yield-module/GrowYieldExecutorV3.sol";
import {
    IGrowYieldAdapterRegistry
} from "../src/yield-module/interfaces/IGrowYieldAdapterRegistry.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../src/interfaces/IAaveProtocolDataProvider.sol";
import {IMorphoVaultEligibility} from "../src/interfaces/IMorphoVaultEligibility.sol";

/// @notice Deploys executor-pinned Aave and Morpho venue adapters.
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
