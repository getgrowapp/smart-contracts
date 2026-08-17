// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {MorphoVaultEligibility} from "../src/MorphoVaultEligibility.sol";

/// @title DeployMorphoVaultEligibility
/// @notice Deploys `MorphoVaultEligibility` via CREATE2 with initial child allowlist.
/// @dev Usage:
///      forge script script/DeployMorphoVaultEligibility.s.sol \
///        --sig "run(string)" production-polygon \
///        --rpc-url $POLYGON_RPC_URL --broadcast --account grow-deployer
///
///      Env:
///      - ELIGIBILITY_OWNER (default Grow Safe `0xe8D212…`)
///      - ELIGIBILITY_SALT (default `0x1f`, must match `production-polygon.json` `.salts.morphoEligibility`)
contract DeployMorphoVaultEligibility is Script {
    address internal constant DEFAULT_OWNER = 0xe8D212F886109cbf01e8294E3640a6Fb05544ff3;

    /// @dev Steakhouse PaoTech JPYC — child for gbyJPY / ghyJPY on Polygon.
    address internal constant POLYGON_CHILD_JPYC = 0xBEEf0F82E269760429BE6255Fa00821b7e4b592A;

    bytes32 internal constant DEFAULT_SALT = bytes32(uint256(0x1f));

    function run(string calldata env) external {
        string memory config = vm.readFile(string.concat("script/config/", env, ".json"));
        address owner = vm.envOr("ELIGIBILITY_OWNER", DEFAULT_OWNER);
        bytes32 salt = vm.envOr("ELIGIBILITY_SALT", DEFAULT_SALT);
        address[] memory children = _resolveChildren(config);

        bytes memory init = abi.encodePacked(
            type(MorphoVaultEligibility).creationCode, abi.encode(owner, children)
        );
        address predicted =
            vm.computeCreate2Address(salt, keccak256(init), CREATE2_FACTORY);

        console2.log("=== MorphoVaultEligibility deploy:", env, "===");
        console2.log("  predicted:", predicted);
        console2.log("  owner:    ", owner);
        console2.log("  salt:     ", vm.toString(salt));
        for (uint256 i; i < children.length; ++i) {
            console2.log("  child:    ", children[i]);
        }

        vm.startBroadcast();

        MorphoVaultEligibility eligibility;
        if (predicted.code.length == 0) {
            eligibility = new MorphoVaultEligibility{salt: salt}(owner, children);
            require(address(eligibility) == predicted, "eligibility address mismatch");
            console2.log("MorphoVaultEligibility (new):", address(eligibility));
        } else {
            eligibility = MorphoVaultEligibility(predicted);
            console2.log("MorphoVaultEligibility (existing):", address(eligibility));
            for (uint256 i; i < children.length; ++i) {
                require(
                    eligibility.isEligibleVault(children[i]),
                    "existing oracle missing configured child"
                );
            }
        }

        vm.stopBroadcast();

        _writeArtifact(env, address(eligibility), owner, salt, children);
    }

    function _resolveChildren(string memory config)
        internal
        view
        returns (address[] memory children)
    {
        string memory key = ".morphoEligibilityChildren";
        if (vm.keyExistsJson(config, key)) {
            bytes memory raw = vm.parseJson(config, key);
            children = abi.decode(raw, (address[]));
            return children;
        }

        children = new address[](1);
        children[0] = POLYGON_CHILD_JPYC;
    }

    function _writeArtifact(
        string memory env,
        address eligibility,
        address owner,
        bytes32 salt,
        address[] memory children
    ) internal {
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "owner", owner);
        vm.serializeBytes32(root, "salt", salt);
        vm.serializeAddress(root, "children", children);
        string memory json = vm.serializeAddress(root, "eligibility", eligibility);

        string memory path = string.concat("deployments/morpho-eligibility-", env, ".json");
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("Simulation only; not writing", path);
            return;
        }
        vm.writeJson(json, path);
        console2.log("Deployment written to", path);
    }
}
