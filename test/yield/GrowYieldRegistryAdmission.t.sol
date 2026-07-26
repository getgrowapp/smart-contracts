// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {GrowYieldTestBase} from "./GrowYieldTestBase.sol";
import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {CapyFiAdapter} from "../../src/adapters/CapyFiAdapter.sol";
import {EulerEarnAdapter} from "../../src/adapters/EulerEarnAdapter.sol";
import {EulerEVaultAdapter} from "../../src/adapters/EulerEVaultAdapter.sol";
import {ICapyFiCaToken} from "../../src/interfaces/ICapyFiCaToken.sol";
import {ICapyFiComptroller} from "../../src/interfaces/ICapyFiComptroller.sol";
import {IEulerEarnFactory} from "../../src/interfaces/IEulerEarnFactory.sol";
import {IEulerEVaultFactory} from "../../src/interfaces/IEulerEVaultFactory.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {MockUnderlying, MockVault} from "../invariant/MockYieldVenues.sol";
import {
    MockCapyFiMarket,
    MockEulerEarnFactory,
    MockEulerEVaultFactory,
    MockEulerVault
} from "./mocks/MockEulerCapyFiStack.sol";
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

    function setUp() public {
        _setUpBase();

        evkFactory = new MockEulerEVaultFactory();
        earnFactory = new MockEulerEarnFactory();
        evault = new MockEulerVault(IERC20(address(underlying)), "eUSD", "eUSD");
        earnVault = new MockEulerVault(IERC20(address(underlying)), "eeUSD", "eeUSD");
        evkFactory.setProxy(address(evault), true);
        earnFactory.setVault(address(earnVault), true);
        capyMarket = new MockCapyFiMarket(new MockUnderlying());

        evaultAdapter = new EulerEVaultAdapter(
            IEulerEVaultFactory(address(evkFactory)),
            IERC4626(address(evault)),
            address(underlying),
            address(executor)
        );
        earnAdapter = new EulerEarnAdapter(
            IEulerEarnFactory(address(earnFactory)),
            IERC4626(address(earnVault)),
            address(underlying),
            address(executor)
        );
        capyAdapter = new CapyFiAdapter(
            address(executor),
            ICapyFiComptroller(address(capyMarket.comptroller())),
            ICapyFiCaToken(address(capyMarket.caToken())),
            address(capyMarket.asset())
        );
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

    function _add(GrowYieldAdapterRegistry to, address adapter, Protocol protocol) internal {
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(adapter, protocol, true, true);
        to.addVaults(vaults);
    }

    /// @dev Rogue adapter over a brand-new position token, so protocol-independent checks pass
    ///      and only the registrar dispatch can reject it.
    function _rogue() internal returns (MockRogueVenueAdapter) {
        return new MockRogueVenueAdapter(
            address(executor), address(underlying), address(new MockUnderlying())
        );
    }

    // -------------------------------------------------------------------------
    // Authentic venues are admitted for every protocol
    // -------------------------------------------------------------------------

    function test_admitsAuthenticVenueForEveryProtocol() public {
        GrowYieldAdapterRegistry full = _fullRegistry();

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](5);
        vaults[0] =
            IGrowYieldAdapterRegistry.VaultConfig(address(aaveAdapter), Protocol.AAVE, true, true);
        vaults[1] = IGrowYieldAdapterRegistry.VaultConfig(
            address(morphoAdapter), Protocol.MORPHO, true, true
        );
        vaults[2] = IGrowYieldAdapterRegistry.VaultConfig(
            address(evaultAdapter), Protocol.EULER_EVK, true, true
        );
        vaults[3] = IGrowYieldAdapterRegistry.VaultConfig(
            address(earnAdapter), Protocol.EULER_EARN, true, true
        );
        vaults[4] = IGrowYieldAdapterRegistry.VaultConfig(
            address(capyAdapter), Protocol.CAPYFI, true, true
        );
        full.addVaults(vaults);

        assertEq(full.vaultCount(), 5);
        for (uint256 i; i < vaults.length; ++i) {
            address adapter = vaults[i].adapter;
            assertEq(full.vaultAt(i), adapter);
            assertTrue(full.vaultProtocol(adapter) == vaults[i].protocol);
            assertEq(full.adapterCodeHash(adapter), adapter.codehash);
        }
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
            _add(limited, adapters[i], protocols[i]);
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

    // -------------------------------------------------------------------------
    // Foreign infrastructure
    // -------------------------------------------------------------------------

    function test_registrarMismatch_aavePool() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setAave(makeAddr("foreignPool"), address(aaveDataProvider));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(rogue), Protocol.AAVE);
    }

    function test_registrarMismatch_aaveDataProvider() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setAave(address(aavePool), makeAddr("foreignProvider"));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(rogue), Protocol.AAVE);
    }

    function test_registrarMismatch_morphoEligibility() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setMorpho(
            makeAddr("foreignEligibility"), address(morphoChild), morphoAdapter.liquidityAdapter()
        );

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(rogue), Protocol.MORPHO);
    }

    function test_registrarMismatch_eulerFactories() public {
        GrowYieldAdapterRegistry full = _fullRegistry();

        MockRogueVenueAdapter evkRogue = _rogue();
        evkRogue.setFactory(makeAddr("foreignEvkFactory"));
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(evkRogue), Protocol.EULER_EVK);

        // The Earn adapter's real factory is not the EVK factory the entry declares.
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(earnAdapter), Protocol.EULER_EVK);

        MockRogueVenueAdapter earnRogue = _rogue();
        earnRogue.setFactory(makeAddr("foreignEarnFactory"));
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(earnRogue), Protocol.EULER_EARN);
    }

    function test_registrarMismatch_capyFiComptroller() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setComptroller(makeAddr("foreignComptroller"));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.RegistrarMismatch.selector);
        _add(full, address(rogue), Protocol.CAPYFI);
    }

    // -------------------------------------------------------------------------
    // Venues the pinned registrar does not recognize
    // -------------------------------------------------------------------------

    function test_notCanonical_aaveReserveNotListed() public {
        // Correct pool and provider, but the provider maps no aToken for this asset.
        MockUnderlying unlisted = new MockUnderlying();
        MockRogueVenueAdapter rogue = new MockRogueVenueAdapter(
            address(executor), address(unlisted), address(new MockUnderlying())
        );
        rogue.setAave(address(aavePool), address(aaveDataProvider));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), Protocol.AAVE);
    }

    function test_notCanonical_aaveReserveAtokenMismatch() public {
        // A listed reserve, but the adapter claims a different position token for it.
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setAave(address(aavePool), address(aaveDataProvider));

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), Protocol.AAVE);
    }

    function test_notCanonical_morphoWrapperNotFromFactory() public {
        MockRogueVenueAdapter rogue = _rogue();
        rogue.setMorpho(
            address(morphoEligibility), address(morphoChild), morphoAdapter.liquidityAdapter()
        );

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), Protocol.MORPHO);
    }

    function test_notCanonical_morphoLiquidityAdapterNotFromFactory() public {
        MockRogueVenueAdapter rogue = _rogue();
        morphoFactory.set(rogue.positionToken(), true);
        rogue.setMorpho(
            address(morphoEligibility), address(morphoChild), makeAddr("foreignLiquidityAdapter")
        );

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), Protocol.MORPHO);
    }

    /// @dev An eligible child claimed by a wrapper that routes somewhere else: the registry
    ///      re-derives routing from the liquidity adapter, so the claim fails.
    function test_notCanonical_morphoRoutingDoesNotMatchClaimedChild() public {
        MockRogueVenueAdapter rogue = _rogue();
        morphoFactory.set(rogue.positionToken(), true);

        // Liquidity adapter genuinely created by the pinned factory, but for another parent.
        address foreignRouting =
            morphoAdapterFactory.create(address(morphoWrapper), address(morphoChild));
        rogue.setMorpho(address(morphoEligibility), address(morphoChild), foreignRouting);

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), Protocol.MORPHO);
    }

    function test_notCanonical_morphoChildNotEligible() public {
        MockRogueVenueAdapter rogue = _rogue();
        morphoFactory.set(rogue.positionToken(), true);

        MockVault ineligibleChild = new MockVault(IERC20(address(underlying)), "Bad", "bad");
        address routing =
            morphoAdapterFactory.create(rogue.positionToken(), address(ineligibleChild));
        rogue.setMorpho(address(morphoEligibility), address(ineligibleChild), routing);

        GrowYieldAdapterRegistry full = _fullRegistry();
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), Protocol.MORPHO);
    }

    function test_notCanonical_eulerVaultsNotRegistered() public {
        GrowYieldAdapterRegistry full = _fullRegistry();

        MockRogueVenueAdapter evkRogue = _rogue();
        evkRogue.setFactory(address(evkFactory));
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(evkRogue), Protocol.EULER_EVK);

        MockRogueVenueAdapter earnRogue = _rogue();
        earnRogue.setFactory(address(earnFactory));
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(earnRogue), Protocol.EULER_EARN);
    }

    /// @dev A vault the factory delists after the adapter was deployed can no longer be
    ///      admitted, even though the adapter's constructor once passed.
    function test_notCanonical_eulerVaultDelistedAfterAdapterDeployment() public {
        GrowYieldAdapterRegistry full = _fullRegistry();
        evkFactory.setProxy(address(evault), false);

        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(evaultAdapter), Protocol.EULER_EVK);
    }

    function test_notCanonical_capyFiMarketNotListed() public {
        GrowYieldAdapterRegistry full = _fullRegistry();

        MockRogueVenueAdapter rogue = _rogue();
        rogue.setComptroller(address(capyMarket.comptroller()));
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(rogue), Protocol.CAPYFI);

        capyMarket.comptroller().setListed(address(capyMarket.caToken()), false);
        vm.expectRevert(IGrowYieldAdapterRegistry.NotCanonicalVenue.selector);
        _add(full, address(capyAdapter), Protocol.CAPYFI);
    }
}
