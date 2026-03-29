// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

/// @title PriorityFeeCollector - Deployed on Polygon PoS.
/// @notice Accumulates priority fees and bridges them to Ethereum via the
///         native PoS bridge. Two-step timelock flow, fully permissionless.
contract PriorityFeeCollector {
    event BridgeInitiated(address indexed caller, uint256 amount, uint256 timestamp);
    event TimelockQueued(uint256 amount, uint256 executeAfter);
    event TransferCancelled(uint256 amount, address indexed cancelledBy);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);

    error BelowThreshold(uint256 balance, uint256 threshold);
    error TimelockNotReady(uint256 executeAfter, uint256 currentTime);
    error NoPendingTransfer();
    error TransferAlreadyQueued(uint256 executeAfter);
    error ExceedsTransferCap(uint256 amount, uint256 cap);
    error OnlyGovernance();
    error ZeroAddress();
    error InvalidParameter();
    error CancelTooEarly(uint256 cancelableAfter, uint256 currentTime);

    /// @notice Grace period after timelock expiry during which only executeBridge
    ///         can be called. Prevents cancel front-running.
    uint256 public constant EXECUTE_GRACE_PERIOD = 1 hours;
    uint256 public constant MIN_TIMELOCK_DURATION = 1 hours;
    uint256 public constant MAX_TIMELOCK_DURATION = 7 days;
    uint256 public constant MAX_BRIDGE_PERIOD = 30 days;

    address public governance;
    address public pendingGovernance;
    uint256 public bridgeThreshold;
    uint256 public maxBridgePeriod;
    uint256 public transferCap;
    uint256 public timelockDuration;
    address public ethereumReceiver;
    address public bridge;
    uint256 public lastBridgeTimestamp;

    struct PendingTransfer {
        uint256 amount;
        uint256 executeAfter;
    }

    PendingTransfer public pendingTransfer;

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    /// @param _governance       Protocol Council address on Polygon PoS.
    /// @param _ethereumReceiver PriorityFeeDistributor address on Ethereum.
    /// @param _bridge           Native PoS bridge contract address.
    constructor(
        address _governance,
        address _ethereumReceiver,
        address _bridge,
        uint256 _bridgeThreshold,
        uint256 _maxBridgePeriod,
        uint256 _transferCap,
        uint256 _timelockDuration
    ) {
        if (_governance == address(0)) revert ZeroAddress();
        if (_ethereumReceiver == address(0)) revert ZeroAddress();
        if (_bridge == address(0)) revert ZeroAddress();
        if (_bridgeThreshold == 0) revert InvalidParameter();
        if (_maxBridgePeriod == 0 || _maxBridgePeriod > MAX_BRIDGE_PERIOD) revert InvalidParameter();
        if (_transferCap == 0) revert InvalidParameter();
        if (_timelockDuration < MIN_TIMELOCK_DURATION || _timelockDuration > MAX_TIMELOCK_DURATION) revert InvalidParameter();

        governance = _governance;
        ethereumReceiver = _ethereumReceiver;
        bridge = _bridge;
        bridgeThreshold = _bridgeThreshold;
        maxBridgePeriod = _maxBridgePeriod;
        transferCap = _transferCap;
        timelockDuration = _timelockDuration;
        lastBridgeTimestamp = block.timestamp;
    }

    receive() external payable {}

    /// @notice Queue a bridge transfer. Anyone can call.
    /// @dev Requires balance >= threshold OR maxBridgePeriod elapsed.
    function queueBridge() external {
        if (pendingTransfer.amount != 0) {
            revert TransferAlreadyQueued(pendingTransfer.executeAfter);
        }

        uint256 balance = address(this).balance;
        bool thresholdMet = balance >= bridgeThreshold;
        bool periodElapsed = block.timestamp >= lastBridgeTimestamp + maxBridgePeriod;

        if (!thresholdMet && !periodElapsed) {
            revert BelowThreshold(balance, bridgeThreshold);
        }

        uint256 amount = balance > transferCap ? transferCap : balance;

        pendingTransfer = PendingTransfer({
            amount: amount,
            executeAfter: block.timestamp + timelockDuration
        });

        emit TimelockQueued(amount, block.timestamp + timelockDuration);
    }

    /// @notice Execute the queued bridge transfer. Anyone can call.
    function executeBridge() external {
        PendingTransfer memory pt = pendingTransfer;

        if (pt.amount == 0) revert NoPendingTransfer();
        if (block.timestamp < pt.executeAfter) {
            revert TimelockNotReady(pt.executeAfter, block.timestamp);
        }

        uint256 amount = pt.amount > address(this).balance
            ? address(this).balance
            : pt.amount;

        if (amount > transferCap) revert ExceedsTransferCap(amount, transferCap);

        delete pendingTransfer;
        lastBridgeTimestamp = block.timestamp;

        (bool success, ) = bridge.call{value: amount}(
            abi.encodeWithSignature("depositFor(address)", ethereumReceiver)
        );
        require(success, "Bridge call failed");

        emit BridgeInitiated(msg.sender, amount, block.timestamp);
    }

    /// @notice Cancel a pending bridge transfer. Governance can cancel at any time.
    ///         Others must wait for timelock + grace period (prevents front-running executeBridge).
    function cancelQueue() external {
        PendingTransfer memory pt = pendingTransfer;
        if (pt.amount == 0) revert NoPendingTransfer();

        if (msg.sender != governance) {
            uint256 cancelableAfter = pt.executeAfter + EXECUTE_GRACE_PERIOD;
            if (block.timestamp < cancelableAfter) {
                revert CancelTooEarly(cancelableAfter, block.timestamp);
            }
        }

        delete pendingTransfer;
        emit TransferCancelled(pt.amount, msg.sender);
    }

    function setBridgeThreshold(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("bridgeThreshold", bridgeThreshold, _value);
        bridgeThreshold = _value;
    }

    function setMaxBridgePeriod(uint256 _value) external onlyGovernance {
        if (_value == 0 || _value > MAX_BRIDGE_PERIOD) revert InvalidParameter();
        emit ParameterUpdated("maxBridgePeriod", maxBridgePeriod, _value);
        maxBridgePeriod = _value;
    }

    function setTransferCap(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("transferCap", transferCap, _value);
        transferCap = _value;
    }

    function setTimelockDuration(uint256 _value) external onlyGovernance {
        if (_value < MIN_TIMELOCK_DURATION || _value > MAX_TIMELOCK_DURATION) revert InvalidParameter();
        emit ParameterUpdated("timelockDuration", timelockDuration, _value);
        timelockDuration = _value;
    }

    function setBridge(address _bridge) external onlyGovernance {
        if (_bridge == address(0)) revert ZeroAddress();
        bridge = _bridge;
    }

    function setEthereumReceiver(address _receiver) external onlyGovernance {
        if (_receiver == address(0)) revert ZeroAddress();
        ethereumReceiver = _receiver;
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
}
