// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {GrowYieldExecutor} from "../src/GrowYieldExecutor.sol";
import {GrowYieldPlugin} from "../src/GrowYieldPlugin.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {CapyFiAdapter} from "../src/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../src/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../src/adapters/EulerEVaultAdapter.sol";
import {MorphoVaultV2Adapter} from "../src/adapters/MorphoVaultV2Adapter.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol,
    Venue
} from "../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "../src/interfaces/IYieldAdapter.sol";

import {GrowYieldDeployer} from "./GrowYieldDeployer.sol";

/// @title Deploy
/// @notice Deploys the full GrowYield stack deterministically via CREATE2 from a per-environment
///         JSON config, then writes the resulting addresses to `deployments/<env>.json`.
/// @dev Usage: forge script script/Deploy.s.sol --sig "run(string)" staging \
///          --rpc-url <url> --broadcast --account <keystore-name>
///      Import the signer once: cast wallet import grow-deployer --interactive
///      Set GIT_COMMIT=$(git rev-parse HEAD) to stamp the deployment artifact with the source
///      commit. Commit the resulting `deployments/<env>.json` so on-chain addresses are tracked
///      in version control (see deployments/README.md).
///
///      One adapter is deployed per supported protocol, and its constructor arguments are taken
///      from `.registry.registrars` — the same source the registry pins — so an adapter cannot be
///      wired to infrastructure the registry does not recognize. Venues are then listed per
///      protocol under `.vaults`.
///
///      The executor is also the venue registry. It is deployed owned by the shared deployer,
///      receives the configured venue set in the same transaction, and is then offered to
///      `.registry.owner`. That governance address must call `acceptOwnership()` before it can
///      admit further venues. `.executor.riskGuardian` must be a different address: it may pause
///      deposits but never un-pause or admit.
///
///      `VaultCfg` fields are ordered ALPHABETICALLY by JSON key: `vm.parseJson` abi-encodes
///      object keys in lexicographic (byte) order, so the struct layout must match or decoding
///      silently misaligns. `test/yield/Deploy.t.sol` locks this ordering.
contract Deploy is Script {
    using SafeCast for uint256;

    /// @dev Fixed salt for the shared deployer; yields one address across chains/environments.
    bytes32 internal constant DEPLOYER_SALT = bytes32(0);

    /// @dev Number of `Protocol` enum members.
    uint256 internal constant PROTOCOL_COUNT = 5;

    /// @notice One venue entry under `.vaults.<protocol>`.
    struct VaultCfg {
        bool canDeposit;
        bool canRedeem;
        address vault;
    }

    /// @dev Adapters to deploy, one per supported protocol.
    struct AdapterPlan {
        bytes32[] salts;
        bytes[] inits;
        Protocol[] protocols;
        address[] addrs;
    }

    /// @notice Deploys every contract for `env` (matching `script/config/<env>.json`).
    function run(string calldata env) external {
        string memory config = _loadConfig(env);
        GrowYieldDeployer deployer = _ensureDeployer();

        GrowYieldDeployer.StackParams memory params;
        params.registryOwner = vm.parseJsonAddress(config, ".registry.owner");
        require(params.registryOwner != CREATE2_FACTORY, "registry owner is CREATE2 factory");

        // --- Executor init code + predicted address ---
        address riskGuardian = vm.parseJsonAddress(config, ".executor.riskGuardian");
        require(riskGuardian != CREATE2_FACTORY, "risk guardian is CREATE2 factory");
        // The executor is the venue registry, so the registrars and the initial owner (this
        // deployer, which hands over in the same transaction) are its own constructor args.
        IGrowYieldAdapterRegistry.Registrars memory registrars = _registrars(config);
        params.executorInit = abi.encodePacked(
            type(GrowYieldExecutor).creationCode,
            abi.encode(
                vm.parseJsonUint(config, ".executor.maxLossBps").toUint16(),
                riskGuardian,
                address(deployer),
                registrars
            )
        );
        params.executorSalt = _salt(config, "executor");
        address executorAddr = vm.computeCreate2Address(
            params.executorSalt, keccak256(params.executorInit), address(deployer)
        );

        // --- Policy module init code (pins no executor; accounts approve one at install) ---
        params.policyInit = _policyInit(config);
        params.policySalt = _salt(config, "policyModule");

        // --- One adapter per supported protocol ---
        AdapterPlan memory plan = _buildAdapters(config, executorAddr, registrars, deployer);
        params.adapterSalts = plan.salts;
        params.adapterInits = plan.inits;

        // --- Initial venue set (binds predicted adapter addresses) ---
        params.vaults = _buildVaults(config, plan);

        _logPlan(env, address(deployer), executorAddr, plan, params.vaults);

        vm.startBroadcast();
        (address executor, address policyModule, address[] memory adapters) =
            deployer.deployStack(params);
        vm.stopBroadcast();

        _validateAuthorities(config, address(deployer), riskGuardian, executor, policyModule);
        _validateVenues(executor, address(deployer), params);

        // Deployed addresses must equal the pre-broadcast predictions; otherwise the artifact
        // (and any dependent off-chain config) would record the wrong contracts.
        require(executor == executorAddr, "executor address mismatch");
        for (uint256 i; i < adapters.length; ++i) {
            require(adapters[i] == plan.addrs[i], "adapter address mismatch");
            require(IYieldAdapter(adapters[i]).executor() == executor, "wrong adapter executor");
        }

        _writeDeployment(env, address(deployer), executor, policyModule, plan, params);
    }

    // -------------------------------------------------------------------------
    // Deployer bootstrap
    // -------------------------------------------------------------------------

    /// @dev Returns the shared deployer, deploying it via the canonical CREATE2 factory if absent.
    function _ensureDeployer() internal returns (GrowYieldDeployer deployer) {
        address predicted = vm.computeCreate2Address(
            DEPLOYER_SALT, keccak256(type(GrowYieldDeployer).creationCode), CREATE2_FACTORY
        );
        if (predicted.code.length == 0) {
            vm.broadcast();
            deployer = new GrowYieldDeployer{salt: DEPLOYER_SALT}();
            require(address(deployer) == predicted, "deployer address mismatch");
            console2.log("GrowYieldDeployer (new):", address(deployer));
        } else {
            deployer = GrowYieldDeployer(predicted);
            console2.log("GrowYieldDeployer (existing):", address(deployer));
        }
    }

    // -------------------------------------------------------------------------
    // Init-code builders
    // -------------------------------------------------------------------------

    function _policyInit(string memory config) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(GrowYieldPlugin).creationCode,
            abi.encode(
                vm.parseJsonUint(config, ".policyModule.maxVerificationGas").toUint128(),
                vm.parseJsonUint(config, ".policyModule.maxCallGas").toUint128(),
                vm.parseJsonUint(config, ".policyModule.maxPreVerificationGas"),
                vm.parseJsonUint(config, ".policyModule.maxPaymasterVerificationGas").toUint128(),
                vm.parseJsonUint(config, ".policyModule.maxPaymasterPostOpGas").toUint128(),
                vm.parseJsonUint(config, ".policyModule.maxPriorityFeePerGas").toUint128(),
                vm.parseJsonUint(config, ".policyModule.maxFeePerGas").toUint128()
            )
        );
    }

    /// @dev Reads the registry's pinned registrars; an absent key leaves that protocol
    ///      unsupported by the deployed registry, and no adapter is deployed for it.
    function _registrars(string memory config)
        internal
        view
        returns (IGrowYieldAdapterRegistry.Registrars memory r)
    {
        r.aavePool = _optionalAddress(config, ".registry.registrars.aavePool");
        r.aaveDataProvider = _optionalAddress(config, ".registry.registrars.aaveDataProvider");
        r.morphoVaultFactory = _optionalAddress(config, ".registry.registrars.morphoVaultFactory");
        r.morphoAdapterFactory =
            _optionalAddress(config, ".registry.registrars.morphoAdapterFactory");
        r.morphoEligibility = _optionalAddress(config, ".registry.registrars.morphoEligibility");
        r.eulerEVaultFactory = _optionalAddress(config, ".registry.registrars.eulerEVaultFactory");
        r.eulerEarnFactory = _optionalAddress(config, ".registry.registrars.eulerEarnFactory");
        r.capyFiComptroller = _optionalAddress(config, ".registry.registrars.capyFiComptroller");
    }

    /// @dev Builds one adapter per protocol that has both a configured salt and pinned
    ///      registrars. Constructor arguments come from the registrars themselves, so adapter and
    ///      registry can never disagree about a protocol's canonical infrastructure.
    function _buildAdapters(
        string memory config,
        address executor,
        IGrowYieldAdapterRegistry.Registrars memory registrars,
        GrowYieldDeployer deployer
    ) internal view returns (AdapterPlan memory plan) {
        bytes32[] memory salts = new bytes32[](PROTOCOL_COUNT);
        bytes[] memory inits = new bytes[](PROTOCOL_COUNT);
        Protocol[] memory protocols = new Protocol[](PROTOCOL_COUNT);
        uint256 n;

        for (uint256 i; i < PROTOCOL_COUNT; ++i) {
            Protocol protocol = Protocol(i);
            string memory name = _protocolName(protocol);
            string memory key = string.concat(".adapters.", name);
            if (!vm.keyExistsJson(config, key)) continue;

            bytes memory init = _adapterInit(protocol, registrars, executor);
            require(init.length != 0, string.concat("registrars missing for adapter: ", name));

            salts[n] = vm.parseJsonBytes32(config, key);
            inits[n] = init;
            protocols[n] = protocol;
            ++n;
        }

        require(n != 0, "no adapters configured");

        plan.salts = new bytes32[](n);
        plan.inits = new bytes[](n);
        plan.protocols = new Protocol[](n);
        plan.addrs = new address[](n);
        for (uint256 i; i < n; ++i) {
            plan.salts[i] = salts[i];
            plan.inits[i] = inits[i];
            plan.protocols[i] = protocols[i];
            plan.addrs[i] =
                vm.computeCreate2Address(salts[i], keccak256(inits[i]), address(deployer));
        }
    }

    /// @dev Adapter init code for `protocol`, or empty bytes if its registrars are not pinned.
    function _adapterInit(
        Protocol protocol,
        IGrowYieldAdapterRegistry.Registrars memory r,
        address executor
    ) internal pure returns (bytes memory) {
        if (protocol == Protocol.AAVE) {
            if (r.aavePool == address(0)) return bytes("");
            return abi.encodePacked(
                type(AaveV3Adapter).creationCode,
                abi.encode(r.aavePool, r.aaveDataProvider, executor)
            );
        }
        if (protocol == Protocol.MORPHO) {
            if (r.morphoEligibility == address(0)) return bytes("");
            return abi.encodePacked(
                type(MorphoVaultV2Adapter).creationCode, abi.encode(r.morphoEligibility, executor)
            );
        }
        if (protocol == Protocol.EULER_EVK) {
            if (r.eulerEVaultFactory == address(0)) return bytes("");
            return abi.encodePacked(
                type(EulerEVaultAdapter).creationCode, abi.encode(r.eulerEVaultFactory, executor)
            );
        }
        if (protocol == Protocol.EULER_EARN) {
            if (r.eulerEarnFactory == address(0)) return bytes("");
            return abi.encodePacked(
                type(EulerEarnAdapter).creationCode, abi.encode(r.eulerEarnFactory, executor)
            );
        }
        if (r.capyFiComptroller == address(0)) return bytes("");
        return abi.encodePacked(
            type(CapyFiAdapter).creationCode, abi.encode(executor, r.capyFiComptroller)
        );
    }

    /// @dev Flattens `.vaults.<protocol>` into admission entries bound to the protocol's adapter.
    function _buildVaults(string memory config, AdapterPlan memory plan)
        internal
        view
        returns (IGrowYieldAdapterRegistry.VaultConfig[] memory vaults)
    {
        address[PROTOCOL_COUNT] memory adapterByProtocol;
        for (uint256 i; i < plan.protocols.length; ++i) {
            adapterByProtocol[uint256(plan.protocols[i])] = plan.addrs[i];
        }

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

    // -------------------------------------------------------------------------
    // Post-deployment validation
    // -------------------------------------------------------------------------

    /// @dev Fail the script unless the executor and policy module bound the configured
    ///      authorities. The executor is ownerless, so there is no owner to verify.
    function _validateAuthorities(
        string memory config,
        address deployer,
        address expectedRiskGuardian,
        address executor,
        address policyModule
    ) internal view {
        require(deployer != CREATE2_FACTORY, "CREATE2 factory is the deployer");
        require(
            GrowYieldExecutor(executor).riskGuardian() == expectedRiskGuardian,
            "wrong risk guardian"
        );
        require(
            GrowYieldExecutor(executor).riskGuardian()
                != vm.parseJsonAddress(config, ".registry.owner"),
            "guardian and owner must differ"
        );

        // The module pins no executor and no paymaster: both are per-account install data.
        GrowYieldPlugin policy = GrowYieldPlugin(policyModule);
        require(
            policy.maxCallGas() == vm.parseJsonUint(config, ".policyModule.maxCallGas").toUint128(),
            "wrong policy call-gas ceiling"
        );
    }

    /// @dev Fail the script unless the executor admitted every configured venue and is offered
    ///      to the configured governance owner. Admission and execution are one contract.
    function _validateVenues(
        address executor,
        address deployer,
        GrowYieldDeployer.StackParams memory params
    ) internal view {
        GrowYieldExecutor r = GrowYieldExecutor(executor);
        require(r.owner() == deployer, "unexpected owner");
        require(r.pendingOwner() == params.registryOwner, "not offered to governance");
        require(r.vaultCount() == params.vaults.length, "unexpected venue count");

        for (uint256 i; i < params.vaults.length; ++i) {
            IGrowYieldAdapterRegistry.VaultConfig memory expected = params.vaults[i];
            Venue memory venue = r.venue(expected.vault);
            require(venue.adapter == expected.adapter, "venue adapter mismatch");
            require(venue.canDeposit == expected.canDeposit, "venue deposit flag");
            require(venue.canRedeem == expected.canRedeem, "venue redeem flag");
            require(r.vaultProtocol(expected.vault) == expected.protocol, "venue protocol");
            require(
                r.adapterCodeHash(expected.adapter) == expected.adapter.codehash,
                "adapter code hash mismatch"
            );
            require(
                venue.asset == IYieldAdapter(expected.adapter).asset(expected.vault),
                "venue asset drift"
            );
            require(
                venue.positionToken
                    == IYieldAdapter(expected.adapter).positionToken(expected.vault),
                "venue position drift"
            );
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _optionalAddress(string memory config, string memory key)
        internal
        view
        returns (address)
    {
        if (!vm.keyExistsJson(config, key)) return address(0);
        return vm.parseJsonAddress(config, key);
    }

    function _salt(string memory config, string memory key) internal pure returns (bytes32) {
        return vm.parseJsonBytes32(config, string.concat(".salts.", key));
    }

    function _loadConfig(string memory env) internal view returns (string memory) {
        return vm.readFile(string.concat("script/config/", env, ".json"));
    }

    /// @dev JSON key and log label for a protocol.
    function _protocolName(Protocol protocol) internal pure returns (string memory) {
        if (protocol == Protocol.AAVE) return "aave";
        if (protocol == Protocol.MORPHO) return "morpho";
        if (protocol == Protocol.EULER_EVK) return "eulerEVault";
        if (protocol == Protocol.EULER_EARN) return "eulerEarn";
        return "capyfi";
    }

    function _logPlan(
        string memory env,
        address deployer,
        address executor,
        AdapterPlan memory plan,
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults
    ) internal pure {
        console2.log("=== GrowYield deploy plan:", env, "===");
        console2.log("  deployer:  ", deployer);
        console2.log("  executor:  ", executor);
        for (uint256 i; i < plan.addrs.length; ++i) {
            console2.log(
                string.concat("  adapter[", _protocolName(plan.protocols[i]), "]:"), plan.addrs[i]
            );
        }
        for (uint256 i; i < vaults.length; ++i) {
            console2.log(
                string.concat("  vault[", _protocolName(vaults[i].protocol), "]:"), vaults[i].vault
            );
        }
    }

    /// @dev Serializes the deployment to `deployments/<env>.json`. Commit the file for tracking.
    ///      Only a real broadcast writes: a simulation would otherwise overwrite the record of
    ///      what is actually live with addresses that were never deployed.
    function _writeDeployment(
        string memory env,
        address deployer,
        address executor,
        address policyModule,
        AdapterPlan memory plan,
        GrowYieldDeployer.StackParams memory params
    ) internal {
        string[] memory adapterKinds = new string[](plan.protocols.length);
        for (uint256 i; i < plan.protocols.length; ++i) {
            adapterKinds[i] = _protocolName(plan.protocols[i]);
        }

        uint256 count = params.vaults.length;
        string[] memory vaultKinds = new string[](count);
        address[] memory vaultAddrs = new address[](count);
        address[] memory vaultAdapters = new address[](count);
        bool[] memory vaultCanDeposit = new bool[](count);
        bool[] memory vaultCanRedeem = new bool[](count);
        for (uint256 i; i < count; ++i) {
            vaultKinds[i] = _protocolName(params.vaults[i].protocol);
            vaultAddrs[i] = params.vaults[i].vault;
            vaultAdapters[i] = params.vaults[i].adapter;
            vaultCanDeposit[i] = params.vaults[i].canDeposit;
            vaultCanRedeem[i] = params.vaults[i].canRedeem;
        }

        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "timestamp", block.timestamp);
        vm.serializeString(root, "commitSha", vm.envOr("GIT_COMMIT", string("")));
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "executor", executor);
        vm.serializeAddress(root, "policyModule", policyModule);
        // The executor is the venue registry; one address, one owner.
        vm.serializeAddress(root, "owner", GrowYieldExecutor(executor).owner());
        vm.serializeAddress(root, "pendingOwner", GrowYieldExecutor(executor).pendingOwner());
        vm.serializeString(root, "adapterKinds", adapterKinds);
        vm.serializeAddress(root, "adapterAddresses", plan.addrs);
        vm.serializeString(root, "vaultKinds", vaultKinds);
        vm.serializeAddress(root, "vaultAdapters", vaultAdapters);
        vm.serializeBool(root, "vaultCanDeposit", vaultCanDeposit);
        vm.serializeBool(root, "vaultCanRedeem", vaultCanRedeem);
        string memory json = vm.serializeAddress(root, "vaultAddresses", vaultAddrs);

        string memory path = string.concat("deployments/", env, ".json");
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("Simulation only; not writing", path);
            return;
        }
        vm.writeJson(json, path);
        console2.log("Deployment written to", path);
    }
}
