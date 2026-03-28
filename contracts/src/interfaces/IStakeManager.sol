// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

/// @title IStakeManager - Read-only interface for the Polygon StakeManager.
/// @notice StakeManager is NOT modified. This interface reads validator data.
interface IStakeManager {
    /// @notice Validator status enum matching StakeManager.
    enum Status {
        Inactive,
        Active,
        Locked,
        Unstaked
    }

    /// @notice Minimal validator struct fields we need.
    struct Validator {
        uint256 amount;          // Self-stake in wei
        uint256 reward;          // Pending rewards
        uint256 activationEpoch;
        uint256 deactivationEpoch;
        uint256 jailTime;
        address signer;
        address contractAddress; // ValidatorShare proxy
        Status status;
        uint256 commissionRate;  // Basis points (0–10000)
        uint256 lastCommissionUpdate;
        uint256 delegatedAmount; // Total delegated stake in wei
        uint256 initialRewardPerStake;
    }

    /// @notice Returns the total number of validators (including deactivated).
    function currentValidatorSetSize() external view returns (uint256);

    /// @notice Returns full validator struct by validator ID.
    function validators(uint256 validatorId) external view returns (Validator memory);

    /// @notice Returns the validator ID for a given signer address.
    function signerToValidator(address signer) external view returns (uint256);

    /// @notice Returns the total staked amount across all validators.
    function totalStaked() external view returns (uint256);

    /// @notice Returns the NFT contract address for validator IDs.
    function NFTContract() external view returns (address);

    /// @notice Returns the number of validators in the current active set.
    function validatorThreshold() external view returns (uint256);

    /// @notice Checks if a validator ID is part of the active set.
    function isValidator(uint256 validatorId) external view returns (bool);
}
