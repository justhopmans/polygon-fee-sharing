// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

/// @title BaseFeeForwarder - Deployed on Polygon PoS.
/// @notice Receives base fees and bridges them to a burn address on Ethereum.
///         Replaces the current base fee "burn" contract that just holds POL
///         with no way to actually burn it.
///
/// @dev The burn address is immutable -- governance cannot redirect funds.
///      No timelock needed because the destination is a dead address.
contract BaseFeeForwarder {
    // --- Events ---

    event BridgeExecuted(address indexed caller, uint256 amount, uint256 timestamp);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);

    // --- Errors ---

    error BelowThreshold(uint256 balance, uint256 threshold);
    error OnlyGovernance();
    error ZeroAddress();
    error InvalidParameter();

    // --- Constants ---

    /// @notice Burn address on Ethereum. Immutable -- cannot be changed.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // --- State ---

    /// @notice Governance address on Polygon.
    address public governance;

    /// @notice Pending governance address for two-step transfer.
    address public pendingGovernance;

    /// @notice The native PoS bridge contract on Polygon.
    address public bridgeContract;

    /// @notice Minimum balance before bridging is allowed.
    uint256 public bridgeThreshold;

    /// @notice Maximum POL bridged per transaction.
    uint256 public transferCap;

    // --- Modifiers ---

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    // --- Constructor ---

    /// @param _governance      Protocol Council address on Polygon PoS.
    /// @param _bridge          Native PoS bridge contract address.
    /// @param _bridgeThreshold Minimum balance to trigger bridge (in wei).
    /// @param _transferCap     Max bridgeable per tx (in wei).
    constructor(
        address _governance,
        address _bridge,
        uint256 _bridgeThreshold,
        uint256 _transferCap
    ) {
        if (_governance == address(0)) revert ZeroAddress();
        if (_bridge == address(0)) revert ZeroAddress();

        governance = _governance;
        bridgeContract = _bridge;
        bridgeThreshold = _bridgeThreshold;
        transferCap = _transferCap;
    }

    // --- Receive base fees ---

    /// @notice Accepts native POL sent as base fees.
    receive() external payable {}

    // --- Permissionless bridge to burn ---

    /// @notice Bridge accumulated base fees to the burn address on Ethereum.
    ///         Anyone can call once the threshold is met.
    function bridgeToBurn() external {
        uint256 balance = address(this).balance;
        if (balance < bridgeThreshold) {
            revert BelowThreshold(balance, bridgeThreshold);
        }

        uint256 amount = balance > transferCap ? transferCap : balance;

        (bool success, ) = bridgeContract.call{value: amount}(
            abi.encodeWithSignature("depositFor(address)", BURN_ADDRESS)
        );
        require(success, "Bridge call failed");

        emit BridgeExecuted(msg.sender, amount, block.timestamp);
    }

    // --- Governance parameter updates ---

    function setBridgeThreshold(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("bridgeThreshold", bridgeThreshold, _value);
        bridgeThreshold = _value;
    }

    function setTransferCap(uint256 _value) external onlyGovernance {
        if (_value == 0) revert InvalidParameter();
        emit ParameterUpdated("transferCap", transferCap, _value);
        transferCap = _value;
    }

    function setBridge(address _bridge) external onlyGovernance {
        if (_bridge == address(0)) revert ZeroAddress();
        bridgeContract = _bridge;
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
}
