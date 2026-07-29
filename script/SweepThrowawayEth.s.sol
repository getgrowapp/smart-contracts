// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Sweep leftover throwaway ETH to the relay deployer after Morpho smoke.
contract SweepThrowawayEth is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        uint256 throwawayPk =
            uint256(keccak256(abi.encodePacked("grow-smoke-v3", deployer, block.chainid)));
        address throwaway = vm.addr(throwawayPk);
        console2.log("throwaway", throwaway);
        console2.log("deployer", deployer);

        vm.startBroadcast(throwawayPk);
        uint256 bal = throwaway.balance;
        // Leave dust for the gas of this transfer itself.
        uint256 keep = 0.00002 ether;
        require(bal > keep, "nothing to sweep");
        uint256 sendAmount = bal - keep;
        (bool ok,) = deployer.call{value: sendAmount}("");
        require(ok, "eth sweep failed");
        console2.log("sweptEth", sendAmount);
        vm.stopBroadcast();
    }
}
