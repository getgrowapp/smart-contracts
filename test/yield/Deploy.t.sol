// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {GrowYieldDeployer} from "../../script/GrowYieldDeployer.sol";
import {Deploy} from "../../script/Deploy.s.sol";

import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {GrowYieldPlugin} from "../../src/GrowYieldPlugin.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol,
    Venue
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";

import {MockAToken, MockAavePool, MockUnderlying} from "../invariant/MockYieldVenues.sol";
import {MockMutableAaveDataProvider} from "./mocks/MockVaultV2Stack.sol";

/// @notice Verifies the CREATE2 deployer admits the initial vault set and hands registry
///         ownership to governance atomically, and that the config structs decode JSON in the
///         alphabetical key order Foundry serializes.
contract DeployTest is Test {
    GrowYieldDeployer internal deployer;
    MockUnderlying internal underlying;
    MockAavePool internal pool;
    MockMutableAaveDataProvider internal provider;
    address internal governance;

    bytes32 internal constant EXECUTOR_SALT = bytes32(uint256(1));
    bytes32 internal constant POLICY_SALT = bytes32(uint256(2));
    bytes32 internal constant AAVE_SALT = bytes32(uint256(0x10));
    address internal constant RISK_GUARDIAN = address(0x1234);

    function setUp() public {
        deployer = new GrowYieldDeployer();
        underlying = new MockUnderlying();
        pool = new MockAavePool(underlying);
        provider = new MockMutableAaveDataProvider(address(underlying), address(pool.aToken()));
        governance = makeAddr("governance");
    }

    /// @dev Deploys executor + policy + adapter + registry in one call, admits the vault, and
    ///      offers ownership to governance, using the same address precomputation the script
    ///      relies on. Front-run safety hinges on this being a single atomic transaction.
    function test_deployStack_admitsVaultsAndOffersOwnership() public {
        GrowYieldDeployer.StackParams memory params = _params(governance);
        address executorAddr = _predict(params.executorSalt, params.executorInit);
        address adapterAddr = params.vaults[0].adapter;
        address vaultAddr = params.vaults[0].vault;

        (address executor, address policyModule, address[] memory adapters) =
            deployer.deployStack(params);

        // Addresses land exactly where predicted.
        assertEq(executor, executorAddr, "executor addr");
        assertEq(adapters[0], adapterAddr, "adapter addr");
        assertGt(policyModule.code.length, 0, "policy deployed");

        // Every component pinned the same executor, which itself is ownerless.
        assertEq(GrowYieldExecutor(executor).riskGuardian(), RISK_GUARDIAN, "risk guardian");
        // The module pins neither executor nor paymaster: both are per-account install data.
        assertEq(GrowYieldPlugin(policyModule).accountExecutor(address(this)), address(0));
        assertEq(GrowYieldPlugin(policyModule).accountPaymaster(address(this)), address(0));
        assertEq(IYieldAdapter(adapters[0]).executor(), executor, "adapter executor");

        // Admission and execution are one contract; there is no second address to check.
        GrowYieldExecutor r = GrowYieldExecutor(executor);
        assertEq(r.vaultCount(), 1, "vault count");
        assertEq(r.vaultAt(0), vaultAddr, "vault order");
        assertEq(r.adapterCodeHash(adapterAddr), adapterAddr.codehash, "adapter code hash");

        Venue memory venue = r.venue(vaultAddr);
        assertEq(venue.adapter, adapterAddr, "venue adapter");
        assertEq(venue.asset, vaultAddr, "venue asset");
        assertEq(venue.positionToken, address(pool.aToken()), "venue position token");
        assertTrue(venue.canDeposit, "vault deposits");
        assertTrue(venue.canRedeem, "vault redemptions");
        assertTrue(r.vaultProtocol(vaultAddr) == Protocol.AAVE, "vault protocol");

        // Ownership is offered, not transferred: governance must accept it.
        assertEq(r.owner(), address(deployer), "owner");
        assertEq(r.pendingOwner(), governance, "pending owner");
        assertNotEq(r.owner(), CREATE2_FACTORY, "CREATE2 factory owns the stack");
        // The two authorities must be distinct addresses.
        assertNotEq(r.riskGuardian(), r.owner(), "guardian separated from owner");
    }

    /// @dev After handover only governance admits vaults; the deployer has no path back in
    ///      because CREATE2 cannot reproduce the occupied stack addresses.
    function test_deployStack_deployerCannotAdmitVaultsAfterHandover() public {
        GrowYieldDeployer.StackParams memory params = _params(governance);
        (address executor,,) = deployer.deployStack(params);
        GrowYieldExecutor r = GrowYieldExecutor(executor);

        vm.prank(governance);
        r.acceptOwnership();
        assertEq(r.owner(), governance, "governance owns registry");

        // Re-running the same plan cannot resurrect the deployer's ownership window.
        vm.expectRevert(GrowYieldDeployer.DeploymentFailed.selector);
        deployer.deployStack(params);

        // Governance admits a second reserve — served by the SAME adapter, no redeploy needed.
        MockUnderlying second = new MockUnderlying();
        MockAToken secondAToken = pool.addReserve(second);
        provider.setReserve(address(second), address(secondAToken));

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            params.vaults[0].adapter, address(second), Protocol.AAVE, true, true
        );

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(deployer))
        );
        vm.prank(address(deployer));
        r.addVaults(vaults);

        vm.prank(governance);
        r.addVaults(vaults);
        assertEq(r.vaultCount(), 2, "second vault admitted");
        assertEq(r.venue(address(second)).adapter, params.vaults[0].adapter, "same adapter reused");
        assertEq(r.venue(address(second)).positionToken, address(secondAToken), "second aToken");
        assertEq(executor.code.length > 0 ? 1 : 0, 1, "executor untouched");
    }

    /// @dev Naming the deployer as governance would strand ownership with a contract that can
    ///      never call `addVaults` again.
    function test_deployStack_rejectsUnusableRegistryOwner() public {
        vm.expectRevert(GrowYieldDeployer.InvalidAuthority.selector);
        deployer.deployStack(_params(address(deployer)));

        vm.expectRevert(GrowYieldDeployer.InvalidAuthority.selector);
        deployer.deployStack(_params(address(0)));
    }

    // -------------------------------------------------------------------------
    // Plan construction
    // -------------------------------------------------------------------------

    function _predict(bytes32 salt, bytes memory initCode) internal view returns (address) {
        return vm.computeCreate2Address(salt, keccak256(initCode), address(deployer));
    }

    /// @dev One-Aave-vault stack plan whose registry is owned by the deployer at construction.
    function _params(address registryOwner)
        internal
        view
        returns (GrowYieldDeployer.StackParams memory params)
    {
        params.executorSalt = EXECUTOR_SALT;
        // The executor is the venue registry, naming the deployer as its initial owner.
        params.executorInit = abi.encodePacked(
            type(GrowYieldExecutor).creationCode,
            abi.encode(
                uint16(50),
                RISK_GUARDIAN,
                address(deployer),
                IGrowYieldAdapterRegistry.Registrars({
                    aavePool: address(pool),
                    aaveDataProvider: address(provider),
                    morphoVaultFactory: address(0),
                    morphoAdapterFactory: address(0),
                    morphoEligibility: address(0),
                    eulerEVaultFactory: address(0),
                    eulerEarnFactory: address(0),
                    capyFiComptroller: address(0)
                })
            )
        );
        address executorAddr = _predict(params.executorSalt, params.executorInit);

        params.policySalt = POLICY_SALT;
        params.policyInit = abi.encodePacked(
            type(GrowYieldPlugin).creationCode,
            abi.encode(
                uint128(500_000),
                uint128(2_000_000),
                uint256(150_000),
                uint128(200_000),
                uint128(200_000),
                uint128(2 gwei),
                uint128(2 gwei)
            )
        );

        params.adapterSalts = new bytes32[](1);
        params.adapterSalts[0] = AAVE_SALT;
        params.adapterInits = new bytes[](1);
        // One adapter serves every reserve of the pinned pool.
        params.adapterInits[0] = abi.encodePacked(
            type(AaveV3Adapter).creationCode,
            abi.encode(address(pool), address(provider), executorAddr)
        );

        params.vaults = new IGrowYieldAdapterRegistry.VaultConfig[](1);
        params.vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            _predict(params.adapterSalts[0], params.adapterInits[0]),
            address(underlying), // an Aave venue is its underlying asset
            Protocol.AAVE,
            true,
            true
        );
        params.registryOwner = registryOwner;
    }

    // -------------------------------------------------------------------------
    // Config struct <-> JSON key-ordering guards
    // -------------------------------------------------------------------------

    /// @dev Every protocol now shares one venue-entry shape, so this is the only ordering guard
    ///      the script depends on. `vm.parseJson` abi-encodes keys in lexicographic order.
    function test_vaultCfgDecodesInKeyOrder() public pure {
        string memory json = "{" '"canDeposit":true,' '"canRedeem":false,'
            '"vault":"0x00000000000000000000000000000000000000A5"' "}";
        Deploy.VaultCfg memory c = abi.decode(vm.parseJson(json), (Deploy.VaultCfg));
        assertTrue(c.canDeposit, "canDeposit");
        assertFalse(c.canRedeem, "canRedeem");
        assertEq(c.vault, address(0xA5), "vault");
    }

    /// @dev Every shipped environment config must decode under the current schema. The
    ///      pre-refactor configs carried per-vault protocol wiring (`pool`, `wrapper`, `salt`,
    ///      ...), which `abi.decode` rejects against `VaultCfg` only at deploy time — after the
    ///      deployer contract is already broadcast. Failing here instead keeps that drift out of
    ///      a live run.
    function test_shippedConfigsDecodeUnderCurrentSchema() public view {
        string[2] memory envs = ["staging", "production"];
        for (uint256 i; i < envs.length; ++i) {
            string memory config = vm.readFile(string.concat("script/config/", envs[i], ".json"));
            string[5] memory protocols = ["aave", "morpho", "eulerEVault", "eulerEarn", "capyfi"];

            uint256 venues;
            for (uint256 j; j < protocols.length; ++j) {
                string memory key = string.concat(".vaults.", protocols[j]);
                if (!vm.keyExistsJson(config, key)) continue;

                // A venue set requires the protocol's adapter salt and pinned registrars;
                // otherwise `_buildAdapters` / `_buildVaults` abort mid-deploy.
                assertTrue(
                    vm.keyExistsJson(config, string.concat(".adapters.", protocols[j])),
                    string.concat(envs[i], ": vaults without adapter salt: ", protocols[j])
                );

                Deploy.VaultCfg[] memory cfgs =
                    abi.decode(vm.parseJson(config, key), (Deploy.VaultCfg[]));
                for (uint256 k; k < cfgs.length; ++k) {
                    assertNotEq(cfgs[k].vault, address(0), string.concat(envs[i], ": zero vault"));
                    assertTrue(
                        cfgs[k].canDeposit || cfgs[k].canRedeem,
                        string.concat(envs[i], ": venue permits no direction")
                    );
                }
                venues += cfgs.length;
            }
            assertGt(venues, 0, string.concat(envs[i], ": no venues configured"));
        }
    }

    /// @dev Each configured adapter salt must have its protocol's registrars pinned, or
    ///      `_buildAdapters` reverts with "registrars missing for adapter".
    function test_shippedConfigsPinRegistrarsForEveryAdapter() public view {
        string[2] memory envs = ["staging", "production"];
        string[5] memory protocols = ["aave", "morpho", "eulerEVault", "eulerEarn", "capyfi"];
        string[5] memory registrarKeys = [
            ".registry.registrars.aavePool",
            ".registry.registrars.morphoEligibility",
            ".registry.registrars.eulerEVaultFactory",
            ".registry.registrars.eulerEarnFactory",
            ".registry.registrars.capyFiComptroller"
        ];

        for (uint256 i; i < envs.length; ++i) {
            string memory config = vm.readFile(string.concat("script/config/", envs[i], ".json"));
            for (uint256 j; j < protocols.length; ++j) {
                if (!vm.keyExistsJson(config, string.concat(".adapters.", protocols[j]))) continue;
                assertTrue(
                    vm.keyExistsJson(config, registrarKeys[j]),
                    string.concat(envs[i], ": adapter without registrars: ", protocols[j])
                );
            }
            // Aave needs both halves pinned, or the registry constructor reverts.
            assertEq(
                vm.keyExistsJson(config, ".registry.registrars.aavePool"),
                vm.keyExistsJson(config, ".registry.registrars.aaveDataProvider"),
                string.concat(envs[i], ": half-configured Aave registrars")
            );
            bool morpho = vm.keyExistsJson(config, ".registry.registrars.morphoVaultFactory");
            assertEq(
                morpho,
                vm.keyExistsJson(config, ".registry.registrars.morphoAdapterFactory"),
                string.concat(envs[i], ": half-configured Morpho registrars")
            );
            assertEq(
                morpho,
                vm.keyExistsJson(config, ".registry.registrars.morphoEligibility"),
                string.concat(envs[i], ": half-configured Morpho registrars")
            );
        }
    }

    function test_vaultCfgArrayDecodesInKeyOrder() public pure {
        string memory json = "[" "{" '"canDeposit":false,' '"canRedeem":true,'
            '"vault":"0x0000000000000000000000000000000000000011"' "}," "{" '"canDeposit":true,'
            '"canRedeem":true,' '"vault":"0x0000000000000000000000000000000000000022"' "}" "]";
        Deploy.VaultCfg[] memory c = abi.decode(vm.parseJson(json), (Deploy.VaultCfg[]));
        assertEq(c.length, 2, "length");
        assertFalse(c[0].canDeposit, "0.canDeposit");
        assertTrue(c[0].canRedeem, "0.canRedeem");
        assertEq(c[0].vault, address(0x11), "0.vault");
        assertTrue(c[1].canDeposit, "1.canDeposit");
        assertEq(c[1].vault, address(0x22), "1.vault");
    }
}
