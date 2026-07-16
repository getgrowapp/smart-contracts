// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {GrowYieldAdapterRegistry} from "../src/yield-1271/GrowYieldAdapterRegistry.sol";
import {GrowYieldExecutorV3} from "../src/yield-1271/GrowYieldExecutorV3.sol";
import {GrowYield1271PolicySignerV4} from "../src/yield-1271/GrowYield1271PolicySignerV4.sol";

/**
 * @notice Deploys the adapter-based stack: registry + executor + policy signer.
 *         Adapters are deployed separately (DeployAdapters.s.sol) and allowlisted by
 *         the registry owner.
 *
 * Env:
 * - PRIVATE_KEY        deployer key
 * - REGISTRY_OWNER     adapter-allowlist owner (Safe or TimelockController)
 * - VALIDATION_MODULE  Alchemy SingleSignerValidationModule v2.0.1 address.
 *                      REQUIRED with no default, deliberately: the signer pins this
 *                      address on-chain because the module's hash-wrapping scheme
 *                      (userOpHash.toEthSignedMessageHash()) is version-specific.
 *                      Take it from Alchemy's official modular-account deployments
 *                      for the target chain and verify the version before deploying.
 * - MAX_LOSS_BPS       loss cap vs adapter preview (default 50 = 0.5%)
 */
contract DeployGrowYieldV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("REGISTRY_OWNER");
        address validationModule = vm.envAddress("VALIDATION_MODULE");
        uint16 maxLossBps = uint16(vm.envOr("MAX_LOSS_BPS", uint256(50)));

        vm.startBroadcast(pk);

        GrowYieldAdapterRegistry registry = new GrowYieldAdapterRegistry(owner);
        GrowYieldExecutorV3 executor = new GrowYieldExecutorV3(registry, maxLossBps);
        GrowYield1271PolicySignerV4 signer =
            new GrowYield1271PolicySignerV4(address(executor), validationModule);

        vm.stopBroadcast();

        console2.log("GrowYieldAdapterRegistry", address(registry));
        console2.log("GrowYieldExecutorV3", address(executor));
        console2.log("GrowYield1271PolicySignerV4", address(signer));
        console2.log("registryOwner", owner);
        console2.log("validationModule", validationModule);
        console2.log("maxLossBps", maxLossBps);
        console2.log("deployer", vm.addr(pk));
    }
}
