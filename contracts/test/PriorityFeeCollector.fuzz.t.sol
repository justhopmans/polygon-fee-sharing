// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PriorityFeeCollector} from "../src/PriorityFeeCollector.sol";

/// @dev Mock bridge that records deposits.
contract FuzzMockBridge {
    uint256 public totalDeposited;
    uint256 public callCount;

    function depositFor(address) external payable {
        totalDeposited += msg.value;
        callCount++;
    }
}

contract PriorityFeeCollectorFuzzTest is Test {
    PriorityFeeCollector collector;
    FuzzMockBridge bridge;

    address governance = address(0x600);
    address ethReceiver = address(0xE7D);

    uint256 constant THRESHOLD = 500_000 ether;
    uint256 constant MAX_PERIOD = 3 days;
    uint256 constant TRANSFER_CAP = 1_000_000 ether;
    uint256 constant TIMELOCK = 2 hours;

    function setUp() public {
        vm.warp(100_000);

        bridge = new FuzzMockBridge();
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

    // ─── Invariant: queued amount never exceeds transfer cap ───

    function testFuzz_QueuedAmountCappedAtTransferCap(uint256 balance) public {
        balance = bound(balance, THRESHOLD, 10_000_000 ether);

        vm.deal(address(collector), balance);
        collector.queueBridge();

        (uint256 amount, ) = collector.pendingTransfer();
        assertLe(amount, TRANSFER_CAP, "Queued amount exceeds transfer cap");
    }

    // ─── Invariant: timelock always enforced ───

    function testFuzz_TimelockAlwaysEnforced(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 0, TIMELOCK - 1);

        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        vm.warp(block.timestamp + timeDelta);

        vm.expectRevert();
        collector.executeBridge();
    }

    // ─── Invariant: after timelock, execute always succeeds ───

    function testFuzz_ExecuteSucceedsAfterTimelock(uint256 extraTime) public {
        extraTime = bound(extraTime, 0, 365 days);

        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        vm.warp(block.timestamp + TIMELOCK + extraTime);

        collector.executeBridge();

        assertEq(bridge.totalDeposited(), THRESHOLD);
        (uint256 amount, ) = collector.pendingTransfer();
        assertEq(amount, 0, "Pending not cleared after execute");
    }

    // ─── Invariant: bridge preserves all value ───

    function testFuzz_BridgePreservesValue(uint256 balance) public {
        balance = bound(balance, THRESHOLD, TRANSFER_CAP);

        vm.deal(address(collector), balance);
        collector.queueBridge();
        vm.warp(block.timestamp + TIMELOCK);
        collector.executeBridge();

        // All bridged value should arrive at bridge contract.
        assertEq(bridge.totalDeposited(), balance);
        assertEq(address(collector).balance, 0);
    }

    // ─── Invariant: cannot double-queue ───

    function testFuzz_CannotDoubleQueue(uint256 balance1, uint256 balance2) public {
        balance1 = bound(balance1, THRESHOLD, 10_000_000 ether);
        balance2 = bound(balance2, 1, 10_000_000 ether);

        vm.deal(address(collector), balance1);
        collector.queueBridge();

        // Add more balance and try again.
        vm.deal(address(collector), address(collector).balance + balance2);

        vm.expectRevert();
        collector.queueBridge();
    }

    // ─── Invariant: cancel grace period protects execute window ───

    function testFuzz_GracePeriodProtectsExecute(uint256 timeSinceTimelock) public {
        timeSinceTimelock = bound(timeSinceTimelock, 0, collector.EXECUTE_GRACE_PERIOD() - 1);

        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        // Warp to timelock + some time within grace period.
        vm.warp(block.timestamp + TIMELOCK + timeSinceTimelock);

        // Non-governance cancel should fail during grace period.
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert();
        collector.cancelQueue();

        // But execute should work.
        collector.executeBridge();
    }

    // ─── Invariant: governance can always cancel ───

    function testFuzz_GovernanceCanAlwaysCancel(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 0, 365 days);

        vm.deal(address(collector), THRESHOLD);
        collector.queueBridge();

        vm.warp(block.timestamp + timeDelta);

        vm.prank(governance);
        collector.cancelQueue();

        (uint256 amount, ) = collector.pendingTransfer();
        assertEq(amount, 0);
    }

    // ─── Invariant: cancel preserves balance ───

    function testFuzz_CancelPreservesBalance(uint256 balance) public {
        balance = bound(balance, THRESHOLD, 10_000_000 ether);

        vm.deal(address(collector), balance);
        collector.queueBridge();

        uint256 balBefore = address(collector).balance;

        vm.prank(governance);
        collector.cancelQueue();

        // Balance should be unchanged — cancel doesn't move funds.
        assertEq(address(collector).balance, balBefore, "Cancel changed balance");
    }

    // ─── Invariant: can re-queue after cancel ───

    function testFuzz_CanRequeueAfterCancel(uint256 balance) public {
        balance = bound(balance, THRESHOLD, TRANSFER_CAP);

        vm.deal(address(collector), balance);
        collector.queueBridge();

        vm.prank(governance);
        collector.cancelQueue();

        // Re-queue should succeed.
        collector.queueBridge();
        (uint256 amount, ) = collector.pendingTransfer();
        assertGt(amount, 0, "Re-queue failed");
    }

    // ─── Invariant: can re-queue after execute ───

    function testFuzz_CanRequeueAfterExecute(uint256 balance) public {
        balance = bound(balance, THRESHOLD, TRANSFER_CAP);

        vm.deal(address(collector), balance);
        collector.queueBridge();
        vm.warp(block.timestamp + TIMELOCK);
        collector.executeBridge();

        // Fund again and re-queue.
        vm.deal(address(collector), balance);
        collector.queueBridge();
        (uint256 amount, ) = collector.pendingTransfer();
        assertGt(amount, 0, "Re-queue after execute failed");
    }

    // ─── Invariant: period-based bridge works below threshold ───

    function testFuzz_PeriodOverridesBelowThreshold(uint256 balance, uint256 extraTime) public {
        balance = bound(balance, 1 wei, THRESHOLD - 1);
        extraTime = bound(extraTime, 0, 365 days);

        vm.deal(address(collector), balance);
        vm.warp(block.timestamp + MAX_PERIOD + 1 + extraTime);

        collector.queueBridge();
        (uint256 amount, ) = collector.pendingTransfer();
        assertEq(amount, balance, "Period override didn't capture full balance");
    }

    // ─── Invariant: below threshold and before period always reverts ───

    function testFuzz_BelowThresholdBeforePeriodReverts(uint256 balance, uint256 timeDelta) public {
        balance = bound(balance, 1 wei, THRESHOLD - 1);
        // Keep time well within period.
        timeDelta = bound(timeDelta, 0, MAX_PERIOD - 1);

        vm.deal(address(collector), balance);
        // Warp only within the bridge period.
        vm.warp(block.timestamp + timeDelta);

        vm.expectRevert();
        collector.queueBridge();
    }

    // ─── Governance parameter bounds ───

    function testFuzz_TimelockDurationBounds(uint256 value) public {
        vm.prank(governance);

        if (value < 1 hours || value > 7 days) {
            vm.expectRevert(PriorityFeeCollector.InvalidParameter.selector);
            collector.setTimelockDuration(value);
        } else {
            collector.setTimelockDuration(value);
            assertEq(collector.timelockDuration(), value);
        }
    }

    function testFuzz_MaxBridgePeriodBounds(uint256 value) public {
        vm.prank(governance);

        if (value == 0 || value > 30 days) {
            vm.expectRevert(PriorityFeeCollector.InvalidParameter.selector);
            collector.setMaxBridgePeriod(value);
        } else {
            collector.setMaxBridgePeriod(value);
            assertEq(collector.maxBridgePeriod(), value);
        }
    }

    function testFuzz_BridgeThresholdRejectsZero(uint256 value) public {
        vm.prank(governance);

        if (value == 0) {
            vm.expectRevert(PriorityFeeCollector.InvalidParameter.selector);
            collector.setBridgeThreshold(value);
        } else {
            collector.setBridgeThreshold(value);
            assertEq(collector.bridgeThreshold(), value);
        }
    }

    // ─── Full lifecycle fuzz: queue → execute → re-queue → cancel → re-queue → execute ───

    function testFuzz_FullLifecycle(
        uint256 balance1,
        uint256 balance2,
        uint256 balance3
    ) public {
        balance1 = bound(balance1, THRESHOLD, TRANSFER_CAP);
        balance2 = bound(balance2, THRESHOLD, TRANSFER_CAP);
        balance3 = bound(balance3, THRESHOLD, TRANSFER_CAP);

        // Cycle 1: queue → execute.
        vm.deal(address(collector), balance1);
        collector.queueBridge();
        vm.warp(block.timestamp + TIMELOCK);
        collector.executeBridge();
        assertEq(address(collector).balance, 0);

        // Cycle 2: queue → cancel.
        vm.deal(address(collector), balance2);
        collector.queueBridge();
        vm.prank(governance);
        collector.cancelQueue();
        assertEq(address(collector).balance, balance2);

        // Cycle 3: queue → execute.
        collector.queueBridge();
        vm.warp(block.timestamp + TIMELOCK);
        collector.executeBridge();
        assertEq(address(collector).balance, 0);

        // Total bridged should be balance1 + balance2.
        assertEq(bridge.totalDeposited(), balance1 + balance2);
        assertEq(bridge.callCount(), 2);
    }
}
