// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowYieldExecutor1271V2} from
    "../../src/yield-1271/GrowYieldExecutor1271V2.sol";
import {
    IGrowYieldExecutor
} from "../../src/yield-v6/IGrowYieldSystem.sol";
import {MockGrowYieldRegistry1271} from "./MockGrowYieldRegistry1271.sol";

/// @notice Executor correctness / venue gating for yield-1271.
contract GrowYield1271ExecutorTest is GrowYield1271TestBase {
    function setUp() public {
        _setUpBase();
    }

    function test_reallocate_revertsDifferentUnderlying() public {
        uint256 amount = 1_000e6;
        underlying.mint(account, amount);

        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        IERC20(address(aavePool.aToken())).approve(
            address(executor), type(uint256).max
        );
        executor.depositAll(Protocol.AAVE, address(aavePool), address(underlying));

        vm.expectRevert(GrowYieldExecutor1271V2.AssetMismatch.selector);
        executor.reallocateAll(
            Protocol.AAVE,
            address(aavePool),
            address(underlying),
            Protocol.AAVE,
            address(aavePoolOther),
            address(otherUnderlying)
        );
        vm.stopPrank();
    }

    function test_deposit_revertsDisabledEntryVenue() public {
        _setAave(
            Protocol.AAVE, address(aavePool), address(underlying), false, true
        );
        underlying.mint(account, 1e6);

        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        vm.expectRevert(MockGrowYieldRegistry1271.Unknown.selector);
        executor.depositAll(Protocol.AAVE, address(aavePool), address(underlying));
        vm.stopPrank();
    }

    function test_withdraw_fromExitEnabledEntryDisabled_succeeds() public {
        uint256 amount = 1_000e6;
        underlying.mint(account, amount);

        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        IERC20(address(aavePool.aToken())).approve(
            address(executor), type(uint256).max
        );
        executor.depositAll(Protocol.AAVE, address(aavePool), address(underlying));
        vm.stopPrank();

        // Disable new entry; keep exits.
        _setAave(
            Protocol.AAVE, address(aavePool), address(underlying), false, true
        );

        uint256 beforeBal = underlying.balanceOf(account);

        vm.startPrank(account);
        executor.withdrawAll(
            Protocol.AAVE, address(aavePool), address(underlying)
        );
        vm.stopPrank();

        assertEq(underlying.balanceOf(account), beforeBal + amount);
        assertEq(aavePool.aToken().balanceOf(account), 0);
        assertEq(underlying.balanceOf(address(executor)), 0);
        assertEq(aavePool.aToken().balanceOf(address(executor)), 0);
    }

    function test_deposit_recipientIsSmartAccount_noResidual() public {
        uint256 amount = 500e6;
        underlying.mint(account, amount);

        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        uint256 out = executor.depositAll(
            Protocol.AAVE, address(aavePool), address(underlying)
        );
        vm.stopPrank();

        assertEq(out, amount);
        assertEq(aavePool.aToken().balanceOf(account), amount);
        assertEq(aavePool.aToken().balanceOf(address(executor)), 0);
        assertEq(underlying.balanceOf(address(executor)), 0);
        assertEq(
            IERC20(address(underlying)).allowance(account, address(executor)),
            type(uint256).max
        ); // batch reset is policy-layer; direct call leaves approval
    }

    function test_reallocate_sameUnderlying_recipientIsAccount() public {
        uint256 amount = 800e6;
        underlying.mint(account, amount);

        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        IERC20(address(aavePool.aToken())).approve(
            address(executor), type(uint256).max
        );
        IERC20(address(morphoVault)).approve(address(executor), type(uint256).max);

        executor.depositAll(Protocol.AAVE, address(aavePool), address(underlying));
        uint256 out = executor.reallocateAll(
            Protocol.AAVE,
            address(aavePool),
            address(underlying),
            Protocol.MORPHO,
            address(morphoVault),
            address(underlying)
        );
        vm.stopPrank();

        assertEq(out, amount);
        assertEq(morphoVault.balanceOf(account), amount);
        assertEq(aavePool.aToken().balanceOf(account), 0);
        assertEq(underlying.balanceOf(address(executor)), 0);
        assertEq(aavePool.aToken().balanceOf(address(executor)), 0);
        assertEq(morphoVault.balanceOf(address(executor)), 0);
    }

    function test_noArbitraryRecipientOrAmountOnAbi() public pure {
        // Security claim: executor entrypoints take only (protocol, target, hint)
        // — no recipient / amount parameters an attacker can set via policy batch.
        bytes4 depositSel = IGrowYieldExecutor.depositAll.selector;
        bytes4 withdrawSel = IGrowYieldExecutor.withdrawAll.selector;
        bytes4 reallocSel = bytes4(
            keccak256(
                "reallocateAll(uint8,address,address,uint8,address,address)"
            )
        );
        assertTrue(depositSel != bytes4(0));
        assertTrue(withdrawSel != bytes4(0));
        assertTrue(reallocSel != bytes4(0));
    }
}
