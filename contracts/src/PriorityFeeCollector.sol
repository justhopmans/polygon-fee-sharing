// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

/// @title PriorityFeeCollector — Deployed on Polygon PoS.
/// @notice Accumulates priority fees paid by transactions, then bridges them
///         to Ethereum via the native PoS bridge. Fully permissionless.
///
/// @dev The Polygon PoS system-transaction logic must set this contract as the
///      priority-fee recipient (or fees are forwarded here by a minimal wrapper).
///      Anyone can trigger bridging once the threshold is met.
contract PriorityFeeCollector {
    // ─── Events ───

    event BridgeInitiated(address indexed caller, uint256 amount, uint256 timestamp);
    event TimelockQueued(uint256 amount, uint256 executeAfter);
    event TransferCancelled(uint256 amount, address indexed cancelledBy);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);

    // ─── Errors ───

    error BelowThreshold(uint256 balance, uint256 threshold);
    error TimelockNotReady(uint256 executeAfter, uint256 currentTime);
    error NoPendingTransfer();
    error TransferAlreadyQueued(uint256 executeAfter);
    error ExceedsTransferCap(uint256 amount, uint256 cap);
    error OnlyGovernance();
    error ZeroAddress();
    error InvalidParameter();
    error NoCancelBeforeTimelock();

    // ─── State ───

    /// @notice Protocol Council multisig or governance timelock on Polygon PoS.
    address public governance;

    /// @notice Minimum POL balance before bridging is allowed.
    uint256 public bridgeThreshold;

    /// @notice Maximum time between bridges, regardless of threshold.
    uint256 public maxBridgePeriod;

    /// @notice Maximum POL that can be bridged in a single transaction.
    uint256 public transferCap;

    /// @notice Timelock duration for queued transfers.
    uint256 public timelockDuration;

    /// @notice Receiver on Ethereum (the PriorityFeeDistributor).
    address public ethereumReceiver;

    /// @notice The native PoS bridge contract on Polygon.
    address public bridge;

    /// @notice Timestamp of the last successful bridge.
    uint256 public lastBridgeTimestamp;

    // ─── Timelock state ───

    struct PendingTransfer {
        uint256 amount;
        uint256 executeAfter;
    }

    PendingTransfer public pendingTransfer;

    // ─── Modifiers ───

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    // ─── Constructor ───

    /// @param _governance       Protocol Council address on Polygon PoS.
    /// @param _ethereumReceiver PriorityFeeDistributor address on Ethereum.
    /// @param _bridge           Native PoS bridge contract address.
    /// @param _bridgeThreshold  Minimum balance to trigger bridge (in wei).
    /// @param _maxBridgePeriod  Max seconds between bridges.
    /// @param _transferCap      Max bridgeable per tx (in wei).
    /// @param _timelockDuration Seconds the transfer must wait after queuing.
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

        governance = _governance;
        ethereumReceiver = _ethereumReceiver;
        bridge = _bridge;
        bridgeThreshold = _bridgeThreshold;
        maxBridgePeriod = _maxBridgePeriod;
        transferCap = _transferCap;
        timelockDuration = _timelockDuration;
        lastBridgeTimestamp = block.timestamp;
    }

    // ─── Receive priority fees ───

    /// @notice Accepts native POL sent as priority fees.
    receive() external payable {}

    // ─── Permissionless bridge flow (two-step with timelock) ───

    /// @notice Step 1: Queue a bridge transfer. Anyone can call.
    /// @dev Requires balance >= threshold OR maxBridgePeriod elapsed.
    function queueBridge() external {
        // Prevent overwriting an already queued transfer.
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

    /// @notice Step 2: Execute the queued bridge transfer. Anyone can call.
    /// @dev Calls the native PoS bridge to send POL to Ethereum.
    function executeBridge() external {
        PendingTransfer memory pt = pendingTransfer;

        if (pt.amount == 0) revert NoPendingTransfer();
        if (block.timestamp < pt.executeAfter) {
            revert TimelockNotReady(pt.executeAfter, block.timestamp);
        }

        // Cap to actual balance in case fees were somehow withdrawn.
        uint256 amount = pt.amount > address(this).balance
            ? address(this).balance
            : pt.amount;

        if (amount > transferCap) revert ExceedsTransferCap(amount, transferCap);

        // Clear pending transfer before external call.
        delete pendingTransfer;
        lastBridgeTimestamp = block.timestamp;

        // Bridge native POL to Ethereum receiver via the PoS bridge.
        // The bridge interface accepts native value and a destination address.
        (bool success, ) = bridge.call{value: amount}(
            abi.encodeWithSignature("depositFor(address)", ethereumReceiver)
        );
        require(success, "Bridge call failed");

        emit BridgeInitiated(msg.sender, amount, block.timestamp);
    }

    // ─── Cancel a queued transfer ───

    /// @notice Cancel a pending bridge transfer. Anyone can call, but only
    ///         after the timelock has expired (prevents griefing during the
    ///         waiting period). Governance can cancel at any time.
    function cancelQueue() external {
        PendingTransfer memory pt = pendingTransfer;
        if (pt.amount == 0) revert NoPendingTransfer();

        // Non-governance callers can only cancel after timelock expiry
        // (i.e., when executeBridge is also possible but keeps failing).
        if (msg.sender != governance && block.timestamp < pt.executeAfter) {
            revert NoCancelBeforeTimelock();
        }

        delete pendingTransfer;
        emit TransferCancelled(pt.amount, msg.sender);
    }

    // ─── Governance parameter updates ───

    function setBridgeThreshold(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("bridgeThreshold", bridgeThreshold, _value);
        bridgeThreshold = _value;
    }

    function setMaxBridgePeriod(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("maxBridgePeriod", maxBridgePeriod, _value);
        maxBridgePeriod = _value;
    }

    function setTransferCap(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("transferCap", transferCap, _value);
        transferCap = _value;
    }

    function setTimelockDuration(uint256 _value) external onlyGovernance {
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
        emit GovernanceTransferred(governance, _newGov);
        governance = _newGov;
    }
}
