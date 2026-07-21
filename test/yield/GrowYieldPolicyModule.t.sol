// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Call,
    IModularAccount
} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {GrowYieldTestBase} from "./GrowYieldTestBase.sol";
import {IGrowYieldPolicyModule} from "../../src/interfaces/IGrowYieldPolicyModule.sol";
import {BaseModule} from "@erc6900/reference-implementation/modules/BaseModule.sol";
import {Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";

/// @notice Direct ERC-6900 policy validation, owner lifecycle, and policy bounds.
contract GrowYieldPolicyModuleTest is GrowYieldTestBase {
    function setUp() public {
        _setUpBase();
    }

    function _depositOps() internal view returns (Operation[] memory) {
        return _ops1(_op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max));
    }

    function _validDeposit(uint256 key)
        internal
        view
        returns (PackedUserOperation memory userOp, bytes32 userOpHash)
    {
        userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOpHash = keccak256("valid-deposit");
        userOp = _authorize(userOp, userOpHash, key);
    }

    function test_acceptsDepositBatch() public {
        (PackedUserOperation memory userOp, bytes32 hash) = _validDeposit(automationPk);
        _assertValid(userOp, hash);
    }

    function test_acceptsRedeemBatch() public {
        PackedUserOperation memory userOp = _baseUserOp(
            _batch1(
                address(aavePool.aToken()),
                _ops1(_op(aaveAdapter, OperationKind.REDEEM, type(uint256).max))
            )
        );
        bytes32 hash = keccak256("redeem");
        userOp = _authorize(userOp, hash);
        _assertValid(userOp, hash);
    }

    function test_acceptsTwoVenueReallocation() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(aavePool.aToken());
        tokens[1] = address(underlying);
        PackedUserOperation memory userOp = _baseUserOp(
            _batch(
                tokens,
                _ops2(
                    _op(aaveAdapter, OperationKind.REDEEM, type(uint256).max),
                    _op(morphoAdapter, OperationKind.DEPOSIT, type(uint256).max)
                )
            )
        );
        bytes32 hash = keccak256("reallocate");
        userOp = _authorize(userOp, hash);
        _assertValid(userOp, hash);
    }

    function test_addOwner_authorizesSecondOwner() public {
        (address secondOwner, uint256 secondKey) = makeAddrAndKey("secondOwner");
        vm.prank(account);
        policyModule.addOwner(secondOwner);

        (PackedUserOperation memory userOp, bytes32 hash) = _validDeposit(secondKey);
        _assertValid(userOp, hash);
        assertEq(policyModule.ownerCount(account), 2);
        assertTrue(policyModule.isOwner(account, automation));
        assertTrue(policyModule.isOwner(account, secondOwner));
    }

    function test_ownerEnumeration() public {
        address secondOwner = makeAddr("secondOwner");
        vm.prank(account);
        policyModule.addOwner(secondOwner);

        assertEq(policyModule.ownerAt(account, 0), automation);
        assertEq(policyModule.ownerAt(account, 1), secondOwner);

        vm.expectRevert(IGrowYieldPolicyModule.OwnerNotFound.selector);
        policyModule.ownerAt(account, 2);
    }

    function test_removeOwner_revokesOnlyRemovedOwner() public {
        (address secondOwner, uint256 secondKey) = makeAddrAndKey("secondOwner");
        vm.startPrank(account);
        policyModule.addOwner(secondOwner);
        policyModule.removeOwner(automation);
        vm.stopPrank();

        (PackedUserOperation memory removedOp, bytes32 removedHash) = _validDeposit(automationPk);
        _assertInvalid(removedOp, removedHash);

        (PackedUserOperation memory retainedOp, bytes32 retainedHash) = _validDeposit(secondKey);
        _assertValid(retainedOp, retainedHash);
    }

    function test_removeLastOwner_disablesPolicy() public {
        vm.prank(account);
        policyModule.removeOwner(automation);

        (PackedUserOperation memory userOp, bytes32 hash) = _validDeposit(automationPk);
        _assertInvalid(userOp, hash);
        assertEq(policyModule.ownerCount(account), 0);
    }

    function test_ownerSetsAreAccountScoped() public {
        address otherAccount = makeAddr("otherAccount");
        (address otherOwner, uint256 otherKey) = makeAddrAndKey("otherOwner");
        address[] memory owners = new address[](1);
        owners[0] = otherOwner;
        vm.prank(otherAccount);
        policyModule.onInstall(abi.encode(uint32(7), owners));

        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.sender = otherAccount;
        bytes32 hash = keccak256("other-account");
        userOp = _authorize(userOp, hash, otherKey);
        vm.prank(otherAccount);
        assertEq(uint160(policyModule.validateUserOp(7, userOp, hash)), 0);

        assertFalse(policyModule.isOwner(account, otherOwner));
        assertFalse(policyModule.isOwner(otherAccount, automation));
    }

    function test_rejectsDuplicateAndInvalidOwner() public {
        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.OwnerAlreadyExists.selector);
        policyModule.addOwner(automation);

        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.InvalidConfiguration.selector);
        policyModule.addOwner(address(0));
    }

    function test_capsOwnerSet() public {
        vm.startPrank(account);
        for (uint256 i = 1; i < policyModule.MAX_OWNERS(); ++i) {
            policyModule.addOwner(vm.addr(10_000 + i));
        }
        vm.expectRevert(IGrowYieldPolicyModule.TooManyOwners.selector);
        policyModule.addOwner(makeAddr("ninth"));
        vm.stopPrank();
    }

    function test_reinstallRequiresUninstallFirst() public {
        address replacement = makeAddr("replacement");
        address[] memory owners = new address[](1);
        owners[0] = replacement;
        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.PolicyAlreadyInstalled.selector);
        policyModule.onInstall(abi.encode(uint32(9), owners));

        assertTrue(policyModule.isOwner(account, automation));
        assertFalse(policyModule.isOwner(account, replacement));
        assertEq(policyModule.policyEntityId(account), POLICY_ENTITY_ID);

        vm.startPrank(account);
        policyModule.onUninstall(hex"");
        policyModule.onInstall(abi.encode(uint32(9), owners));
        vm.stopPrank();

        assertFalse(policyModule.isOwner(account, automation));
        assertTrue(policyModule.isOwner(account, replacement));
        assertEq(policyModule.policyEntityId(account), 9);
    }

    function test_uninstallClearsEntityAndOwners() public {
        vm.prank(account);
        policyModule.onUninstall(hex"");
        assertEq(policyModule.ownerCount(account), 0);
        assertEq(policyModule.policyEntityId(account), 0);

        vm.prank(account);
        vm.expectRevert(IGrowYieldPolicyModule.PolicyNotInstalled.selector);
        policyModule.addOwner(automation);
    }

    function test_rejectsWrongCallingAccount() public {
        (PackedUserOperation memory userOp, bytes32 hash) = _validDeposit(automationPk);
        vm.prank(makeAddr("notAccount"));
        assertEq(uint160(policyModule.validateUserOp(POLICY_ENTITY_ID, userOp, hash)), 1);
    }

    function test_rejectsWrongEntity() public {
        (PackedUserOperation memory userOp, bytes32 hash) = _validDeposit(automationPk);
        vm.prank(account);
        assertEq(uint160(policyModule.validateUserOp(0, userOp, hash)), 1);
    }

    function test_rejectsWrongOwnerKey() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrongOwner");
        (PackedUserOperation memory userOp, bytes32 hash) = _validDeposit(wrongKey);
        _assertInvalid(userOp, hash);
    }

    function test_signatureBindsUserOpHash() public {
        (PackedUserOperation memory userOp, bytes32 hash) = _validDeposit(automationPk);
        _assertValid(userOp, hash);
        _assertInvalid(userOp, keccak256("mutated"));
    }

    function test_returnsValidationDataWithoutTimeRange() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        bytes32 hash = keccak256("no-time-range");
        userOp = _authorize(userOp, hash);
        assertEq(_validationResult(userOp, hash), 0);
    }

    function test_rejectsMalformedSignature_withoutRevert() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.signature = hex"01";
        _assertInvalid(userOp, keccak256("malformed"));
    }

    function test_rejectsLegacy71ByteSignature() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        bytes32 hash = keccak256("legacy-signature");
        userOp.signature =
            abi.encodePacked(bytes6(uint48(1)), _signAuthorization(automationPk, hash));
        _assertInvalid(userOp, hash);
    }

    function test_rejectsInitCode() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.initCode = hex"01";
        bytes32 hash = keccak256("init-code");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);
    }

    function test_rejectsWrongOrMissingPaymaster() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.paymasterAndData = "";
        bytes32 hash = keccak256("missing-paymaster");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);

        userOp.paymasterAndData =
            abi.encodePacked(makeAddr("wrongPaymaster"), uint128(100_000), uint128(100_000));
        hash = keccak256("wrong-paymaster");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);
    }

    function test_rejectsGasAndFeeFieldsAboveCaps() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.preVerificationGas = MAX_PRE_VERIFICATION_GAS + 1;
        bytes32 hash = keccak256("high-pre-verification");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);

        userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.gasFees = bytes32((uint256(MAX_PRIORITY_FEE) << 128) | uint256(MAX_FEE + 1));
        hash = keccak256("high-fee");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);

        userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.accountGasLimits =
            bytes32((uint256(MAX_VERIFICATION_GAS + 1) << 128) | uint256(MAX_CALL_GAS));
        hash = keccak256("high-verification-gas");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);
    }

    function test_rejectsPaymasterGasAboveCaps() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.paymasterAndData = abi.encodePacked(
            sponsorPaymaster,
            uint128(MAX_PAYMASTER_VERIFICATION_GAS + 1),
            uint128(MAX_PAYMASTER_POST_OP_GAS)
        );
        bytes32 hash = keccak256("high-paymaster-gas");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);
    }

    function test_rejectsOversizedPaymasterData() public {
        PackedUserOperation memory userOp = _baseUserOp(_batch1(address(underlying), _depositOps()));
        userOp.paymasterAndData = bytes.concat(
            abi.encodePacked(sponsorPaymaster, uint128(100_000), uint128(100_000)), new bytes(461)
        );
        bytes32 hash = keccak256("oversized-paymaster-data");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);
    }

    function test_rejectsMissingApprovalReset() public {
        Call[] memory calls = new Call[](2);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(address(executor), 0, _executeData(_depositOps()));
        _assertOwnerSignedPolicyRejection(abi.encodeCall(IModularAccount.executeBatch, (calls)));
    }

    function test_rejectsForeignSpender() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(makeAddr("attacker"), type(uint256).max));
        calls[1] = Call(address(executor), 0, _executeData(_depositOps()));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        _assertOwnerSignedPolicyRejection(abi.encodeCall(IModularAccount.executeBatch, (calls)));
    }

    function test_rejectsWrongApprovalToken() public {
        _assertOwnerSignedPolicyRejection(_batch1(address(otherUnderlying), _depositOps()));
    }

    function test_rejectsNonExecutorTarget() public {
        Call[] memory calls = new Call[](3);
        calls[0] = Call(address(underlying), 0, _approve(address(executor), type(uint256).max));
        calls[1] = Call(makeAddr("evil"), 0, _executeData(_depositOps()));
        calls[2] = Call(address(underlying), 0, _approve(address(executor), 0));
        _assertOwnerSignedPolicyRejection(abi.encodeCall(IModularAccount.executeBatch, (calls)));
    }

    function test_rejectsEmptyAndOversizedOps() public {
        _assertOwnerSignedPolicyRejection(_batch1(address(underlying), new Operation[](0)));

        Operation[] memory ops = new Operation[](5);
        for (uint256 i; i < ops.length; ++i) {
            ops[i] = _op(aaveAdapter, OperationKind.DEPOSIT, 1e6);
        }
        _assertOwnerSignedPolicyRejection(_batch1(address(underlying), ops));
    }

    function test_rejectsOperationWithoutAbsoluteOutputFloor() public {
        Operation[] memory ops = _depositOps();
        ops[0].minAmountOut = 0;
        _assertOwnerSignedPolicyRejection(_batch1(address(underlying), ops));
    }

    function test_malformedCallData_returnsFailure() public {
        PackedUserOperation memory userOp = _baseUserOp(hex"12345678deadbeef");
        bytes32 hash = keccak256("malformed-call-data");
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);
    }

    function test_runtimeAnd1271PathsAreDisabled() public {
        vm.expectRevert(BaseModule.NotImplemented.selector);
        policyModule.validateRuntime(account, 0, automation, 0, "", "");
        assertEq(
            policyModule.validateSignature(account, 0, automation, bytes32(0), ""),
            bytes4(0xffffffff)
        );
    }

    function _assertOwnerSignedPolicyRejection(bytes memory callData) private {
        PackedUserOperation memory userOp = _baseUserOp(callData);
        bytes32 hash = keccak256(callData);
        userOp = _authorize(userOp, hash);
        _assertInvalid(userOp, hash);
    }
}
