// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Adapter for the external Morpho eligibility source Grow chooses to trust.
 *      Production implementation should be immutable or independently governed.
 */
interface IMorphoVaultEligibility {
    function isEligibleVault(address vault) external view returns (bool);
}
