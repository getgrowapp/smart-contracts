// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {GrowYieldPlugin} from "../../src/GrowYieldPlugin.sol";

contract GrowYieldManifestHashTest is Test {
    function test_logManifestHash() public {
        GrowYieldPlugin plugin = new GrowYieldPlugin(
            500_000, 2_000_000, 150_000, 200_000, 200_000, 2 gwei, 2 gwei
        );
        bytes32 hash = keccak256(abi.encode(plugin.pluginManifest()));
        emit log_bytes32(hash);
    }
}
