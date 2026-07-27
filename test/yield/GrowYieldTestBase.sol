// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    Call,
    IModularAccount
} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";
import {
    IMorphoVaultV1AdapterFactory
} from "vault-v2/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";

import {GrowYieldPolicyModule} from "../../src/GrowYieldPolicyModule.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {GrowYieldAdapterRegistry} from "../../src/GrowYieldAdapterRegistry.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../../src/adapters/MorphoVaultV2Adapter.sol";
import {
    IGrowYieldAdapterRegistry,
    Protocol,
    Venue
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IMorphoVaultEligibility} from "../../src/interfaces/IMorphoVaultEligibility.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    Operation,
    OperationKind
} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {
    MockAToken,
    MockAavePool,
    MockUnderlying,
    MockVault
} from "../invariant/MockYieldVenues.sol";
import {
    MockEligibility,
    MockMorphoV1AdapterFactory,
    MockMutableAaveDataProvider,
    MockValidationModule,
    MockVaultV2,
    MockVaultV2Factory
} from "./mocks/MockVaultV2Stack.sol";

abstract contract GrowYieldTestBase is Test {
    uint16 internal constant MAX_LOSS_BPS = 50;
    uint128 internal constant MAX_VERIFICATION_GAS = 500_000;
    uint128 internal constant MAX_CALL_GAS = 2_000_000;
    uint256 internal constant MAX_PRE_VERIFICATION_GAS = 150_000;
    uint128 internal constant MAX_PAYMASTER_VERIFICATION_GAS = 200_000;
    uint128 internal constant MAX_PAYMASTER_POST_OP_GAS = 200_000;
    uint128 internal constant MAX_PRIORITY_FEE = 2 gwei;
    uint128 internal constant MAX_FEE = 2 gwei;
    uint32 internal constant POLICY_ENTITY_ID = 1;

    GrowYieldExecutor internal executor;
    GrowYieldPolicyModule internal policyModule;
    address internal sponsorPaymaster;
    address internal riskGuardian;

    MockUnderlying internal underlying;
    MockUnderlying internal otherUnderlying;

    MockAavePool internal aavePool;
    MockMutableAaveDataProvider internal aaveDataProvider;
    AaveV3Adapter internal aaveAdapter;

    /// @dev Aave venues are their underlying assets, both served by the one adapter.
    address internal aaveVault;
    address internal aaveVaultOther;

    MockVaultV2Factory internal morphoFactory;
    MockEligibility internal morphoEligibility;
    MockMorphoV1AdapterFactory internal morphoAdapterFactory;
    MockVault internal morphoChild;
    MockVaultV2 internal morphoWrapper;
    MorphoVaultV2Adapter internal morphoAdapter;

    /// @dev The Morpho venue is the wrapper itself.
    address internal morphoVault;

    address internal account;
    uint256 internal automationPk;
    address internal automation;

    function _setUpBase() internal {
        account = makeAddr("smartAccount");
        sponsorPaymaster = address(new MockValidationModule());
        _deployStack();

        // One call is the account's whole opt-in: entity, policy owners, and the executor whose
        // registry defines every venue it may use.
        address[] memory initialOwners = new address[](1);
        initialOwners[0] = automation;
        vm.prank(account);
        policyModule.onInstall(
            abi.encode(POLICY_ENTITY_ID, initialOwners, address(executor), sponsorPaymaster)
        );
    }

    /// @dev Deploys venue infrastructure, then the executor (which deploys its own registry),
    ///      then the adapters that authorize it, then admits the initial vault set.
    function _deployStack() internal {
        automationPk = uint256(keccak256("automation"));
        automation = vm.addr(automationPk);
        riskGuardian = makeAddr("riskGuardian");

        underlying = new MockUnderlying();
        otherUnderlying = new MockUnderlying();

        _deployAaveVenues();
        _deployMorphoVenues();

        // Admission and execution are one contract: deploy it, deploy adapters that authorize
        // it, then admit the venues.
        executor = _deployExecutor(address(this));
        _deployAdapters();
        executor.addVaults(_defaultVaults());

        policyModule = new GrowYieldPolicyModule(
            MAX_VERIFICATION_GAS,
            MAX_CALL_GAS,
            MAX_PRE_VERIFICATION_GAS,
            MAX_PAYMASTER_VERIFICATION_GAS,
            MAX_PAYMASTER_POST_OP_GAS,
            MAX_PRIORITY_FEE,
            MAX_FEE
        );
    }

    /// @dev The three venues every suite starts with, all directions enabled.
    function _defaultVaults()
        internal
        view
        returns (IGrowYieldAdapterRegistry.VaultConfig[] memory vaults)
    {
        vaults = new IGrowYieldAdapterRegistry.VaultConfig[](3);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(aaveAdapter), aaveVault, Protocol.AAVE, true, true
        );
        vaults[1] = IGrowYieldAdapterRegistry.VaultConfig(
            address(aaveAdapter), aaveVaultOther, Protocol.AAVE, true, true
        );
        vaults[2] = IGrowYieldAdapterRegistry.VaultConfig(
            address(morphoAdapter), morphoVault, Protocol.MORPHO, true, true
        );
    }

    /// @dev A fresh executor over the same mock venues, owned by `owner_` and holding its own
    ///      empty venue set. Each executor is its own registry, so this is how a test obtains a
    ///      second, independent venue set.
    function _deployExecutor(address owner_) internal returns (GrowYieldExecutor) {
        return new GrowYieldExecutor(MAX_LOSS_BPS, riskGuardian, owner_, _mockRegistrars());
    }

    /// @dev The mock Aave and Morpho registrars; every other protocol is unsupported here.
    function _mockRegistrars() internal view returns (IGrowYieldAdapterRegistry.Registrars memory) {
        return IGrowYieldAdapterRegistry.Registrars({
            aavePool: address(aavePool),
            aaveDataProvider: address(aaveDataProvider),
            morphoVaultFactory: address(morphoFactory),
            morphoAdapterFactory: address(morphoAdapterFactory),
            morphoEligibility: address(morphoEligibility),
            eulerEVaultFactory: address(0),
            eulerEarnFactory: address(0),
            capyFiComptroller: address(0)
        });
    }

    /// @dev One pool, one data provider, two reserves — matching real Aave topology, where a
    ///      single pool fronts every reserve.
    function _deployAaveVenues() internal {
        aavePool = new MockAavePool(underlying);
        aaveDataProvider =
            new MockMutableAaveDataProvider(address(underlying), address(aavePool.aToken()));

        MockAToken otherAToken = aavePool.addReserve(otherUnderlying);
        aaveDataProvider.setReserve(address(otherUnderlying), address(otherAToken));

        aaveVault = address(underlying);
        aaveVaultOther = address(otherUnderlying);
    }

    /// @dev One adapter per protocol, each serving every venue of that protocol.
    function _deployAdapters() internal {
        aaveAdapter = new AaveV3Adapter(
            IAaveV3Pool(address(aavePool)),
            IAaveProtocolDataProvider(address(aaveDataProvider)),
            address(executor)
        );
        morphoAdapter = new MorphoVaultV2Adapter(
            IMorphoVaultEligibility(address(morphoEligibility)), address(executor)
        );
    }

    /// @dev Admits one more Aave venue on the default registry, reusing the same adapter.
    function _admitAaveVault(address vault) internal {
        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig(
            address(aaveAdapter), vault, Protocol.AAVE, true, true
        );
        executor.addVaults(vaults);
    }

    /// @dev Adds an extra Aave reserve served by the same pool, provider, and adapter.
    function _addAaveReserve() internal returns (address vault, MockAToken aToken) {
        MockUnderlying newAsset = new MockUnderlying();
        aToken = aavePool.addReserve(newAsset);
        aaveDataProvider.setReserve(address(newAsset), address(aToken));
        vault = address(newAsset);
    }

    function _deployMorphoVenues() internal {
        morphoFactory = new MockVaultV2Factory();
        morphoEligibility = new MockEligibility();
        morphoAdapterFactory = new MockMorphoV1AdapterFactory();

        morphoChild = new MockVault(IERC20(address(underlying)), "Child", "cV");
        morphoEligibility.set(address(morphoChild), true);

        morphoWrapper = new MockVaultV2(IERC20(address(underlying)), "Wrapper", "wV");
        morphoFactory.set(address(morphoWrapper), true);
        morphoWrapper.addMockAdapter(
            morphoAdapterFactory.create(address(morphoWrapper), address(morphoChild))
        );
        morphoWrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        morphoWrapper.setAbdicated(IVaultV2.removeAdapter.selector, true);

        morphoVault = address(morphoWrapper);
    }

    /// @dev The venue's source token for `kind`, taken from the registry's admitted pair
    ///      exactly as the executor does.
    function _sourceToken(address vault, OperationKind kind) internal view returns (address) {
        Venue memory v = executor.venue(vault);
        return kind == OperationKind.DEPOSIT ? v.asset : v.positionToken;
    }

    function _outputToken(address vault, OperationKind kind) internal view returns (address) {
        Venue memory v = executor.venue(vault);
        return kind == OperationKind.DEPOSIT ? v.positionToken : v.asset;
    }

    function _op(address vault, OperationKind kind, uint256 amount)
        internal
        view
        returns (Operation memory)
    {
        AmountMode amountMode =
            amount == type(uint256).max ? AmountMode.FULL_BALANCE : AmountMode.EXACT;
        return Operation({
            vault: vault,
            kind: kind,
            sourceToken: _sourceToken(vault, kind),
            amount: amountMode == AmountMode.EXACT ? amount : 0,
            amountMode: amountMode,
            minAmountOut: 1
        });
    }

    function _opWithMode(
        address vault,
        OperationKind kind,
        AmountMode amountMode,
        uint256 amount,
        uint256 minAmountOut
    ) internal view returns (Operation memory) {
        return Operation({
            vault: vault,
            kind: kind,
            sourceToken: _sourceToken(vault, kind),
            amount: amount,
            amountMode: amountMode,
            minAmountOut: minAmountOut
        });
    }

    function _ops1(Operation memory op) internal pure returns (Operation[] memory ops) {
        ops = new Operation[](1);
        ops[0] = op;
    }

    function _ops2(Operation memory a, Operation memory b)
        internal
        view
        returns (Operation[] memory ops)
    {
        address firstOutputToken = _outputToken(a.vault, a.kind);
        if (b.amountMode == AmountMode.FULL_BALANCE && b.sourceToken == firstOutputToken) {
            b.amountMode = AmountMode.PREVIOUS_OUTPUT;
        }
        ops = new Operation[](2);
        ops[0] = a;
        ops[1] = b;
    }

    function _executeData(Operation[] memory ops) internal pure returns (bytes memory) {
        return abi.encodeCall(IGrowYieldExecutor.execute, (ops));
    }

    function _approve(address spender, uint256 amount) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, amount);
    }

    /// @dev The one calldata shape the policy accepts: a single `execute` on the account
    ///      forwarding to the executor. Allowances are standing and granted by the owner.
    function _policyCall(Operation[] memory ops) internal view returns (bytes memory) {
        return abi.encodeCall(IModularAccount.execute, (address(executor), 0, _executeData(ops)));
    }

    /// @dev Standing allowance from `account` to the executor, as the owner would grant once.
    function _approveExecutor(address token) internal {
        vm.prank(account);
        IERC20(token).approve(address(executor), type(uint256).max);
    }

    function _baseUserOp(bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp.sender = account;
        userOp.nonce = 1;
        userOp.callData = callData;
        userOp.accountGasLimits =
            bytes32((uint256(MAX_VERIFICATION_GAS) << 128) | uint256(MAX_CALL_GAS));
        userOp.preVerificationGas = 100_000;
        userOp.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        userOp.paymasterAndData =
            abi.encodePacked(sponsorPaymaster, uint128(100_000), uint128(100_000));
    }

    function _signAuthorization(uint256 key, bytes32 userOpHash)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(keccak256("GrowYieldAuthorization(bytes32 userOpHash)"), userOpHash)
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("GrowYieldPolicy")),
                keccak256(bytes("1")),
                block.chainid,
                address(policyModule)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _authorize(PackedUserOperation memory userOp, bytes32 userOpHash, uint256 key)
        internal
        view
        returns (PackedUserOperation memory)
    {
        userOp.signature = _signAuthorization(key, userOpHash);
        return userOp;
    }

    function _authorize(PackedUserOperation memory userOp, bytes32 userOpHash)
        internal
        view
        returns (PackedUserOperation memory)
    {
        return _authorize(userOp, userOpHash, automationPk);
    }

    function _validationResult(PackedUserOperation memory userOp, bytes32 userOpHash)
        internal
        returns (uint256 result)
    {
        vm.prank(account);
        result = policyModule.validateUserOp(POLICY_ENTITY_ID, userOp, userOpHash);
    }

    function _assertValid(PackedUserOperation memory userOp, bytes32 userOpHash) internal {
        assertEq(uint160(_validationResult(userOp, userOpHash)), 0);
    }

    function _assertInvalid(PackedUserOperation memory userOp, bytes32 userOpHash) internal {
        assertEq(uint160(_validationResult(userOp, userOpHash)), 1);
    }
}
