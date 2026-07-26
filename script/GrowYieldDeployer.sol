// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IGrowYieldAdapterRegistry} from "../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IGrowYieldPolicyModule} from "../src/interfaces/IGrowYieldPolicyModule.sol";
import {IYieldAdapter} from "../src/interfaces/IYieldAdapter.sol";

/// @title GrowYieldDeployer
/// @notice Deterministic CREATE2 deployer for the GrowYield stack.
/// @dev Deployed once at a chain-independent address. As the registry's constructor-declared
///      owner it admits the initial vault set and hands ownership to governance in the same
///      transaction — no window in which a foreign party owns the registry. It cannot admit
///      vaults later: `deployStack` is its only function and CREATE2 fails once the stack
///      addresses are occupied.
///      Pending `deployStack` calldata can be front-run to occupy the target addresses;
///      deploy from a private endpoint, or redeploy with fresh salts if taken.
/// @custom:security-contact security@getgrowapp.co
contract GrowYieldDeployer {
    /// @notice Full stack deployment plan.
    /// @param executorSalt CREATE2 salt for the executor.
    /// @param executorInit Executor init code (creation code + abi-encoded constructor args).
    /// @param policySalt CREATE2 salt for the policy module.
    /// @param policyInit Policy module init code.
    /// @param adapterSalts CREATE2 salts, one per adapter, aligned with `adapterInits`.
    /// @param adapterInits Adapter init codes.
    /// @param registrySalt CREATE2 salt for the registry.
    /// @param registryInit Registry init code; must declare this deployer as the initial owner.
    /// @param vaults Initial venue set admitted before ownership is handed over.
    /// @param registryOwner Governance address offered registry ownership; must accept it.
    struct StackParams {
        bytes32 executorSalt;
        bytes executorInit;
        bytes32 policySalt;
        bytes policyInit;
        bytes32[] adapterSalts;
        bytes[] adapterInits;
        bytes32 registrySalt;
        bytes registryInit;
        IGrowYieldAdapterRegistry.VaultConfig[] vaults;
        address registryOwner;
    }

    /// @notice A CREATE2 deployment returned the zero address or produced no code.
    error DeploymentFailed();

    /// @notice A deployed contract granted authority to an unexpected address.
    error InvalidAuthority();

    /// @notice A configured venue is absent from the registry after admission.
    error VaultNotAdmitted();

    /// @notice Atomically deploys the full stack, admits the initial venues, and offers
    ///         registry ownership to governance.
    /// @param params Deployment plan; see `StackParams`.
    /// @return executor Deployed executor address.
    /// @return policyModule Deployed policy module address.
    /// @return adapters Deployed adapter addresses, aligned with `params.adapterInits`.
    /// @return registry Deployed registry address, holding the initial venue set.
    function deployStack(StackParams calldata params)
        external
        returns (
            address executor,
            address policyModule,
            address[] memory adapters,
            address registry
        )
    {
        // Governance must be able to accept ownership later; this deployer never can, because
        // it has no path back into `addVaults` once the stack addresses are occupied.
        if (params.registryOwner == address(0) || params.registryOwner == address(this)) {
            revert InvalidAuthority();
        }

        executor = _create2(params.executorSalt, params.executorInit);

        policyModule = _create2(params.policySalt, params.policyInit);
        if (IGrowYieldPolicyModule(policyModule).executor() != executor) {
            revert InvalidAuthority();
        }

        adapters = new address[](params.adapterInits.length);
        for (uint256 i; i < params.adapterInits.length; ++i) {
            adapters[i] = _create2(params.adapterSalts[i], params.adapterInits[i]);
            if (IYieldAdapter(adapters[i]).executor() != executor) revert InvalidAuthority();
        }

        registry = _create2(params.registrySalt, params.registryInit);
        if (IGrowYieldAdapterRegistry(registry).executor() != executor) {
            revert InvalidAuthority();
        }
        if (Ownable2Step(registry).owner() != address(this)) revert InvalidAuthority();

        IGrowYieldAdapterRegistry(registry).addVaults(params.vaults);
        for (uint256 i; i < params.vaults.length; ++i) {
            if (
                IGrowYieldAdapterRegistry(registry).vaultAdapter(params.vaults[i].vault)
                    != params.vaults[i].adapter
            ) revert VaultNotAdmitted();
        }

        Ownable2Step(registry).transferOwnership(params.registryOwner);
        if (Ownable2Step(registry).pendingOwner() != params.registryOwner) {
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
