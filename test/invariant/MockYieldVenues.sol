// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";

contract MockUnderlying is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVault is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {}
}

/// @dev Minimal aToken that the mock pool can mint/burn.
contract MockAToken is ERC20 {
    address public immutable pool;
    address public immutable underlying;

    error OnlyPool();

    constructor(address pool_, address underlying_) ERC20("Mock aToken", "maUSD") {
        pool = pool_;
        underlying = underlying_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != pool) revert OnlyPool();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != pool) revert OnlyPool();
        _burn(from, amount);
    }
}

/// @dev Aave-like pool for invariant testing. aTokens mint 1:1 with underlying.
contract MockAavePool is IAaveV3Pool {
    MockUnderlying public immutable underlying;
    MockAToken public immutable aToken;

    constructor(MockUnderlying underlying_) {
        underlying = underlying_;
        aToken = new MockAToken(address(this), address(underlying_));
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        require(asset == address(underlying), "asset");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to)
        external
        override
        returns (uint256)
    {
        require(asset == address(underlying), "asset");
        // Real Aave V3 treats uint256.max as "full balance of msg.sender".
        if (amount == type(uint256).max) amount = aToken.balanceOf(msg.sender);
        aToken.burn(msg.sender, amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }
}

contract MockAaveDataProvider is IAaveProtocolDataProvider {
    address public immutable aToken;
    address public immutable asset;

    constructor(address asset_, address aToken_) {
        asset = asset_;
        aToken = aToken_;
    }

    function getReserveTokensAddresses(address queried)
        external
        view
        returns (address, address, address)
    {
        require(queried == asset, "unknown");
        return (aToken, address(0), address(0));
    }
}
