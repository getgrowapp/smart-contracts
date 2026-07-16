// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    Call,
    IERC6900Account
} from "@erc6900/reference-implementation/interfaces/IERC6900Account.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IVaultV2Factory} from "vault-v2/interfaces/IVaultV2Factory.sol";

import {GrowYield1271PolicySignerV4} from "../../src/yield-1271/GrowYield1271PolicySignerV4.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {GrowYieldExecutorV3} from "../../src/yield-1271/GrowYieldExecutorV3.sol";
import {GrowYieldAdapterRegistry} from "../../src/yield-1271/GrowYieldAdapterRegistry.sol";
import {AaveV3Adapter} from "../../src/yield-1271/adapters/AaveV3Adapter.sol";
import {MorphoVaultV2Adapter} from "../../src/yield-1271/adapters/MorphoVaultV2Adapter.sol";
import {IMorphoVaultEligibility} from "../../src/interfaces/IMorphoVaultEligibility.sol";
import {IAaveV3Pool} from "../../src/interfaces/IAaveV3Pool.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {
    IGrowYieldExecutor,
    IYieldAdapter,
    Operation,
    OperationKind
} from "../../src/yield-1271/IGrowYield1271.sol";
import {MockUnderlying, MockVault, MockAavePool} from "../invariant/MockYieldVenues.sol";
import {
    MockEligibility,
    MockMorphoV1Adapter,
    MockMutableAaveDataProvider,
    MockVaultV2,
    MockVaultV2Factory
} from "./mocks/MockVaultV2Stack.sol";

abstract contract GrowYield1271TestBase is Test {
    using MessageHashUtils for bytes32;

    bytes4 internal constant MAGIC = GrowYield1271PolicySignerV4.isValidSignature.selector;
    bytes4 internal constant INVALID = 0xffffffff;
    address internal constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    uint16 internal constant MAX_LOSS_BPS = 50;

    GrowYieldAdapterRegistry internal registry;
    GrowYieldExecutorV3 internal executor;
    GrowYield1271PolicySignerV4 internal signer;
    address internal module;

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
    address internal morphoAdapterFactory;
    MockVault internal morphoChild;
    MockVaultV2 internal morphoWrapper;
    MorphoVaultV2Adapter internal morphoAdapter;

    address internal account;
    uint256 internal automationPk;
    address internal automation;

    function _setUpBase() internal {
        account = makeAddr("smartAccount");
        module = makeAddr("validationModule");
        _deployStack();

        vm.prank(account);
        signer.configure(automation, 0);
    }

    /**
     * @dev Deploys the Grow stack (registry, executor, signer) and mock venues with
     *      their adapters. Callers must set `module` first — the signer pins it as the
     *      only authorized `isValidSignature` caller. `_setUpBase` uses a synthetic
     *      address; the E2E suite injects the real ERC-6900 validation module and
     *      performs `configure` through a UserOperation instead of a prank.
     */
    function _deployStack() internal {
        automationPk = uint256(keccak256("automation"));
        automation = vm.addr(automationPk);

        registry = new GrowYieldAdapterRegistry(address(this));
        executor = new GrowYieldExecutorV3(registry, MAX_LOSS_BPS);
        signer = new GrowYield1271PolicySignerV4(address(executor), module);

        underlying = new MockUnderlying();
        otherUnderlying = new MockUnderlying();

        (aavePool, aaveDataProvider, aaveAdapter) = _deployAaveStack(underlying);
        (aavePoolOther, aaveDataProviderOther, aaveAdapterOther) = _deployAaveStack(otherUnderlying);
        _deployMorphoStack();

        registry.setAdapter(address(aaveAdapter), true, true);
        registry.setAdapter(address(aaveAdapterOther), true, true);
        registry.setAdapter(address(morphoAdapter), true, true);
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
        morphoAdapterFactory = makeAddr("morphoAdapterFactory");

        morphoChild = new MockVault(IERC20(address(underlying)), "Child", "cV");
        morphoFactory.set(address(morphoChild), true);
        morphoEligibility.set(address(morphoChild), true);

        morphoWrapper = new MockVaultV2(IERC20(address(underlying)), "Wrapper", "wV");
        morphoFactory.set(address(morphoWrapper), true);
        morphoWrapper.addMockAdapter(
            address(
                new MockMorphoV1Adapter(
                    morphoAdapterFactory, address(morphoWrapper), address(morphoChild)
                )
            )
        );
        morphoWrapper.setAbdicated(IVaultV2.addAdapter.selector, true);
        morphoWrapper.setAbdicated(IVaultV2.removeAdapter.selector, true);

        morphoAdapter = new MorphoVaultV2Adapter(
            IVaultV2(address(morphoWrapper)),
            IVaultV2Factory(address(morphoFactory)),
            morphoAdapterFactory,
            IMorphoVaultEligibility(address(morphoEligibility)),
            address(executor)
        );
    }

    // --- operation / batch builders ---

    function _op(IYieldAdapter adapter, OperationKind kind, uint256 amount)
        internal
        pure
        returns (Operation memory)
    {
        return Operation({adapter: adapter, kind: kind, amount: amount});
    }

    function _ops1(Operation memory op) internal pure returns (Operation[] memory ops) {
        ops = new Operation[](1);
        ops[0] = op;
    }

    function _ops2(Operation memory a, Operation memory b)
        internal
        pure
        returns (Operation[] memory ops)
    {
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

    /// @dev Canonical policy batch: k approve-max, execute(ops), k approve-zero.
    function _batch(address[] memory tokens, Operation[] memory ops)
        internal
        view
        returns (bytes memory)
    {
        uint256 k = tokens.length;
        Call[] memory calls = new Call[](2 * k + 1);

        for (uint256 i; i < k; ++i) {
            calls[i] = Call(tokens[i], 0, _approve(address(executor), type(uint256).max));
            calls[k + 1 + i] = Call(tokens[i], 0, _approve(address(executor), 0));
        }
        calls[k] = Call(address(executor), 0, _executeData(ops));

        return abi.encodeCall(IERC6900Account.executeBatch, (calls));
    }

    function _batch1(address token, Operation[] memory ops) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return _batch(tokens, ops);
    }

    // --- userOp / proof builders ---

    function _baseUserOp(bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp.sender = account;
        userOp.nonce = 1;
        userOp.initCode = "";
        userOp.callData = callData;
        userOp.accountGasLimits = bytes32((uint256(500_000) << 128) | uint256(500_000));
        userOp.preVerificationGas = 50_000;
        userOp.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        userOp.paymasterAndData = "";
        userOp.signature = "";
    }

    function _signAuth(bytes32 userOpHash, uint48 validUntil) internal view returns (bytes memory) {
        return _signAuthWithKey(automationPk, userOpHash, validUntil);
    }

    function _signAuthWithKey(uint256 pk, bytes32 userOpHash, uint48 validUntil)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("GrowYieldAuthorization(bytes32 userOpHash,uint48 validUntil)"),
                userOpHash,
                validUntil
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("GrowYieldPolicySigner")),
                keccak256(bytes("1")),
                block.chainid,
                address(signer)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _encodeProof(
        PackedUserOperation memory userOp,
        address entryPoint,
        uint48 validUntil,
        bytes memory authSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            GrowYield1271PolicySignerV4.Proof({
                version: 1,
                entryPoint: entryPoint,
                validUntil: validUntil,
                userOp: userOp,
                signature: authSig
            })
        );
    }

    function _validProof(PackedUserOperation memory userOp)
        internal
        view
        returns (bytes memory proof, bytes32 ethHash)
    {
        bytes32 userOpHash = GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        proof = _encodeProof(userOp, ENTRY_POINT, validUntil, _signAuth(userOpHash, validUntil));
        ethHash = userOpHash.toEthSignedMessageHash();
    }

    // --- signer call helpers (module-pinned caller) ---

    function _isValid(bytes32 hash, bytes memory proof) internal returns (bytes4 result) {
        // startPrank: single vm.prank cannot override the fuzzer's own prank in
        // invariant runs.
        vm.startPrank(module);
        result = signer.isValidSignature(hash, proof);
        vm.stopPrank();
    }

    function _assertValid(bytes32 hash, bytes memory proof) internal {
        assertEq(_isValid(hash, proof), MAGIC);
    }

    function _assertInvalid(bytes32 hash, bytes memory proof) internal {
        assertEq(_isValid(hash, proof), INVALID);
    }
}
