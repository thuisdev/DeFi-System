// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface INexumStaking {
    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function exit() external;

    function earned(address account) external view returns (uint256 rewardsEarned);
}
