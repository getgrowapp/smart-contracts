// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {GrowYieldDeployer} from "../../script/GrowYieldDeployer.sol";
import {Deploy} from "../../script/Deploy.s.sol";

import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {GrowYieldPolicyModule} from "../../src/GrowYieldPolicyModule.sol";
import {IGrowYieldAdapterRegistry} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";

import {MockUnderlying, MockAavePool} from "../invariant/MockYieldVenues.sol";
import {MockMutableAaveDataProvider} from "./mocks/MockVaultV2Stack.sol";

/// @notice Verifies the CREATE2 deployer wires the registry atomically and that the config
///         structs decode JSON in the alphabetical key order Foundry serializes.
contract DeployTest is Test {
    GrowYieldDeployer internal deployer;
    MockUnderlying internal underlying;
    MockAavePool internal pool;
    MockMutableAaveDataProvider internal provider;

    bytes32 internal constant EXECUTOR_SALT = bytes32(uint256(1));
    bytes32 internal constant POLICY_SALT = bytes32(uint256(2));
    bytes32 internal constant REGISTRY_SALT = bytes32(uint256(3));
    bytes32 internal constant AAVE_SALT = bytes32(uint256(0x10));
    address internal constant RISK_GUARDIAN = address(0x1234);

    function setUp() public {
        deployer = new GrowYieldDeployer();
        underlying = new MockUnderlying();
        pool = new MockAavePool(underlying);
        provider = new MockMutableAaveDataProvider(address(underlying), address(pool.aToken()));
    }

    /// @dev Deploys executor + policy + adapter + registry in one call and asserts the executor
    ///      is wired to the predicted registry, using the same address precomputation the script
    ///      relies on. Front-run safety hinges on this being a single atomic transaction.
    function test_deployStack_wiresRegistryAtomically() public {
        bytes memory executorInit = abi.encodePacked(
            type(GrowYieldExecutor).creationCode, abi.encode(uint16(50), RISK_GUARDIAN)
        );
        address executorAddr =
            vm.computeCreate2Address(EXECUTOR_SALT, keccak256(executorInit), address(deployer));

        bytes memory adapterInit = abi.encodePacked(
            type(AaveV3Adapter).creationCode,
            abi.encode(address(pool), address(provider), address(underlying), executorAddr)
        );
        address adapterAddr =
            vm.computeCreate2Address(AAVE_SALT, keccak256(adapterInit), address(deployer));

        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](1);
        configs[0] = IGrowYieldAdapterRegistry.AdapterConfig(adapterAddr, true, true);
        bytes memory registryInit = abi.encodePacked(
            type(GrowYieldAdapterRegistry).creationCode, abi.encode(executorAddr, configs)
        );

        // requiredPaymaster only needs code; this test contract suffices.
        bytes memory policyInit = abi.encodePacked(
            type(GrowYieldPolicyModule).creationCode,
            abi.encode(
                executorAddr,
                address(this),
                uint128(500_000),
                uint128(2_000_000),
                uint256(150_000),
                uint128(200_000),
                uint128(200_000),
                uint128(2 gwei),
                uint128(2 gwei)
            )
        );

        bytes32[] memory adapterSalts = new bytes32[](1);
        adapterSalts[0] = AAVE_SALT;
        bytes[] memory adapterInits = new bytes[](1);
        adapterInits[0] = adapterInit;

        (address executor, address policyModule, address[] memory adapters, address registry) = deployer.deployStack(
            EXECUTOR_SALT,
            executorInit,
            POLICY_SALT,
            policyInit,
            adapterSalts,
            adapterInits,
            REGISTRY_SALT,
            registryInit
        );

        // Addresses land exactly where predicted.
        assertEq(executor, executorAddr, "executor addr");
        assertEq(adapters[0], adapterAddr, "adapter addr");
        assertGt(policyModule.code.length, 0, "policy deployed");

        // Registry wired into the executor, with the deployer as owner.
        assertEq(address(GrowYieldExecutor(executor).registry()), registry, "registry wired");
        assertEq(GrowYieldExecutor(executor).owner(), address(deployer), "owner");
        assertNotEq(
            GrowYieldExecutor(executor).owner(), CREATE2_FACTORY, "CREATE2 factory owns executor"
        );
        assertEq(GrowYieldExecutor(executor).riskGuardian(), RISK_GUARDIAN, "risk guardian");
        assertEq(GrowYieldPolicyModule(policyModule).executor(), executor, "policy executor");
        assertEq(GrowYieldAdapterRegistry(registry).executor(), executor, "registry executor");
        assertEq(IYieldAdapter(adapters[0]).executor(), executor, "adapter executor");
        assertTrue(GrowYieldAdapterRegistry(registry).canDeposit(adapterAddr), "adapter enabled");
    }

    /// @dev A second wiring attempt fails: the registry is one-time and set inside deployStack.
    function test_deployStack_executorOwnerIsDeployer() public {
        bytes memory executorInit = abi.encodePacked(
            type(GrowYieldExecutor).creationCode, abi.encode(uint16(50), RISK_GUARDIAN)
        );
        address executorAddr =
            vm.computeCreate2Address(EXECUTOR_SALT, keccak256(executorInit), address(deployer));

        bytes memory adapterInit = abi.encodePacked(
            type(AaveV3Adapter).creationCode,
            abi.encode(address(pool), address(provider), address(underlying), executorAddr)
        );
        address adapterAddr =
            vm.computeCreate2Address(AAVE_SALT, keccak256(adapterInit), address(deployer));

        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](1);
        configs[0] = IGrowYieldAdapterRegistry.AdapterConfig(adapterAddr, true, true);
        bytes memory registryInit = abi.encodePacked(
            type(GrowYieldAdapterRegistry).creationCode, abi.encode(executorAddr, configs)
        );
        bytes memory policyInit = abi.encodePacked(
            type(GrowYieldPolicyModule).creationCode,
            abi.encode(
                executorAddr,
                address(this),
                uint128(500_000),
                uint128(2_000_000),
                uint256(150_000),
                uint128(200_000),
                uint128(200_000),
                uint128(2 gwei),
                uint128(2 gwei)
            )
        );
        bytes32[] memory adapterSalts = new bytes32[](1);
        adapterSalts[0] = AAVE_SALT;
        bytes[] memory adapterInits = new bytes[](1);
        adapterInits[0] = adapterInit;

        (address executor,,, address registry) = deployer.deployStack(
            EXECUTOR_SALT,
            executorInit,
            POLICY_SALT,
            policyInit,
            adapterSalts,
            adapterInits,
            REGISTRY_SALT,
            registryInit
        );

        // The EOA (this test) is not the owner; only the deployer may initialize.
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        GrowYieldExecutor(executor).initializeRegistry(GrowYieldAdapterRegistry(registry));
    }

    // -------------------------------------------------------------------------
    // Config struct <-> JSON key-ordering guards
    // -------------------------------------------------------------------------

    function test_aaveCfgDecodesInKeyOrder() public pure {
        string memory json = "{" '"asset":"0x00000000000000000000000000000000000000A5",'
            '"canDeposit":true,' '"canRedeem":false,'
            '"dataProvider":"0x00000000000000000000000000000000000000D9",'
            '"pool":"0x0000000000000000000000000000000000000900",'
            '"salt":"0x0000000000000000000000000000000000000000000000000000000000000010"' "}";
        Deploy.AaveCfg memory c = abi.decode(vm.parseJson(json), (Deploy.AaveCfg));
        assertEq(c.asset, address(0xA5), "asset");
        assertTrue(c.canDeposit, "canDeposit");
        assertFalse(c.canRedeem, "canRedeem");
        assertEq(c.dataProvider, address(0xD9), "dataProvider");
        assertEq(c.pool, address(0x900), "pool");
        assertEq(c.salt, bytes32(uint256(0x10)), "salt");
    }

    function test_eulerEarnCfgDecodesInKeyOrder() public pure {
        string memory json = "{" '"canDeposit":true,' '"canRedeem":true,'
            '"childStrategy":"0x00000000000000000000000000000000000000C5",'
            '"eligibility":"0x0000000000000000000000000000000000000EA3",'
            '"factory":"0x0000000000000000000000000000000000000EA1",'
            '"salt":"0x0000000000000000000000000000000000000000000000000000000000000013",'
            '"vault":"0x0000000000000000000000000000000000000EA2"' "}";
        Deploy.EulerEarnCfg memory c = abi.decode(vm.parseJson(json), (Deploy.EulerEarnCfg));
        assertTrue(c.canDeposit, "canDeposit");
        assertTrue(c.canRedeem, "canRedeem");
        assertEq(c.childStrategy, address(0xC5), "childStrategy");
        assertEq(c.eligibility, address(0xEA3), "eligibility");
        assertEq(c.factory, address(0xEA1), "factory");
        assertEq(c.salt, bytes32(uint256(0x13)), "salt");
        assertEq(c.vault, address(0xEA2), "vault");
    }

    function test_eulerEVaultCfgDecodesInKeyOrder() public pure {
        string memory json = "{" '"canDeposit":true,' '"canRedeem":true,'
            '"eVault":"0x0000000000000000000000000000000000000E01",'
            '"factory":"0x0000000000000000000000000000000000000EA1",'
            '"salt":"0x0000000000000000000000000000000000000000000000000000000000000012"' "}";
        Deploy.EulerEVaultCfg memory c = abi.decode(vm.parseJson(json), (Deploy.EulerEVaultCfg));
        assertTrue(c.canDeposit, "canDeposit");
        assertTrue(c.canRedeem, "canRedeem");
        assertEq(c.eVault, address(0xE01), "eVault");
        assertEq(c.factory, address(0xEA1), "factory");
        assertEq(c.salt, bytes32(uint256(0x12)), "salt");
    }

    function test_capyFiCfgDecodesInKeyOrder() public pure {
        string memory json = "{" '"caToken":"0x00000000000000000000000000000000000000CA",'
            '"canDeposit":false,' '"canRedeem":true,'
            '"comptroller":"0x0000000000000000000000000000000000000C09",'
            '"salt":"0x0000000000000000000000000000000000000000000000000000000000000014"' "}";
        Deploy.CapyFiCfg memory c = abi.decode(vm.parseJson(json), (Deploy.CapyFiCfg));
        assertEq(c.caToken, address(0xCA), "caToken");
        assertFalse(c.canDeposit, "canDeposit");
        assertTrue(c.canRedeem, "canRedeem");
        assertEq(c.comptroller, address(0xC09), "comptroller");
        assertEq(c.salt, bytes32(uint256(0x14)), "salt");
    }
}
