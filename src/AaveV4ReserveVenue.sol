// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title AaveV4ReserveVenue
/// @notice Immutable id for one Aave V4 reserve. The executor keys venues by address, and a spoke
///         has no position token, so each (spoke, reserveId) is a contract deployed by the
///         registry. Immutables are the whole state: a later market is another deployment.
/// @custom:security-contact security@getgrowapp.co
contract AaveV4ReserveVenue {
    /// @notice Spoke that lists this reserve.
    address public immutable spoke;

    /// @notice Reserve id on `spoke`.
    uint256 public immutable reserveId;

    error Invalid();

    /// @param spoke_ Spoke that lists the reserve. Must already be deployed.
    /// @param reserveId_ Reserve id on that spoke.
    constructor(address spoke_, uint256 reserveId_) {
        if (spoke_.code.length == 0) revert Invalid();
        spoke = spoke_;
        reserveId = reserveId_;
    }
}
