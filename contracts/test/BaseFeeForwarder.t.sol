// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {BaseFeeForwarder} from "../src/BaseFeeForwarder.sol";

contract MockBridge {
    address public lastDepositor;
    uint256 public lastAmount;
    uint256 public totalDeposited;

    function depositFor(address _depositor) external payable {
        lastDepositor = _depositor;
        lastAmount = msg.value;
        totalDeposited += msg.value;
    }
}

contract BaseFeeForwarderTest is Test {
    BaseFeeForwarder forwarder;
    MockBridge mockBridge;

    address governance = address(0x600);
    uint256 constant THRESHOLD = 100_000 ether;
    uint256 constant TRANSFER_CAP = 5_000_000 ether;

    function setUp() public {
        mockBridge = new MockBridge();
        forwarder = new BaseFeeForwarder(
            governance,
            address(mockBridge),
            THRESHOLD,
            TRANSFER_CAP
        );
    }

    function test_ReceiveFees() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(forwarder).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(forwarder).balance, 1 ether);
    }

    function test_Bridge_BelowThreshold() public {
        vm.deal(address(forwarder), THRESHOLD - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseFeeForwarder.BelowThreshold.selector,
                THRESHOLD - 1,
                THRESHOLD
            )
        );
        forwarder.bridgeToBurn();
    }

    function test_Bridge_AtThreshold() public {
        vm.deal(address(forwarder), THRESHOLD);
        forwarder.bridgeToBurn();

        assertEq(mockBridge.lastDepositor(), forwarder.BURN_ADDRESS());
        assertEq(mockBridge.lastAmount(), THRESHOLD);
        assertEq(address(forwarder).balance, 0);
    }

    function test_Bridge_CapsAmount() public {
        vm.deal(address(forwarder), TRANSFER_CAP * 3);
        forwarder.bridgeToBurn();

        assertEq(mockBridge.lastAmount(), TRANSFER_CAP);
        assertEq(address(forwarder).balance, TRANSFER_CAP * 2);
    }

    function test_Bridge_MultipleCalls() public {
        vm.deal(address(forwarder), TRANSFER_CAP * 3);

        forwarder.bridgeToBurn();
        forwarder.bridgeToBurn();
        forwarder.bridgeToBurn();

        assertEq(mockBridge.totalDeposited(), TRANSFER_CAP * 3);
        assertEq(address(forwarder).balance, 0);
    }

    function test_Bridge_DestinationIsBurnAddress() public {
        vm.deal(address(forwarder), THRESHOLD);
        forwarder.bridgeToBurn();

        assertEq(
            mockBridge.lastDepositor(),
            0x000000000000000000000000000000000000dEaD
        );
    }

    function test_Bridge_NoCooldown() public {
        // Can call back-to-back with no cooldown.
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(address(forwarder), THRESHOLD);
            forwarder.bridgeToBurn();
        }

        assertEq(mockBridge.totalDeposited(), THRESHOLD * 3);
    }

    function test_SetBridgeThreshold_OnlyGovernance() public {
        vm.expectRevert(BaseFeeForwarder.OnlyGovernance.selector);
        forwarder.setBridgeThreshold(200_000 ether);

        vm.prank(governance);
        forwarder.setBridgeThreshold(200_000 ether);
        assertEq(forwarder.bridgeThreshold(), 200_000 ether);
    }

    function test_SetTransferCap_OnlyGovernance() public {
        vm.expectRevert(BaseFeeForwarder.OnlyGovernance.selector);
        forwarder.setTransferCap(1_000_000 ether);

        vm.prank(governance);
        forwarder.setTransferCap(1_000_000 ether);
        assertEq(forwarder.transferCap(), 1_000_000 ether);
    }

    function test_SetBridgeThreshold_RejectsZero() public {
        vm.prank(governance);
        vm.expectRevert(BaseFeeForwarder.InvalidParameter.selector);
        forwarder.setBridgeThreshold(0);
    }

    function test_SetTransferCap_RejectsZero() public {
        vm.prank(governance);
        vm.expectRevert(BaseFeeForwarder.InvalidParameter.selector);
        forwarder.setTransferCap(0);
    }

    function test_TwoStepGovernanceTransfer() public {
        address newGov = address(0xBEEF);

        vm.prank(governance);
        forwarder.transferGovernance(newGov);
        assertEq(forwarder.governance(), governance);

        vm.prank(newGov);
        forwarder.acceptGovernance();
        assertEq(forwarder.governance(), newGov);
    }

    function test_RevertZeroAddresses() public {
        vm.expectRevert(BaseFeeForwarder.ZeroAddress.selector);
        new BaseFeeForwarder(address(0), address(mockBridge), THRESHOLD, TRANSFER_CAP);

        vm.expectRevert(BaseFeeForwarder.ZeroAddress.selector);
        new BaseFeeForwarder(governance, address(0), THRESHOLD, TRANSFER_CAP);
    }
}
