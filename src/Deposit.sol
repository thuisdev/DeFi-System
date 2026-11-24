// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAutocompoundingVault} from "./interfaces/IAutocompoundingVault.sol";
import {INexumStaking} from "./interfaces/INexumStaking.sol";
import {WrappedNexumToken} from "./WrappedNexumToken.sol";

/// @title Deposit - Entry point that wraps NXM into wNXM and routes staking yield to the autocompounding vault
/// @author Adrian (thuisdev)
/// @notice Deposit NXM to receive wNXM 1:1, optionally auto-staked into the vault as aNXM. Redeem wNXM back for NXM.
/// @dev This contract is the sole staker in the NXM staking contract. Core invariant: wNXM total supply equals the NXM
///      staked by this contract. Harvested rewards are re-staked and minted as wNXM straight into the vault, so only
///      aNXM holders earn yield. Requires MINTER_ROLE and BURNER_ROLE on wNXM.
contract Deposit is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice The underlying NXM token users deposit.
    IERC20 public immutable NEXUM_TOKEN;

    /// @notice The wNXM token minted 1:1 for deposited NXM; read from the vault's asset() at deployment.
    WrappedNexumToken public immutable WRAPPED_NEXUM_TOKEN;

    /// @notice The NXM staking contract all deposited NXM is staked in.
    INexumStaking public immutable STAKING_CONTRACT;

    /// @notice The ERC-4626 vault for wNXM that issues aNXM shares and streams harvested rewards.
    IAutocompoundingVault public immutable AUTOCOMPOUNDING_VAULT;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    /// @notice Cumulative amount of NXM ever deposited by users; not decremented on redeem.
    uint256 public totalNexumDeposited;

    /// @notice Cumulative amount of wNXM ever minted, including harvested rewards; not decremented on redeem.
    uint256 public totalWrappedNexumMinted;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when NXM is deposited and wNXM (or aNXM via the vault) is issued.
    /// @param depositor Address that supplied the NXM.
    /// @param receiver  Address that received the wNXM or the aNXM shares.
    /// @param amount    Amount of NXM deposited and wNXM minted.
    /// @param compound  True if the wNXM was deposited into the vault on behalf of receiver.
    event Deposited(address indexed depositor, address indexed receiver, uint256 amount, bool compound);

    /// @notice Emitted when wNXM is burned and the underlying NXM is sent to the receiver.
    /// @param caller   Address whose wNXM was burned.
    /// @param receiver Address that received the NXM.
    /// @param amount   Amount of wNXM burned and NXM withdrawn.
    event Redeemed(address indexed caller, address indexed receiver, uint256 amount);

    /// @notice Emitted when harvested staking rewards are minted as wNXM into the vault for streaming.
    /// @param amount Amount of NXM rewards re-staked and wNXM minted to the vault.
    event RewardsSynced(uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a zero address is passed for a token, contract or receiver.
    error ZeroAddress();

    /// @notice Thrown when a zero amount is passed to deposit or redeem.
    error ZeroAmount();

    /// @notice Thrown when harvest is called but the staking contract paid out no rewards.
    error NoRewardsToHarvest();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Sets the NXM token, staking contract and vault; derives wNXM from the vault's underlying asset.
    /// @dev Reverts with ZeroAddress if any argument is the zero address. Deployment order: NXM, wNXM, staking, vault,
    ///      then this contract; afterwards the wNXM admin grants MINTER_ROLE and BURNER_ROLE to this contract.
    /// @param nexumToken_           Address of the NXM token.
    /// @param stakingContract_      Address of the NXM staking contract.
    /// @param autocompoundingVault_ Address of the ERC-4626 vault for wNXM.
    constructor(address nexumToken_, address stakingContract_, address autocompoundingVault_) {
        if (nexumToken_ == address(0) || stakingContract_ == address(0) || autocompoundingVault_ == address(0)) {
            revert ZeroAddress();
        }

        NEXUM_TOKEN = IERC20(nexumToken_);
        STAKING_CONTRACT = INexumStaking(stakingContract_);
        AUTOCOMPOUNDING_VAULT = IAutocompoundingVault(autocompoundingVault_);
        WRAPPED_NEXUM_TOKEN = WrappedNexumToken(AUTOCOMPOUNDING_VAULT.asset());
    }

    // -------------------------------------------------------------------------
    // External: state-changing
    // -------------------------------------------------------------------------

    /// @notice Deposits NXM and issues wNXM 1:1 to receiver, or aNXM vault shares if compound is true.
    /// @dev Caller must approve this contract for `amount` NXM. All NXM is staked in the staking contract.
    ///      The amount is an explicit argument: pulling the full allowance breaks on unlimited approvals, and pulling
    ///      the full balance takes the size of the deposit out of the caller's control.
    ///      Reverts with ZeroAmount or ZeroAddress. Emits Deposited.
    /// @param amount   Amount of NXM to deposit, in wei (18 decimals).
    /// @param receiver Address that receives the wNXM or the aNXM shares.
    /// @param compound If true, the minted wNXM is deposited into the vault and receiver gets aNXM shares.
    function deposit(uint256 amount, address receiver, bool compound) external nonReentrant {
        // CHECKS
        _checkZeroAmount(amount);
        _checkZeroAddress(receiver);

        // EFFECTS
        totalNexumDeposited += amount;
        totalWrappedNexumMinted += amount;

        emit Deposited(msg.sender, receiver, amount, compound);

        // INTERACTIONS
        NEXUM_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        NEXUM_TOKEN.forceApprove(address(STAKING_CONTRACT), amount);
        STAKING_CONTRACT.stake(amount);

        // wNXM is minted 1:1 for the deposited NXM in both branches.
        if (compound) {
            WRAPPED_NEXUM_TOKEN.mint(address(this), amount);
            IERC20(address(WRAPPED_NEXUM_TOKEN)).forceApprove(address(AUTOCOMPOUNDING_VAULT), amount);

            // Shares are minted directly to receiver; solmate's ERC4626 already reverts on zero shares.
            // forge-lint: disable-next-line(unused-return)
            AUTOCOMPOUNDING_VAULT.deposit(amount, receiver);
        } else {
            WRAPPED_NEXUM_TOKEN.mint(receiver, amount);
        }
    }

    /// @notice Claims staking rewards, re-stakes them and streams the matching wNXM to aNXM holders via the vault.
    /// @dev Permissionless so keepers or users can trigger it; the caller receives nothing. Reward is measured as the
    ///      NXM balance delta around getReward() instead of trusting earned(), so minted wNXM can never exceed what was
    ///      actually received and re-staked. Reverts with NoRewardsToHarvest if nothing was paid. Emits RewardsSynced.
    function harvest() external nonReentrant {
        uint256 balanceBefore = NEXUM_TOKEN.balanceOf(address(this));
        STAKING_CONTRACT.getReward();
        uint256 reward = NEXUM_TOKEN.balanceOf(address(this)) - balanceBefore;

        if (reward == 0) {
            revert NoRewardsToHarvest();
        }

        // Harvested rewards increase cumulative wNXM minted; totalNexumDeposited only tracks user deposits.
        totalWrappedNexumMinted += reward;

        // Reward amount is only known after getReward(); function is nonReentrant and staking is trusted.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RewardsSynced(reward);

        // Re-stake first so the new wNXM is fully backed before it exists.
        NEXUM_TOKEN.forceApprove(address(STAKING_CONTRACT), reward);
        STAKING_CONTRACT.stake(reward);

        // Minted directly to the vault without creating shares, which raises the value of every aNXM share.
        WRAPPED_NEXUM_TOKEN.mint(address(AUTOCOMPOUNDING_VAULT), reward);

        // Sync newly added rewards so the vault streams them over REWARDS_DURATION.
        AUTOCOMPOUNDING_VAULT.notifyRewardAmount();
    }

    /// @notice Burns the caller's wNXM and sends the same amount of NXM to receiver.
    /// @dev Always burns from msg.sender, as this contract can burn from any address without allowance.
    ///      Withdraws exactly `assets` from staking, leaving rewards for the next harvest. aNXM holders must first
    ///      redeem their shares from the vault. Reverts with ZeroAmount, ZeroAddress or ERC20InsufficientBalance.
    ///      Emits Redeemed.
    /// @param assets   Amount of wNXM to burn and NXM to receive, in wei (18 decimals).
    /// @param receiver Address that receives the NXM.
    function redeem(uint256 assets, address receiver) external nonReentrant {
        // CHECKS
        _checkZeroAmount(assets);
        _checkZeroAddress(receiver);

        emit Redeemed(msg.sender, receiver, assets);

        // INTERACTIONS
        WRAPPED_NEXUM_TOKEN.burn(msg.sender, assets);
        STAKING_CONTRACT.withdraw(assets);
        NEXUM_TOKEN.safeTransfer(receiver, assets);
    }

    // -------------------------------------------------------------------------
    // Private
    // -------------------------------------------------------------------------

    /// @dev Reverts with ZeroAmount if `amount` is zero.
    /// @param amount Value to check.
    function _checkZeroAmount(uint256 amount) private pure {
        if (amount == 0) {
            revert ZeroAmount();
        }
    }

    /// @dev Reverts with ZeroAddress if `account` is the zero address.
    /// @param account Address to check.
    function _checkZeroAddress(address account) private pure {
        if (account == address(0)) {
            revert ZeroAddress();
        }
    }
}
