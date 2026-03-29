// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

/// @title IStakeManager - Read-only interface for the Polygon StakeManager.
interface IStakeManager {
    enum Status {
        Inactive,
        Active,
        Locked,
        Unstaked
    }

    struct Validator {
        uint256 amount;          // Self-stake
        uint256 reward;
        uint256 activationEpoch;
        uint256 deactivationEpoch;
        uint256 jailTime;
        address signer;
        address contractAddress; // ValidatorShare proxy
        Status status;
        uint256 commissionRate;  // 0-100 (percentage)
        uint256 lastCommissionUpdate;
        uint256 delegatedAmount;
        uint256 initialRewardPerStake;
    }

    function currentValidatorSetSize() external view returns (uint256);
    function validators(uint256 validatorId) external view returns (Validator memory);
    function signerToValidator(address signer) external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function NFTContract() external view returns (address);
    function validatorThreshold() external view returns (uint256);
    function isValidator(uint256 validatorId) external view returns (bool);
}
