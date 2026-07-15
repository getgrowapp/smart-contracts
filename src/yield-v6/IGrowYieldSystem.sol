// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGrowYieldTypes {
    enum Protocol {
        MORPHO,
        AAVE
    }

    struct Venue {
        address asset;
        address positionToken;
        bool canEnter;
        bool canExit;
    }
}

interface IGrowYieldRegistry is IGrowYieldTypes {
    function entryVenue(
        Protocol protocol,
        address target,
        address assetHint
    ) external view returns (Venue memory);

    function exitVenue(
        Protocol protocol,
        address target,
        address assetHint
    ) external view returns (Venue memory);
}

interface IGrowYieldExecutor is IGrowYieldTypes {
    function withdrawAll(
        Protocol protocol,
        address target,
        address assetHint
    ) external;

    function depositAll(
        Protocol protocol,
        address target,
        address asset
    ) external returns (uint256);
}
