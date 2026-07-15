// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IGrowYieldRegistry,
    IGrowYieldTypes
} from "../../src/yield-v6/IGrowYieldSystem.sol";

/// @dev Controllable registry for yield-1271 unit / invariant tests.
contract MockGrowYieldRegistry1271 is IGrowYieldRegistry {
    mapping(bytes32 => Venue) public entries;
    mapping(bytes32 => Venue) public exits;

    error Unknown();

    function setEntry(
        Protocol protocol,
        address target,
        address assetHint,
        Venue memory venue
    ) external {
        entries[_key(protocol, target, assetHint)] = venue;
    }

    function setExit(
        Protocol protocol,
        address target,
        address assetHint,
        Venue memory venue
    ) external {
        exits[_key(protocol, target, assetHint)] = venue;
    }

    function entryVenue(
        Protocol protocol,
        address target,
        address assetHint
    ) external view returns (Venue memory venue) {
        venue = entries[_key(protocol, target, assetHint)];
        if (!venue.canEnter || venue.asset == address(0)) revert Unknown();
    }

    function exitVenue(
        Protocol protocol,
        address target,
        address assetHint
    ) external view returns (Venue memory venue) {
        venue = exits[_key(protocol, target, assetHint)];
        if (!venue.canExit || venue.positionToken == address(0)) revert Unknown();
    }

    function _key(
        Protocol protocol,
        address target,
        address assetHint
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(protocol, target, assetHint));
    }
}
