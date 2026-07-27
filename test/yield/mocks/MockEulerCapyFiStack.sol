// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICapyFiCaToken} from "../../../src/interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../../../src/interfaces/ICapyFiComptroller.sol";
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

    function setVault(address vault, bool enabled) external {
        isVault[vault] = enabled;
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

    // Compound accrual surface. Dormant by default (no borrows), so the stored rate is exact
    // until a test opts in with `setBorrowState`.
    uint256 public accrualBlockNumber = block.number;
    uint256 public borrowRatePerBlock;
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public reserveFactorMantissa;
    uint256 public cash;
    address public underlyingOverride;
    bool public useUnderlyingOverride;
    address public comptrollerOverride;
    bool public useComptrollerOverride;

    constructor(address comptroller_, address underlying_) ERC20("Mock caToken", "caMOCK") {
        _comptroller = comptroller_;
        _underlying = underlying_;
    }

    /// @dev Switches the market into a borrowing state so interest actually accrues, and pins
    ///      `cash`/`totalSupply` so `exchangeRateStored` derives from Compound's own formula.
    function setBorrowState(
        uint256 cash_,
        uint256 borrows_,
        uint256 ratePerBlock,
        uint256 reserveFactor
    ) external {
        cash = cash_;
        totalBorrows = borrows_;
        borrowRatePerBlock = ratePerBlock;
        reserveFactorMantissa = reserveFactor;
        accrualBlockNumber = block.number;
        _syncRate();
    }

    function getCash() external view returns (uint256) {
        return cash;
    }

    /// @dev Compound's `accrueInterest`, run for real so `mint` and `redeem` use the accrued
    ///      rate while `exchangeRateStored` stays behind until something touches the market.
    function accrueInterest() public {
        uint256 blocks = block.number - accrualBlockNumber;
        if (blocks == 0 || totalBorrows == 0) return;

        uint256 interest = Math.mulDiv(borrowRatePerBlock * blocks, totalBorrows, 1e18);
        totalBorrows += interest;
        totalReserves += Math.mulDiv(reserveFactorMantissa, interest, 1e18);
        accrualBlockNumber = block.number;
        _syncRate();
    }

    function _syncRate() private {
        if (totalSupply() == 0 || cash == 0) return;
        exchangeRateStored = Math.mulDiv(cash + totalBorrows - totalReserves, 1e18, totalSupply());
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
        accrueInterest(); // Compound accrues before quoting, which is the whole point.
        IERC20(_underlying).safeTransferFrom(msg.sender, address(this), mintAmount);
        uint256 shares = Math.mulDiv(mintAmount, 1e18, exchangeRateStored);
        _mint(msg.sender, shares);
        return 0;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        if (redeemErrorCode != 0) return redeemErrorCode;
        accrueInterest();
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
