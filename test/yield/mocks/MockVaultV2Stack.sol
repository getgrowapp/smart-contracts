// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAaveProtocolDataProvider} from "../../../src/interfaces/IAaveProtocolDataProvider.sol";
import {IMorphoVaultEligibility} from "../../../src/interfaces/IMorphoVaultEligibility.sol";

/// @dev Minimal VaultV2Factory stand-in with a settable registry.
contract MockVaultV2Factory {
    mapping(address => bool) public isVaultV2;

    function set(address vault, bool enabled) external {
        isVaultV2[vault] = enabled;
    }
}

/// @dev Settable eligibility oracle.
contract MockEligibility is IMorphoVaultEligibility {
    mapping(address => bool) public isEligibleVault;

    function set(address vault, bool eligible) external {
        isEligibleVault[vault] = eligible;
    }
}

/// @dev MorphoVaultV1Adapter stand-in: static wiring returned to the venue adapter.
contract MockMorphoV1Adapter {
    address public immutable factory;
    address public immutable parentVault;
    address public immutable morphoVaultV1;

    constructor(address factory_, address parentVault_, address morphoVaultV1_) {
        factory = factory_;
        parentVault = parentVault_;
        morphoVaultV1 = morphoVaultV1_;
    }
}

/// @dev Registry-backed stand-in for MorphoVaultV1AdapterFactory.
contract MockMorphoV1AdapterFactory {
    mapping(address adapter => bool) public isMorphoVaultV1Adapter;

    function create(address parentVault, address child) external returns (address adapter) {
        adapter = address(new MockMorphoV1Adapter(address(this), parentVault, child));
        isMorphoVaultV1Adapter[adapter] = true;
    }
}

/// @dev Deployed caller used to satisfy the policy signer's module-code check.
contract MockValidationModule {}

/// @dev ERC-4626 vault exposing the IVaultV2 surface MorphoVaultV2Adapter validates,
///      with configurable deposit loss and liquidity-routing drift.
contract MockVaultV2 is ERC4626 {
    address[] private _adapters;
    mapping(address => bool) public isAdapter;
    address public liquidityAdapter;
    bytes private _liquidityData;
    mapping(bytes4 => bool) public abdicated;
    mapping(bytes4 selector => mapping(address account => bool)) public blockedByGate;

    uint256 public haircutBps;

    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    {}

    // --- test wiring ---

    function addMockAdapter(address adapter) external {
        _adapters.push(adapter);
        isAdapter[adapter] = true;
        liquidityAdapter = adapter;
    }

    function setLiquidityAdapter(address adapter) external {
        liquidityAdapter = adapter;
    }

    function setLiquidityData(bytes calldata data) external {
        _liquidityData = data;
    }

    function setAbdicated(bytes4 selector, bool value) external {
        abdicated[selector] = value;
    }

    function setHaircutBps(uint256 bps) external {
        haircutBps = bps;
    }

    function setGateBlocked(bytes4 selector, address account, bool blocked) external {
        blockedByGate[selector][account] = blocked;
    }

    // --- IVaultV2 surface used by MorphoVaultV2Adapter ---

    function adaptersLength() external view returns (uint256) {
        return _adapters.length;
    }

    function adapters(uint256 index) external view returns (address) {
        return _adapters[index];
    }

    function liquidityData() external view returns (bytes memory) {
        return _liquidityData;
    }

    function canSendShares(address account) external view returns (bool) {
        return !blockedByGate[this.canSendShares.selector][account];
    }

    function canReceiveShares(address account) external view returns (bool) {
        return !blockedByGate[this.canReceiveShares.selector][account];
    }

    function canSendAssets(address account) external view returns (bool) {
        return !blockedByGate[this.canSendAssets.selector][account];
    }

    function canReceiveAssets(address account) external view returns (bool) {
        return !blockedByGate[this.canReceiveAssets.selector][account];
    }

    // --- fault injection ---

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = (previewDeposit(assets) * (10_000 - haircutBps)) / 10_000;
        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }
}

/// @dev Multi-reserve data provider with re-pointable aTokens, for reserve-drift tests.
///      `asset`/`aToken` name the reserve given at construction.
contract MockMutableAaveDataProvider is IAaveProtocolDataProvider {
    address public asset;

    mapping(address asset => address aToken) public reserves;

    constructor(address asset_, address aToken_) {
        asset = asset_;
        reserves[asset_] = aToken_;
    }

    function aToken() external view returns (address) {
        return reserves[asset];
    }

    function setAToken(address aToken_) external {
        reserves[asset] = aToken_;
    }

    function setReserve(address asset_, address aToken_) external {
        reserves[asset_] = aToken_;
    }

    function getReserveTokensAddresses(address queried)
        external
        view
        returns (address, address, address)
    {
        return (reserves[queried], address(0), address(0));
    }
}

/// @dev Fee-on-transfer token: skims `feeBps` on every transfer/transferFrom.
contract MockFeeToken is ERC20 {
    uint256 public constant FEE_BPS = 100;

    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, address(0xFEE), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
