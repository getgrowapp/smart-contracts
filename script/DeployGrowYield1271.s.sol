// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IGrowYieldRegistry} from "../src/yield-v6/IGrowYieldSystem.sol";
import {GrowYieldExecutor1271V2} from
    "../src/yield-1271/GrowYieldExecutor1271V2.sol";
import {GrowYield1271PolicySignerV3} from
    "../src/yield-1271/GrowYield1271PolicySignerV3.sol";

/**
 * @notice Deploys EIP-1271 executor + policy signer against an existing registry.
 *
 * Env:
 * - PRIVATE_KEY
 * - REGISTRY (defaults to Base V6 registry)
 * - MAX_LOSS_BPS (default 50)
 */
contract DeployGrowYield1271 is Script {
    address internal constant DEFAULT_REGISTRY =
        0x7F219F5009Df002307Cf759994a1370De3d089E0;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address registry = vm.envOr("REGISTRY", DEFAULT_REGISTRY);
        uint16 maxLossBps = uint16(vm.envOr("MAX_LOSS_BPS", uint256(50)));

        vm.startBroadcast(pk);

        GrowYieldExecutor1271V2 executor = new GrowYieldExecutor1271V2(
            IGrowYieldRegistry(registry), maxLossBps
        );
        GrowYield1271PolicySignerV3 signer =
            new GrowYield1271PolicySignerV3(address(executor));

        vm.stopBroadcast();

        console2.log("GrowYieldExecutor1271V2", address(executor));
        console2.log("GrowYield1271PolicySignerV3", address(signer));
        console2.log("registry", registry);
        console2.log("deployer", vm.addr(pk));
    }
}
