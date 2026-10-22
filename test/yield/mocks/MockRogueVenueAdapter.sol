// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAdapterVenue} from "../../../src/interfaces/IAdapterVenue.sol";
import {IYieldAdapter} from "../../../src/interfaces/IYieldAdapter.sol";

/// @dev Reports fully attacker-chosen protocol wiring, asset, and position token while
///      authorizing a real executor. Registry admission must reject it on its own registrar
///      evidence, never on the adapter's self-report, so this mock stands in for an adapter a
///      compromised registry owner could deploy. Deposits and redemptions always revert.
contract MockRogueVenueAdapter is IYieldAdapter, IAdapterVenue {
    address public executor;
    address public factory;
    address public pool;
    address public dataProvider;
    address public comptroller;
    address public eligibility;
    address public market;
    address public child;
    address public liquidityAdapter;

    address private _asset;
    address private _positionToken;

    constructor(address executor_, address asset_, address positionToken_) {
        executor = executor_;
        _asset = asset_;
        _positionToken = positionToken_;
    }

    /// @dev Reports the same attacker-chosen pair for every venue queried.
    function asset(address) external view returns (address) {
        return _asset;
    }

    function positionToken(address) external view returns (address) {
        return _positionToken;
    }

    /// @notice The venue this mock claims, for tests that need it without a vault argument.
    function claimedVault() external view returns (address) {
        return _positionToken;
    }

    function setAave(address pool_, address dataProvider_) external {
        pool = pool_;
        dataProvider = dataProvider_;
    }

    function setFactory(address factory_) external {
        factory = factory_;
    }

    function setComptroller(address comptroller_) external {
        comptroller = comptroller_;
    }

    function setMorpho(address eligibility_, address child_, address liquidityAdapter_) external {
        eligibility = eligibility_;
        child = child_;
        liquidityAdapter = liquidityAdapter_;
    }

    function previewDeposit(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function previewRedeem(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function deposit(address, uint256, address) external pure returns (uint256) {
        revert("rogue");
    }

    function redeem(address, uint256, address) external pure returns (uint256) {
        revert("rogue");
    }
}
