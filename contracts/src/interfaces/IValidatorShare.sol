// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

/// @title IValidatorShare - Interface for ValidatorShare with priority fee extension.
interface IValidatorShare {
    function buyVouchers(uint256 _amount, uint256 _minSharesToMint) external returns (uint256);
    function sellVouchers_new(uint256 claimAmount, uint256 maximumSharesToBurn) external;
    function unstakeClaimTokens_new(uint256 unbondNonce) external;
    function restake() external returns (uint256, uint256);
    function withdrawRewards() external;
    function stakingLogger() external view returns (address);
    function rewardPerShare() external view returns (uint256);
    function getLiquidRewards(address user) external view returns (uint256);
    function totalStake() external view returns (uint256, uint256);

    /// @notice Adds priority fee rewards to the reward-per-share accumulator.
    /// @dev Only callable by PriorityFeeDistributor. POL must be transferred first.
    function addPriorityFeeReward(uint256 _amount) external;
}
