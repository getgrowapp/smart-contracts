// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from
    "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYield1271PolicySignerV3} from
    "../../src/yield-1271/GrowYield1271PolicySignerV3.sol";
import {GrowYieldExecutor1271V2} from
    "../../src/yield-1271/GrowYieldExecutor1271V2.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {GrowYieldPolicyLib} from "../../src/yield-1271/GrowYieldPolicyLib.sol";
import {
    IGrowYieldTypes
} from "../../src/yield-v6/IGrowYieldSystem.sol";
import {MockGrowYieldRegistry1271} from "./MockGrowYieldRegistry1271.sol";
import {
    MockUnderlying,
    MockVault,
    MockAavePool
} from "../invariant/MockYieldVenues.sol";
import {Call, IModularAccount} from
    "@erc6900/reference-implementation/interfaces/IModularAccount.sol";

/**
 * @notice Halmos symbolic properties for yield-1271 signer + executor.
 *
 * Run:
 *   halmos --contract GrowYield1271HalmosTest
 */
contract GrowYield1271HalmosTest is Test, IGrowYieldTypes {
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

    address internal account = address(0xA11CE);
    uint256 internal automationPk = 0xA017;
    address internal automation;

    function setUp() public {
        automation = vm.addr(automationPk);
        registry = new MockGrowYieldRegistry1271();
        executor = new GrowYieldExecutor1271V2(registry, 50);
        signer = new GrowYield1271PolicySignerV3(address(executor));

        underlying = new MockUnderlying();
        otherUnderlying = new MockUnderlying();
        aavePool = new MockAavePool(underlying);
        aavePoolOther = new MockAavePool(otherUnderlying);
        morphoVault = new MockVault(underlying, "mA", "mA");

        Venue memory v = Venue({
            asset: address(underlying),
            positionToken: address(aavePool.aToken()),
            canEnter: true,
            canExit: true
        });
        registry.setEntry(Protocol.AAVE, address(aavePool), address(underlying), v);
        registry.setExit(Protocol.AAVE, address(aavePool), address(underlying), v);

        Venue memory v2 = Venue({
            asset: address(otherUnderlying),
            positionToken: address(aavePoolOther.aToken()),
            canEnter: true,
            canExit: true
        });
        registry.setEntry(
            Protocol.AAVE, address(aavePoolOther), address(otherUnderlying), v2
        );
        registry.setExit(
            Protocol.AAVE, address(aavePoolOther), address(otherUnderlying), v2
        );

        Venue memory mv = Venue({
            asset: address(underlying),
            positionToken: address(morphoVault),
            canEnter: true,
            canExit: true
        });
        registry.setEntry(
            Protocol.MORPHO, address(morphoVault), address(underlying), mv
        );
        registry.setExit(
            Protocol.MORPHO, address(morphoVault), address(underlying), mv
        );

        vm.prank(account);
        signer.configure(automation, 0);
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_shortOrGarbageProof_returnsInvalid(bytes memory junk)
        public
        view
    {
        // Bound to encodings too small to be a well-formed Proof with signature.
        if (junk.length >= 64) return;
        bytes4 result = signer.isValidSignature(bytes32(uint256(1)), junk);
        assert(result == INVALID);
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_wrongOuterHash_returnsInvalid(bytes32 wrongHash) public view {
        PackedUserOperation memory userOp = _depositUserOp();
        bytes32 userOpHash =
            GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        // Avoid the concrete valid hash coincidentally equaling the symbolic value
        // for the concrete case where wrongHash == ethSigned — constrain !=.
        bytes32 eth = userOpHash.toEthSignedMessageHash();
        if (wrongHash == eth) return;

        uint48 validUntil = uint48(block.timestamp + 1 hours);
        bytes memory proof = abi.encode(
            GrowYield1271PolicySignerV3.Proof({
                version: 1,
                entryPoint: ENTRY_POINT,
                validUntil: validUntil,
                userOp: userOp,
                signature: _sign(userOpHash, validUntil)
            })
        );
        assert(signer.isValidSignature(wrongHash, proof) == INVALID);
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_reallocate_rejectsAssetMismatch() public {
        uint256 amount = 100e6;
        underlying.mint(account, amount);

        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        IERC20(address(aavePool.aToken())).approve(
            address(executor), type(uint256).max
        );
        executor.depositAll(Protocol.AAVE, address(aavePool), address(underlying));

        try executor.reallocateAll(
            Protocol.AAVE,
            address(aavePool),
            address(underlying),
            Protocol.AAVE,
            address(aavePoolOther),
            address(otherUnderlying)
        ) {
            assert(false);
        } catch {
            assert(underlying.balanceOf(address(executor)) == 0);
            assert(otherUnderlying.balanceOf(address(executor)) == 0);
        }
        vm.stopPrank();
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_policyRejectsNonExecutorTarget(address target) public view {
        if (target == address(executor) || target == address(0) || target == account)
        {
            return;
        }
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            target,
            0,
            abi.encodeCall(
                GrowYieldExecutor1271V2.depositAll,
                (Protocol.AAVE, address(aavePool), address(underlying))
            )
        );
        calls[2] =
            Call(address(underlying), 0, _approve(address(executor), 0));
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        assert(
            !GrowYieldPolicyLib.isAllowed(
                account, address(executor), registry, callData
            )
        );
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_successfulDeposit_leavesNoResidual(uint96 amountSeed)
        public
    {
        uint256 amount = uint256(amountSeed);
        if (amount == 0) amount = 1;
        if (amount > 1_000_000e6) amount = 1_000_000e6;

        underlying.mint(account, amount);
        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        executor.depositAll(Protocol.AAVE, address(aavePool), address(underlying));
        vm.stopPrank();

        assert(underlying.balanceOf(address(executor)) == 0);
        assert(aavePool.aToken().balanceOf(address(executor)) == 0);
        assert(aavePool.aToken().balanceOf(account) == amount);
    }

    function _depositUserOp()
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            address(executor),
            0,
            abi.encodeCall(
                GrowYieldExecutor1271V2.depositAll,
                (Protocol.AAVE, address(aavePool), address(underlying))
            )
        );
        calls[2] =
            Call(address(underlying), 0, _approve(address(executor), 0));

        userOp.sender = account;
        userOp.nonce = 1;
        userOp.initCode = "";
        userOp.callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        userOp.accountGasLimits =
            bytes32((uint256(500_000) << 128) | uint256(500_000));
        userOp.preVerificationGas = 50_000;
        userOp.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        userOp.paymasterAndData = "";
        userOp.signature = "";
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

    function _sign(bytes32 userOpHash, uint48 validUntil)
        internal
        view
        returns (bytes memory)
    {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(automationPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
