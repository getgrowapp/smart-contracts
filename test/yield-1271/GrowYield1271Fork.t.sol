// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GrowYieldExecutor1271V2} from
    "../../src/yield-1271/GrowYieldExecutor1271V2.sol";
import {GrowYield1271PolicySignerV3} from
    "../../src/yield-1271/GrowYield1271PolicySignerV3.sol";
import {
    IGrowYieldRegistry,
    IGrowYieldTypes
} from "../../src/yield-v6/IGrowYieldSystem.sol";

/**
 * @notice Base mainnet fork smoke against deployed 1271 contracts.
 * @dev Requires `BASE_RPC_URL`. Skips if unset.
 */
contract GrowYield1271ForkTest is Test, IGrowYieldTypes {
    address internal constant REGISTRY =
        0x7F219F5009Df002307Cf759994a1370De3d089E0;
    address internal constant EXECUTOR =
        0xDD440Cb9530502dAE4e6a5022e5f1dD2718d5dCE;
    // Beta PolicySigner (token-bound approve + non-reverting INVALID proofs).
    address internal constant POLICY_SIGNER =
        0xF2f02Ca6632EECb9232D3270fccF93D7b002c722;
    address internal constant LEGACY_POLICY_SIGNER =
        0x7fde78b9AF63640cAAEEeb15343319612B1a9d8E;
    address internal constant SCW =
        0x68f1ac3B164519EA9cb66418216D548C39283021;

    address internal constant USDC =
        0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);
    }

    function test_fork_deployedCodePresent() public view {
        assertGt(EXECUTOR.code.length, 0);
        assertGt(POLICY_SIGNER.code.length, 0);
        assertGt(REGISTRY.code.length, 0);
        assertEq(
            address(GrowYieldExecutor1271V2(EXECUTOR).registry()), REGISTRY
        );
        assertEq(
            GrowYield1271PolicySignerV3(POLICY_SIGNER).executor(), EXECUTOR
        );
    }

    function test_fork_invalidProof_returnsInvalid_notRevert() public view {
        bytes4 result = GrowYield1271PolicySignerV3(POLICY_SIGNER)
            .isValidSignature(bytes32(uint256(1)), hex"01");
        assertEq(result, bytes4(0xffffffff));
    }

    function test_fork_legacySigner_mayStillRevertOnJunk() public {
        try this.callLegacyIsValidSignature(bytes32(uint256(1)), hex"01")
        returns (bytes4 result) {
            assertEq(result, bytes4(0xffffffff));
        } catch {
            // Expected for pre-harden deployment.
        }
    }

    function callLegacyIsValidSignature(bytes32 hash, bytes calldata proof)
        external
        view
        returns (bytes4)
    {
        return GrowYield1271PolicySignerV3(LEGACY_POLICY_SIGNER)
            .isValidSignature(hash, proof);
    }

    function test_fork_scwConfiguredSigner() public view {
        (address configured,) =
            GrowYield1271PolicySignerV3(POLICY_SIGNER).config(SCW);
        assertEq(configured, 0x5F6694c633DfB3f8Dc46791CF34A70643515422D);
    }
}
