// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {AutocompoundingVault} from "../src/AutocompoundingVault.sol";
import {Deposit} from "../src/Deposit.sol";
import {NexumToken} from "../src/NexumToken.sol";
import {Staking} from "../src/Staking.sol";
import {WrappedNexumToken} from "../src/WrappedNexumToken.sol";

/// @title DeployScript - Deploys and wires the Nexum yield system
/// @author Adrian (thuisdev)
/// @notice Run with: forge script script/Deploy.s.sol --rpc-url <url> --broadcast
/// @dev Reads PRIVATE_KEY from .env. The deployer becomes admin/owner of all admin-controlled contracts.
///      Deployment order is fixed by constructor dependencies: wNXM before the vault, the vault before Deposit.
contract DeployScript is Script {
    /// @notice Initial NXM reward pool funded into the staking contract.
    uint256 public constant INITIAL_REWARDS = 1_000e18;

    /// @notice Deploys all contracts, wires roles and permissions, and starts the first reward period.
    function run() external {
        vm.startBroadcast();
        address admin = msg.sender;

        // 1. Deploy
        NexumToken nxm = new NexumToken(admin);
        WrappedNexumToken wnxm = new WrappedNexumToken(admin);
        Staking staking = new Staking(address(nxm), admin);
        AutocompoundingVault vault = new AutocompoundingVault(ERC20(address(wnxm)), admin);
        Deposit deposit = new Deposit(address(nxm), address(staking), address(vault));

        // 2. Wire: Deposit only exists now, so its permissions are granted after deployment
        vault.setDepositContract(address(deposit));
        wnxm.grantRole(wnxm.MINTER_ROLE(), address(deposit));
        wnxm.grantRole(wnxm.BURNER_ROLE(), address(deposit));

        // 3. Fund rewards: NXM must be in the staking contract before notifyRewardAmount passes its coverage check
        nxm.mint(address(staking), INITIAL_REWARDS);
        staking.notifyRewardAmount(INITIAL_REWARDS);

        vm.stopBroadcast();

        // 4. Log
        console.log("NXM:     ", address(nxm));
        console.log("wNXM:    ", address(wnxm));
        console.log("Staking: ", address(staking));
        console.log("Vault:   ", address(vault));
        console.log("Deposit: ", address(deposit));
    }
}
