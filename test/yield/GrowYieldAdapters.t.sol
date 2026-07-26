// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {GrowYieldTestBase} from "./GrowYieldTestBase.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {AbstractEulerAdapter} from "../../src/adapters/AbstractEulerAdapter.sol";
import {CapyFiAdapter} from "../../src/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../../src/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../../src/adapters/EulerEVaultAdapter.sol";
import {MorphoVaultV2Adapter} from "../../src/adapters/MorphoVaultV2Adapter.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {ICapyFiComptroller} from "../../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "../../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../../src/interfaces/IEulerEVaultFactory.sol";
import {IMorphoVaultEligibility} from "../../src/interfaces/IMorphoVaultEligibility.sol";
import {OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {MockAToken, MockUnderlying} from "../invariant/MockYieldVenues.sol";

/// @notice Adapter construction and venue-agnostic runtime behaviour.
/// @dev Each adapter now serves every venue of its protocol, so it pins only protocol-wide
///      infrastructure. Whether a specific venue may be used is the registry's decision and is
///      covered by `GrowYieldRegistryAdmission.t.sol`.
contract GrowYieldAdaptersTest is GrowYieldTestBase {
    function setUp() public {
        _setUpBase();
    }

    // -------------------------------------------------------------------------
    // Construction: only protocol-wide infrastructure is pinned
    // -------------------------------------------------------------------------

    function test_aave_rejectsZeroArgs() public {
        vm.expectRevert(AaveV3Adapter.Invalid.selector);
        new AaveV3Adapter(
            IAaveV3Pool(address(0)),
            IAaveProtocolDataProvider(address(aaveDataProvider)),
            address(executor)
        );

        vm.expectRevert(AaveV3Adapter.Invalid.selector);
        new AaveV3Adapter(
            IAaveV3Pool(address(aavePool)), IAaveProtocolDataProvider(address(0)), address(executor)
        );

        vm.expectRevert(AaveV3Adapter.Invalid.selector);
        new AaveV3Adapter(
            IAaveV3Pool(address(aavePool)),
            IAaveProtocolDataProvider(address(aaveDataProvider)),
            makeAddr("eoaExecutor")
        );
    }

    function test_morpho_rejectsZeroArgs() public {
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        new MorphoVaultV2Adapter(IMorphoVaultEligibility(address(0)), address(executor));

        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        new MorphoVaultV2Adapter(
            IMorphoVaultEligibility(address(morphoEligibility)), makeAddr("eoaExecutor")
        );
    }

    function test_euler_rejectsZeroArgs() public {
        vm.expectRevert(AbstractEulerAdapter.Invalid.selector);
        new EulerEVaultAdapter(IEulerEVaultFactory(address(0)), address(executor));

        vm.expectRevert(AbstractEulerAdapter.Invalid.selector);
        new EulerEarnAdapter(IEulerEarnFactory(address(0)), address(executor));
    }

    function test_capy_rejectsZeroArgs() public {
        vm.expectRevert(CapyFiAdapter.Invalid.selector);
        new CapyFiAdapter(address(executor), ICapyFiComptroller(address(0)));

        vm.expectRevert(CapyFiAdapter.Invalid.selector);
        new CapyFiAdapter(makeAddr("eoaExecutor"), ICapyFiComptroller(address(aavePool)));
    }

    function test_adaptersPinProtocolWideInfrastructureOnly() public view {
        assertEq(address(aaveAdapter.pool()), address(aavePool));
        assertEq(address(aaveAdapter.dataProvider()), address(aaveDataProvider));
        assertEq(aaveAdapter.executor(), address(executor));

        assertEq(address(morphoAdapter.eligibility()), address(morphoEligibility));
        assertEq(morphoAdapter.executor(), address(executor));
    }

    // -------------------------------------------------------------------------
    // One adapter, many venues
    // -------------------------------------------------------------------------

    /// @dev The core property of this architecture: a single deployed adapter transacts with
    ///      every reserve of its pool, and the registry keeps the venues independent.
    function test_aave_oneAdapterServesEveryReserve() public {
        (address thirdVault, MockAToken thirdAToken) = _addAaveReserve();
        _admitAaveVault(thirdVault);

        vm.prank(account);
        executor.setVaultPolicy(thirdVault, DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days);

        address[3] memory vaults = [aaveVault, aaveVaultOther, thirdVault];
        address[3] memory aTokens = [
            address(aavePool.aToken()),
            address(aavePool.aTokens(aaveVaultOther)),
            address(thirdAToken)
        ];

        for (uint256 i; i < vaults.length; ++i) {
            assertEq(registry.venue(vaults[i]).adapter, address(aaveAdapter), "shared adapter");

            MockUnderlying(vaults[i]).mint(account, 100e6);
            vm.prank(account);
            IERC20(vaults[i]).approve(address(executor), type(uint256).max);

            vm.prank(account);
            executor.execute(_ops1(_op(vaults[i], OperationKind.DEPOSIT, 40e6)));

            assertEq(IERC20(aTokens[i]).balanceOf(account), 40e6, "position credited");
            assertEq(IERC20(vaults[i]).balanceOf(address(aaveAdapter)), 0, "no residual");
        }
    }

    function test_aave_venueIsItsUnderlyingAsset() public view {
        assertEq(aaveAdapter.asset(aaveVault), aaveVault);
        assertEq(aaveAdapter.positionToken(aaveVault), address(aavePool.aToken()));
        assertEq(aaveAdapter.asset(aaveVaultOther), aaveVaultOther);
        assertEq(
            aaveAdapter.positionToken(aaveVaultOther), address(aavePool.aTokens(aaveVaultOther))
        );
    }

    function test_aave_previewsAreIdentity() public view {
        assertEq(aaveAdapter.previewDeposit(aaveVault, 123e6), 123e6);
        assertEq(aaveAdapter.previewRedeem(aaveVault, 456e6), 456e6);
    }

    /// @dev A reserve the pinned data provider does not list has no position token, so the
    ///      adapter cannot be talked into transacting with it.
    function test_aave_unknownReserveHasNoPositionToken() public {
        MockUnderlying unlisted = new MockUnderlying();

        vm.expectRevert(AaveV3Adapter.UnknownReserve.selector);
        aaveAdapter.positionToken(address(unlisted));
    }

    function test_erc4626Adapters_venueIsItsOwnShareToken() public view {
        assertEq(morphoAdapter.positionToken(morphoVault), morphoVault);
        assertEq(morphoAdapter.asset(morphoVault), IERC4626(morphoVault).asset());
    }

    // -------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------

    function test_onlyExecutorMayDepositOrRedeem() public {
        vm.expectRevert(AaveV3Adapter.OnlyExecutor.selector);
        aaveAdapter.deposit(aaveVault, 1, account);

        vm.expectRevert(AaveV3Adapter.OnlyExecutor.selector);
        aaveAdapter.redeem(aaveVault, 1, account);

        vm.expectRevert(MorphoVaultV2Adapter.OnlyExecutor.selector);
        morphoAdapter.deposit(morphoVault, 1, account);

        vm.expectRevert(MorphoVaultV2Adapter.OnlyExecutor.selector);
        morphoAdapter.redeem(morphoVault, 1, account);
    }
}
