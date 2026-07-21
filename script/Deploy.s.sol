// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {GrowYieldExecutor} from "../src/GrowYieldExecutor.sol";
import {GrowYieldPolicyModule} from "../src/GrowYieldPolicyModule.sol";
import {GrowYieldAdapterRegistry} from "../src/GrowYieldAdapterRegistry.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {CapyFiAdapter} from "../src/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../src/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../src/adapters/EulerEVaultAdapter.sol";
import {MorphoVaultV2Adapter} from "../src/adapters/MorphoVaultV2Adapter.sol";
import {IGrowYieldAdapterRegistry} from "../src/interfaces/IGrowYieldAdapterRegistry.sol";

import {GrowYieldDeployer} from "./GrowYieldDeployer.sol";

/// @title Deploy
/// @notice Deploys the full GrowYield stack deterministically via CREATE2 from a per-environment
///         JSON config, then writes the resulting addresses to `deployments/<env>.json`.
/// @dev Usage: forge script script/Deploy.s.sol --sig "run(string)" staging \
///          --rpc-url <url> --broadcast --private-key $PK
///      Set GIT_COMMIT=$(git rev-parse HEAD) to stamp the deployment artifact with the source
///      commit. Commit the resulting `deployments/<env>.json` so on-chain addresses are tracked
///      in version control (see deployments/README.md).
///
///      Struct fields below are ordered ALPHABETICALLY by JSON key: `vm.parseJson` abi-encodes
///      object keys in lexicographic (byte) order, so the struct layout must match or decoding
///      silently misaligns. `test/yield/Deploy.t.sol` locks this ordering.
contract Deploy is Script {
    using SafeCast for uint256;

    /// @dev Fixed salt for the shared deployer; yields one address across chains/environments.
    bytes32 internal constant DEPLOYER_SALT = bytes32(0);

    struct AaveCfg {
        address asset;
        bool canDeposit;
        bool canRedeem;
        address dataProvider;
        address pool;
        bytes32 salt;
    }

    struct MorphoCfg {
        bool canDeposit;
        bool canRedeem;
        address eligibility;
        address factory;
        bytes32 salt;
        address v1AdapterFactory;
        address wrapper;
    }

    struct EulerEVaultCfg {
        address asset;
        bool canDeposit;
        bool canRedeem;
        address eVault;
        address factory;
        bytes32 salt;
    }

    struct EulerEarnCfg {
        address asset;
        bool canDeposit;
        bool canRedeem;
        address factory;
        bytes32 salt;
        address vault;
    }

    struct CapyFiCfg {
        address asset;
        address caToken;
        bool canDeposit;
        bool canRedeem;
        address comptroller;
        bytes32 salt;
    }

    /// @notice Deploys every contract for `env` (matching `script/config/<env>.json`).
    function run(string calldata env) external {
        string memory config = _loadConfig(env);
        GrowYieldDeployer deployer = _ensureDeployer();

        // --- Executor init code + predicted address ---
        uint16 maxLossBps = vm.parseJsonUint(config, ".executor.maxLossBps").toUint16();
        address riskGuardian = vm.parseJsonAddress(config, ".executor.riskGuardian");
        bytes memory executorInit = abi.encodePacked(
            type(GrowYieldExecutor).creationCode, abi.encode(maxLossBps, riskGuardian)
        );
        bytes32 executorSalt = _salt(config, "executor");
        address executorAddr =
            vm.computeCreate2Address(executorSalt, keccak256(executorInit), address(deployer));

        // --- Policy module init code (binds the executor address) ---
        bytes memory policyInit = _policyInit(config, executorAddr);
        bytes32 policySalt = _salt(config, "policyModule");

        // --- Adapters (each binds the executor address) ---
        (
            bytes32[] memory adapterSalts,
            bytes[] memory adapterInits,
            bool[] memory canDeposit,
            bool[] memory canRedeem,
            string[] memory kinds
        ) = _buildAdapters(config, executorAddr);

        // --- Registry init code (binds executor + predicted adapter addresses) ---
        address[] memory adapterAddrs = new address[](adapterInits.length);
        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](adapterInits.length);
        for (uint256 i; i < adapterInits.length; ++i) {
            adapterAddrs[i] = vm.computeCreate2Address(
                adapterSalts[i], keccak256(adapterInits[i]), address(deployer)
            );
            configs[i] = IGrowYieldAdapterRegistry.AdapterConfig(
                adapterAddrs[i], canDeposit[i], canRedeem[i]
            );
        }
        bytes memory registryInit = abi.encodePacked(
            type(GrowYieldAdapterRegistry).creationCode, abi.encode(executorAddr, configs)
        );
        bytes32 registrySalt = _salt(config, "registry");

        _logPlan(env, address(deployer), executorAddr, adapterAddrs, kinds);

        vm.startBroadcast();
        (address executor, address policyModule, address[] memory adapters, address registry) = deployer.deployStack(
            executorSalt,
            executorInit,
            policySalt,
            policyInit,
            adapterSalts,
            adapterInits,
            registrySalt,
            registryInit
        );
        vm.stopBroadcast();

        // Deployed addresses must equal the pre-broadcast predictions; otherwise the artifact
        // (and any dependent off-chain config) would record the wrong contracts.
        require(executor == executorAddr, "executor address mismatch");
        for (uint256 i; i < adapters.length; ++i) {
            require(adapters[i] == adapterAddrs[i], "adapter address mismatch");
        }

        _writeDeployment(
            env,
            address(deployer),
            executor,
            policyModule,
            registry,
            adapters,
            kinds,
            canDeposit,
            canRedeem
        );
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

    function _policyInit(string memory config, address executor)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(GrowYieldPolicyModule).creationCode,
            abi.encode(
                executor,
                vm.parseJsonAddress(config, ".policyModule.requiredPaymaster"),
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

    /// @dev Decodes every configured adapter kind into flat, parallel deployment arrays.
    function _buildAdapters(string memory config, address executor)
        internal
        view
        returns (
            bytes32[] memory salts,
            bytes[] memory inits,
            bool[] memory canDeposit,
            bool[] memory canRedeem,
            string[] memory kinds
        )
    {
        AaveCfg[] memory aave = _decodeAave(config);
        MorphoCfg[] memory morpho = _decodeMorpho(config);
        EulerEVaultCfg[] memory eev = _decodeEulerEVault(config);
        EulerEarnCfg[] memory earn = _decodeEulerEarn(config);
        CapyFiCfg[] memory capy = _decodeCapyFi(config);

        uint256 n = aave.length + morpho.length + eev.length + earn.length + capy.length;
        require(n > 0, "no adapters configured");

        salts = new bytes32[](n);
        inits = new bytes[](n);
        canDeposit = new bool[](n);
        canRedeem = new bool[](n);
        kinds = new string[](n);
        uint256 k;

        for (uint256 i; i < aave.length; ++i) {
            salts[k] = aave[i].salt;
            inits[k] = abi.encodePacked(
                type(AaveV3Adapter).creationCode,
                abi.encode(aave[i].pool, aave[i].dataProvider, aave[i].asset, executor)
            );
            canDeposit[k] = aave[i].canDeposit;
            canRedeem[k] = aave[i].canRedeem;
            kinds[k] = "aave";
            ++k;
        }
        for (uint256 i; i < morpho.length; ++i) {
            salts[k] = morpho[i].salt;
            inits[k] = abi.encodePacked(
                type(MorphoVaultV2Adapter).creationCode,
                abi.encode(
                    morpho[i].wrapper,
                    morpho[i].factory,
                    morpho[i].v1AdapterFactory,
                    morpho[i].eligibility,
                    executor
                )
            );
            canDeposit[k] = morpho[i].canDeposit;
            canRedeem[k] = morpho[i].canRedeem;
            kinds[k] = "morpho";
            ++k;
        }
        for (uint256 i; i < eev.length; ++i) {
            salts[k] = eev[i].salt;
            inits[k] = abi.encodePacked(
                type(EulerEVaultAdapter).creationCode,
                abi.encode(eev[i].factory, eev[i].eVault, eev[i].asset, executor)
            );
            canDeposit[k] = eev[i].canDeposit;
            canRedeem[k] = eev[i].canRedeem;
            kinds[k] = "eulerEVault";
            ++k;
        }
        for (uint256 i; i < earn.length; ++i) {
            salts[k] = earn[i].salt;
            inits[k] = abi.encodePacked(
                type(EulerEarnAdapter).creationCode,
                abi.encode(earn[i].factory, earn[i].vault, earn[i].asset, executor)
            );
            canDeposit[k] = earn[i].canDeposit;
            canRedeem[k] = earn[i].canRedeem;
            kinds[k] = "eulerEarn";
            ++k;
        }
        for (uint256 i; i < capy.length; ++i) {
            salts[k] = capy[i].salt;
            inits[k] = abi.encodePacked(
                type(CapyFiAdapter).creationCode,
                abi.encode(executor, capy[i].comptroller, capy[i].caToken, capy[i].asset)
            );
            canDeposit[k] = capy[i].canDeposit;
            canRedeem[k] = capy[i].canRedeem;
            kinds[k] = "capyfi";
            ++k;
        }
    }

    // -------------------------------------------------------------------------
    // Config decoding (optional per-kind arrays under `.adapters.<kind>`)
    // -------------------------------------------------------------------------

    function _decodeAave(string memory config) internal view returns (AaveCfg[] memory a) {
        if (!vm.keyExistsJson(config, ".adapters.aave")) return new AaveCfg[](0);
        a = abi.decode(vm.parseJson(config, ".adapters.aave"), (AaveCfg[]));
    }

    function _decodeMorpho(string memory config) internal view returns (MorphoCfg[] memory a) {
        if (!vm.keyExistsJson(config, ".adapters.morpho")) return new MorphoCfg[](0);
        a = abi.decode(vm.parseJson(config, ".adapters.morpho"), (MorphoCfg[]));
    }

    function _decodeEulerEVault(string memory config)
        internal
        view
        returns (EulerEVaultCfg[] memory a)
    {
        if (!vm.keyExistsJson(config, ".adapters.eulerEVault")) return new EulerEVaultCfg[](0);
        a = abi.decode(vm.parseJson(config, ".adapters.eulerEVault"), (EulerEVaultCfg[]));
    }

    function _decodeEulerEarn(string memory config)
        internal
        view
        returns (EulerEarnCfg[] memory a)
    {
        if (!vm.keyExistsJson(config, ".adapters.eulerEarn")) {
            return new EulerEarnCfg[](0);
        }
        a = abi.decode(vm.parseJson(config, ".adapters.eulerEarn"), (EulerEarnCfg[]));
    }

    function _decodeCapyFi(string memory config) internal view returns (CapyFiCfg[] memory a) {
        if (!vm.keyExistsJson(config, ".adapters.capyfi")) return new CapyFiCfg[](0);
        a = abi.decode(vm.parseJson(config, ".adapters.capyfi"), (CapyFiCfg[]));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _salt(string memory config, string memory key) internal pure returns (bytes32) {
        return vm.parseJsonBytes32(config, string.concat(".salts.", key));
    }

    function _loadConfig(string memory env) internal view returns (string memory) {
        return vm.readFile(string.concat("script/config/", env, ".json"));
    }

    function _logPlan(
        string memory env,
        address deployer,
        address executor,
        address[] memory adapterAddrs,
        string[] memory kinds
    ) internal pure {
        console2.log("=== GrowYield deploy plan:", env, "===");
        console2.log("  deployer:  ", deployer);
        console2.log("  executor:  ", executor);
        for (uint256 i; i < adapterAddrs.length; ++i) {
            console2.log(string.concat("  adapter[", kinds[i], "]:"), adapterAddrs[i]);
        }
    }

    /// @dev Serializes the deployment to `deployments/<env>.json`. Commit the file for tracking.
    function _writeDeployment(
        string memory env,
        address deployer,
        address executor,
        address policyModule,
        address registry,
        address[] memory adapters,
        string[] memory kinds,
        bool[] memory canDeposit,
        bool[] memory canRedeem
    ) internal {
        string memory root = "deployment";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "timestamp", block.timestamp);
        vm.serializeString(root, "commitSha", vm.envOr("GIT_COMMIT", string("")));
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "executor", executor);
        vm.serializeAddress(root, "policyModule", policyModule);
        vm.serializeAddress(root, "registry", registry);
        vm.serializeString(root, "adapterKinds", kinds);
        vm.serializeBool(root, "adapterCanDeposit", canDeposit);
        vm.serializeBool(root, "adapterCanRedeem", canRedeem);
        string memory json = vm.serializeAddress(root, "adapterAddresses", adapters);

        string memory path = string.concat("deployments/", env, ".json");
        vm.writeJson(json, path);
        console2.log("Deployment written to", path);
    }
}
