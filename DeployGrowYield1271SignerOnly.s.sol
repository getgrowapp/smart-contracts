// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {GrowYield1271PolicySignerV3} from
    "../src/yield-1271/GrowYield1271PolicySignerV3.sol";

/**
 * @notice Redeploys only the EIP-1271 PolicySigner against an existing executor.
 *
 * Env:
 * - PRIVATE_KEY
 * - EXECUTOR (defaults to Base PoC executor)
 */
contract DeployGrowYield1271SignerOnly is Script {
    address internal constant DEFAULT_EXECUTOR =
        0xDD440Cb9530502dAE4e6a5022e5f1dD2718d5dCE;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address executor = vm.envOr("EXECUTOR", DEFAULT_EXECUTOR);

        vm.startBroadcast(pk);
        GrowYield1271PolicySignerV3 signer =
            new GrowYield1271PolicySignerV3(executor);
        vm.stopBroadcast();

        console2.log("GrowYield1271PolicySignerV3", address(signer));
        console2.log("executor", executor);
        console2.log("deployer", vm.addr(pk));
    }
}
