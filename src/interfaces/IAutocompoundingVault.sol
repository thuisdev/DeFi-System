// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IAutocompoundingVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function notifyRewardAmount() external;

    function asset() external view returns (address);
}
