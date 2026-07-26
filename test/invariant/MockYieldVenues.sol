// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
///      Like the real pool it serves many reserves; `underlying`/`aToken` name the first.
contract MockAavePool is IAaveV3Pool {
    using SafeERC20 for IERC20;

    MockUnderlying public immutable underlying;
    MockAToken public immutable aToken;

    mapping(address asset => MockAToken) public aTokens;

    constructor(MockUnderlying underlying_) {
        underlying = underlying_;
        aToken = new MockAToken(address(this), address(underlying_));
        aTokens[address(underlying_)] = aToken;
    }

    /// @dev Lists an additional reserve so one pool can back several adapters.
    function addReserve(MockUnderlying asset_) external returns (MockAToken token) {
        token = new MockAToken(address(this), address(asset_));
        aTokens[address(asset_)] = token;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        MockAToken token = aTokens[asset];
        require(address(token) != address(0), "asset");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        token.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to)
        external
        override
        returns (uint256)
    {
        MockAToken token = aTokens[asset];
        require(address(token) != address(0), "asset");
        // Real Aave V3 treats uint256.max as "full balance of msg.sender".
        if (amount == type(uint256).max) amount = token.balanceOf(msg.sender);
        token.burn(msg.sender, amount);
        IERC20(asset).safeTransfer(to, amount);
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
