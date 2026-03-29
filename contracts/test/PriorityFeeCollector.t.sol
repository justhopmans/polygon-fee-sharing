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

    uint256 constant THRESHOLD = 500_000 ether;
    uint256 constant MAX_PERIOD = 3 days;
    uint256 constant TRANSFER_CAP = 1_000_000 ether;
    uint256 constant TIMELOCK = 2 hours;

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

    function test_QueueBridge_RevertsIfAlreadyQueued() public {
        vm.deal(address(collector), THRESHOLD * 2);
        collector.queueBridge();

        // Second queue should revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                PriorityFeeCollector.TransferAlreadyQueued.selector,
                block.timestamp + TIMELOCK
            )
        );
        collector.queueBridge();
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

    function test_CancelQueue_ByGovernance() public {
        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        // Governance can cancel immediately (before timelock).
        vm.prank(governance);
        collector.cancelQueue();

        (uint256 amount, ) = collector.pendingTransfer();
        assertEq(amount, 0);

        // Can queue again after cancel.
        collector.queueBridge();
        (amount, ) = collector.pendingTransfer();
        assertEq(amount, THRESHOLD);
    }

    function test_CancelQueue_ByAnyone_AfterGracePeriod() public {
        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        // Non-governance cannot cancel before timelock.
        vm.expectRevert();
        collector.cancelQueue();

        // After timelock but within grace period, still cannot cancel.
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert();
        collector.cancelQueue();

        // After timelock + grace period, anyone can cancel.
        vm.warp(block.timestamp + collector.EXECUTE_GRACE_PERIOD());
        collector.cancelQueue();

        (uint256 amount, ) = collector.pendingTransfer();
        assertEq(amount, 0);
    }

    function test_CancelQueue_CannotFrontrunExecute() public {
        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        // Warp to exactly when timelock expires.
        vm.warp(block.timestamp + TIMELOCK);

        // Attacker tries to cancel — blocked by grace period.
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert();
        collector.cancelQueue();

        // But executeBridge works fine.
        collector.executeBridge();
        assertEq(address(collector).balance, 0);
    }

    function test_SetTimelockDuration_BoundedMinMax() public {
        // Below minimum (1 hour).
        vm.prank(governance);
        vm.expectRevert(PriorityFeeCollector.InvalidParameter.selector);
        collector.setTimelockDuration(30 minutes);

        // Above maximum (7 days).
        vm.prank(governance);
        vm.expectRevert(PriorityFeeCollector.InvalidParameter.selector);
        collector.setTimelockDuration(8 days);

        // At minimum — works.
        vm.prank(governance);
        collector.setTimelockDuration(1 hours);
        assertEq(collector.timelockDuration(), 1 hours);

        // At maximum — works.
        vm.prank(governance);
        collector.setTimelockDuration(7 days);
        assertEq(collector.timelockDuration(), 7 days);
    }

    function test_CancelQueue_RevertsNoQueue() public {
        vm.expectRevert(PriorityFeeCollector.NoPendingTransfer.selector);
        collector.cancelQueue();
    }

    function test_OnlyGovernance_SetThreshold() public {
        vm.expectRevert(PriorityFeeCollector.OnlyGovernance.selector);
        collector.setBridgeThreshold(200_000 ether);

        vm.prank(governance);
        collector.setBridgeThreshold(200_000 ether);
        assertEq(collector.bridgeThreshold(), 200_000 ether);
    }

    function test_TwoStepGovernanceTransfer() public {
        address newGov = address(0xBEEF);

        // Step 1: Propose.
        vm.prank(governance);
        collector.transferGovernance(newGov);
        // Governance hasn't changed yet.
        assertEq(collector.governance(), governance);
        assertEq(collector.pendingGovernance(), newGov);

        // Step 2: Accept.
        vm.prank(newGov);
        collector.acceptGovernance();
        assertEq(collector.governance(), newGov);
        assertEq(collector.pendingGovernance(), address(0));
    }

    function test_AcceptGovernance_RevertsIfNotPending() public {
        address rando = address(0xBAD);
        vm.prank(rando);
        vm.expectRevert(PriorityFeeCollector.OnlyGovernance.selector);
        collector.acceptGovernance();
    }

    function test_RevertZeroAddresses() public {
        vm.expectRevert(PriorityFeeCollector.ZeroAddress.selector);
        new PriorityFeeCollector(
            address(0), ethReceiver, address(bridge),
            THRESHOLD, MAX_PERIOD, TRANSFER_CAP, TIMELOCK
        );
    }
}
