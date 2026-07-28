// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {GrowYieldPlugin} from "../src/GrowYieldPlugin.sol";

/// @notice Deploy a new unified GrowYieldPlugin (executor unchanged).
contract DeployMscaPlugin is Script {
    using SafeCast for uint256;

    function run(string calldata env) external {
        string memory config = vm.readFile(string.concat("script/config/", env, ".json"));
        string memory existingPath = string.concat("deployments/", env, "-msca.json");
        require(vm.exists(existingPath), "missing msca deployment json");

        address executor = vm.parseJsonAddress(vm.readFile(existingPath), ".executor");

        vm.startBroadcast();
        GrowYieldPlugin plugin = new GrowYieldPlugin(
            vm.parseJsonUint(config, ".policyModule.maxVerificationGas").toUint128(),
            vm.parseJsonUint(config, ".policyModule.maxCallGas").toUint128(),
            vm.parseJsonUint(config, ".policyModule.maxPreVerificationGas"),
            vm.parseJsonUint(config, ".policyModule.maxPaymasterVerificationGas").toUint128(),
            vm.parseJsonUint(config, ".policyModule.maxPaymasterPostOpGas").toUint128(),
            vm.parseJsonUint(config, ".policyModule.maxPriorityFeePerGas").toUint128(),
            vm.parseJsonUint(config, ".policyModule.maxFeePerGas").toUint128()
        );
        vm.stopBroadcast();

        console2.log("executor (unchanged):", executor);
        console2.log("mscaPlugin (new):      ", address(plugin));
        console2.log("policyModule (=plugin):", address(plugin));

        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("Simulation only; not writing deployment artifact");
            return;
        }

        string memory root = "msca";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "timestamp", block.timestamp);
        vm.serializeString(root, "commitSha", vm.envOr("GIT_COMMIT", string("")));
        vm.serializeAddress(root, "executor", executor);
        vm.serializeAddress(root, "policyModule", address(plugin));
        string memory json = vm.serializeAddress(root, "mscaPlugin", address(plugin));

        vm.writeJson(json, existingPath);
        console2.log("Wrote", existingPath);
    }
}
