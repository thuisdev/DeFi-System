// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Staking} from "../src/Staking.sol";
import {BaseTest} from "./BaseTest.t.sol";

/// @title StakingTest - Unit tests for the Synthetix-style NXM staking contract
/// @dev Users stake directly here to test the contract generically with several stakers.
contract StakingTest is BaseTest {
    function _stake(address user, uint256 amount) internal {
        vm.prank(admin);
        nxm.mint(user, amount);
        vm.startPrank(user);
        nxm.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function test_stake_updatesBalancesAndEmitsStaked() public {
        vm.prank(admin);
        nxm.mint(alice, 100e18);
        vm.startPrank(alice);
        nxm.approve(address(staking), 100e18);

        vm.expectEmit(true, false, false, true, address(staking));
        emit Staking.Staked(alice, 100e18);
        staking.stake(100e18);
        vm.stopPrank();

        assertEq(staking.balanceOf(alice), 100e18);
        assertEq(staking.totalSupply(), 100e18);
    }

    function test_earned_singleStaker_receivesFullRewardAfterPeriod() public {
        _stake(alice, 100e18);
        _fundStakingRewards(STAKING_REWARDS);
        vm.warp(block.timestamp + DURATION);

        assertApproxEqAbs(staking.earned(alice), STAKING_REWARDS, 1e12);
    }

    // Proportional to amount and duration: alice alone for half the period, then shared equally.
    function test_earned_lateStaker_getsOnlyRewardsSinceJoining() public {
        _stake(alice, 100e18);
        _fundStakingRewards(STAKING_REWARDS);

        vm.warp(block.timestamp + DURATION / 2);
        _stake(bob, 100e18);
        vm.warp(block.timestamp + DURATION / 2);

        assertApproxEqAbs(staking.earned(alice), 52.5e18, 1e12);
        assertApproxEqAbs(staking.earned(bob), 17.5e18, 1e12);
    }

    function test_earned_afterPeriodFinish_stopsAccruing() public {
        _stake(alice, 100e18);
        _fundStakingRewards(STAKING_REWARDS);
        vm.warp(block.timestamp + DURATION);
        uint256 atFinish = staking.earned(alice);

        vm.warp(block.timestamp + 30 days);
        assertEq(staking.earned(alice), atFinish);
    }

    function test_withdraw_moreThanStaked_revertsInsufficientBalance() public {
        _stake(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Staking.InsufficientBalance.selector, 100e18, 101e18));
        staking.withdraw(101e18);
    }

    function test_getReward_paysAndResetsRewards() public {
        _stake(alice, 100e18);
        _fundStakingRewards(STAKING_REWARDS);
        vm.warp(block.timestamp + DURATION);
        uint256 expected = staking.earned(alice);

        vm.expectEmit(true, false, false, true, address(staking));
        emit Staking.RewardPaid(alice, expected);
        vm.prank(alice);
        staking.getReward();

        assertEq(nxm.balanceOf(alice), expected);
        assertEq(staking.earned(alice), 0);
    }

    function test_exit_returnsStakePlusRewards() public {
        _stake(alice, 100e18);
        _fundStakingRewards(STAKING_REWARDS);
        vm.warp(block.timestamp + DURATION);
        uint256 expected = 100e18 + staking.earned(alice);

        vm.prank(alice);
        staking.exit();

        assertEq(nxm.balanceOf(alice), expected);
        assertEq(staking.balanceOf(alice), 0);
        assertEq(staking.totalSupply(), 0);
    }

    // Regression: exit must not revert with ZeroAmount when only rewards are left.
    function test_exit_withOnlyRewardsLeft_succeeds() public {
        _stake(alice, 100e18);
        _fundStakingRewards(STAKING_REWARDS);
        vm.warp(block.timestamp + DURATION);

        vm.startPrank(alice);
        staking.withdraw(100e18);
        staking.exit();
        vm.stopPrank();

        assertApproxEqAbs(nxm.balanceOf(alice), 100e18 + STAKING_REWARDS, 1e12);
    }

    function test_notifyRewardAmount_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.notifyRewardAmount(1e18);
    }

    // Staked NXM must never count as reward funding, since stake and reward token are the same.
    function test_notifyRewardAmount_backedOnlyByStakedTokens_reverts() public {
        _stake(alice, 100e18);

        uint256 required = (50e18 / DURATION) * DURATION;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Staking.InsufficientRewardBalance.selector, required, 0));
        staking.notifyRewardAmount(50e18);
    }

    function test_notifyRewardAmount_duringPeriod_rollsOverLeftover() public {
        _stake(alice, 100e18);
        _fundStakingRewards(STAKING_REWARDS);
        vm.warp(block.timestamp + DURATION / 2);

        _fundStakingRewards(STAKING_REWARDS);
        vm.warp(block.timestamp + DURATION);

        assertApproxEqAbs(staking.earned(alice), 2 * STAKING_REWARDS, 1e12, "no reward is lost on top-up");
    }
}
