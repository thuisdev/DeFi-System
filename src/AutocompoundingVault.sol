// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/tokens/ERC4626.sol";

/// @title AutocompoundingVault - ERC-4626 vault for wNXM that streams harvested staking rewards to aNXM holders
/// @author Adrian (thuisdev)
/// @notice Deposit wNXM to receive aNXM shares; harvested rewards raise the wNXM value of every share over time.
/// @dev totalAssets() is totalStaked + earned(), never the raw wNXM balance. New rewards are streamed linearly over
///      REWARDS_DURATION, so just-in-time deposits cannot capture yield and direct wNXM donations cannot move the
///      share price instantly (ERC-4626 inflation attack). Only the DepositContract can notify new rewards.
contract AutocompoundingVault is ERC4626, Ownable2Step {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Length of each reward stream started by notifyRewardAmount.
    uint256 public constant REWARDS_DURATION = 7 days;

    /// @notice Scaling factor for rewardPerToken to keep decimals in integer division.
    uint256 public constant PRECISION = 1e18;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    /// @notice The only address allowed to call notifyRewardAmount; set once by the owner.
    address public depositContract;

    /// @notice wNXM deposited by users plus rewards already harvested into the vault.
    uint256 public totalStaked;

    /// @notice wNXM released to the vault per second during the active reward period.
    uint256 public rewardRate;

    /// @notice Timestamp up to which streamed rewards have been harvested; never exceeds periodFinish.
    uint256 public lastUpdateTime;

    /// @notice Timestamp at which the active reward stream ends.
    uint256 public periodFinish;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when the owner sets the DepositContract.
    /// @param depositContract Address of the DepositContract.
    event DepositContractSet(address indexed depositContract);

    /// @notice Emitted when a new reward stream starts.
    /// @param reward Amount of wNXM streamed over the new period, including any unstreamed remainder.
    event RewardAdded(uint256 reward);

    /// @notice Emitted when streamed rewards are moved into totalStaked.
    /// @param reward Amount of wNXM harvested.
    event YieldHarvested(uint256 reward);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the zero address is passed as DepositContract.
    error ZeroAddress();

    /// @notice Thrown when a function restricted to the DepositContract is called by another address.
    /// @param caller The unauthorized caller.
    error NotDepositContract(address caller);

    /// @notice Thrown when setDepositContract is called after the DepositContract was already set.
    error DepositContractAlreadySet();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Reverts with NotDepositContract unless msg.sender is the configured DepositContract. While it is unset,
    ///      no caller can pass, because msg.sender is never the zero address.
    modifier onlyDepositContract() {
        if (msg.sender != depositContract) {
            revert NotDepositContract(msg.sender);
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the vault with wNXM as underlying asset and sets the admin.
    /// @dev The DepositContract is deployed after this vault, so the owner sets it once via setDepositContract.
    /// @param wrappedNexumToken_ The wNXM token used as the vault's underlying asset.
    /// @param owner_             Admin that sets the DepositContract; ownership transfers use two steps.
    constructor(ERC20 wrappedNexumToken_, address owner_)
        ERC4626(wrappedNexumToken_, "NexumShares", "aNXM")
        Ownable(owner_)
    {}

    // -------------------------------------------------------------------------
    // External: state-changing
    // -------------------------------------------------------------------------

    /// @notice Sets the DepositContract that may call notifyRewardAmount. Can only be called once.
    /// @dev Only callable by the owner. Reverts with ZeroAddress or DepositContractAlreadySet. The one-time setter
    ///      stops a compromised admin from later swapping in a contract that notifies arbitrary rewards.
    ///      Emits DepositContractSet.
    /// @param depositContract_ Address of the DepositContract.
    function setDepositContract(address depositContract_) external onlyOwner {
        if (depositContract_ == address(0)) {
            revert ZeroAddress();
        }
        if (depositContract != address(0)) {
            revert DepositContractAlreadySet();
        }

        depositContract = depositContract_;
        emit DepositContractSet(depositContract_);
    }

    /// @notice Starts a new reward period for wNXM newly minted into the vault by the DepositContract.
    /// @dev Harvests already streamed rewards first so none are lost when rate and timestamps reset. The new reward is
    ///      the balance minus totalStaked and earned(), which also rolls over any unstreamed remainder of the previous
    ///      period and rounding dust. Reverts with NotDepositContract for any other caller. Emits RewardAdded.
    function notifyRewardAmount() external onlyDepositContract {
        harvest();
        uint256 newReward = asset.balanceOf(address(this)) - totalStaked - earned();

        rewardRate = newReward / REWARDS_DURATION;

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARDS_DURATION;

        emit RewardAdded(newReward);
    }

    // -------------------------------------------------------------------------
    // Public: state-changing
    // -------------------------------------------------------------------------

    /// @notice Claims rewards streamed so far by moving them into totalStaked and restarts the earned() counter.
    /// @dev Permissionless; also runs before every withdrawal and reward notification. Leaves totalAssets()
    ///      unchanged, it only rebooks earned() into totalStaked. Returns early instead of reverting when nothing
    ///      was earned, so withdrawals are never blocked. Emits YieldHarvested.
    function harvest() public {
        uint256 reward = earned();

        if (reward == 0) {
            return;
        }

        _stake(reward);
        lastUpdateTime = lastTimeRewardApplicable();

        emit YieldHarvested(reward);
    }

    // -------------------------------------------------------------------------
    // Public: view
    // -------------------------------------------------------------------------

    /// @notice Returns rewards streamed since the last harvest per staked wNXM, scaled by PRECISION.
    /// @dev Informational only, not used in share accounting. Returns 0 if nothing is staked to avoid division by zero.
    ///      Multiplies before dividing so decimals are not truncated.
    /// @return rewardPerAsset Streamed reward per staked wNXM, scaled by 1e18.
    function rewardPerToken() public view returns (uint256 rewardPerAsset) {
        if (totalStaked == 0) {
            return 0;
        }

        rewardPerAsset = earned() * PRECISION / totalStaked;
    }

    /// @notice Returns the wNXM rewards streamed to the vault since the last harvest.
    /// @dev Linear stream: (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate, which stops at periodFinish.
    /// @return reward Streamed but not yet harvested wNXM.
    function earned() public view returns (uint256 reward) {
        return (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
    }

    /// @notice Returns the current timestamp, capped at the end of the active reward period.
    /// @dev Used by earned() and harvest() so lastUpdateTime can never exceed periodFinish, which would underflow
    ///      earned() and make totalAssets() revert for every deposit and withdrawal.
    /// @return timestamp The smaller of block.timestamp and periodFinish.
    function lastTimeRewardApplicable() public view returns (uint256 timestamp) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Returns the wNXM backing all aNXM shares: user deposits plus rewards streamed so far.
    /// @dev Deliberately ignores the raw wNXM balance so unstreamed rewards and donations do not move the share price.
    /// @return assets totalStaked plus earned().
    function totalAssets() public view override returns (uint256 assets) {
        return totalStaked + earned();
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev solmate hook, called by deposit() and mint() after the assets were transferred in.
    /// @param assets Amount of wNXM deposited.
    function afterDeposit(uint256 assets, uint256) internal override {
        _stake(assets);
    }

    /// @dev solmate hook, called by withdraw() and redeem() before the assets leave. Harvests first so totalStaked
    ///      includes the streamed rewards owed to the withdrawer and cannot underflow.
    /// @param assets Amount of wNXM withdrawn.
    function beforeWithdraw(uint256 assets, uint256) internal override {
        harvest();
        _withdrawInternal(assets);
    }

    /// @dev Increases totalStaked on deposit, mint and harvest.
    /// @param amount Amount of wNXM added to totalStaked.
    function _stake(uint256 amount) internal {
        totalStaked += amount;
    }

    /// @dev Decreases totalStaked on withdraw and redeem.
    /// @param amount Amount of wNXM removed from totalStaked.
    function _withdrawInternal(uint256 amount) internal {
        totalStaked -= amount;
    }
}
