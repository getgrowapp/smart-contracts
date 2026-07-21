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

import {GrowYieldPolicyModule} from "../../src/yield-module/GrowYieldPolicyModule.sol";
import {GrowYieldExecutorV3} from "../../src/yield-module/GrowYieldExecutorV3.sol";
import {GrowYieldAdapterRegistry} from "../../src/yield-module/GrowYieldAdapterRegistry.sol";
import {AaveV3Adapter} from "../../src/yield-module/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../../src/yield-module/adapters/MorphoVaultV2Adapter.sol";
import {
    IGrowYieldAdapterRegistry
} from "../../src/yield-module/interfaces/IGrowYieldAdapterRegistry.sol";
import {IMorphoVaultEligibility} from "../../src/interfaces/IMorphoVaultEligibility.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {
    AmountMode,
    IGrowYieldExecutor,
    IYieldAdapter,
    Operation,
    OperationKind
} from "../../src/yield-module/interfaces/IGrowYieldExecutor.sol";
import {MockUnderlying, MockVault, MockAavePool} from "../invariant/MockYieldVenues.sol";
import {
    MockEligibility,
    MockMorphoV1AdapterFactory,
    MockMutableAaveDataProvider,
    MockValidationModule,
    MockVaultV2,
    MockVaultV2Factory
} from "./mocks/MockVaultV2Stack.sol";

abstract contract GrowYield1271TestBase is Test {
    uint16 internal constant MAX_LOSS_BPS = 50;
    uint128 internal constant MAX_VERIFICATION_GAS = 500_000;
    uint128 internal constant MAX_CALL_GAS = 2_000_000;
    uint256 internal constant MAX_PRE_VERIFICATION_GAS = 150_000;
    uint128 internal constant MAX_PAYMASTER_VERIFICATION_GAS = 200_000;
    uint128 internal constant MAX_PAYMASTER_POST_OP_GAS = 200_000;
    uint128 internal constant MAX_PRIORITY_FEE = 2 gwei;
    uint128 internal constant MAX_FEE = 2 gwei;
    uint32 internal constant POLICY_ENTITY_ID = 1;
    uint256 internal constant DEFAULT_VOLUME_LIMIT = 1e36;

    GrowYieldAdapterRegistry internal registry;
    GrowYieldExecutorV3 internal executor;
    GrowYieldPolicyModule internal policyModule;
    address internal sponsorPaymaster;
    address internal riskGuardian;

    MockUnderlying internal underlying;
    MockUnderlying internal otherUnderlying;

    MockAavePool internal aavePool;
    MockAavePool internal aavePoolOther;
    MockMutableAaveDataProvider internal aaveDataProvider;
    MockMutableAaveDataProvider internal aaveDataProviderOther;
    AaveV3Adapter internal aaveAdapter;
    AaveV3Adapter internal aaveAdapterOther;

    MockVaultV2Factory internal morphoFactory;
    MockEligibility internal morphoEligibility;
    MockMorphoV1AdapterFactory internal morphoAdapterFactory;
    MockVault internal morphoChild;
    MockVaultV2 internal morphoWrapper;
    MorphoVaultV2Adapter internal morphoAdapter;

    address internal account;
    uint256 internal automationPk;
    address internal automation;

    function _setUpBase() internal {
        account = makeAddr("smartAccount");
        sponsorPaymaster = address(new MockValidationModule());
        _deployStack();

        address[] memory initialOwners = new address[](1);
        initialOwners[0] = automation;
        vm.prank(account);
        policyModule.onInstall(abi.encode(POLICY_ENTITY_ID, initialOwners));
        _enableAllAdapters(account);
    }

    /// @dev Deploys executor, adapters, fixed registry, then the policy module.
    function _deployStack() internal {
        automationPk = uint256(keccak256("automation"));
        automation = vm.addr(automationPk);
        riskGuardian = makeAddr("riskGuardian");

        executor = new GrowYieldExecutorV3(MAX_LOSS_BPS, riskGuardian);
        underlying = new MockUnderlying();
        otherUnderlying = new MockUnderlying();

        (aavePool, aaveDataProvider, aaveAdapter) = _deployAaveStack(underlying);
        (aavePoolOther, aaveDataProviderOther, aaveAdapterOther) = _deployAaveStack(otherUnderlying);
        _deployMorphoStack();

        IGrowYieldAdapterRegistry.AdapterConfig[] memory adapters =
            new IGrowYieldAdapterRegistry.AdapterConfig[](3);
        adapters[0] = IGrowYieldAdapterRegistry.AdapterConfig(address(aaveAdapter), true, true);
        adapters[1] = IGrowYieldAdapterRegistry.AdapterConfig(address(aaveAdapterOther), true, true);
        adapters[2] = IGrowYieldAdapterRegistry.AdapterConfig(address(morphoAdapter), true, true);
        registry = new GrowYieldAdapterRegistry(address(executor), adapters);
        executor.initializeRegistry(registry);

        policyModule = new GrowYieldPolicyModule(
            address(executor),
            sponsorPaymaster,
            MAX_VERIFICATION_GAS,
            MAX_CALL_GAS,
            MAX_PRE_VERIFICATION_GAS,
            MAX_PAYMASTER_VERIFICATION_GAS,
            MAX_PAYMASTER_POST_OP_GAS,
            MAX_PRIORITY_FEE,
            MAX_FEE
        );
    }

    function _enableAllAdapters(address account_) internal {
        vm.startPrank(account_);
        executor.setAdapterPolicy(
            address(aaveAdapter), DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days
        );
        executor.setAdapterPolicy(
            address(aaveAdapterOther), DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days
        );
        executor.setAdapterPolicy(
            address(morphoAdapter), DEFAULT_VOLUME_LIMIT, DEFAULT_VOLUME_LIMIT, 1 days
        );
        vm.stopPrank();
    }

    function _deployAaveStack(MockUnderlying asset_)
        internal
        returns (MockAavePool pool, MockMutableAaveDataProvider provider, AaveV3Adapter adapter)
    {
        pool = new MockAavePool(asset_);
        provider = new MockMutableAaveDataProvider(address(asset_), address(pool.aToken()));
        adapter = new AaveV3Adapter(
            IAaveV3Pool(address(pool)),
            IAaveProtocolDataProvider(address(provider)),
            address(asset_),
            address(executor)
        );
    }

    function _deployMorphoStack() internal {
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

        morphoAdapter = new MorphoVaultV2Adapter(
            IVaultV2(address(morphoWrapper)),
            IVaultV2Factory(address(morphoFactory)),
            IMorphoVaultV1AdapterFactory(address(morphoAdapterFactory)),
            IMorphoVaultEligibility(address(morphoEligibility)),
            address(executor)
        );
    }

    function _op(IYieldAdapter adapter, OperationKind kind, uint256 amount)
        internal
        view
        returns (Operation memory)
    {
        address sourceToken =
            kind == OperationKind.DEPOSIT ? adapter.asset() : adapter.positionToken();
        AmountMode amountMode =
            amount == type(uint256).max ? AmountMode.FULL_BALANCE : AmountMode.EXACT;
        return Operation({
            adapter: adapter,
            kind: kind,
            sourceToken: sourceToken,
            amount: amountMode == AmountMode.EXACT ? amount : 0,
            amountMode: amountMode,
            minAmountOut: 1
        });
    }

    function _opWithMode(
        IYieldAdapter adapter,
        OperationKind kind,
        AmountMode amountMode,
        uint256 amount,
        uint256 minAmountOut
    ) internal view returns (Operation memory) {
        address sourceToken = kind == OperationKind.DEPOSIT
            ? adapter.asset()
            : adapter.positionToken();
        return Operation({
            adapter: adapter,
            kind: kind,
            sourceToken: sourceToken,
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
        address firstOutputToken =
            a.kind == OperationKind.DEPOSIT ? a.adapter.positionToken() : a.adapter.asset();
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

    /// @dev Canonical policy batch: approve-max, execute, then approve-zero per source token.
    function _batch(address[] memory tokens, Operation[] memory ops)
        internal
        view
        returns (bytes memory)
    {
        uint256 count = tokens.length;
        Call[] memory calls = new Call[](2 * count + 1);

        for (uint256 i; i < count; ++i) {
            calls[i] = Call(tokens[i], 0, _approve(address(executor), type(uint256).max));
            calls[count + 1 + i] = Call(tokens[i], 0, _approve(address(executor), 0));
        }
        calls[count] = Call(address(executor), 0, _executeData(ops));

        return abi.encodeCall(IModularAccount.executeBatch, (calls));
    }

    function _batch1(address token, Operation[] memory ops) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return _batch(tokens, ops);
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
