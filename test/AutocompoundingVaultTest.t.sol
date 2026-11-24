// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AutocompoundingVault} from "../src/AutocompoundingVault.sol";
import {BaseTest} from "./BaseTest.t.sol";

/// @title AutocompoundingVaultTest - Unit tests for the vault
/// @dev The Deposit contract is impersonated with vm.prank to mint wNXM and notify rewards in isolation.
contract AutocompoundingVaultTest is BaseTest {
    uint256 internal constant VAULT_REWARDS = 70e18;

    function _giveWnxm(address user, uint256 amount) internal {
        vm.prank(address(deposit));
        wnxm.mint(user, amount);
    }

    function _vaultDeposit(address user, uint256 amount) internal {
        _giveWnxm(user, amount);
        vm.startPrank(user);
        wnxm.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _sendRewards(uint256 amount) internal {
        vm.startPrank(address(deposit));
        wnxm.mint(address(vault), amount);
        vault.notifyRewardAmount();
        vm.stopPrank();
    }

    function test_notifyRewardAmount_notDepositContract_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AutocompoundingVault.NotDepositContract.selector, alice));
        vault.notifyRewardAmount();
    }

    function test_setDepositContract_secondCall_reverts() public {
        vm.prank(admin);
        vm.expectRevert(AutocompoundingVault.DepositContractAlreadySet.selector);
        vault.setDepositContract(alice);
    }

    function test_setDepositContract_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setDepositContract(alice);
    }

    function test_deposit_firstDeposit_mintsSharesOneToOne() public {
        _vaultDeposit(alice, 100e18);

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalStaked(), 100e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_notifyRewardAmount_streamsRewardsLinearly() public {
        _vaultDeposit(alice, 100e18);

        vm.startPrank(address(deposit));
        wnxm.mint(address(vault), VAULT_REWARDS);
        vm.expectEmit(false, false, false, true, address(vault));
        emit AutocompoundingVault.RewardAdded(VAULT_REWARDS);
        vault.notifyRewardAmount();
        vm.stopPrank();

        assertEq(vault.totalAssets(), 100e18, "rewards must not count instantly");

        vm.warp(block.timestamp + DURATION / 2);
        assertApproxEqAbs(vault.totalAssets(), 135e18, 1e12);
        assertApproxEqAbs(vault.convertToAssets(100e18), 135e18, 1e12, "share price rises");

        vm.warp(block.timestamp + DURATION * 2);
        assertApproxEqAbs(vault.totalAssets(), 170e18, 1e12, "stream stops at periodFinish");
    }

    function test_rewardPerToken_zeroWhenEmptyAndScaledAfterStreaming() public {
        assertEq(vault.rewardPerToken(), 0, "no division by zero when nothing is staked");

        _vaultDeposit(alice, 100e18);
        _sendRewards(VAULT_REWARDS);
        vm.warp(block.timestamp + DURATION);

        // 70 wNXM streamed onto 100 staked = 0.7 per token, scaled by 1e18
        assertApproxEqAbs(vault.rewardPerToken(), 0.7e18, 1e10);
    }

    function test_harvest_movesEarnedIntoTotalStakedWithoutChangingTotalAssets() public {
        _vaultDeposit(alice, 100e18);
        _sendRewards(VAULT_REWARDS);
        vm.warp(block.timestamp + 3 days);

        uint256 assetsBefore = vault.totalAssets();
        uint256 earned = vault.earned();

        vm.expectEmit(false, false, false, true, address(vault));
        emit AutocompoundingVault.YieldHarvested(earned);
        vault.harvest();

        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.totalStaked(), 100e18 + earned);
        assertEq(vault.earned(), 0);
    }

    // Regression: lastUpdateTime must never pass periodFinish, otherwise earned() underflows.
    function test_harvest_afterPeriodFinish_keepsTotalAssetsCallable() public {
        _vaultDeposit(alice, 100e18);
        _sendRewards(VAULT_REWARDS);
        vm.warp(block.timestamp + DURATION + 3 days);

        vault.harvest();
        vm.warp(block.timestamp + 1 days);

        assertApproxEqAbs(vault.totalAssets(), 170e18, 1e12);
    }

    // Regression: withdrawing everything incl. streamed rewards must not underflow totalStaked.
    function test_redeem_allShares_returnsDepositPlusStreamedRewards() public {
        _vaultDeposit(alice, 100e18);
        _sendRewards(VAULT_REWARDS);
        vm.warp(block.timestamp + DURATION);

        vm.startPrank(alice);
        uint256 assets = vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(assets, 170e18, 1e12);
        assertEq(wnxm.balanceOf(alice), assets);
        assertEq(vault.totalStaked(), 0);
    }

    // Regression: harvest returns early on zero rewards, so withdrawals are never blocked.
    function test_withdraw_withoutAnyRewards_succeeds() public {
        _vaultDeposit(alice, 100e18);

        vm.prank(alice);
        vault.withdraw(100e18, alice, alice);

        assertEq(wnxm.balanceOf(alice), 100e18);
    }

    // Inflation attack defense: direct donations must not move the share price.
    function test_donation_doesNotChangeSharePrice() public {
        _vaultDeposit(alice, 1);
        _giveWnxm(bob, 1_000e18);
        vm.prank(bob);
        wnxm.transfer(address(vault), 1_000e18);

        assertEq(vault.totalAssets(), 1);

        _vaultDeposit(alice, 100e18);
        assertEq(vault.balanceOf(alice), 100e18 + 1, "victim still receives fair shares");
    }

    // Streaming defense: a deposit right after notify captures almost nothing.
    function test_justInTimeDeposit_capturesNegligibleYield() public {
        _vaultDeposit(alice, 100e18);
        _sendRewards(VAULT_REWARDS);
        _vaultDeposit(bob, 100e18);

        vm.warp(block.timestamp + 1);
        vm.startPrank(bob);
        uint256 assets = vault.redeem(vault.balanceOf(bob), bob, bob);
        vm.stopPrank();

        assertLt(assets - 100e18, 1e15, "bob should earn at most one second of rewards");
    }

    // Known limitation found by the invariant test: if the share supply shrinks to dust while rewards keep
    // streaming, one share becomes worth so much that a normal-sized deposit rounds down to zero shares.
    // solmate reverts with ZERO_SHARES (no silent loss), but compounding deposits are blocked until supply grows.
    function test_dustShareSupply_largeRewards_blocksSmallDeposits() public {
        _vaultDeposit(alice, 100e18);
        vm.startPrank(alice);
        vault.redeem(vault.balanceOf(alice) - 1, alice, alice);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 1, "one wei of shares left");

        _sendRewards(VAULT_REWARDS);
        vm.warp(block.timestamp + DURATION);

        _giveWnxm(bob, 100e18);
        vm.startPrank(bob);
        wnxm.approve(address(vault), 100e18);
        vm.expectRevert(bytes("ZERO_SHARES"));
        vault.deposit(1e18, bob);
        vm.stopPrank();
    }
}
