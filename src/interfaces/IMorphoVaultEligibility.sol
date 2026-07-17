// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice External policy for eligible Morpho VaultV1 children.
interface IMorphoVaultEligibility {
    function isEligibleVault(address vault) external view returns (bool);
}
