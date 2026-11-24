// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "../BaseTest.t.sol";
import {DepositHandler} from "./DepositHandler.sol";

/// @title DepositInvariantTest - System-wide properties that must hold after any sequence of user actions
contract DepositInvariantTest is BaseTest {
    DepositHandler internal handler;

    function setUp() public override {
        super.setUp();
        _fundStakingRewards(1_000_000e18);
        handler = new DepositHandler(deposit, nxm, wnxm, vault, admin);
        targetContract(address(handler));
    }

    /// @notice Every wNXM is backed by exactly one NXM staked by the Deposit contract.
    function invariant_wnxmSupplyEqualsStakedNxm() public view {
        _assertBacking();
    }

    /// @notice The vault always holds enough wNXM to pay out its reported total assets.
    function invariant_vaultHoldsAtLeastTotalAssets() public view {
        assertGe(wnxm.balanceOf(address(vault)), vault.totalAssets());
    }

    /// @notice The staking contract can always repay all stakes plus the rewards owed to the Deposit contract.
    function invariant_stakingIsSolvent() public view {
        assertGe(nxm.balanceOf(address(staking)), staking.totalSupply() + staking.earned(address(deposit)));
    }
}
