// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {AutocompoundingVault} from "../src/AutocompoundingVault.sol";
import {Deposit} from "../src/Deposit.sol";
import {NexumToken} from "../src/NexumToken.sol";
import {Staking} from "../src/Staking.sol";
import {WrappedNexumToken} from "../src/WrappedNexumToken.sol";

/// @title BaseTest - Shared setup that deploys and wires the full system like script/Deploy.s.sol
/// @dev Uses the same deployment order and wiring as the deploy script, but calls admin functions via vm.prank so
///      msg.sender is the admin and not the test contract.
abstract contract BaseTest is Test {
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant STAKING_REWARDS = 70e18;

    NexumToken internal nxm;
    WrappedNexumToken internal wnxm;
    Staking internal staking;
    AutocompoundingVault internal vault;
    Deposit internal deposit;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.startPrank(admin);
        nxm = new NexumToken(admin);
        wnxm = new WrappedNexumToken(admin);
        staking = new Staking(address(nxm), admin);
        vault = new AutocompoundingVault(ERC20(address(wnxm)), admin);
        deposit = new Deposit(address(nxm), address(staking), address(vault));

        vault.setDepositContract(address(deposit));
        wnxm.grantRole(wnxm.MINTER_ROLE(), address(deposit));
        wnxm.grantRole(wnxm.BURNER_ROLE(), address(deposit));
        vm.stopPrank();
    }

    /// @dev Admin mints `amount` NXM into the staking contract and starts a reward period.
    function _fundStakingRewards(uint256 amount) internal {
        vm.startPrank(admin);
        nxm.mint(address(staking), amount);
        staking.notifyRewardAmount(amount);
        vm.stopPrank();
    }

    /// @dev Mints NXM to `user`, approves the Deposit contract and deposits.
    function _depositFor(address user, uint256 amount, bool compound) internal {
        vm.prank(admin);
        nxm.mint(user, amount);

        vm.startPrank(user);
        nxm.approve(address(deposit), amount);
        deposit.deposit(amount, user, compound);
        vm.stopPrank();
    }

    /// @dev Core invariant: every wNXM is backed by exactly one NXM staked by the Deposit contract.
    function _assertBacking() internal view {
        assertEq(wnxm.totalSupply(), staking.balanceOf(address(deposit)), "wNXM not fully backed");
    }
}
