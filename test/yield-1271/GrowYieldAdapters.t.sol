// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {
    IMorphoVaultV1AdapterFactory
} from "vault-v2/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowYieldAdapterRegistry} from "../../src/yield-module/GrowYieldAdapterRegistry.sol";
import {AaveV3Adapter} from "../../src/yield-module/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../../src/yield-module/adapters/MorphoVaultV2Adapter.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {IMorphoVaultEligibility} from "../../src/interfaces/IMorphoVaultEligibility.sol";
import {
    IGrowYieldAdapterRegistry
} from "../../src/yield-module/interfaces/IGrowYieldAdapterRegistry.sol";
import {MockUnderlying, MockVault} from "../invariant/MockYieldVenues.sol";
import {
    MockMorphoV1Adapter,
    MockMorphoV1AdapterFactory,
    MockMutableAaveDataProvider,
    MockVaultV2
} from "./mocks/MockVaultV2Stack.sol";

/// @notice Construction-time venue validation (ported from GrowYieldRegistryV6,
///         previously untested) must reject every malformed wrapper configuration.
contract GrowYieldAdaptersTest is GrowYield1271TestBase {
    function setUp() public {
        _setUpBase();
    }

    function _newMorphoAdapter(address wrapper) internal returns (MorphoVaultV2Adapter) {
        return new MorphoVaultV2Adapter(
            IVaultV2(wrapper),
            IVaultV2Factory(address(morphoFactory)),
            IMorphoVaultV1AdapterFactory(address(morphoAdapterFactory)),
            IMorphoVaultEligibility(address(morphoEligibility)),
            address(executor)
        );
    }

    /// @dev Fresh, fully-valid wrapper the individual tests then break one way each.
    function _freshWrapper() internal returns (MockVaultV2 wrapper) {
        wrapper = new MockVaultV2(IERC20(address(underlying)), "W2", "W2");
        morphoFactory.set(address(wrapper), true);
        wrapper.addMockAdapter(morphoAdapterFactory.create(address(wrapper), address(morphoChild)));
        wrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        wrapper.setAbdicated(IVaultV2.removeAdapter.selector, true);
    }

    function test_validWrapper_constructs() public {
        MorphoVaultV2Adapter adapter = _newMorphoAdapter(address(_freshWrapper()));
        assertEq(adapter.asset(), address(underlying));
        assertEq(adapter.child(), address(morphoChild));
    }

    function test_rejectsWrapperNotFromFactory() public {
        MockVaultV2 wrapper = _freshWrapper();
        morphoFactory.set(address(wrapper), false);
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsMultipleAdapters() public {
        MockVaultV2 wrapper = _freshWrapper();
        wrapper.addMockAdapter(makeAddr("secondAdapter"));
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsLiquidityAdapterMismatch() public {
        MockVaultV2 wrapper = _freshWrapper();
        wrapper.setLiquidityAdapter(makeAddr("other"));
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsNonEmptyLiquidityData() public {
        MockVaultV2 wrapper = _freshWrapper();
        wrapper.setLiquidityData(hex"01");
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsForeignAdapterFactory() public {
        MockVaultV2 wrapper = new MockVaultV2(IERC20(address(underlying)), "W2", "W2");
        morphoFactory.set(address(wrapper), true);
        MockMorphoV1AdapterFactory rogueFactory = new MockMorphoV1AdapterFactory();
        wrapper.addMockAdapter(rogueFactory.create(address(wrapper), address(morphoChild)));
        wrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        wrapper.setAbdicated(IVaultV2.removeAdapter.selector, true);
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsAdapterSpoofingTrustedFactory() public {
        MockVaultV2 wrapper = new MockVaultV2(IERC20(address(underlying)), "W2", "W2");
        morphoFactory.set(address(wrapper), true);
        wrapper.addMockAdapter(
            address(
                new MockMorphoV1Adapter(
                    address(morphoAdapterFactory), address(wrapper), address(morphoChild)
                )
            )
        );
        wrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        wrapper.setAbdicated(IVaultV2.removeAdapter.selector, true);

        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsParentVaultMismatch() public {
        MockVaultV2 wrapper = new MockVaultV2(IERC20(address(underlying)), "W2", "W2");
        morphoFactory.set(address(wrapper), true);
        wrapper.addMockAdapter(
            morphoAdapterFactory.create(makeAddr("otherParent"), address(morphoChild))
        );
        wrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        wrapper.setAbdicated(IVaultV2.removeAdapter.selector, true);
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsIneligibleChild() public {
        MockVaultV2 wrapper = _freshWrapper();
        morphoEligibility.set(address(morphoChild), false);
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsChildAssetMismatch() public {
        MockVault wrongAssetChild = new MockVault(IERC20(address(otherUnderlying)), "C2", "C2");
        morphoEligibility.set(address(wrongAssetChild), true);

        MockVaultV2 wrapper = new MockVaultV2(IERC20(address(underlying)), "W2", "W2");
        morphoFactory.set(address(wrapper), true);
        wrapper.addMockAdapter(
            morphoAdapterFactory.create(address(wrapper), address(wrongAssetChild))
        );
        wrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        wrapper.setAbdicated(IVaultV2.removeAdapter.selector, true);
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsMissingAbdication() public {
        MockVaultV2 wrapper = _freshWrapper();
        wrapper.setAbdicated(IVaultV2.addAdapter.selector, false);
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        _newMorphoAdapter(address(wrapper));
    }

    function test_rejectsZeroConstructorArgs() public {
        vm.expectRevert(MorphoVaultV2Adapter.Invalid.selector);
        new MorphoVaultV2Adapter(
            IVaultV2(address(0)),
            IVaultV2Factory(address(morphoFactory)),
            IMorphoVaultV1AdapterFactory(address(morphoAdapterFactory)),
            IMorphoVaultEligibility(address(morphoEligibility)),
            address(executor)
        );
    }

    // --- Aave adapter construction ---

    function test_aave_rejectsUnknownReserve() public {
        MockMutableAaveDataProvider provider =
            new MockMutableAaveDataProvider(address(underlying), address(0));
        vm.expectRevert(AaveV3Adapter.Invalid.selector);
        new AaveV3Adapter(
            IAaveV3Pool(address(aavePool)),
            IAaveProtocolDataProvider(address(provider)),
            address(underlying),
            address(executor)
        );
    }

    function test_aave_rejectsZeroArgs() public {
        vm.expectRevert(AaveV3Adapter.Invalid.selector);
        new AaveV3Adapter(
            IAaveV3Pool(address(0)),
            IAaveProtocolDataProvider(address(aaveDataProvider)),
            address(underlying),
            address(executor)
        );
    }

    // --- fixed registry construction ---

    function test_registry_rejectsNonContractAdapter() public {
        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](1);
        configs[0] = IGrowYieldAdapterRegistry.AdapterConfig(makeAddr("eoa"), true, false);
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldAdapterRegistry(address(executor), configs);
    }

    function test_registry_rejectsDuplicateAdapter() public {
        IGrowYieldAdapterRegistry.AdapterConfig[] memory configs =
            new IGrowYieldAdapterRegistry.AdapterConfig[](2);
        configs[0] = IGrowYieldAdapterRegistry.AdapterConfig(address(aaveAdapter), true, true);
        configs[1] = IGrowYieldAdapterRegistry.AdapterConfig(address(aaveAdapter), true, false);
        vm.expectRevert(IGrowYieldAdapterRegistry.Invalid.selector);
        new GrowYieldAdapterRegistry(address(executor), configs);
    }

    function test_registryHasNoPostDeploymentMutationPath() public {
        (bool success,) = address(registry)
            .call(
                abi.encodeWithSignature(
                    "setAdapter(address,bool,bool)", address(aaveAdapter), false, false
                )
            );
        assertFalse(success);
        assertTrue(registry.canDeposit(address(aaveAdapter)));
    }

    function test_registryEnumeratesFixedAdaptersInConstructorOrder() public view {
        assertEq(registry.adapterCount(), 3);
        assertEq(registry.adapterAt(0), address(aaveAdapter));
        assertEq(registry.adapterAt(1), address(aaveAdapterOther));
        assertEq(registry.adapterAt(2), address(morphoAdapter));
    }
}
