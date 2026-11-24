// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {AutocompoundingVault} from "../../src/AutocompoundingVault.sol";
import {Deposit} from "../../src/Deposit.sol";
import {NexumToken} from "../../src/NexumToken.sol";
import {WrappedNexumToken} from "../../src/WrappedNexumToken.sol";

/// @title DepositHandler - Drives random but valid user actions for invariant testing
/// @dev Inputs are bounded so calls do not revert; the fuzzer then explores arbitrary call sequences.
contract DepositHandler is Test {
    Deposit internal deposit;
    NexumToken internal nxm;
    WrappedNexumToken internal wnxm;
    AutocompoundingVault internal vault;
    address internal admin;
    address[] internal actors;

    constructor(
        Deposit deposit_,
        NexumToken nxm_,
        WrappedNexumToken wnxm_,
        AutocompoundingVault vault_,
        address admin_
    ) {
        deposit = deposit_;
        nxm = nxm_;
        wnxm = wnxm_;
        vault = vault_;
        admin = admin_;
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
    }

    function depositNxm(uint256 actorSeed, uint256 amount, bool compound) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        amount = bound(amount, 1e18, 1_000e18);

        // Known limitation (see AutocompoundingVaultTest): with a dust share supply a deposit can round to zero
        // shares and revert. Fall back to a plain deposit so the fuzzer keeps exploring the backing invariant.
        if (compound && vault.previewDeposit(amount) == 0) {
            compound = false;
        }

        vm.prank(admin);
        nxm.mint(actor, amount);

        vm.startPrank(actor);
        nxm.approve(address(deposit), amount);
        deposit.deposit(amount, actor, compound);
        vm.stopPrank();
    }

    function redeemWnxm(uint256 actorSeed, uint256 amount) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = wnxm.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(actor);
        deposit.redeem(amount, actor);
    }

    function redeemVaultShares(uint256 actorSeed, uint256 shares) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);
        if (vault.previewRedeem(shares) == 0) return;

        vm.prank(actor);
        vault.redeem(shares, actor, actor);
    }

    function warpAndHarvest(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 2 days));
        try deposit.harvest() {} catch {}
    }
}
