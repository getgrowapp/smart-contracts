// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Call, IModularAccount} from
    "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {MessageHashUtils} from
    "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {GrowYieldPolicyLib} from "../../src/yield-1271/GrowYieldPolicyLib.sol";

contract GrowYield1271PolicySignerTest is GrowYield1271TestBase {
    using MessageHashUtils for bytes32;

    function setUp() public {
        _setUpBase();
    }

    function test_isValidSignature_acceptsAlchemyEthSignedUserOpHash() public {
        PackedUserOperation memory userOp = _baseUserOp(
            _batch(
                address(underlying),
                _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
            )
        );
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);
        assertEq(
            signer.isValidSignature(ethHash, proof),
            signer.isValidSignature.selector
        );
    }

    function test_isValidSignature_rejectsRawUserOpHash() public {
        PackedUserOperation memory userOp = _baseUserOp(
            _batch(
                address(underlying),
                _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
            )
        );
        bytes32 userOpHash =
            GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        bytes memory proof = _encodeProof(
            userOp, ENTRY_POINT, validUntil, _signAuth(userOpHash, validUntil)
        );
        assertEq(signer.isValidSignature(userOpHash, proof), INVALID);
    }

    function test_policy_rejectsWrongBatchLength() public view {
        Call[] memory calls = new Call[](2);
        calls[0] = Call(
            address(underlying),
            0,
            _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            address(executor),
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        assertFalse(
            GrowYieldPolicyLib.isAllowed(
                account, address(executor), registry, callData
            )
        );
    }

    function test_policy_acceptsDepositBatch() public view {
        assertTrue(
            GrowYieldPolicyLib.isAllowed(
                account,
                address(executor),
                registry,
                _batch(
                    address(underlying),
                    _depositOp(
                        Protocol.AAVE, address(aavePool), address(underlying)
                    )
                )
            )
        );
    }

    function test_policy_acceptsWithdrawBatch_withPositionToken() public view {
        address aToken = address(aavePool.aToken());
        assertTrue(
            GrowYieldPolicyLib.isAllowed(
                account,
                address(executor),
                registry,
                _batch(
                    aToken,
                    _withdrawOp(
                        Protocol.AAVE, address(aavePool), address(underlying)
                    )
                )
            )
        );
    }

    function test_policy_rejectsWithdrawBatch_withUnderlyingApprove()
        public
        view
    {
        assertFalse(
            GrowYieldPolicyLib.isAllowed(
                account,
                address(executor),
                registry,
                _batch(
                    address(underlying),
                    _withdrawOp(
                        Protocol.AAVE, address(aavePool), address(underlying)
                    )
                )
            )
        );
    }

    function test_policy_rejectsSelfCall() public view {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(
            account, 0, _approve(address(executor), type(uint256).max)
        );
        calls[1] = Call(
            address(executor),
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        calls[2] = Call(account, 0, _approve(address(executor), 0));

        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        assertFalse(
            GrowYieldPolicyLib.isAllowed(
                account, address(executor), registry, callData
            )
        );
    }

    function test_policy_rejectsNonMaxApprove() public view {
        Call[] memory calls = new Call[](3);
        calls[0] =
            Call(address(underlying), 0, _approve(address(executor), 1e6));
        calls[1] = Call(
            address(executor),
            0,
            _depositOp(Protocol.AAVE, address(aavePool), address(underlying))
        );
        calls[2] =
            Call(address(underlying), 0, _approve(address(executor), 0));

        bytes memory callData =
            abi.encodeCall(IModularAccount.executeBatch, (calls));
        assertFalse(
            GrowYieldPolicyLib.isAllowed(
                account, address(executor), registry, callData
            )
        );
    }

    function test_malformedProof_returnsInvalid_notRevert() public view {
        assertEq(signer.isValidSignature(bytes32(0), hex""), INVALID);
        assertEq(signer.isValidSignature(bytes32(0), hex"aaaa"), INVALID);
    }
}
