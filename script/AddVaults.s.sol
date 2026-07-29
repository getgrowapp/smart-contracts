// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {GrowYieldExecutor} from "../src/GrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol,
    Venue
} from "../src/interfaces/IGrowYieldAdapterRegistry.sol";

/// @title AddVaults
/// @notice Admits additional venues on an existing GrowYield executor via `addVaults`.
/// @dev Usage:
///      forge script script/AddVaults.s.sol --sig "run(string)" production \
///        --rpc-url $BASE_RPC_URL --private-key $PK --broadcast
///
///      Config: `script/config/add-vaults-<env>.json` (adapter addresses + vault list).
///      Skips vaults already admitted (adapter != zero).
contract AddVaults is Script {
    uint256 internal constant PROTOCOL_COUNT = 5;

    struct VaultCfg {
        bool canDeposit;
        bool canRedeem;
        address vault;
    }

    function run(string calldata env) external {
        string memory config = _loadConfig(env);
        address executor = vm.parseJsonAddress(config, ".executor");
        require(executor.code.length != 0, "executor not deployed");

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults = _buildVaults(config);
        IGrowYieldAdapterRegistry.VaultConfig[] memory pending = _filterPending(executor, vaults);
        require(pending.length != 0, "all vaults already admitted");

        _logPending(executor, pending);

        vm.startBroadcast();
        GrowYieldExecutor(executor).addVaults(pending);
        vm.stopBroadcast();

        _validateAdmission(executor, pending);
        console2.log("Admitted", pending.length, "vault(s); vaultCount:", GrowYieldExecutor(executor).vaultCount());
    }

    function _filterPending(address executor, IGrowYieldAdapterRegistry.VaultConfig[] memory vaults)
        internal
        view
        returns (IGrowYieldAdapterRegistry.VaultConfig[] memory pending)
    {
        uint256 count;
        for (uint256 i; i < vaults.length; ++i) {
            if (GrowYieldExecutor(executor).venue(vaults[i].vault).adapter == address(0)) {
                ++count;
            }
        }
        pending = new IGrowYieldAdapterRegistry.VaultConfig[](count);
        uint256 k;
        for (uint256 i; i < vaults.length; ++i) {
            if (GrowYieldExecutor(executor).venue(vaults[i].vault).adapter == address(0)) {
                pending[k++] = vaults[i];
            }
        }
    }

    function _buildVaults(string memory config)
        internal
        view
        returns (IGrowYieldAdapterRegistry.VaultConfig[] memory vaults)
    {
        address[PROTOCOL_COUNT] memory adapterByProtocol;
        adapterByProtocol[uint256(Protocol.AAVE)] = vm.parseJsonAddress(config, ".adapters.aave");
        adapterByProtocol[uint256(Protocol.MORPHO)] = vm.parseJsonAddress(config, ".adapters.morpho");
        adapterByProtocol[uint256(Protocol.EULER_EVK)] =
            vm.parseJsonAddress(config, ".adapters.eulerEVault");
        adapterByProtocol[uint256(Protocol.EULER_EARN)] =
            vm.parseJsonAddress(config, ".adapters.eulerEarn");
        adapterByProtocol[uint256(Protocol.CAPYFI)] = vm.parseJsonAddress(config, ".adapters.capyfi");

        VaultCfg[][] memory perProtocol = new VaultCfg[][](PROTOCOL_COUNT);
        uint256 total;
        for (uint256 i; i < PROTOCOL_COUNT; ++i) {
            perProtocol[i] = _decodeVaults(config, _protocolName(Protocol(i)));
            if (perProtocol[i].length != 0) {
                require(
                    adapterByProtocol[i] != address(0),
                    string.concat("no adapter for vaults: ", _protocolName(Protocol(i)))
                );
            }
            total += perProtocol[i].length;
        }
        require(total != 0, "no vaults configured");

        vaults = new IGrowYieldAdapterRegistry.VaultConfig[](total);
        uint256 k;
        for (uint256 i; i < PROTOCOL_COUNT; ++i) {
            for (uint256 j; j < perProtocol[i].length; ++j) {
                vaults[k++] = IGrowYieldAdapterRegistry.VaultConfig({
                    adapter: adapterByProtocol[i],
                    vault: perProtocol[i][j].vault,
                    protocol: Protocol(i),
                    canDeposit: perProtocol[i][j].canDeposit,
                    canRedeem: perProtocol[i][j].canRedeem
                });
            }
        }
    }

    function _decodeVaults(string memory config, string memory protocolName)
        internal
        view
        returns (VaultCfg[] memory)
    {
        string memory key = string.concat(".vaults.", protocolName);
        if (!vm.keyExistsJson(config, key)) return new VaultCfg[](0);
        return abi.decode(vm.parseJson(config, key), (VaultCfg[]));
    }

    function _validateAdmission(
        address executor,
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults
    ) internal view {
        GrowYieldExecutor r = GrowYieldExecutor(executor);
        for (uint256 i; i < vaults.length; ++i) {
            IGrowYieldAdapterRegistry.VaultConfig memory expected = vaults[i];
            Venue memory venue = r.venue(expected.vault);
            require(venue.adapter == expected.adapter, "venue adapter mismatch");
            require(venue.canDeposit == expected.canDeposit, "venue deposit flag");
            require(venue.canRedeem == expected.canRedeem, "venue redeem flag");
            require(r.vaultProtocol(expected.vault) == expected.protocol, "venue protocol");
        }
    }

    function _logPending(address executor, IGrowYieldAdapterRegistry.VaultConfig[] memory vaults)
        internal
        view
    {
        console2.log("Executor:", executor);
        console2.log("Owner:", GrowYieldExecutor(executor).owner());
        console2.log("Pending owner:", GrowYieldExecutor(executor).pendingOwner());
        console2.log("Current vaultCount:", GrowYieldExecutor(executor).vaultCount());
        for (uint256 i; i < vaults.length; ++i) {
            console2.log("  + vault", vaults[i].vault);
            console2.log("    adapter", vaults[i].adapter);
        }
    }

    function _loadConfig(string memory env) internal view returns (string memory) {
        string memory path = string.concat("script/config/add-vaults-", env, ".json");
        return vm.readFile(path);
    }

    function _protocolName(Protocol protocol) internal pure returns (string memory) {
        if (protocol == Protocol.AAVE) return "aave";
        if (protocol == Protocol.MORPHO) return "morpho";
        if (protocol == Protocol.EULER_EVK) return "eulerEVault";
        if (protocol == Protocol.EULER_EARN) return "eulerEarn";
        return "capyfi";
    }
}
