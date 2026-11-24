// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Staking - Synthetix-style single-token staking for NXM with NXM rewards
/// @author Adrian (thuisdev)
/// @notice Stake NXM to earn NXM rewards proportional to the amount and duration of your stake.
/// @dev Rewards accrue through a global rewardPerToken accumulator; each account is settled lazily via updateReward.
///      Stake and reward token are the same, so the reward pool is the NXM balance minus totalSupply.
///      In this system the DepositContract is the only staker.
contract Staking is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants & Immutables
    // -------------------------------------------------------------------------

    /// @notice Length of each reward period started by notifyRewardAmount.
    uint256 public constant REWARDS_DURATION = 7 days;

    /// @notice Scaling factor for rewardPerToken so integer division keeps 18 decimals.
    uint256 public constant PRECISION = 1e18;

    /// @notice The NXM token used for both staking and rewards.
    IERC20 public immutable STAKING_TOKEN;

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    /// @notice NXM distributed per second across all stakers during the active period.
    uint256 public rewardRate;

    /// @notice Last time rewardPerTokenStored was updated; never exceeds periodFinish.
    uint256 public lastUpdateTime;

    /// @notice Timestamp at which the active reward period ends.
    uint256 public periodFinish;

    /// @notice Accumulated reward per staked token up to lastUpdateTime, scaled by PRECISION.
    uint256 public rewardPerTokenStored;

    /// @notice Total NXM staked by all accounts.
    uint256 public totalSupply;

    /// @notice rewardPerToken value at which each account was last settled.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice NXM staked per account.
    mapping(address => uint256) public balanceOf;

    /// @notice Rewards earned per account but not yet claimed.
    mapping(address => uint256) public rewards;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when an account stakes NXM.
    /// @param user   The staking account.
    /// @param amount Amount of NXM staked.
    event Staked(address indexed user, uint256 amount);

    /// @notice Emitted when an account withdraws staked NXM.
    /// @param user   The withdrawing account.
    /// @param amount Amount of NXM withdrawn.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when an account claims its rewards.
    /// @param user   The claiming account.
    /// @param reward Amount of NXM paid out.
    event RewardPaid(address indexed user, uint256 reward);

    /// @notice Emitted when the owner starts a new reward period.
    /// @param reward Amount of new NXM rewards added.
    event RewardAdded(uint256 reward);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a zero amount is passed.
    error ZeroAmount();

    /// @notice Thrown when the zero address is passed as staking token.
    error ZeroAddress();

    /// @notice Thrown when an account withdraws more than it has staked.
    /// @param available The account's staked balance.
    /// @param requested The amount the account tried to withdraw.
    error InsufficientBalance(uint256 available, uint256 requested);

    /// @notice Thrown when the reward pool cannot cover the new reward rate for the full period.
    /// @param required NXM needed to pay the new rate for REWARDS_DURATION.
    /// @param available NXM in the reward pool (balance minus totalSupply).
    error InsufficientRewardBalance(uint256 required, uint256 available);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Checkpoints the global accumulator, then settles the earned rewards of `account`.
    ///      Pass address(0) to update only the global state, as notifyRewardAmount does.
    /// @param account Account to settle, or address(0) for a global-only update.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploys the staking contract for NXM and sets the admin.
    /// @dev Reverts with ZeroAddress if stakingToken_ is the zero address; OpenZeppelin rejects a zero owner.
    /// @param stakingToken_ Address of the NXM token.
    /// @param owner_        Admin allowed to start reward periods via notifyRewardAmount.
    constructor(address stakingToken_, address owner_) Ownable(owner_) {
        _checkZeroAddress(stakingToken_);
        STAKING_TOKEN = IERC20(stakingToken_);
    }

    // -------------------------------------------------------------------------
    // External: state-changing
    // -------------------------------------------------------------------------

    /// @notice Stakes NXM and starts earning rewards.
    /// @dev Settles the caller's rewards first. Caller must approve this contract for `amount`.
    ///      Reverts with ZeroAmount. Emits Staked.
    /// @param amount Amount of NXM to stake, in wei (18 decimals).
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        _checkZeroAmount(amount);

        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        emit Staked(msg.sender, amount);

        STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraws the caller's entire stake and claims all earned rewards.
    /// @dev Skips the withdrawal when nothing is staked, so accounts holding only rewards can still exit.
    ///      Not nonReentrant itself, because withdraw() and getReward() each carry the guard and run one after another.
    function exit() external {
        uint256 staked = balanceOf[msg.sender];
        if (staked > 0) {
            withdraw(staked);
        }
        getReward();
    }

    /// @notice Starts a new reward period of REWARDS_DURATION funded with `reward` NXM.
    /// @dev Only callable by the owner, who transfers the NXM to this contract beforehand. Unpaid rewards of an active
    ///      period roll over into the new rate. Reverts with InsufficientRewardBalance if the reward pool (balance
    ///      minus totalSupply) cannot cover the new rate for the full duration. Emits RewardAdded.
    /// @param reward Amount of new NXM rewards to distribute over the period.
    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        _checkZeroAmount(reward);

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / REWARDS_DURATION;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (reward + leftover) / REWARDS_DURATION;
        }

        // Stake and reward token are both NXM, so staked tokens must be excluded from the reward pool.
        uint256 rewardPool = STAKING_TOKEN.balanceOf(address(this)) - totalSupply;
        if (rewardRate > rewardPool / REWARDS_DURATION) {
            revert InsufficientRewardBalance(rewardRate * REWARDS_DURATION, rewardPool);
        }

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARDS_DURATION;

        emit RewardAdded(reward);
    }

    // -------------------------------------------------------------------------
    // Public: state-changing
    // -------------------------------------------------------------------------

    /// @notice Withdraws staked NXM without claiming rewards.
    /// @dev Settles the caller's rewards first. Reverts with ZeroAmount or InsufficientBalance. Emits Withdrawn.
    /// @param amount Amount of NXM to withdraw, in wei (18 decimals).
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        _checkZeroAmount(amount);

        uint256 staked = balanceOf[msg.sender];
        if (staked < amount) {
            revert InsufficientBalance(staked, amount);
        }

        totalSupply -= amount;
        balanceOf[msg.sender] = staked - amount;

        emit Withdrawn(msg.sender, amount);

        STAKING_TOKEN.safeTransfer(msg.sender, amount);
    }

    /// @notice Claims all rewards earned by the caller.
    /// @dev Settles the caller first and does nothing if no rewards are owed. Emits RewardPaid when paying out.
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];

        if (reward > 0) {
            rewards[msg.sender] = 0;
            emit RewardPaid(msg.sender, reward);
            STAKING_TOKEN.safeTransfer(msg.sender, reward);
        }
    }

    // -------------------------------------------------------------------------
    // Public: view
    // -------------------------------------------------------------------------

    /// @notice Returns the rewards earned by `account` that have not been claimed yet.
    /// @dev Synthetix formula: balanceOf * (rewardPerToken - userRewardPerTokenPaid) / PRECISION + rewards.
    /// @param account Account to query.
    /// @return rewardsEarned Claimable NXM rewards.
    function earned(address account) public view returns (uint256 rewardsEarned) {
        return
            (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION) + rewards[account];
    }

    /// @notice Returns the accumulated reward per staked token, scaled by PRECISION.
    /// @dev Returns rewardPerTokenStored unchanged while nothing is staked, so accrued history is never lost.
    /// @return perToken Accumulated reward per staked token.
    function rewardPerToken() public view returns (uint256 perToken) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored
                + (rewardRate * (lastTimeRewardApplicable() - lastUpdateTime) * PRECISION / totalSupply);
    }

    /// @notice Returns the current timestamp, capped at the end of the active reward period.
    /// @dev Stops rewards from accruing after periodFinish, which would promise more NXM than the pool holds.
    /// @return timestamp The smaller of block.timestamp and periodFinish.
    function lastTimeRewardApplicable() public view returns (uint256 timestamp) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
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
