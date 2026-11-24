// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title NexumToken - Underlying ERC-20 token (NXM) of the Nexum yield system
/// @author Adrian (thuisdev)
/// @notice NXM is the base asset users deposit into the DepositContract to receive wNXM and earn staking rewards.
/// @dev Minting is restricted to the owner, who funds users in tests and tops up the staking contract's reward pool.
///      No contract in the system needs mint rights for NXM; only wNXM is minted by the DepositContract.
contract NexumToken is ERC20, Ownable2Step {
    /// @notice Deploys the NXM token and sets the initial owner.
    /// @param owner_ Address that receives ownership and therefore the exclusive right to mint NXM.
    constructor(address owner_) ERC20("Nexum", "NXM") Ownable(owner_) {}

    /// @notice Mints new NXM tokens to the given address
    /// @dev Only callable by the owner (reverts with OwnableUnauthorizedAccount otherwise).
    ///      Reverts with ERC20InvalidReceiver if `to` is the zero address, enforced by OpenZeppelin's internal _mint.
    ///      Emits a Transfer event from address(0).
    /// @param to     Address that receives the newly minted tokens.
    /// @param amount Amount of NXM to mint, in wei (18 decimals).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
