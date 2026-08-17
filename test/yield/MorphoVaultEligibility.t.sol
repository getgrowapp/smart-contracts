// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {MorphoVaultEligibility} from "../../src/MorphoVaultEligibility.sol";

contract MorphoVaultEligibilityTest is Test {
    address internal constant CHILD = 0xBEEf0F82E269760429BE6255Fa00821b7e4b592A;

    function test_constructorSeedsChildren() public {
        address[] memory children = new address[](1);
        children[0] = CHILD;

        MorphoVaultEligibility eligibility = new MorphoVaultEligibility(makeAddr("owner"), children);

        assertTrue(eligibility.isEligibleVault(CHILD));
    }

    function test_ownerCanToggleEligibility() public {
        address owner = makeAddr("owner");
        MorphoVaultEligibility eligibility =
            new MorphoVaultEligibility(owner, new address[](0));

        vm.prank(owner);
        eligibility.setEligible(CHILD, true);
        assertTrue(eligibility.isEligibleVault(CHILD));

        vm.prank(owner);
        eligibility.setEligible(CHILD, false);
        assertFalse(eligibility.isEligibleVault(CHILD));
    }
}
