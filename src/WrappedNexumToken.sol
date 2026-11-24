// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title WrappedNexumToken - 1:1 wrapped representation (wNXM) of staked NXM
/// @author Adrian (thuisdev)
/// @notice wNXM is minted 1:1 when NXM is deposited into the DepositContract and burned when it is redeemed.
/// @dev Mint and burn are gated by MINTER_ROLE and BURNER_ROLE, both granted to the DepositContract after deployment.
///      The role holder can burn from any address without allowance, so it must be a trusted contract, never an EOA.
contract WrappedNexumToken is ERC20, AccessControl {
    /// @notice Role allowed to mint wNXM; held by the DepositContract.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role allowed to burn wNXM; held by the DepositContract.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Deploys the wNXM token and assigns the admin role.
    /// @dev MINTER_ROLE and BURNER_ROLE are not granted here because the DepositContract is deployed after this token.
    ///      The admin grants both roles to the DepositContract via AccessControl.grantRole once it exists.
    /// @param admin_ Address that receives DEFAULT_ADMIN_ROLE and can grant or revoke MINTER_ROLE and BURNER_ROLE.
    constructor(address admin_) ERC20("Wrapped Nexum", "wNXM") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Mints new wNXM tokens to the given address.
    /// @dev Only callable by MINTER_ROLE (reverts with AccessControlUnauthorizedAccount otherwise).
    ///      Reverts with ERC20InvalidReceiver if `to` is the zero address. Emits a Transfer event from address(0).
    /// @param to     Address that receives the newly minted tokens.
    /// @param amount Amount of wNXM to mint, in wei (18 decimals).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burns wNXM tokens from the given address.
    /// @dev Only callable by BURNER_ROLE (reverts with AccessControlUnauthorizedAccount otherwise).
    ///      No allowance needed. Reverts with ERC20InsufficientBalance if `from` holds less than `amount`.
    ///      Emits a Transfer event to address(0).
    /// @param from   Address whose tokens are burned.
    /// @param amount Amount of wNXM to burn, in wei (18 decimals).
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }
}
