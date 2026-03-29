// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {IValidatorShare} from "./interfaces/IValidatorShare.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title PriorityFeeDistributor - Deployed on Ethereum Mainnet.
/// @notice Receives bridged POL from PriorityFeeCollector and distributes it
///         to validators and their delegators via ValidatorShare contracts.
///
/// @dev Distribution per cycle:
///      1. Each active validator receives a base reward.
///      2. Remaining POL is split pro-rata by total stake.
///      3. Commission is sent to the validator signer.
///      4. The rest goes to ValidatorShare.addPriorityFeeReward() for delegators.
///      If addPriorityFeeReward reverts, tokens stay in this contract for the next cycle.
contract PriorityFeeDistributor {
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
    event ValidatorRewardFailed(uint256 indexed validatorIndex, uint256 amount);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error OnlyGovernance();
    error ZeroAddress();
    error InvalidParameter();
    error InsufficientBalance(uint256 balance, uint256 required);
    error NoActiveValidators();
    error DistributionTooFrequent(uint256 nextAllowed, uint256 currentTime);
    error Reentrancy();

    uint256 public constant MAX_DISTRIBUTION_COOLDOWN = 30 days;

    bool public paused;
    address public governance;
    address public pendingGovernance;
    IERC20 public immutable polToken;
    IStakeManager public immutable stakeManager;
    uint256 public baseRewardPerValidator;
    uint256 public distributionCooldown;
    uint256 public lastDistribution;
    uint256 public maxValidatorId;
    bool private _distributing;

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    /// @param _governance            Protocol Council on Ethereum.
    /// @param _polToken              POL token address on Ethereum.
    /// @param _stakeManager          StakeManager proxy address.
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
        if (_maxValidatorId == 0) revert InvalidParameter();
        if (_distributionCooldown > MAX_DISTRIBUTION_COOLDOWN) revert InvalidParameter();

        governance = _governance;
        polToken = IERC20(_polToken);
        stakeManager = IStakeManager(_stakeManager);
        baseRewardPerValidator = _baseRewardPerValidator;
        distributionCooldown = _distributionCooldown;
        maxValidatorId = _maxValidatorId;
    }

    /// @notice Distribute all POL held by this contract to active validators
    ///         and their delegators. Anyone can call.
    function distribute() external whenNotPaused {
        if (_distributing) revert Reentrancy();
        _distributing = true;

        if (block.timestamp < lastDistribution + distributionCooldown) {
            revert DistributionTooFrequent(
                lastDistribution + distributionCooldown,
                block.timestamp
            );
        }

        uint256 totalBalance = polToken.balanceOf(address(this));
        if (totalBalance == 0) revert InsufficientBalance(0, 1);

        lastDistribution = block.timestamp;

        uint256 maxId = maxValidatorId;
        uint256[] memory stakes = new uint256[](maxId);
        address[] memory signers = new address[](maxId);
        address[] memory shareContracts = new address[](maxId);
        uint256[] memory commissions = new uint256[](maxId);
        uint256 activeCount;
        uint256 totalStake;

        for (uint256 id = 1; id <= maxId; id++) {
            IStakeManager.Validator memory v = stakeManager.validators(id);

            if (
                v.status == IStakeManager.Status.Active &&
                v.deactivationEpoch == 0 &&
                v.contractAddress != address(0)
            ) {
                uint256 stake = v.amount + v.delegatedAmount;
                stakes[activeCount] = stake;
                signers[activeCount] = v.signer;
                shareContracts[activeCount] = v.contractAddress;
                commissions[activeCount] = v.commissionRate;
                totalStake += stake;
                activeCount++;
            }
        }

        if (activeCount == 0) revert NoActiveValidators();

        uint256 totalBaseRewards = baseRewardPerValidator * activeCount;

        // If insufficient balance for base rewards, fall back to pure pro-rata.
        if (totalBalance <= totalBaseRewards) {
            totalBaseRewards = 0;
        }

        uint256 remainingPool = totalBalance - totalBaseRewards;
        uint256 distributed;

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 stakeShare = totalStake > 0
                ? (remainingPool * stakes[i]) / totalStake
                : 0;

            uint256 totalReward = totalBaseRewards > 0
                ? baseRewardPerValidator + stakeShare
                : totalStake > 0 ? (totalBalance * stakes[i]) / totalStake : 0;

            if (totalReward == 0) continue;

            // commissionRate is 0-100 (percentage) per StakeManager.
            uint256 commission = (totalReward * commissions[i]) / 100;
            uint256 delegatorReward = totalReward - commission;

            if (commission > 0) {
                // solhint-disable-next-line no-empty-blocks
                try polToken.transfer(signers[i], commission) returns (bool success) {
                    if (success) distributed += commission;
                } catch {}
            }

            // Transfer + addPriorityFeeReward must be atomic: tokens sent to
            // ValidatorShare without updating rewardPerShare are permanently stuck.
            if (delegatorReward > 0) {
                // solhint-disable-next-line no-empty-blocks
                try this.transferAndNotify(shareContracts[i], delegatorReward) {
                    distributed += delegatorReward;
                } catch {
                    emit ValidatorRewardFailed(i, delegatorReward);
                }
            }

            emit ValidatorRewarded(i, commission, delegatorReward);
        }

        _distributing = false;

        emit DistributionExecuted(msg.sender, distributed, activeCount, block.timestamp);
    }

    /// @dev Called via this.transferAndNotify() so try/catch reverts both
    ///      the transfer and notification atomically.
    function transferAndNotify(address _validatorShare, uint256 _amount) external {
        require(msg.sender == address(this), "Only self");
        require(polToken.transfer(_validatorShare, _amount), "Transfer failed");
        IValidatorShare(_validatorShare).addPriorityFeeReward(_amount);
    }

    function setBaseRewardPerValidator(uint256 _value) external onlyGovernance {
        emit ParameterUpdated("baseRewardPerValidator", baseRewardPerValidator, _value);
        baseRewardPerValidator = _value;
    }

    function setDistributionCooldown(uint256 _value) external onlyGovernance {
        if (_value > MAX_DISTRIBUTION_COOLDOWN) revert InvalidParameter();
        emit ParameterUpdated("distributionCooldown", distributionCooldown, _value);
        distributionCooldown = _value;
    }

    function setMaxValidatorId(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("maxValidatorId", maxValidatorId, _value);
        maxValidatorId = _value;
    }

    function setPaused(bool _paused) external onlyGovernance {
        paused = _paused;
        if (_paused) emit Paused(msg.sender);
        else emit Unpaused(msg.sender);
    }

    function transferGovernance(address _newGov) external onlyGovernance {
        if (_newGov == address(0)) revert ZeroAddress();
        pendingGovernance = _newGov;
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert OnlyGovernance();
        emit GovernanceTransferred(governance, msg.sender);
        governance = msg.sender;
        pendingGovernance = address(0);
    }

    function recoverTokens(address _token, address _to, uint256 _amount) external onlyGovernance {
        if (_to == address(0)) revert ZeroAddress();
        require(IERC20(_token).transfer(_to, _amount), "Recovery transfer failed");
    }
}
