// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";

import {GrowYieldTestBase} from "./GrowYieldTestBase.sol";
import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {CapyFiAdapter} from "../../src/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../../src/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../../src/adapters/EulerEVaultAdapter.sol";
import {ICapyFiComptroller} from "../../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "../../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../../src/interfaces/IEulerEVaultFactory.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol,
    Venue
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {MockUnderlying, MockVault} from "../invariant/MockYieldVenues.sol";
import {
    MockCapyFiMarket,
    MockEulerEarnFactory,
    MockEulerEVaultFactory,
    MockEulerVault
} from "./mocks/MockEulerCapyFiStack.sol";
import {MockVaultV2} from "./mocks/MockVaultV2Stack.sol";
import {MockRogueVenueAdapter} from "./mocks/MockRogueVenueAdapter.sol";

/// @notice Every branch of the registry's per-protocol admission dispatch.
/// @dev The registry must prove venue provenance from its own pinned registrars, so each
///      protocol is exercised three ways: an authentic venue is admitted, an adapter wired to
///      foreign infrastructure is rejected, and a venue the registrar does not recognize is
///      rejected — including when the adapter claims otherwise.
contract GrowYieldRegistryAdmissionTest is GrowYieldTestBase {
    MockEulerEVaultFactory internal evkFactory;
    MockEulerEarnFactory internal earnFactory;
    MockEulerVault internal evault;
    MockEulerVault internal earnVault;
    MockCapyFiMarket internal capyMarket;

    EulerEVaultAdapter internal evaultAdapter;
    EulerEarnAdapter internal earnAdapter;
    CapyFiAdapter internal capyAdapter;

    address internal evaultVault;
    address internal earnVaultAddr;
    address internal capyVault;

    function setUp() public {
        _setUpBase();

        evkFactory = new MockEulerEVaultFactory();
        earnFactory = new MockEulerEarnFactory();
        evault = new MockEulerVault(IERC20(address(underlying)), "eUSD", "eUSD");
        earnVault = new MockEulerVault(IERC20(address(underlying)), "eeUSD", "eeUSD");
        evkFactory.setProxy(address(evault), true);
        earnFactory.setVault(address(earnVault), true);
        capyMarket = new MockCapyFiMarket(new MockUnderlying());

        evaultAdapter =
            new EulerEVaultAdapter(IEulerEVaultFactory(address(evkFactory)), address(executor));
        earnAdapter =
            new EulerEarnAdapter(IEulerEarnFactory(address(earnFactory)), address(executor));
        capyAdapter = new CapyFiAdapter(
            address(executor), ICapyFiComptroller(address(capyMarket.comptroller()))
        );

        evaultVault = address(evault);
        earnVaultAddr = address(earnVault);
        capyVault = address(capyMarket.caToken());
    }

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    function _registrars() internal view returns (IGrowYieldAdapterRegistry.Registrars memory r) {
        r = IGrowYieldAdapterRegistry.Registrars({
            aavePool: address(aavePool),
            aaveDataProvider: address(aaveDataProvider),
            morphoVaultFactory: address(morphoFactory),
            morphoAdapterFactory: address(morphoAdapterFactory),
            morphoEligibility: address(morphoEligibility),
            eulerEVaultFactory: address(evkFactory),
            eulerEarnFactory: address(earnFactory),
            capyFiComptroller: address(capyMarket.comptroller())
        });
    }

    /// @dev Empty registry pinning every protocol this suite exercises.
    function _fullRegistry() internal returns (GrowYieldAdapterRegistry) {
        return new GrowYieldAdapterRegistry(address(executor), address(this), _registrars());
    }

    function _add(GrowYieldAdapterRegistry to, address adapter, address vault, Protocol protocol)
        internal
    {
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(adapter, vault, protocol, true, true);
        to.addVaults(vaults);
    }

    /// @dev Rogue adapter reporting `asset_` and a brand-new position token, so the
    ///      protocol-independent checks pass and only the registrar dispatch can reject it.
    function _rogue(address asset_) internal returns (MockRogueVenueAdapter) {
        return new MockRogueVenueAdapter(address(executor), asset_, address(new MockUnderlying()));
    }

    function _rogue() internal returns (MockRogueVenueAdapter) {
        return _rogue(address(underlying));
    }

    /// @dev A VaultV2 wrapper the pinned factory recognizes, with a settable adapter set.
    function _wrapper() internal returns (MockVaultV2 wrapper) {
        wrapper = new MockVaultV2(IERC20(address(underlying)), "Wrapper", "wV");
        morphoFactory.set(address(wrapper), true);
        wrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        wrapper.setAbdicated(IVaultV2.removeAdapter.selector, true);
    }

    // -------------------------------------------------------------------------
    // Authentic venues are admitted for every protocol
    // -------------------------------------------------------------------------

    function test_admitsAuthenticVenueForEveryProtocol() public {
        GrowYieldAdapterRegistry full = _fullRegistry();

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](5);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(aaveAdapter), aaveVault, Protocol.AAVE, true, true
        );
        vaults[1] = IGrowYieldAdapterRegistry.VaultConfig(
            address(morphoAdapter), morphoVault, Protocol.MORPHO, true, true
        );
        vaults[2] = IGrowYieldAdapterRegistry.VaultConfig(
            address(evaultAdapter), evaultVault, Protocol.EULER_EVK, true, true
        );
        vaults[3] = IGrowYieldAdapterRegistry.VaultConfig(
            address(earnAdapter), earnVaultAddr, Protocol.EULER_EARN, true, true
        );
        vaults[4] = IGrowYieldAdapterRegistry.VaultConfig(
            address(capyAdapter), capyVault, Protocol.CAPYFI, true, true
        );
        full.addVaults(vaults);

        assertEq(full.vaultCount(), 5);
        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i].vault;
            address adapter = vaults[i].adapter;
            assertEq(full.vaultAt(i), vault);
            assertEq(full.vaultAdapter(vault), adapter);
            assertTrue(full.vaultProtocol(vault) == vaults[i].protocol);
            assertEq(full.adapterCodeHash(adapter), adapter.codehash);

            // The pinned pair must be what the adapter derives, and Aave alone splits the
            // venue from its position token.
            Venue memory v = full.venue(vault);
            assertEq(v.asset, IYieldAdapter(adapter).asset(vault));
            assertEq(v.positionToken, IYieldAdapter(adapter).positionToken(vault));
            assertTrue(v.canDeposit && v.canRedeem);
            if (vaults[i].protocol == Protocol.AAVE) {
                assertEq(v.asset, vault);
                assertEq(v.positionToken, address(aavePool.aToken()));
            } else {
                assertEq(v.positionToken, vault);
            }
        }
    }

    /// @dev One adapter serves every venue of its protocol, so a second reserve admits under the
    ///      same adapter and reuses its pinned code hash.
    function test_admitsSecondVenueUnderTheSameAdapter() public {
        GrowYieldAdapterRegistry full = _fullRegistry();
        _add(full, address(aaveAdapter), aaveVault, Protocol.AAVE);
        _add(full, address(aaveAdapter), aaveVaultOther, Protocol.AAVE);

        assertEq(full.vaultCount(), 2);
        assertEq(full.vaultAdapter(aaveVaultOther), address(aaveAdapter));
        assertEq(full.adapterCodeHash(address(aaveAdapter)), address(aaveAdapter).codehash);
    }

    function test_rejectsDuplicateVenue() public {
        GrowYieldAdapterRegistry full = _fullRegistry();
        _add(full, address(aaveAdapter), aaveVault, Protocol.AAVE);

        vm.expectRevert(IGrowYieldAdapterRegistry.VaultAlreadyRegistered.selector);
        _add(full, address(aaveAdapter), aaveVault, Protocol.AAVE);
    }

    /// @dev Two venues reporting the same position token would double-count one balance against
    ///      two directional budgets.
    function test_rejectsDuplicatePositionToken() public {
        GrowYieldAdapterRegistry full = _fullRegistry();
        _add(full, address(evaultAdapter), evaultVault, Protocol.EULER_EVK);

        // A second EVK proxy the factory recognizes, but whose adapter reports the first
        // vault's position token.
        MockRogueVenueAdapter rogue =
            new MockRogueVenueAdapter(address(executor), address(underlying), evaultVault);
        rogue.setFactory(address(evkFactory));
        MockEulerVault other = new MockEulerVault(IERC20(address(underlying)), "e2", "e2");
        evkFactory.setProxy(address(other), true);

        vm.expectRevert(IGrowYieldAdapterRegistry.DuplicateVenue.selector);
        _add(full, address(rogue), address(other), Protocol.EULER_EVK);
    }

    // -------------------------------------------------------------------------
    // Unsupported protocols
    // -------------------------------------------------------------------------

    /// @dev Zeroing a registrar makes the registry reject that protocol outright, which is what
    ///      forces a redeployment to support a new protocol.
    function test_unsupportedProtocol_perZeroedRegistrar() public {
        Protocol[5] memory protocols = [
            Protocol.AAVE, Protocol.MORPHO, Protocol.EULER_EVK, Protocol.EULER_EARN, Protocol.CAPYFI
        ];
        address[5] memory adapters = [
            address(aaveAdapter),
            address(morphoAdapter),
            address(evaultAdapter),
            address(earnAdapter),
            address(capyAdapter)
        ];
        address[5] memory venues = [aaveVault, morphoVault, evaultVault, earnVaultAddr, capyVault];

        for (uint256 i; i < protocols.length; ++i) {
            IGrowYieldAdapterRegistry.Registrars memory r = _registrars();
            if (protocols[i] == Protocol.AAVE) {
                r.aavePool = address(0);
                r.aaveDataProvider = address(0);
            } else if (protocols[i] == Protocol.MORPHO) {
                r.morphoVaultFactory = address(0);
                r.morphoAdapterFactory = address(0);
                r.morphoEligibility = address(0);
            } else if (protocols[i] == Protocol.EULER_EVK) {
                r.eulerEVaultFactory = address(0);
            } else if (protocols[i] == Protocol.EULER_EARN) {
                r.eulerEarnFactory = address(0);
            } else {
                r.capyFiComptroller = address(0);
            }

            GrowYieldAdapterRegistry limited =
                new GrowYieldAdapterRegistry(address(executor), address(this), r);
            vm.expectRevert(IGrowYieldAdapterRegistry.UnsupportedProtocol.selector);
            _add(limited, adapters[i], venues[i], protocols[i]);
        }
    }

    function test_rejectsHalfConfiguredMorphoRegistrars() public {
        IGrowYieldAdapterRegistry.Registrars memory missingFactory = _registrars();
        missingFactory.morphoAdapterFactory = address(0);
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldAdapterRegistry(address(executor), address(this), missingFactory);

        IGrowYieldAdapterRegistry.Registrars memory missingEligibility = _registrars();
        missingEligibility.morphoEligibility = address(0);
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldAdapterRegistry(address(executor), address(this), missingEligibility);
    }

    function test_rejectsHalfConfiguredAaveRegistrars() public {
        IGrowYieldAdapterRegistry.Registrars memory missingProvider = _registrars();
        missingProvider.aaveDataProvider = address(0);
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldAdapterRegistry(address(executor), address(this), missingProvider);
    }

    // -------------------------------------------------------------------------
    // Foreign infrastructure
    // -------------------------------------------------------------------------

    function test_registrarMismatch_aavePool() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setAave(makeAddr("foreignPool"), address(aaveDataProvider));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(rogue), aaveVault, Protocol.AAVE);
    }

    function test_registrarMismatch_aaveDataProvider() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setAave(address(aavePool), makeAddr("foreignProvider"));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(rogue), aaveVault, Protocol.AAVE);
    }

    function test_registrarMismatch_morphoEligibility() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setMorpho(makeAddr("foreignEligibility"), address(morphoChild), address(0));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(rogue), morphoVault, Protocol.MORPHO);
    }

    function test_registrarMismatch_eulerFactories() public {
        GrowYieldAdapterRegistry full = _fullRegistry();

        MockRogueVenueAdapter evkRogue = _rogue();
        evkRogue.setFactory(makeAddr("foreignEvkFactory"));
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(evkRogue), evaultVault, Protocol.EULER_EVK);

        // The Earn adapter's real factory is not the EVK factory the entry declares.
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(earnAdapter), evaultVault, Protocol.EULER_EVK);

        MockRogueVenueAdapter earnRogue = _rogue();
        earnRogue.setFactory(makeAddr("foreignEarnFactory"));
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(earnRogue), earnVaultAddr, Protocol.EULER_EARN);
    }

    function test_registrarMismatch_capyFiComptroller() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setComptroller(makeAddr("foreignComptroller"));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(rogue), capyVault, Protocol.CAPYFI);
    }

    // -------------------------------------------------------------------------
    // Venues the pinned registrar does not recognize
    // -------------------------------------------------------------------------

    /// @dev Aave keys reserves by underlying, so an entry whose adapter reports an asset other
    ///      than the venue itself is not an Aave reserve.
    function test_notCanonical_aaveAssetIsNotTheVenue() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setAave(address(aavePool), address(aaveDataProvider));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), aaveVaultOther, Protocol.AAVE);
    }

    function test_notCanonical_aaveReserveNotListed() public {
        // Correct pool and provider, but the provider maps no aToken for this asset.
        MockUnderlying unlisted = new MockUnderlying();
        MockRogueVenueAdapter rogue = _rogue(address(unlisted));
        rogue.setAave(address(aavePool), address(aaveDataProvider));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), address(unlisted), Protocol.AAVE);
    }

    function test_notCanonical_aaveReserveAtokenMismatch() public {
        // A listed reserve, but the adapter claims a different position token for it.
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setAave(address(aavePool), address(aaveDataProvider));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), aaveVault, Protocol.AAVE);
    }

    function test_notCanonical_morphoWrapperNotFromFactory() public {
        MockVaultV2 unregistered = new MockVaultV2(IERC20(address(underlying)), "W", "w");
        unregistered.addMockAdapter(
            morphoAdapterFactory.create(address(unregistered), address(morphoChild))
        );
        unregistered.setAbdicated(IVaultV2.addAdapter.selector, true);
        unregistered.setAbdicated(IVaultV2.removeAdapter.selector, true);

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(unregistered), Protocol.MORPHO);
    }

    /// @dev A wrapper that can still gain or drop adapters is not a frozen single-adapter shape,
    ///      so the one-time routing proof would not hold for its lifetime.
    function test_notCanonical_morphoAdapterSetNotAbdicated() public {
        MockVaultV2 wrapper = new MockVaultV2(IERC20(address(underlying)), "W", "w");
        morphoFactory.set(address(wrapper), true);
        wrapper.addMockAdapter(morphoAdapterFactory.create(address(wrapper), address(morphoChild)));
        wrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        // removeAdapter deliberately left un-abdicated.

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(wrapper), Protocol.MORPHO);
    }

    function test_notCanonical_morphoMultipleAdapters() public {
        MockVaultV2 wrapper = _wrapper();
        wrapper.addMockAdapter(morphoAdapterFactory.create(address(wrapper), address(morphoChild)));
        wrapper.addMockAdapter(morphoAdapterFactory.create(address(wrapper), address(morphoChild)));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(wrapper), Protocol.MORPHO);
    }

    function test_notCanonical_morphoLiquidityAdapterNotFromFactory() public {
        MockVaultV2 wrapper = _wrapper();
        wrapper.addMockAdapter(address(new MockVaultV2(IERC20(address(underlying)), "F", "f")));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(wrapper), Protocol.MORPHO);
    }

    /// @dev Liquidity must route to the frozen `adapters(0)`; an allocator pointing it elsewhere
    ///      breaks the routing proof the per-operation check relies on.
    function test_notCanonical_morphoLiquidityRoutedElsewhere() public {
        MockVaultV2 wrapper = _wrapper();
        wrapper.addMockAdapter(morphoAdapterFactory.create(address(wrapper), address(morphoChild)));
        wrapper.setLiquidityAdapter(makeAddr("elsewhere"));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(wrapper), Protocol.MORPHO);
    }

    function test_notCanonical_morphoLiquidityDataNotEmpty() public {
        MockVaultV2 wrapper = _wrapper();
        wrapper.addMockAdapter(morphoAdapterFactory.create(address(wrapper), address(morphoChild)));
        wrapper.setLiquidityData(hex"01");

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(wrapper), Protocol.MORPHO);
    }

    /// @dev A liquidity adapter genuinely created by the pinned factory, but parented to a
    ///      different wrapper: the registry re-derives the parent and rejects the mismatch.
    function test_notCanonical_morphoLiquidityAdapterParentedElsewhere() public {
        MockVaultV2 wrapper = _wrapper();
        wrapper.addMockAdapter(
            morphoAdapterFactory.create(address(morphoWrapper), address(morphoChild))
        );

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(wrapper), Protocol.MORPHO);
    }

    function test_notCanonical_morphoChildNotEligible() public {
        MockVaultV2 wrapper = _wrapper();
        MockVault ineligibleChild = new MockVault(IERC20(address(underlying)), "Bad", "bad");
        wrapper.addMockAdapter(
            morphoAdapterFactory.create(address(wrapper), address(ineligibleChild))
        );

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(wrapper), Protocol.MORPHO);
    }

    /// @dev The wrapper and its child must share one underlying, or the pinned asset would not
    ///      describe what the position is actually backed by.
    function test_notCanonical_morphoChildAssetMismatch() public {
        MockVaultV2 wrapper = _wrapper();
        MockVault foreignChild = new MockVault(IERC20(address(otherUnderlying)), "Other", "oV");
        morphoEligibility.set(address(foreignChild), true);
        wrapper.addMockAdapter(morphoAdapterFactory.create(address(wrapper), address(foreignChild)));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(morphoAdapter), address(wrapper), Protocol.MORPHO);
    }

    function test_notCanonical_eulerVaultsNotRegistered() public {
        GrowYieldAdapterRegistry full = _fullRegistry();

        MockEulerVault strayEvk = new MockEulerVault(IERC20(address(underlying)), "x", "x");
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(evaultAdapter), address(strayEvk), Protocol.EULER_EVK);

        MockEulerVault strayEarn = new MockEulerVault(IERC20(address(underlying)), "y", "y");
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(earnAdapter), address(strayEarn), Protocol.EULER_EARN);
    }

    /// @dev An ERC-4626 venue is its own position token; an adapter claiming otherwise is
    ///      rejected even though the factory recognizes the vault.
    function test_notCanonical_eulerPositionTokenIsNotTheVault() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setFactory(address(evkFactory));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), evaultVault, Protocol.EULER_EVK);
    }

    /// @dev A vault the factory delists after the adapter was deployed can no longer be
    ///      admitted, even though the adapter's constructor once passed.
    function test_notCanonical_eulerVaultDelistedAfterAdapterDeployment() public {
        GrowYieldAdapterRegistry full = _fullRegistry();
        evkFactory.setProxy(evaultVault, false);

        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(evaultAdapter), evaultVault, Protocol.EULER_EVK);
    }

    function test_notCanonical_capyFiMarketNotListed() public {
        GrowYieldAdapterRegistry full = _fullRegistry();

        capyMarket.comptroller().setListed(capyVault, false);
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(capyAdapter), capyVault, Protocol.CAPYFI);
    }

    /// @dev A listed market whose adapter claims a position token other than the caToken.
    function test_notCanonical_capyFiPositionTokenIsNotTheMarket() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setComptroller(address(capyMarket.comptroller()));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), capyVault, Protocol.CAPYFI);
    }

    /// @dev The market's own `underlying()` is the authority on the venue's asset, not the
    ///      adapter's report.
    function test_notCanonical_capyFiUnderlyingMismatch() public {
        MockRogueVenueAdapter rogue =
            new MockRogueVenueAdapter(address(executor), address(underlying), capyVault);
        rogue.setComptroller(address(capyMarket.comptroller()));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), capyVault, Protocol.CAPYFI);
    }
}
