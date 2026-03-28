// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

/// @title IValidatorShare - Interface for ValidatorShare with priority fee extension.
/// @notice Existing ValidatorShare functions are unchanged. One new function is added.
interface IValidatorShare {
    // --- Existing functions (unchanged) ---

    /// @notice Buy vouchers (delegate) to this validator.
    function buyVouchers(uint256 _amount, uint256 _minSharesToMint) external returns (uint256);

    /// @notice Sell vouchers (undelegate) from this validator.
    function sellVouchers_new(uint256 claimAmount, uint256 maximumSharesToBurn) external;

    /// @notice Withdraw unstaked tokens after unbonding period.
    function unstakeClaimTokens_new(uint256 unbondNonce) external;

    /// @notice Restake rewards.
    function restake() external returns (uint256, uint256);

    /// @notice Withdraw rewards.
    function withdrawRewards() external;

    /// @notice Get total staked amount for this validator (self + delegated).
    function stakingLogger() external view returns (address);

    /// @notice Get the reward per share accumulator.
    function rewardPerShare() external view returns (uint256);

    /// @notice Get liquid rewards for a delegator.
    function getLiquidRewards(address user) external view returns (uint256);

    /// @notice Get total stake including delegations.
    function totalStake() external view returns (uint256, uint256);

    // --- New function for priority fee sharing ---

    /// @notice Adds priority fee rewards to the reward-per-share accumulator.
    /// @dev Can only be called by the PriorityFeeDistributor contract.
    ///      Increases rewardPerShare so all delegators benefit proportionally.
    ///      The POL tokens must be transferred to this contract before calling.
    /// @param _amount The amount of POL (in wei) to distribute as rewards.
    function addPriorityFeeReward(uint256 _amount) external;
}
