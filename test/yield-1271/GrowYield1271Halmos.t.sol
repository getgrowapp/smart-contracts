// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Call,
    IERC6900Account
} from "@erc6900/reference-implementation/interfaces/IERC6900Account.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {GrowYieldPolicyLib} from "../../src/yield-1271/GrowYieldPolicyLib.sol";
import {
    IGrowYieldAdapterRegistry,
    Operation,
    OperationKind
} from "../../src/yield-1271/IGrowYield1271.sol";

/**
 * @notice Halmos symbolic properties for the yield-1271 signer + executor.
 *
 * Run:
 *   halmos --contract GrowYield1271HalmosTest
 */
contract GrowYield1271HalmosTest is GrowYield1271TestBase {
    using MessageHashUtils for bytes32;

    function setUp() public {
        _setUpBase();
    }

    function _depositOps() internal view returns (Operation[] memory) {
        return _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max));
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_shortOrGarbageProof_returnsInvalid(bytes memory junk) public {
        // Bound to encodings too small to be a well-formed Proof with signature.
        if (junk.length >= 64) return;
        assertEq(_isValid(bytes32(uint256(1)), junk), INVALID);
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_wrongOuterHash_returnsInvalid(bytes32 wrongHash) public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        bytes32 userOpHash = GrowUserOpHashLib.hash(userOp, ENTRY_POINT, block.chainid);
        if (wrongHash == userOpHash.toEthSignedMessageHash()) return;

        uint48 validUntil = uint48(block.timestamp + 1 hours);
        bytes memory proof =
            _encodeProof(userOp, ENTRY_POINT, validUntil, _signAuth(userOpHash, validUntil));
        assertEq(_isValid(wrongHash, proof), INVALID);
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_nonModuleCaller_neverValidates(address caller) public {
        if (caller == module) return;
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        (bytes memory proof, bytes32 ethHash) = _validProof(userOp);

        vm.prank(caller);
        assertEq(signer.isValidSignature(ethHash, proof), INVALID);
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_policyRejectsNonExecutorTarget(address target) public view {
        if (target == address(executor) || target == address(0) || target == account) {
            return;
        }
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(target, 0, _executeData(_depositOps()));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));

        assert(
            !GrowYieldPolicyLib.isAllowed(
                account,
                address(executor),
                IGrowYieldAdapterRegistry(address(registry)),
                abi.encodeCall(IERC6900Account.executeBatch, (calls))
            )
        );
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_policyRejectsApprovalTokenMismatch(address token) public view {
        // Deposit's source token is the venue underlying; any other approval target fails.
        if (token == address(underlying)) return;
        Call[] memory calls = new Call[](3);
        calls[0] = Call(token, 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(address(executor), 0, _executeData(_depositOps()));
        calls[2] = Call(token, 0, _approve(address(executor), 0));

        assert(
            !GrowYieldPolicyLib.isAllowed(
                account,
                address(executor),
                IGrowYieldAdapterRegistry(address(registry)),
                abi.encodeCall(IERC6900Account.executeBatch, (calls))
            )
        );
    }

    /// @custom:halmos --solver-timeout-assertion 0
    function check_successfulDeposit_leavesNoResidual(uint96 amountSeed) public {
        uint256 amount = uint256(amountSeed);
        if (amount == 0) amount = 1;
        if (amount > 1_000_000e6) amount = 1_000_000e6;

        underlying.mint(account, amount);
        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        executor.execute(_ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max)));
        vm.stopPrank();

        assert(underlying.balanceOf(address(executor)) == 0);
        assert(underlying.balanceOf(address(aaveAdapter)) == 0);
        assert(aavePool.aToken().balanceOf(address(executor)) == 0);
        assert(aavePool.aToken().balanceOf(address(aaveAdapter)) == 0);
        assert(aavePool.aToken().balanceOf(account) == amount);
    }
}
