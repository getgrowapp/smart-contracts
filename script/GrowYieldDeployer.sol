// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IGrowYieldExecutor} from "../src/interfaces/IGrowYieldExecutor.sol";
import {IGrowYieldAdapterRegistry} from "../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IGrowYieldPolicyModule} from "../src/interfaces/IGrowYieldPolicyModule.sol";
import {IYieldAdapter} from "../src/interfaces/IYieldAdapter.sol";

/// @title GrowYieldDeployer
/// @author 0xOsiris, Grow
/// @notice Deterministic CREATE2 deployer for the GrowYield stack.
/// @dev Deployed once at a chain-independent address. As the executor's CREATE2 caller it
///      becomes the executor's owner, so `deployStack` deploys the full stack and wires
///      the registry in one transaction — no window for a foreign registry.
///      Pending `deployStack` calldata can be front-run to occupy the target addresses;
///      deploy from a private endpoint, or redeploy with fresh salts if taken.
contract GrowYieldDeployer {
    /// @notice A CREATE2 deployment returned the zero address or produced no code.
    error DeploymentFailed();

    /// @notice A deployed contract granted authority to an unexpected address.
    error InvalidAuthority();

    /// @notice Atomically deploys the full stack and wires the registry into the executor.
    /// @param executorSalt CREATE2 salt for the executor.
    /// @param executorInit Executor init code (creation code + abi-encoded constructor args).
    /// @param policySalt   CREATE2 salt for the policy module.
    /// @param policyInit   Policy module init code.
    /// @param adapterSalts CREATE2 salts, one per adapter, aligned with `adapterInits`.
    /// @param adapterInits Adapter init codes.
    /// @param registrySalt CREATE2 salt for the registry.
    /// @param registryInit Registry init code (already encodes the executor + adapter set).
    /// @return executor     Deployed executor address.
    /// @return policyModule Deployed policy module address.
    /// @return adapters     Deployed adapter addresses, aligned with `adapterInits`.
    /// @return registry     Deployed registry address (wired into the executor).
    function deployStack(
        bytes32 executorSalt,
        bytes memory executorInit,
        bytes32 policySalt,
        bytes memory policyInit,
        bytes32[] calldata adapterSalts,
        bytes[] calldata adapterInits,
        bytes32 registrySalt,
        bytes memory registryInit
    )
        external
        returns (
            address executor,
            address policyModule,
            address[] memory adapters,
            address registry
        )
    {
        // Executor first: this contract is the CREATE2 caller, so it owns the executor
        // and may perform the one-time registry wiring below.
        executor = _create2(executorSalt, executorInit);
        if (Ownable(executor).owner() != address(this)) {
            revert InvalidAuthority();
        }

        policyModule = _create2(policySalt, policyInit);
        if (IGrowYieldPolicyModule(policyModule).executor() != executor) {
            revert InvalidAuthority();
        }

        adapters = new address[](adapterInits.length);
        for (uint256 i; i < adapterInits.length; ++i) {
            adapters[i] = _create2(adapterSalts[i], adapterInits[i]);
            if (IYieldAdapter(adapters[i]).executor() != executor) revert InvalidAuthority();
        }

        registry = _create2(registrySalt, registryInit);
        if (IGrowYieldAdapterRegistry(registry).executor() != executor) {
            revert InvalidAuthority();
        }

        // Same transaction as the deployments above: no window for a foreign registry.
        IGrowYieldExecutor(executor).initializeRegistry(IGrowYieldAdapterRegistry(registry));
        if (address(IGrowYieldExecutor(executor).registry()) != registry) {
            revert InvalidAuthority();
        }
    }

    /// @dev Deploys `initCode` with CREATE2 and reverts unless code lands at the address.
    function _create2(bytes32 salt, bytes memory initCode) internal returns (address addr) {
        assembly {
            addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (addr == address(0) || addr.code.length == 0) revert DeploymentFailed();
    }
}
