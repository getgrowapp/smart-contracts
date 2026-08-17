// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IMorphoVaultEligibility} from "./interfaces/IMorphoVaultEligibility.sol";

/// @title MorphoVaultEligibility
/// @notice Ownable allowlist for Morpho VaultV1 children admitted into GrowYield Morpho venues.
/// @dev Owner should be a Safe or TimelockController. Only eligible children pass registry
///      admission (`GrowYieldAdapterRegistry._requireCanonicalMorpho`).
/// @custom:security-contact security@getgrowapp.co
contract MorphoVaultEligibility is Ownable2Step, IMorphoVaultEligibility {
    mapping(address vault => bool) private _eligible;

    error Invalid();

    /// @param owner_ Governance address authorized to update the allowlist.
    /// @param initialChildren_ VaultV1 children marked eligible at deploy time (immutable bootstrap).
    constructor(address owner_, address[] memory initialChildren_) Ownable(owner_) {
        if (owner_ == address(0)) revert Invalid();
        uint256 count = initialChildren_.length;
        for (uint256 i; i < count; ++i) {
            address child = initialChildren_[i];
            if (child == address(0)) revert Invalid();
            _eligible[child] = true;
            emit EligibilityUpdated(child, true);
        }
    }

    /// @notice Marks `vault` as eligible or ineligible for Grow Morpho venue admission.
    function setEligible(address vault, bool enabled) external onlyOwner {
        if (vault == address(0)) revert Invalid();
        _eligible[vault] = enabled;
        emit EligibilityUpdated(vault, enabled);
    }

    /// @inheritdoc IMorphoVaultEligibility
    function isEligibleVault(address vault) external view returns (bool) {
        return _eligible[vault];
    }

    event EligibilityUpdated(address indexed vault, bool enabled);
}
