// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Call, IModularAccount} from
    "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {MessageHashUtils} from
    "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYield1271PolicySignerV3} from
    "../../src/yield-1271/GrowYield1271PolicySignerV3.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {GrowYieldExecutor1271V2} from
    "../../src/yield-1271/GrowYieldExecutor1271V2.sol";
import {
    IGrowYieldExecutor,
    IGrowYieldTypes
} from "../../src/yield-v6/IGrowYieldSystem.sol";
import {MockGrowYieldRegistry1271} from "./MockGrowYieldRegistry1271.sol";
import {
    MockUnderlying,
    MockVault,
    MockAavePool
} from "../invariant/MockYieldVenues.sol";

abstract contract GrowYield1271TestBase is Test, IGrowYieldTypes {
    using MessageHashUtils for bytes32;

    bytes4 internal constant INVALID = 0xffffffff;
    address internal constant ENTRY_POINT =
        0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    GrowYield1271PolicySignerV3 internal signer;
    GrowYieldExecutor1271V2 internal executor;
    MockGrowYieldRegistry1271 internal registry;

    MockUnderlying internal underlying;
    MockUnderlying internal otherUnderlying;
    MockAavePool internal aavePool;
    MockAavePool internal aavePoolOther;
    MockVault internal morphoVault;
    MockVault internal morphoVaultOther;

    address internal account;
    uint256 internal automationPk;
    address internal automation;

    function _setUpBase() internal {
        account = makeAddr("smartAccount");
        automationPk = uint256(keccak256("automation"));
        automation = vm.addr(automationPk);

        registry = new MockGrowYieldRegistry1271();
        executor = new GrowYieldExecutor1271V2(registry, 50);
        signer = new GrowYield1271PolicySignerV3(address(executor));

        underlying = new MockUnderlying();
        otherUnderlying = new MockUnderlying();
        aavePool = new MockAavePool(underlying);
        aavePoolOther = new MockAavePool(otherUnderlying);
        morphoVault = new MockVault(underlying, "Morpho A", "mA");
        morphoVaultOther = new MockVault(otherUnderlying, "Morpho B", "mB");

        _setAave(Protocol.AAVE, address(aavePool), address(underlying), true, true);
        _setAave(
            Protocol.AAVE,
            address(aavePoolOther),
            address(otherUnderlying),
            true,
            true
        );
        _setMorpho(address(morphoVault), address(underlying), true, true);
        _setMorpho(
            address(morphoVaultOther), address(otherUnderlying), true, true
        );

        vm.prank(account);
        signer.configure(automation, 0);
    }

    function _setAave(
        Protocol,
        address pool,
        address asset,
        bool canEnter,
        bool canExit
    ) internal {
        address aToken = address(MockAavePool(pool).aToken());
        Venue memory v = Venue({
            asset: asset,
            positionToken: aToken,
            canEnter: canEnter,
            canExit: canExit
        });
        registry.setEntry(Protocol.AAVE, pool, asset, v);
        registry.setExit(Protocol.AAVE, pool, asset, v);
        // Also index by zero asset hint for exit lookups using position-only flows.
        registry.setExit(Protocol.AAVE, pool, address(0), v);
    }

    function _setMorpho(
        address vault,
        address asset,
        bool canEnter,
        bool canExit
    ) internal {
        Venue memory v = Venue({
            asset: asset,
            positionToken: vault,
            canEnter: canEnter,
            canExit: canExit
        });
        registry.setEntry(Protocol.MORPHO, vault, asset, v);
        registry.setExit(Protocol.MORPHO, vault, asset, v);
        registry.setExit(Protocol.MORPHO, vault, address(0), v);
    }

    function _approve(address spender, uint256 amount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            bytes4(keccak256("approve(address,uint256)")), spender, amount
        );
    }

    function _depositOp(Protocol protocol, address target, address asset)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            IGrowYieldExecutor.depositAll, (protocol, target, asset)
        );
    }

    function _withdrawOp(Protocol protocol, address target, address assetHint)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            IGrowYieldExecutor.withdrawAll, (protocol, target, assetHint)
        );
    }

    function _reallocOp(
        Protocol srcP,
        address srcT,
        address srcHint,
        Protocol dstP,
        address dstT,
        address dstAsset
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(
                keccak256(
                    "reallocateAll(uint8,address,address,uint8,address,address)"
                )
            ),
            srcP,
            srcT,
            srcHint,
            dstP,
            dstT,
            dstAsset
        );
    }

    function _batch(address token, bytes memory opData)
        internal
        view
        returns (bytes memory)
    {
        Call[] memory calls = new Call[](3);
        calls[0] =
            Call(token, 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(address(executor), 0, opData);
        calls[2] = Call(token, 0, _approve(address(executor), 0));
        return abi.encodeCall(IModularAccount.executeBatch, (calls));
    }

    function _baseUserOp(bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp.sender = account;
        userOp.nonce = 1;
        userOp.initCode = "";
        userOp.callData = callData;
        userOp.accountGasLimits =
            bytes32((uint256(500_000) << 128) | uint256(500_000));
        userOp.preVerificationGas = 50_000;
        userOp.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        userOp.paymasterAndData = "";
        userOp.signature = "";
    }

    function _signAuth(bytes32 userOpHash, uint48 validUntil)
        internal
        view
        returns (bytes memory)
    {
        return _signAuthWithKey(automationPk, userOpHash, validUntil);
    }

    function _signAuthWithKey(
        uint256 pk,
        bytes32 userOpHash,
        uint48 validUntil
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "GrowYieldAuthorization(bytes32 userOpHash,uint48 validUntil)"
                ),
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
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
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
            GrowYield1271PolicySignerV3.Proof({
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
        bytes32 userOpHash =
            GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        proof = _encodeProof(
            userOp, ENTRY_POINT, validUntil, _signAuth(userOpHash, validUntil)
        );
        ethHash = userOpHash.toEthSignedMessageHash();
    }

    function _assertInvalid(bytes32 hash, bytes memory proof) internal view {
        assertEq(signer.isValidSignature(hash, proof), INVALID);
    }
}
