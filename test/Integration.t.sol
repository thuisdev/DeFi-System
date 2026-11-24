// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./BaseTest.t.sol";

/// @title IntegrationTest - Full user journey through Deposit, Staking and Vault
contract IntegrationTest is BaseTest {
    /// @dev Alice compounds into the vault, Bob only holds wNXM. All staking yield must reach Alice via aNXM.
    function test_fullFlow_onlyVaultHoldersEarnYield() public {
        _depositFor(alice, 100e18, true);
        _depositFor(bob, 100e18, false);
        _fundStakingRewards(STAKING_REWARDS);

        vm.warp(block.timestamp + DURATION);
        deposit.harvest();
        _assertBacking();

        vm.warp(block.timestamp + DURATION);

        // Alice: aNXM -> wNXM -> NXM
        vm.startPrank(alice);
        uint256 aliceWnxm = vault.redeem(vault.balanceOf(alice), alice, alice);
        deposit.redeem(aliceWnxm, alice);
        vm.stopPrank();

        // Bob: wNXM -> NXM
        vm.prank(bob);
        deposit.redeem(100e18, bob);

        assertEq(nxm.balanceOf(bob), 100e18, "wNXM holders earn no yield");
        assertApproxEqAbs(nxm.balanceOf(alice), 100e18 + STAKING_REWARDS, 1e13, "vault receives all staking yield");
        _assertBacking();
    }
}
