// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {Deposit} from "../src/Deposit.sol";
import {BaseTest} from "./BaseTest.t.sol";

/// @title DepositTest - Unit tests for the Deposit contract
contract DepositTest is BaseTest {
    function test_deposit_compoundFalse_mintsWnxm1to1AndStakes() public {
        _depositFor(alice, 100e18, false);

        assertEq(wnxm.balanceOf(alice), 100e18);
        assertEq(staking.balanceOf(address(deposit)), 100e18);
        assertEq(deposit.totalNexumDeposited(), 100e18);
        assertEq(deposit.totalWrappedNexumMinted(), 100e18);
        _assertBacking();
    }

    function test_deposit_compoundTrue_receiverGetsVaultShares() public {
        _depositFor(alice, 100e18, true);

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(wnxm.balanceOf(alice), 0);
        assertEq(wnxm.balanceOf(address(vault)), 100e18);
        assertEq(vault.totalStaked(), 100e18);
        _assertBacking();
    }

    function test_deposit_emitsDeposited() public {
        vm.prank(admin);
        nxm.mint(alice, 100e18);
        vm.startPrank(alice);
        nxm.approve(address(deposit), 100e18);

        vm.expectEmit(true, true, false, true, address(deposit));
        emit Deposit.Deposited(alice, bob, 100e18, false);
        deposit.deposit(100e18, bob, false);
        vm.stopPrank();
    }

    function test_deposit_zeroAmount_revertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(Deposit.ZeroAmount.selector);
        deposit.deposit(0, alice, false);
    }

    function test_deposit_zeroReceiver_revertsZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(Deposit.ZeroAddress.selector);
        deposit.deposit(1e18, address(0), false);
    }

    function test_harvest_restakesRewardsAndMintsToVault() public {
        _depositFor(alice, 100e18, true);
        _fundStakingRewards(STAKING_REWARDS);
        vm.warp(block.timestamp + DURATION);

        uint256 expectedReward = staking.earned(address(deposit));
        vm.expectEmit(false, false, false, true, address(deposit));
        emit Deposit.RewardsSynced(expectedReward);
        deposit.harvest();

        assertEq(wnxm.balanceOf(address(vault)), 100e18 + expectedReward);
        assertEq(deposit.totalWrappedNexumMinted(), 100e18 + expectedReward);
        assertEq(deposit.totalNexumDeposited(), 100e18, "rewards are not user deposits");
        assertEq(nxm.balanceOf(address(deposit)), 0, "rewards must be re-staked, not left idle");
        assertGt(vault.rewardRate(), 0, "vault reward stream must start");
        _assertBacking();
    }

    function test_harvest_noRewards_revertsNoRewardsToHarvest() public {
        _depositFor(alice, 100e18, false);

        vm.expectRevert(Deposit.NoRewardsToHarvest.selector);
        deposit.harvest();
    }

    function test_redeem_burnsCallerWnxmAndPaysReceiver() public {
        _depositFor(alice, 100e18, false);

        vm.expectEmit(true, true, false, true, address(deposit));
        emit Deposit.Redeemed(alice, bob, 40e18);
        vm.prank(alice);
        deposit.redeem(40e18, bob);

        assertEq(wnxm.balanceOf(alice), 60e18);
        assertEq(nxm.balanceOf(bob), 40e18);
        assertEq(deposit.totalNexumDeposited(), 100e18, "counters are cumulative");
        _assertBacking();
    }

    function test_redeem_moreThanBalance_reverts() public {
        _depositFor(alice, 100e18, false);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1e18));
        deposit.redeem(1e18, bob);
    }

    function test_constructor_zeroAddress_reverts() public {
        vm.expectRevert(Deposit.ZeroAddress.selector);
        new Deposit(address(0), address(staking), address(vault));
    }

    function testFuzz_deposit_anyAmountAndMode_keepsBacking(uint256 amount, bool compound) public {
        amount = bound(amount, 1, 1_000_000_000e18);

        _depositFor(alice, amount, compound);

        assertEq(deposit.totalWrappedNexumMinted(), amount);
        _assertBacking();
    }
}
