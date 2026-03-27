// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PriorityFeeCollector} from "../src/PriorityFeeCollector.sol";

/// @dev Mock bridge that records calls and accepts native value.
contract MockBridge {
    address public lastDepositor;
    uint256 public lastAmount;

    function depositFor(address _depositor) external payable {
        lastDepositor = _depositor;
        lastAmount = msg.value;
    }
}

contract PriorityFeeCollectorTest is Test {
    PriorityFeeCollector collector;
    MockBridge bridge;

    address governance = address(0x600);
    address ethReceiver = address(0xE7D);

    uint256 constant THRESHOLD = 100_000 ether;
    uint256 constant MAX_PERIOD = 7 days;
    uint256 constant TRANSFER_CAP = 100_000 ether;
    uint256 constant TIMELOCK = 1 days;

    function setUp() public {
        bridge = new MockBridge();

        collector = new PriorityFeeCollector(
            governance,
            ethReceiver,
            address(bridge),
            THRESHOLD,
            MAX_PERIOD,
            TRANSFER_CAP,
            TIMELOCK
        );
    }

    function test_ReceiveFees() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(collector).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(collector).balance, 1 ether);
    }

    function test_QueueBridge_RevertsBelow_Threshold() public {
        vm.deal(address(collector), THRESHOLD - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriorityFeeCollector.BelowThreshold.selector,
                THRESHOLD - 1,
                THRESHOLD
            )
        );
        collector.queueBridge();
    }

    function test_QueueBridge_SucceedsAtThreshold() public {
        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        (uint256 amount, uint256 executeAfter) = collector.pendingTransfer();
        assertEq(amount, THRESHOLD);
        assertEq(executeAfter, block.timestamp + TIMELOCK);
    }

    function test_QueueBridge_SucceedsAfterMaxPeriod() public {
        vm.deal(address(collector), 1 ether); // below threshold
        vm.warp(block.timestamp + MAX_PERIOD + 1);

        collector.queueBridge();

        (uint256 amount, ) = collector.pendingTransfer();
        assertEq(amount, 1 ether);
    }

    function test_QueueBridge_CapsAmount() public {
        vm.deal(address(collector), TRANSFER_CAP * 2);
        collector.queueBridge();

        (uint256 amount, ) = collector.pendingTransfer();
        assertEq(amount, TRANSFER_CAP);
    }

    function test_ExecuteBridge_RevertsNoQueue() public {
        vm.expectRevert(PriorityFeeCollector.NoPendingTransfer.selector);
        collector.executeBridge();
    }

    function test_ExecuteBridge_RevertsTimelockNotReady() public {
        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        vm.expectRevert(
            abi.encodeWithSelector(
                PriorityFeeCollector.TimelockNotReady.selector,
                block.timestamp + TIMELOCK,
                block.timestamp
            )
        );
        collector.executeBridge();
    }

    function test_ExecuteBridge_FullFlow() public {
        vm.deal(address(collector), THRESHOLD);

        // Queue
        collector.queueBridge();

        // Wait for timelock
        vm.warp(block.timestamp + TIMELOCK);

        // Execute
        collector.executeBridge();

        assertEq(bridge.lastDepositor(), ethReceiver);
        assertEq(bridge.lastAmount(), THRESHOLD);
        assertEq(address(collector).balance, 0);
    }

    function test_ExecuteBridge_ClearsQueue() public {
        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();
        vm.warp(block.timestamp + TIMELOCK);
        collector.executeBridge();

        // Pending should be cleared
        (uint256 amount, ) = collector.pendingTransfer();
        assertEq(amount, 0);
    }

    function test_OnlyGovernance_SetThreshold() public {
        vm.expectRevert(PriorityFeeCollector.OnlyGovernance.selector);
        collector.setBridgeThreshold(200_000 ether);

        vm.prank(governance);
        collector.setBridgeThreshold(200_000 ether);
        assertEq(collector.bridgeThreshold(), 200_000 ether);
    }

    function test_OnlyGovernance_TransferGovernance() public {
        address newGov = address(0xBEEF);

        vm.prank(governance);
        collector.transferGovernance(newGov);
        assertEq(collector.governance(), newGov);
    }

    function test_RevertZeroAddresses() public {
        vm.expectRevert(PriorityFeeCollector.ZeroAddress.selector);
        new PriorityFeeCollector(
            address(0), ethReceiver, address(bridge),
            THRESHOLD, MAX_PERIOD, TRANSFER_CAP, TIMELOCK
        );
    }
}
