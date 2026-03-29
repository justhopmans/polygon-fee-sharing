// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {BaseFeeForwarder} from "../src/BaseFeeForwarder.sol";

contract FuzzMockBridge {
    uint256 public totalDeposited;
    address public lastDepositor;

    function depositFor(address _depositor) external payable {
        lastDepositor = _depositor;
        totalDeposited += msg.value;
    }
}

contract BaseFeeForwarderFuzzTest is Test {
    BaseFeeForwarder forwarder;
    FuzzMockBridge mockBridge;

    address governance = address(0x600);
    uint256 constant THRESHOLD = 100_000 ether;
    uint256 constant TRANSFER_CAP = 10_000_000 ether;

    function setUp() public {
        mockBridge = new FuzzMockBridge();
        forwarder = new BaseFeeForwarder(
            governance,
            address(mockBridge),
            THRESHOLD,
            TRANSFER_CAP
        );
    }

    function testFuzz_BridgePreservesValue(uint256 balance) public {
        balance = bound(balance, THRESHOLD, TRANSFER_CAP);
        vm.deal(address(forwarder), balance);

        forwarder.bridgeToBurn();

        assertEq(mockBridge.totalDeposited(), balance);
        assertEq(address(forwarder).balance, 0);
    }

    function testFuzz_BridgeCapsAtTransferCap(uint256 balance) public {
        balance = bound(balance, TRANSFER_CAP + 1, 100_000_000 ether);
        vm.deal(address(forwarder), balance);

        forwarder.bridgeToBurn();

        assertEq(mockBridge.totalDeposited(), TRANSFER_CAP);
        assertEq(address(forwarder).balance, balance - TRANSFER_CAP);
    }

    function testFuzz_BelowThresholdReverts(uint256 balance) public {
        balance = bound(balance, 0, THRESHOLD - 1);
        vm.deal(address(forwarder), balance);

        vm.expectRevert();
        forwarder.bridgeToBurn();
    }

    function testFuzz_AlwaysSendsToBurnAddress(uint256 balance) public {
        balance = bound(balance, THRESHOLD, TRANSFER_CAP);
        vm.deal(address(forwarder), balance);

        forwarder.bridgeToBurn();

        assertEq(
            mockBridge.lastDepositor(),
            0x000000000000000000000000000000000000dEaD
        );
    }

    function testFuzz_MultipleBridgesNoLeak(uint256 balance, uint8 rounds) public {
        balance = bound(balance, THRESHOLD, TRANSFER_CAP);
        rounds = uint8(bound(rounds, 1, 10));

        uint256 totalFunded;
        for (uint256 i = 0; i < rounds; i++) {
            vm.deal(address(forwarder), balance);
            totalFunded += balance;
            forwarder.bridgeToBurn();
        }

        assertEq(mockBridge.totalDeposited(), totalFunded);
        assertEq(address(forwarder).balance, 0);
    }

    function testFuzz_SetBridgeThreshold_RejectsZero(uint256 value) public {
        vm.prank(governance);
        if (value == 0) {
            vm.expectRevert(BaseFeeForwarder.InvalidParameter.selector);
            forwarder.setBridgeThreshold(value);
        } else {
            forwarder.setBridgeThreshold(value);
            assertEq(forwarder.bridgeThreshold(), value);
        }
    }

    function testFuzz_SetTransferCap_RejectsZero(uint256 value) public {
        vm.prank(governance);
        if (value == 0) {
            vm.expectRevert(BaseFeeForwarder.InvalidParameter.selector);
            forwarder.setTransferCap(value);
        } else {
            forwarder.setTransferCap(value);
            assertEq(forwarder.transferCap(), value);
        }
    }
}
