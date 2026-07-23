// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICapyFiCaToken} from "../../../src/interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../../../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarn} from "../../../src/interfaces/IEulerEarn.sol";
import {IEulerEarnFactory} from "../../../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../../../src/interfaces/IEulerEVaultFactory.sol";
import {MockUnderlying} from "../../invariant/MockYieldVenues.sol";

/// @dev Settable EVK GenericFactory authenticity oracle.
contract MockEulerEVaultFactory is IEulerEVaultFactory {
    mapping(address => bool) public isProxy;

    function setProxy(address proxy, bool enabled) external {
        isProxy[proxy] = enabled;
    }
}

/// @dev Settable EulerEarnFactory authenticity oracle.
contract MockEulerEarnFactory is IEulerEarnFactory {
    mapping(address => bool) public isVault;
    mapping(address => bool) public isStrategyAllowed;

    function setVault(address vault, bool enabled) external {
        isVault[vault] = enabled;
    }

    function setStrategyAllowed(address strategy, bool allowed) external {
        isStrategyAllowed[strategy] = allowed;
    }
}

/// @dev ERC-4626 vault with optional asset override for drift tests.
contract MockEulerVault is ERC4626 {
    address public assetOverride;
    bool public useAssetOverride;

    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {}

    function setAssetOverride(address asset_) external {
        assetOverride = asset_;
        useAssetOverride = true;
    }

    function asset() public view override returns (address) {
        if (useAssetOverride) return assetOverride;
        return super.asset();
    }
}

/// @dev Euler Earn vault mock with configurable governance lock and routing queues.
contract MockEulerEarnVault is MockEulerVault, IEulerEarn {
    address public owner;
    address public pendingOwner;
    address public curator;
    IERC4626 public immutable pinnedChild;
    IERC4626[] internal _supplyQueue;
    IERC4626[] internal _withdrawQueue;
    mapping(IERC4626 => MarketConfig) internal _config;

    constructor(IERC20 asset_, IERC4626 child_, string memory name_, string memory symbol_)
        MockEulerVault(asset_, name_, symbol_)
    {
        pinnedChild = child_;
        _supplyQueue.push(child_);
        _withdrawQueue.push(child_);
        _config[child_] = MarketConfig({
            balance: 0,
            cap: type(uint136).max,
            enabled: true,
            removableAt: 0
        });
        _setLocked(true);
    }

    function _setLocked(bool locked) internal {
        owner = locked ? address(0) : msg.sender;
        pendingOwner = address(0);
        curator = address(0);
    }

    function setUnlocked() external {
        _setLocked(false);
    }

    function setPendingOwner(address pendingOwner_) external {
        pendingOwner = pendingOwner_;
    }

    function setCurator(address curator_) external {
        curator = curator_;
    }

    function setChildEnabled(bool enabled) external {
        _config[pinnedChild].enabled = enabled;
    }

    function setSupplyQueueHead(IERC4626 head) external {
        if (_supplyQueue.length == 0) {
            _supplyQueue.push(head);
        } else {
            _supplyQueue[0] = head;
        }
    }

    function setWithdrawQueueHead(IERC4626 head) external {
        if (_withdrawQueue.length == 0) {
            _withdrawQueue.push(head);
        } else {
            _withdrawQueue[0] = head;
        }
    }

    function supplyQueueLength() external view returns (uint256) {
        return _supplyQueue.length;
    }

    function supplyQueue(uint256 index) external view returns (IERC4626) {
        return _supplyQueue[index];
    }

    function withdrawQueueLength() external view returns (uint256) {
        return _withdrawQueue.length;
    }

    function withdrawQueue(uint256 index) external view returns (IERC4626) {
        return _withdrawQueue[index];
    }

    function config(IERC4626 id) external view returns (MarketConfig memory) {
        return _config[id];
    }
}

/// @dev Mutable Comptroller listing table.
contract MockCapyFiComptroller is ICapyFiComptroller {
    mapping(address => bool) public listed;

    function setListed(address caToken, bool isListed_) external {
        listed[caToken] = isListed_;
    }

    function markets(address caToken)
        external
        view
        returns (bool isListed, uint256 collateralFactorMantissa, bool isComped)
    {
        return (listed[caToken], 0, false);
    }
}

/// @dev Compound-v2-style caToken with configurable error codes.
contract MockCapyFiCaToken is ERC20, ICapyFiCaToken {
    using SafeERC20 for IERC20;

    address private _comptroller;
    address private immutable _underlying;
    uint256 public exchangeRateStored = 2e16; // 0.02 underlying per caToken
    uint256 public mintErrorCode;
    uint256 public redeemErrorCode;
    address public underlyingOverride;
    bool public useUnderlyingOverride;
    address public comptrollerOverride;
    bool public useComptrollerOverride;

    constructor(address comptroller_, address underlying_) ERC20("Mock caToken", "caMOCK") {
        _comptroller = comptroller_;
        _underlying = underlying_;
    }

    function setMintErrorCode(uint256 code) external {
        mintErrorCode = code;
    }

    function setRedeemErrorCode(uint256 code) external {
        redeemErrorCode = code;
    }

    function setUnderlyingOverride(address underlying_) external {
        underlyingOverride = underlying_;
        useUnderlyingOverride = true;
    }

    function setComptrollerOverride(address comptroller_) external {
        comptrollerOverride = comptroller_;
        useComptrollerOverride = true;
    }

    function comptroller() external view returns (address) {
        if (useComptrollerOverride) return comptrollerOverride;
        return _comptroller;
    }

    function underlying() external view returns (address) {
        if (useUnderlyingOverride) return underlyingOverride;
        return _underlying;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        if (mintErrorCode != 0) return mintErrorCode;
        IERC20(_underlying).safeTransferFrom(msg.sender, address(this), mintAmount);
        uint256 shares = Math.mulDiv(mintAmount, 1e18, exchangeRateStored);
        _mint(msg.sender, shares);
        return 0;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        if (redeemErrorCode != 0) return redeemErrorCode;
        uint256 assets = Math.mulDiv(redeemTokens, exchangeRateStored, 1e18);
        _burn(msg.sender, redeemTokens);
        IERC20(_underlying).safeTransfer(msg.sender, assets);
        return 0;
    }

    /// @dev Seed caTokens without going through mint (donation / balance setup).
    function mintShares(address to, uint256 shares) external {
        _mint(to, shares);
    }
}

/// @dev Convenience deployer for CapyFi mock markets backed by MockUnderlying.
contract MockCapyFiMarket {
    MockCapyFiComptroller public immutable comptroller;
    MockCapyFiCaToken public immutable caToken;
    MockUnderlying public immutable asset;

    constructor(MockUnderlying asset_) {
        asset = asset_;
        comptroller = new MockCapyFiComptroller();
        caToken = new MockCapyFiCaToken(address(comptroller), address(asset_));
        comptroller.setListed(address(caToken), true);
        // Fund the market so redemptions have liquidity.
        asset_.mint(address(caToken), 1_000_000_000e6);
    }
}
