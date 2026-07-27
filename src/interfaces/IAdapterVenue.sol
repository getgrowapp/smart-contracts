// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IAdapterVenue
/// @notice Protocol-wide infrastructure an adapter pins immutably, read by the registry at
///         admission to prove the adapter is wired to the registry's own registrars.
/// @dev Every field is protocol-wide, never per-venue; per-venue facts are read from the venue
///      itself, so the registry never trusts an adapter's account of a vault. Only the getters
///      belonging to the declared protocol are called — unrelated ones are absent on that adapter.
///      Every getter is `address`-shaped in the ABI even where the adapter declares a concrete
///      interface type.
interface IAdapterVenue {
    /// @notice Euler EVK / Euler Earn: the canonical factory that must have created the vault.
    function factory() external view returns (address);

    /// @notice Aave V3: the pool every reserve is supplied to and withdrawn from.
    function pool() external view returns (address);

    /// @notice Aave V3: the data provider used to resolve a reserve's aToken.
    function dataProvider() external view returns (address);

    /// @notice CapyFi: the Comptroller that must list the caToken market.
    function comptroller() external view returns (address);

    /// @notice Morpho: the eligibility oracle gating a wrapper's VaultV1 child.
    function eligibility() external view returns (address);
}
