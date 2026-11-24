// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./BaseTest.t.sol";

/// @title TokensTest - Metadata and access control of NXM and wNXM
contract TokensTest is BaseTest {
    function test_metadata() public view {
        assertEq(nxm.name(), "Nexum");
        assertEq(nxm.symbol(), "NXM");
        assertEq(wnxm.name(), "Wrapped Nexum");
        assertEq(wnxm.symbol(), "wNXM");
        assertEq(vault.name(), "NexumShares");
        assertEq(vault.symbol(), "aNXM");
    }

    function test_nxmMint_byOwner_mintsTokens() public {
        vm.prank(admin);
        nxm.mint(alice, 100e18);

        assertEq(nxm.balanceOf(alice), 100e18);
    }

    function test_nxmMint_byNonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nxm.mint(alice, 100e18);
    }

    function test_wnxmRoles_heldByDepositContract() public view {
        assertTrue(wnxm.hasRole(wnxm.MINTER_ROLE(), address(deposit)));
        assertTrue(wnxm.hasRole(wnxm.BURNER_ROLE(), address(deposit)));
    }

    function test_wnxmMint_withoutMinterRole_reverts() public {
        bytes32 role = wnxm.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        wnxm.mint(alice, 1e18);
    }

    function test_wnxmBurn_withoutBurnerRole_reverts() public {
        bytes32 role = wnxm.BURNER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        wnxm.burn(bob, 1e18);
    }
}
