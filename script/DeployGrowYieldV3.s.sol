// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {GrowYieldExecutorV3} from "../src/yield-module/GrowYieldExecutorV3.sol";
import {GrowYieldPolicyModule} from "../src/yield-module/GrowYieldPolicyModule.sol";

/// @notice Deploys the executor and direct ERC-6900 policy module.
/// @dev Deploy adapters next, then deploy and attach the fixed registry.
contract DeployGrowYieldV3 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint16 maxLossBps = SafeCast.toUint16(vm.envOr("MAX_LOSS_BPS", uint256(50)));
        address riskGuardian = vm.envAddress("RISK_GUARDIAN");

        vm.startBroadcast(pk);
        GrowYieldExecutorV3 executor = new GrowYieldExecutorV3(maxLossBps, riskGuardian);
        GrowYieldPolicyModule policyModule = new GrowYieldPolicyModule(
            address(executor),
            vm.envAddress("REQUIRED_PAYMASTER"),
            SafeCast.toUint128(vm.envOr("MAX_VERIFICATION_GAS", uint256(500_000))),
            SafeCast.toUint128(vm.envOr("MAX_CALL_GAS", uint256(2_000_000))),
            vm.envOr("MAX_PRE_VERIFICATION_GAS", uint256(150_000)),
            SafeCast.toUint128(vm.envOr("MAX_PAYMASTER_VERIFICATION_GAS", uint256(200_000))),
            SafeCast.toUint128(vm.envOr("MAX_PAYMASTER_POST_OP_GAS", uint256(200_000))),
            SafeCast.toUint128(vm.envOr("MAX_PRIORITY_FEE_PER_GAS", uint256(2 gwei))),
            SafeCast.toUint128(vm.envOr("MAX_FEE_PER_GAS", uint256(2 gwei)))
        );
        vm.stopBroadcast();

        console2.log("GrowYieldExecutorV3", address(executor));
        console2.log("GrowYieldPolicyModule", address(policyModule));
        console2.log("requiredPaymaster", policyModule.requiredPaymaster());
        console2.log("maxLossBps", maxLossBps);
        console2.log("riskGuardian", riskGuardian);
        console2.log("registryInitializer", executor.registryInitializer());
    }
}
