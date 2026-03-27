// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {IValidatorShare} from "./interfaces/IValidatorShare.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title PriorityFeeDistributor — Deployed on Ethereum Mainnet.
/// @notice Receives bridged POL from PriorityFeeCollector and distributes it
///         to validators and their delegators via ValidatorShare contracts.
///
/// @dev Distribution logic per cycle:
///      1. Each active validator receives a base reward.
///      2. Remaining POL is split pro-rata by total stake (self + delegated).
///      3. Validator commission is deducted and sent to the validator signer.
///      4. The rest goes to ValidatorShare.addPriorityFeeReward() so
///         delegators earn proportionally via the existing reward accumulator.
contract PriorityFeeDistributor {
    // ─── Events ───

    event DistributionExecuted(
        address indexed caller,
        uint256 totalAmount,
        uint256 validatorCount,
        uint256 timestamp
    );
    event ValidatorRewarded(
        uint256 indexed validatorId,
        uint256 commission,
        uint256 delegatorReward
    );
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);

    // ─── Errors ───

    error OnlyGovernance();
    error ZeroAddress();
    error InvalidParameter();
    error InsufficientBalance(uint256 balance, uint256 required);
    error NoActiveValidators();
    error DistributionTooFrequent(uint256 nextAllowed, uint256 currentTime);

    // ─── State ───

    /// @notice Protocol Council multisig or governance timelock on Ethereum.
    address public governance;

    /// @notice The POL token contract on Ethereum.
    IERC20 public immutable polToken;

    /// @notice The Polygon StakeManager contract (read-only).
    IStakeManager public immutable stakeManager;

    /// @notice Base reward per active validator per distribution cycle (in wei).
    uint256 public baseRewardPerValidator;

    /// @notice Minimum time between distributions.
    uint256 public distributionCooldown;

    /// @notice Timestamp of last distribution.
    uint256 public lastDistribution;

    /// @notice Maximum validator ID to iterate through.
    uint256 public maxValidatorId;

    // ─── Modifiers ───

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    // ─── Constructor ───

    /// @param _governance            Protocol Council on Ethereum.
    /// @param _polToken              POL token address on Ethereum.
    /// @param _stakeManager          StakeManager proxy address.
    /// @param _baseRewardPerValidator Base reward per validator (in wei).
    /// @param _distributionCooldown  Min seconds between distributions.
    /// @param _maxValidatorId        Upper bound for validator ID iteration.
    constructor(
        address _governance,
        address _polToken,
        address _stakeManager,
        uint256 _baseRewardPerValidator,
        uint256 _distributionCooldown,
        uint256 _maxValidatorId
    ) {
        if (_governance == address(0)) revert ZeroAddress();
        if (_polToken == address(0)) revert ZeroAddress();
        if (_stakeManager == address(0)) revert ZeroAddress();

        governance = _governance;
        polToken = IERC20(_polToken);
        stakeManager = IStakeManager(_stakeManager);
        baseRewardPerValidator = _baseRewardPerValidator;
        distributionCooldown = _distributionCooldown;
        maxValidatorId = _maxValidatorId;
    }

    // ─── Core distribution (permissionless) ───

    /// @notice Distribute all POL held by this contract to active validators
    ///         and their delegators. Anyone can call.
    function distribute() external {
        if (block.timestamp < lastDistribution + distributionCooldown) {
            revert DistributionTooFrequent(
                lastDistribution + distributionCooldown,
                block.timestamp
            );
        }

        uint256 totalBalance = polToken.balanceOf(address(this));

        // ── Step 1: Build list of active validators and their stakes ──

        uint256 maxId = maxValidatorId;
        uint256[] memory activeIds = new uint256[](maxId);
        uint256[] memory stakes = new uint256[](maxId);
        uint256 activeCount;
        uint256 totalStake;

        for (uint256 id = 1; id <= maxId; id++) {
            IStakeManager.Validator memory v = stakeManager.validators(id);

            // Active validator with a ValidatorShare contract.
            if (
                v.status == IStakeManager.Status.Active &&
                v.deactivationEpoch == 0 &&
                v.contractAddress != address(0)
            ) {
                uint256 stake = v.amount + v.delegatedAmount;
                activeIds[activeCount] = id;
                stakes[activeCount] = stake;
                totalStake += stake;
                activeCount++;
            }
        }

        if (activeCount == 0) revert NoActiveValidators();

        // ── Step 2: Calculate base rewards total ──

        uint256 totalBaseRewards = baseRewardPerValidator * activeCount;

        // If insufficient balance for base rewards, distribute pro-rata only.
        if (totalBalance <= totalBaseRewards) {
            totalBaseRewards = 0;
        }

        uint256 remainingPool = totalBalance - totalBaseRewards;

        // ── Step 3: Distribute to each validator ──

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 validatorId = activeIds[i];
            IStakeManager.Validator memory v = stakeManager.validators(validatorId);

            // Pro-rata share based on stake weight.
            uint256 stakeShare = totalStake > 0
                ? (remainingPool * stakes[i]) / totalStake
                : 0;

            uint256 totalReward = totalBaseRewards > 0
                ? baseRewardPerValidator + stakeShare
                : (totalBalance * stakes[i]) / totalStake;

            if (totalReward == 0) continue;

            // Commission to the validator signer.
            uint256 commission = (totalReward * v.commissionRate) / 10_000;
            uint256 delegatorReward = totalReward - commission;

            // Transfer commission to validator signer.
            if (commission > 0) {
                require(polToken.transfer(v.signer, commission), "Commission transfer failed");
            }

            // Transfer delegator share to ValidatorShare and notify.
            if (delegatorReward > 0 && v.contractAddress != address(0)) {
                require(polToken.transfer(v.contractAddress, delegatorReward), "Delegator transfer failed");
                IValidatorShare(v.contractAddress).addPriorityFeeReward(delegatorReward);
            }

            emit ValidatorRewarded(validatorId, commission, delegatorReward);
        }

        lastDistribution = block.timestamp;

        emit DistributionExecuted(msg.sender, totalBalance, activeCount, block.timestamp);
    }

    // ─── Governance parameter updates ───

    function setBaseRewardPerValidator(uint256 _value) external onlyGovernance {
        emit ParameterUpdated("baseRewardPerValidator", baseRewardPerValidator, _value);
        baseRewardPerValidator = _value;
    }

    function setDistributionCooldown(uint256 _value) external onlyGovernance {
        emit ParameterUpdated("distributionCooldown", distributionCooldown, _value);
        distributionCooldown = _value;
    }

    function setMaxValidatorId(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("maxValidatorId", maxValidatorId, _value);
        maxValidatorId = _value;
    }

    function transferGovernance(address _newGov) external onlyGovernance {
        if (_newGov == address(0)) revert ZeroAddress();
        emit GovernanceTransferred(governance, _newGov);
        governance = _newGov;
    }

    // ─── Emergency recovery ───

    /// @notice Recover tokens accidentally sent to this contract.
    /// @dev Only governance. Cannot be used during normal operation to
    ///      extract distribution funds — that would require social consensus.
    function recoverTokens(address _token, address _to, uint256 _amount) external onlyGovernance {
        if (_to == address(0)) revert ZeroAddress();
        require(IERC20(_token).transfer(_to, _amount), "Recovery transfer failed");
    }
}
