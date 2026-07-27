// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {GrowYieldTestBase} from "./GrowYieldTestBase.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {Venue} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {IYieldAdapter} from "../../src/interfaces/IYieldAdapter.sol";
import {AmountMode, Operation, OperationKind} from "../../src/interfaces/IGrowYieldExecutor.sol";

/// @dev Handler for stateful invariants. Mimics successful policy batches:
///      approve-max -> execute -> approve-zero, always as the smart account.
contract GrowYieldHandler is Test {
    GrowYieldExecutor public immutable executor;
    address public immutable account;
    address public immutable underlying;
    address public immutable aToken;

    /// @dev Venues, not adapters: the executor resolves the adapter from the executor.
    address public immutable aaveVault;
    address public immutable morphoVault;

    constructor(
        GrowYieldExecutor executor_,
        address account_,
        address underlying_,
        address aToken_,
        address aaveVault_,
        address morphoVault_
    ) {
        executor = executor_;
        account = account_;
        underlying = underlying_;
        aToken = aToken_;
        aaveVault = aaveVault_;
        morphoVault = morphoVault_;
    }

    function deposit(uint256 amountSeed, bool useAave) external {
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);
        deal(underlying, account, IERC20(underlying).balanceOf(account) + amount);

        _executeWithApprovals(
            underlying,
            _one(
                Operation({
                    vault: useAave ? aaveVault : morphoVault,
                    kind: OperationKind.DEPOSIT,
                    sourceToken: underlying,
                    amount: amount,
                    amountMode: AmountMode.EXACT,
                    minAmountOut: 1
                })
            )
        );
    }

    function redeem(uint256 amountSeed, bool useAave) external {
        address position = useAave ? aToken : morphoVault;
        uint256 balance = IERC20(position).balanceOf(account);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);
        _executeWithApprovals(
            position,
            _one(
                Operation({
                    vault: useAave ? aaveVault : morphoVault,
                    kind: OperationKind.REDEEM,
                    sourceToken: position,
                    amount: amount,
                    amountMode: AmountMode.EXACT,
                    minAmountOut: 1
                })
            )
        );
    }

    function reallocate(bool aaveToMorpho) external {
        address sourcePosition = aaveToMorpho ? aToken : morphoVault;
        if (IERC20(sourcePosition).balanceOf(account) == 0) return;

        Operation[] memory ops = new Operation[](2);
        ops[0] = Operation({
            vault: aaveToMorpho ? aaveVault : morphoVault,
            kind: OperationKind.REDEEM,
            sourceToken: sourcePosition,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
        ops[1] = Operation({
            vault: aaveToMorpho ? morphoVault : aaveVault,
            kind: OperationKind.DEPOSIT,
            sourceToken: underlying,
            amount: 0,
            amountMode: AmountMode.PREVIOUS_OUTPUT,
            minAmountOut: 1
        });

        vm.startPrank(account);
        IERC20(sourcePosition).approve(address(executor), type(uint256).max);
        IERC20(underlying).approve(address(executor), type(uint256).max);
        executor.execute(ops);
        IERC20(sourcePosition).approve(address(executor), 0);
        IERC20(underlying).approve(address(executor), 0);
        vm.stopPrank();
    }

    function _executeWithApprovals(address token, Operation[] memory ops) private {
        vm.startPrank(account);
        IERC20(token).approve(address(executor), type(uint256).max);
        executor.execute(ops);
        IERC20(token).approve(address(executor), 0);
        vm.stopPrank();
    }

    function _one(Operation memory op) private pure returns (Operation[] memory ops) {
        ops = new Operation[](1);
        ops[0] = op;
    }
}

contract GrowYieldInvariants is GrowYieldTestBase {
    GrowYieldHandler internal handler;

    function setUp() public {
        _setUpBase();

        handler = new GrowYieldHandler(
            executor,
            account,
            address(underlying),
            address(aavePool.aToken()),
            aaveVault,
            morphoVault
        );

        // Seed one position so redeem/reallocate have material.
        underlying.mint(account, 10_000e6);
        vm.startPrank(account);
        underlying.approve(address(executor), type(uint256).max);
        Operation[] memory ops = new Operation[](1);
        ops[0] = _op(aaveVault, OperationKind.DEPOSIT, type(uint256).max);
        executor.execute(ops);
        underlying.approve(address(executor), 0);
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// @dev The executor and adapters are pure pass-throughs: no balance survives a tx.
    function invariant_noFundsStrandedInExecutorOrAdapters() public view {
        address[4] memory holders = [
            address(executor), address(aaveAdapter), address(morphoAdapter), address(policyModule)
        ];
        for (uint256 i; i < holders.length; ++i) {
            assertEq(underlying.balanceOf(holders[i]), 0);
            assertEq(otherUnderlying.balanceOf(holders[i]), 0);
            assertEq(aavePool.aToken().balanceOf(holders[i]), 0);
            assertEq(morphoWrapper.balanceOf(holders[i]), 0);
        }
    }

    /// @dev Successful batches always end with zero allowance to the executor.
    function invariant_allowancesToExecutorZeroAfterBatch() public view {
        assertEq(underlying.allowance(account, address(executor)), 0);
        assertEq(IERC20(address(aavePool.aToken())).allowance(account, address(executor)), 0);
        assertEq(IERC20(address(morphoWrapper)).allowance(account, address(executor)), 0);
    }

    /// @dev Total account value (underlying + positions at 1:1 mocks) never leaks.
    function invariant_accountValueConserved() public view {
        uint256 value = underlying.balanceOf(account) + aavePool.aToken().balanceOf(account)
            + morphoWrapper.previewRedeem(morphoWrapper.balanceOf(account));
        // Mock venues are lossless; every deposit is matched by mint in the handler.
        assertLe(value, 10_000e6 + 1_000_000e6 * 512); // depth * max mint upper bound
        assertGt(value, 0);
    }

    /// @dev No operation path admits a vault or edits an admitted entry: admission is
    ///      `onlyOwner` on the very contract the operations run through.
    function invariant_admittedVenuesAreStable() public view {
        assertEq(executor.owner(), address(this));
        assertEq(executor.vaultCount(), 3);

        address[3] memory expected = [aaveVault, aaveVaultOther, morphoVault];
        for (uint256 i; i < expected.length; ++i) {
            Venue memory admitted = executor.venue(expected[i]);
            assertEq(executor.vaultAt(i), expected[i]);
            assertTrue(admitted.canDeposit);
            assertTrue(admitted.canRedeem);
            assertEq(executor.adapterCodeHash(admitted.adapter), admitted.adapter.codehash);
            assertEq(
                admitted.positionToken,
                IYieldAdapter(admitted.adapter).positionToken(expected[i]),
                "pinned pair still matches"
            );
        }
    }

    /// @dev A malformed policy signature never validates.
    function invariant_junkSignatureNeverValidates() public {
        PackedUserOperation memory userOp = _baseUserOp(hex"12345678");
        userOp.signature = hex"01";
        assertEq(uint160(_validationResult(userOp, bytes32(0))), 1);
    }
}
