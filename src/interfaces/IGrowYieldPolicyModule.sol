// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    IValidationModule
} from "@erc6900/reference-implementation/interfaces/IValidationModule.sol";

/// @title IGrowYieldPolicyModule
/// @notice ERC-6900 validation module for policy-owner-authorized yield operations.
interface IGrowYieldPolicyModule is IValidationModule {
    /// @notice Emitted when an account authorizes a policy owner.
    event OwnerAdded(address indexed account, address indexed owner);

    /// @notice Emitted when an account revokes a policy owner.
    event OwnerRemoved(address indexed account, address indexed owner);

    /// @notice Emitted when an account sets the single executor its policy batches may call.
    event ExecutorSet(address indexed account, address indexed executor);

    /// @notice Emitted when an account sets the paymaster it accepts as its sponsor.
    event PaymasterSet(address indexed account, address indexed paymaster);

    /// @notice The owner set, executor, or constructor policy is invalid.
    error InvalidConfiguration();

    /// @notice The owner is already authorized for the calling account.
    error OwnerAlreadyExists();

    /// @notice The owner is not authorized for the calling account.
    error OwnerNotFound();

    /// @notice The account already has the maximum number of policy owners.
    error TooManyOwners();

    /// @notice The calling account has not configured a nonzero Grow validation entity.
    error PolicyNotInstalled();

    /// @notice The calling account already has a Grow validation entity configured.
    error PolicyAlreadyInstalled();

    /// @notice Add an ECDSA policy owner for the calling account.
    /// @dev A modular account should call this through its owner-authorized execution path.
    function addOwner(address owner) external;

    /// @notice Remove an ECDSA policy owner from the calling account.
    /// @dev Removing the last owner disables this validation until another is added.
    function removeOwner(address owner) external;

    /// @notice Return whether `owner` is authorized for `account`.
    function isOwner(address account, address owner) external view returns (bool);

    /// @notice Return the number of policy owners authorized for `account`.
    function ownerCount(address account) external view returns (uint8);

    /// @notice Return one policy owner authorized for `account`.
    function ownerAt(address account, uint256 index) external view returns (address);

    /// @notice Return the account-selected validation entity for this module.
    function policyEntityId(address account) external view returns (uint32);

    /// @notice Replace the single yield executor the calling account's policy batches may call.
    /// @dev Owner-authorized execution path only: the calldata policy accepts no batch containing
    ///      this call, so a policy owner (session key) can never reach it. Replacement has no
    ///      overlap — batches targeting the previous executor stop validating the moment this
    ///      returns, so exit positions opened through it first.
    function setExecutor(address executor) external;

    /// @notice Yield executor `account` approved; zero until the account installs the policy.
    function accountExecutor(address account) external view returns (address);

    /// @notice Replace the paymaster the calling account accepts as sponsor for policy
    ///         UserOperations.
    /// @dev Owner path only, like `setExecutor`. Per-account rather than a protocol-wide immutable
    ///      so rotating a sponsor is one signature, and one depleted sponsor cannot halt everyone.
    function setPaymaster(address paymaster) external;

    /// @notice Paymaster `account` accepts as its sponsor; zero until the policy is installed.
    function accountPaymaster(address account) external view returns (address);

    /// @notice Maximum account verification gas accepted by the policy.
    function maxVerificationGas() external view returns (uint128);

    /// @notice Maximum account call gas accepted by the policy.
    function maxCallGas() external view returns (uint128);

    /// @notice Maximum pre-verification gas accepted by the policy.
    function maxPreVerificationGas() external view returns (uint256);

    /// @notice Maximum paymaster verification gas accepted by the policy.
    function maxPaymasterVerificationGas() external view returns (uint128);

    /// @notice Maximum paymaster post-operation gas accepted by the policy.
    function maxPaymasterPostOpGas() external view returns (uint128);

    /// @notice Maximum priority fee accepted by the policy.
    function maxPriorityFeePerGas() external view returns (uint128);

    /// @notice Maximum total fee accepted by the policy.
    function maxFeePerGas() external view returns (uint128);
}
