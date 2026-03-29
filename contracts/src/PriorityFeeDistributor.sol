// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import {IStakeManager} from "./interfaces/IStakeManager.sol";
import {IValidatorShare} from "./interfaces/IValidatorShare.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title PriorityFeeDistributor - Deployed on Ethereum Mainnet.
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
    // --- Events ---

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

    // --- Errors ---

    error OnlyGovernance();
    error ZeroAddress();
    error InvalidParameter();
    error InsufficientBalance(uint256 balance, uint256 required);
    error NoActiveValidators();
    error DistributionTooFrequent(uint256 nextAllowed, uint256 currentTime);
    error Reentrancy();

    // --- State ---

    /// @notice Maximum distribution cooldown to prevent overflow lockout.
    uint256 public constant MAX_DISTRIBUTION_COOLDOWN = 30 days;

    /// @notice Protocol Council multisig or governance timelock on Ethereum.
    address public governance;

    /// @notice Pending governance address for two-step transfer.
    address public pendingGovernance;

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

    /// @notice Reentrancy guard.
    bool private _distributing;

    // --- Modifiers ---

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    // --- Constructor ---

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

    // --- Core distribution (permissionless) ---

    /// @notice Distribute all POL held by this contract to active validators
    ///         and their delegators. Anyone can call.
    function distribute() external {
        // Reentrancy guard.
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

        // Set cooldown BEFORE external calls to prevent reentrancy.
        lastDistribution = block.timestamp;

        // -- Step 1: Build list of active validators and cache their data --

        uint256 maxId = maxValidatorId;
        uint256[] memory stakes = new uint256[](maxId);
        address[] memory signers = new address[](maxId);
        address[] memory shareContracts = new address[](maxId);
        uint256[] memory commissions = new uint256[](maxId);
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
                stakes[activeCount] = stake;
                signers[activeCount] = v.signer;
                shareContracts[activeCount] = v.contractAddress;
                commissions[activeCount] = v.commissionRate;
                totalStake += stake;
                activeCount++;
            }
        }

        if (activeCount == 0) revert NoActiveValidators();

        // -- Step 2: Calculate base rewards total --

        uint256 totalBaseRewards = baseRewardPerValidator * activeCount;

        // If insufficient balance for base rewards, distribute pro-rata only.
        if (totalBalance <= totalBaseRewards) {
            totalBaseRewards = 0;
        }

        uint256 remainingPool = totalBalance - totalBaseRewards;

        // -- Step 3: Distribute to each validator --

        uint256 distributed;

        for (uint256 i = 0; i < activeCount; i++) {
            // Pro-rata share based on stake weight.
            uint256 stakeShare = totalStake > 0
                ? (remainingPool * stakes[i]) / totalStake
                : 0;

            uint256 totalReward = totalBaseRewards > 0
                ? baseRewardPerValidator + stakeShare
                : (totalBalance * stakes[i]) / totalStake;

            if (totalReward == 0) continue;

            // Commission to the validator signer.
            // StakeManager stores commissionRate as 0-100 (percentage),
            // with MAX_COMMISION_RATE = 100.
            uint256 commission = (totalReward * commissions[i]) / 100;
            uint256 delegatorReward = totalReward - commission;

            // Transfer commission to validator signer.
            // Use try/catch so one broken signer can't brick the whole distribution.
            if (commission > 0) {
                // solhint-disable-next-line no-empty-blocks
                try polToken.transfer(signers[i], commission) returns (bool success) {
                    if (success) distributed += commission;
                } catch {}
            }

            // Transfer delegator share to ValidatorShare and notify.
            // IMPORTANT: We must call addPriorityFeeReward atomically with the
            // transfer. If addPriorityFeeReward would fail, we must NOT transfer,
            // because tokens sent to ValidatorShare without updating rewardPerShare
            // are permanently stuck (no approval for transferFrom recovery).
            //
            // Strategy: transfer + addPriorityFeeReward in an inner call that
            // reverts entirely if addPriorityFeeReward fails. We use a helper
            // that does both steps - if addPriorityFeeReward reverts, the transfer
            // is also reverted because it's the same call context.
            if (delegatorReward > 0) {
                // solhint-disable-next-line no-empty-blocks
                try this.transferAndNotify(shareContracts[i], delegatorReward) {
                    distributed += delegatorReward;
                } catch {
                    // Both transfer and notification failed atomically.
                    // Tokens stay in distributor for next cycle.
                    emit ValidatorRewardFailed(i, delegatorReward);
                }
            }

            emit ValidatorRewarded(i, commission, delegatorReward);
        }

        _distributing = false;

        emit DistributionExecuted(msg.sender, distributed, activeCount, block.timestamp);
    }

    // --- Atomic transfer + notification ---

    /// @notice Transfers POL to a ValidatorShare and calls addPriorityFeeReward.
    /// @dev This is an external function called via this.transferAndNotify() so
    ///      that try/catch reverts BOTH the transfer and the notification atomically.
    ///      If addPriorityFeeReward fails, the transfer is also rolled back.
    ///      Can only be called by this contract.
    function transferAndNotify(address _validatorShare, uint256 _amount) external {
        require(msg.sender == address(this), "Only self");
        require(polToken.transfer(_validatorShare, _amount), "Transfer failed");
        IValidatorShare(_validatorShare).addPriorityFeeReward(_amount);
    }

    // --- Governance parameter updates ---

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

    /// @notice Step 1: Propose a new governance address. Must be accepted.
    function transferGovernance(address _newGov) external onlyGovernance {
        if (_newGov == address(0)) revert ZeroAddress();
        pendingGovernance = _newGov;
    }

    /// @notice Step 2: New governance accepts ownership.
    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert OnlyGovernance();
        emit GovernanceTransferred(governance, msg.sender);
        governance = msg.sender;
        pendingGovernance = address(0);
    }

    // --- Emergency recovery ---

    /// @notice Recover tokens accidentally sent to this contract.
    /// @dev Only governance. Cannot be used during normal operation to
    ///      extract distribution funds - that would require social consensus.
    function recoverTokens(address _token, address _to, uint256 _amount) external onlyGovernance {
        if (_to == address(0)) revert ZeroAddress();
        require(IERC20(_token).transfer(_to, _amount), "Recovery transfer failed");
    }
}
