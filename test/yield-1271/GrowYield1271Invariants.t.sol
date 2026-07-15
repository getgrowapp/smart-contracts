// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from
    "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";

import {GrowYield1271TestBase} from "./GrowYield1271TestBase.sol";
import {GrowUserOpHashLib} from "../../src/yield-1271/GrowUserOpHashLib.sol";
import {GrowYieldExecutor1271V2} from
    "../../src/yield-1271/GrowYieldExecutor1271V2.sol";
import {
    IGrowYieldTypes
} from "../../src/yield-v6/IGrowYieldSystem.sol";

/**
 * @dev Handler for stateful invariants. Mimics a successful policy batch:
 *      approve-max → executor op → approve-zero, always as the smart account.
 */
contract GrowYield1271Handler is Test, IGrowYieldTypes {
    GrowYieldExecutor1271V2 public immutable executor;
    address public immutable account;
    address public immutable underlying;
    address public immutable aToken;
    address public immutable morpho;
    address public immutable aavePool;

    uint256 public ghostSuccesses;

    constructor(
        GrowYieldExecutor1271V2 executor_,
        address account_,
        address underlying_,
        address aToken_,
        address morpho_,
        address aavePool_
    ) {
        executor = executor_;
        account = account_;
        underlying = underlying_;
        aToken = aToken_;
        morpho = morpho_;
        aavePool = aavePool_;
    }

    function deposit(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);
        deal(underlying, account, IERC20(underlying).balanceOf(account) + amount);

        vm.startPrank(account);
        IERC20(underlying).approve(address(executor), type(uint256).max);
        executor.depositAll(Protocol.AAVE, aavePool, underlying);
        IERC20(underlying).approve(address(executor), 0);
        IERC20(aToken).approve(address(executor), 0);
        vm.stopPrank();

        ghostSuccesses++;
    }

    function reallocate() external {
        uint256 pos = IERC20(aToken).balanceOf(account);
        if (pos == 0) return;

        vm.startPrank(account);
        IERC20(aToken).approve(address(executor), type(uint256).max);
        IERC20(morpho).approve(address(executor), type(uint256).max);
        executor.reallocateAll(
            Protocol.AAVE,
            aavePool,
            underlying,
            Protocol.MORPHO,
            morpho,
            underlying
        );
        IERC20(aToken).approve(address(executor), 0);
        IERC20(morpho).approve(address(executor), 0);
        IERC20(underlying).approve(address(executor), 0);
        vm.stopPrank();

        ghostSuccesses++;
    }

    function withdraw() external {
        uint256 aPos = IERC20(aToken).balanceOf(account);
        uint256 mPos = IERC20(morpho).balanceOf(account);

        vm.startPrank(account);
        if (aPos > 0) {
            IERC20(aToken).approve(address(executor), type(uint256).max);
            executor.withdrawAll(Protocol.AAVE, aavePool, underlying);
            IERC20(aToken).approve(address(executor), 0);
            ghostSuccesses++;
        } else if (mPos > 0) {
            IERC20(morpho).approve(address(executor), type(uint256).max);
            executor.withdrawAll(Protocol.MORPHO, morpho, underlying);
            IERC20(morpho).approve(address(executor), 0);
            ghostSuccesses++;
        }
        IERC20(underlying).approve(address(executor), 0);
        vm.stopPrank();
    }
}

contract GrowYield1271Invariants is GrowYield1271TestBase {
    using MessageHashUtils for bytes32;

    GrowYield1271Handler internal handler;

    function setUp() public {
        _setUpBase();
        handler = new GrowYield1271Handler(
            executor,
            account,
            address(underlying),
            address(aavePool.aToken()),
            address(morphoVault),
            address(aavePool)
        );

        // Seed one deposit so realloc/withdraw have material.
        underlying.mint(account, 10_000e6);
        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        executor.depositAll(Protocol.AAVE, address(aavePool), address(underlying));
        IERC20(address(underlying)).approve(address(executor), 0);
        IERC20(address(aavePool.aToken())).approve(address(executor), 0);
        vm.stopPrank();

        targetContract(address(handler));
    }

    function invariant_executorRetainsNoUnderlyingOrPositionTokens() public view {
        assertEq(underlying.balanceOf(address(executor)), 0);
        assertEq(aavePool.aToken().balanceOf(address(executor)), 0);
        assertEq(morphoVault.balanceOf(address(executor)), 0);
        assertEq(otherUnderlying.balanceOf(address(executor)), 0);
    }

    function invariant_allowancesToExecutorZeroAfterSuccessfulBatch()
        public
        view
    {
        assertEq(
            IERC20(address(underlying)).allowance(account, address(executor)), 0
        );
        assertEq(
            IERC20(address(aavePool.aToken())).allowance(
                account, address(executor)
            ),
            0
        );
        assertEq(
            IERC20(address(morphoVault)).allowance(account, address(executor)), 0
        );
    }

    function invariant_positionsOnlyOnAccount_whenHeld() public view {
        // Shares / aTokens never sit on the executor (covered above).
        // Any position supply belongs to the smart account or nowhere.
        assertEq(aavePool.aToken().balanceOf(address(executor)), 0);
        assertEq(morphoVault.balanceOf(address(executor)), 0);
    }

    function invariant_invalidProofsNeverReturnMagic() public view {
        // Sample adversarial encodings; full fuzz is in check_invalidProof_fuzz.
        bytes memory garbage = hex"01";
        assertEq(signer.isValidSignature(bytes32(0), garbage), INVALID);

        PackedUserOperation memory userOp =
            _baseUserOp(_batch(address(underlying), _depositOp(
                Protocol.AAVE, address(aavePool), address(underlying)
            )));
        (bytes memory proof,) = _validProof(userOp);
        assertEq(signer.isValidSignature(keccak256("nope"), proof), INVALID);
    }

    function invariant_reallocateOnlySameUnderlying_enforcedByExecutor()
        public
    {
        // Attempt mismatched realloc mid-campaign — must always revert and
        // leave executor clean.
        uint256 pos = aavePool.aToken().balanceOf(account);
        if (pos == 0) return;

        vm.startPrank(account);
        IERC20(address(aavePool.aToken())).approve(
            address(executor), type(uint256).max
        );
        try executor.reallocateAll(
            Protocol.AAVE,
            address(aavePool),
            address(underlying),
            Protocol.AAVE,
            address(aavePoolOther),
            address(otherUnderlying)
        ) {
            revert("mismatched realloc must fail");
        } catch {}
        IERC20(address(aavePool.aToken())).approve(address(executor), 0);
        vm.stopPrank();

        assertEq(underlying.balanceOf(address(executor)), 0);
        assertEq(otherUnderlying.balanceOf(address(executor)), 0);
    }
}

/// @notice Explicit stateful proofs (non-fuzz) for recipient / ABI claims.
contract GrowYield1271StatefulProofs is GrowYield1271TestBase {
    function setUp() public {
        _setUpBase();
    }

    function test_withdrawRecipientIsAlwaysMsgSender() public {
        underlying.mint(account, 100e6);
        vm.startPrank(account);
        IERC20(address(underlying)).approve(address(executor), type(uint256).max);
        IERC20(address(aavePool.aToken())).approve(
            address(executor), type(uint256).max
        );
        executor.depositAll(Protocol.AAVE, address(aavePool), address(underlying));
        IERC20(address(underlying)).approve(address(executor), 0);

        address stranger = makeAddr("stranger");
        // Stranger cannot redirect account funds without allowance/balance.
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert();
        executor.withdrawAll(
            Protocol.AAVE, address(aavePool), address(underlying)
        );

        uint256 before_ = underlying.balanceOf(account);
        vm.startPrank(account);
        executor.withdrawAll(
            Protocol.AAVE, address(aavePool), address(underlying)
        );
        IERC20(address(aavePool.aToken())).approve(address(executor), 0);
        vm.stopPrank();

        assertEq(underlying.balanceOf(account), before_ + 100e6);
        assertEq(underlying.balanceOf(stranger), 0);
    }

    function test_fuzz_invalidProofNeverMagic(bytes calldata junk) public view {
        bytes4 result = signer.isValidSignature(keccak256(junk), junk);
        assertTrue(result != signer.isValidSignature.selector);
        assertEq(result, INVALID);
    }
}
