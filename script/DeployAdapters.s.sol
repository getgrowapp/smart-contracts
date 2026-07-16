// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";

import {AaveV3Adapter} from "../src/yield-1271/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../src/yield-1271/adapters/MorphoVaultV2Adapter.sol";
import {IAaveV3Pool} from "../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../src/interfaces/IAaveProtocolDataProvider.sol";
import {IMorphoVaultEligibility} from "../src/interfaces/IMorphoVaultEligibility.sol";

/**
 * @notice Deploys venue adapters. After deployment, the registry owner must
 *         `setAdapter(adapter, canDeposit, canRedeem)` to activate them.
 *
 * Aave:   forge script script/DeployAdapters.s.sol --sig "deployAave()"
 *   Env: PRIVATE_KEY, EXECUTOR, AAVE_POOL, AAVE_DATA_PROVIDER, ASSET
 *
 * Morpho: forge script script/DeployAdapters.s.sol --sig "deployMorpho()"
 *   Env: PRIVATE_KEY, EXECUTOR, MORPHO_WRAPPER, MORPHO_FACTORY,
 *        MORPHO_ADAPTER_FACTORY, MORPHO_ELIGIBILITY
 */
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
            vm.envAddress("MORPHO_ADAPTER_FACTORY"),
            IMorphoVaultEligibility(vm.envAddress("MORPHO_ELIGIBILITY")),
            vm.envAddress("EXECUTOR")
        );
        vm.stopBroadcast();

        console2.log("MorphoVaultV2Adapter", address(adapter));
        console2.log("asset", adapter.asset());
        console2.log("positionToken", adapter.positionToken());
        console2.log("child", adapter.child());
    }
}
