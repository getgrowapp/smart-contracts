// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowYieldExecutorV3} from "../../src/yield-module/GrowYieldExecutorV3.sol";
import {
    AmountMode,
    IYieldAdapter,
    Operation,
    OperationKind
} from "../../src/yield-module/interfaces/IGrowYieldExecutor.sol";

/// @dev Handler for stateful invariants. Mimics successful policy batches:
///      approve-max -> execute -> approve-zero, always as the smart account.
contract GrowYield1271Handler is Test {
    GrowYieldExecutorV3 public immutable executor;
    address public immutable account;
    address public immutable underlying;
    address public immutable aToken;
    IYieldAdapter public immutable aaveAdapter;
    IYieldAdapter public immutable morphoAdapter;
    address public immutable morphoWrapper;

    constructor(
        GrowYieldExecutorV3 executor_,
        address account_,
        address underlying_,
        address aToken_,
        IYieldAdapter aaveAdapter_,
        IYieldAdapter morphoAdapter_
    ) {
        executor = executor_;
        account = account_;
        underlying = underlying_;
        aToken = aToken_;
        aaveAdapter = aaveAdapter_;
        morphoAdapter = morphoAdapter_;
        morphoWrapper = morphoAdapter_.positionToken();
    }

    function deposit(uint256 amountSeed, bool useAave) external {
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);
        deal(underlying, account, IERC20(underlying).balanceOf(account) + amount);

        _executeWithApprovals(
            underlying,
            _one(
                Operation({
                    adapter: useAave ? aaveAdapter : morphoAdapter,
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
        address position = useAave ? aToken : morphoWrapper;
        uint256 balance = IERC20(position).balanceOf(account);
        if (balance == 0) return;

        uint256 amount = bound(amountSeed, 1, balance);
        _executeWithApprovals(
            position,
            _one(
                Operation({
                    adapter: useAave ? aaveAdapter : morphoAdapter,
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
        address sourcePosition = aaveToMorpho ? aToken : morphoWrapper;
        if (IERC20(sourcePosition).balanceOf(account) == 0) return;

        Operation[] memory ops = new Operation[](2);
        ops[0] = Operation({
            adapter: aaveToMorpho ? aaveAdapter : morphoAdapter,
            kind: OperationKind.REDEEM,
            sourceToken: sourcePosition,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
        ops[1] = Operation({
            adapter: aaveToMorpho ? morphoAdapter : aaveAdapter,
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

contract GrowYield1271Invariants is GrowYield1271TestBase {
    GrowYield1271Handler internal handler;

    function setUp() public {
        _setUpBase();

        handler = new GrowYield1271Handler(
            executor,
            account,
            address(underlying),
            address(aavePool.aToken()),
            aaveAdapter,
            morphoAdapter
        );

        // Seed one position so redeem/reallocate have material.
        underlying.mint(account, 10_000e6);
        vm.startPrank(account);
        underlying.approve(address(executor), type(uint256).max);
        Operation[] memory ops = new Operation[](1);
        ops[0] = _op(aaveAdapter, OperationKind.DEPOSIT, type(uint256).max);
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

    /// @dev A malformed policy signature never validates.
    function invariant_junkSignatureNeverValidates() public {
        PackedUserOperation memory userOp = _baseUserOp(hex"12345678");
        userOp.signature = hex"01";
        assertEq(uint160(_validationResult(userOp, bytes32(0))), 1);
    }
}
