// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PriorityFeeDistributor} from "../src/PriorityFeeDistributor.sol";
import {IStakeManager} from "../src/interfaces/IStakeManager.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @dev Mock ERC-20 that tracks total supply for invariant checking.
contract FuzzMockPOL {
    mapping(address => uint256) public balanceOf;
    uint256 public totalMinted;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalMinted += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract FuzzMockValidatorShare {
    uint256 public totalRewardsAdded;

    function addPriorityFeeReward(uint256 _amount) external {
        totalRewardsAdded += _amount;
    }
}

contract FuzzMockStakeManager {
    mapping(uint256 => IStakeManager.Validator) public _validators;

    function setValidator(
        uint256 id,
        address signer,
        address contractAddress,
        uint256 amount,
        uint256 delegatedAmount,
        uint256 commissionRate,
        IStakeManager.Status status
    ) external {
        _validators[id] = IStakeManager.Validator({
            amount: amount,
            reward: 0,
            activationEpoch: 1,
            deactivationEpoch: 0,
            jailTime: 0,
            signer: signer,
            contractAddress: contractAddress,
            status: status,
            commissionRate: commissionRate,
            lastCommissionUpdate: 0,
            delegatedAmount: delegatedAmount,
            initialRewardPerStake: 0
        });
    }

    function validators(uint256 id) external view returns (IStakeManager.Validator memory) {
        return _validators[id];
    }
}

contract PriorityFeeDistributorFuzzTest is Test {
    PriorityFeeDistributor distributor;
    FuzzMockPOL pol;
    FuzzMockStakeManager stakeManager;

    address governance = address(0x600);
    uint256 constant BASE_REWARD = 9_500 ether;
    uint256 constant COOLDOWN = 7 days;
    uint256 constant MAX_VAL_ID = 105;

    function setUp() public {
        vm.warp(700_000);

        pol = new FuzzMockPOL();
        stakeManager = new FuzzMockStakeManager();

        distributor = new PriorityFeeDistributor(
            governance,
            address(pol),
            address(stakeManager),
            BASE_REWARD,
            COOLDOWN,
            MAX_VAL_ID
        );
    }

    // ─── Invariant: distributed amount never exceeds balance ───

    function testFuzz_DistributedNeverExceedsBalance(
        uint256 fundAmount,
        uint256 stake1,
        uint256 stake2,
        uint8 commission1,
        uint8 commission2
    ) public {
        // Bound inputs to realistic ranges.
        fundAmount = bound(fundAmount, 1, 1_000_000_000 ether);
        stake1 = bound(stake1, 1 ether, 100_000_000 ether);
        stake2 = bound(stake2, 1 ether, 100_000_000 ether);
        commission1 = uint8(bound(commission1, 0, 100));
        commission2 = uint8(bound(commission2, 0, 100));

        FuzzMockValidatorShare vs1 = new FuzzMockValidatorShare();
        FuzzMockValidatorShare vs2 = new FuzzMockValidatorShare();

        stakeManager.setValidator(
            1, address(0x5161), address(vs1),
            stake1 / 5, stake1 - stake1 / 5,
            commission1, IStakeManager.Status.Active
        );
        stakeManager.setValidator(
            2, address(0x5162), address(vs2),
            stake2 / 5, stake2 - stake2 / 5,
            commission2, IStakeManager.Status.Active
        );

        pol.mint(address(distributor), fundAmount);

        uint256 balBefore = pol.balanceOf(address(distributor));
        distributor.distribute();
        uint256 balAfter = pol.balanceOf(address(distributor));

        // Distributor balance should never increase (no minting during distribute).
        assertLe(balAfter, balBefore, "Balance increased after distribution");

        // Total sent out = balBefore - balAfter.
        uint256 totalSent = balBefore - balAfter;

        // Total received by validators must equal total sent.
        uint256 totalReceived = pol.balanceOf(address(0x5161))
            + pol.balanceOf(address(0x5162))
            + vs1.totalRewardsAdded()
            + vs2.totalRewardsAdded();

        assertEq(totalSent, totalReceived, "Token leak: sent != received");
    }

    // ─── Invariant: commission is always correct percentage ───

    function testFuzz_CommissionIsCorrectPercentage(
        uint256 fundAmount,
        uint256 stake,
        uint8 commissionRate
    ) public {
        // Single validator for precise commission checking.
        fundAmount = bound(fundAmount, 1 ether, 1_000_000_000 ether);
        stake = bound(stake, 1 ether, 100_000_000 ether);
        commissionRate = uint8(bound(commissionRate, 0, 100));

        FuzzMockValidatorShare vs = new FuzzMockValidatorShare();

        stakeManager.setValidator(
            1, address(0x5161), address(vs),
            stake / 5, stake - stake / 5,
            commissionRate, IStakeManager.Status.Active
        );

        pol.mint(address(distributor), fundAmount);
        distributor.distribute();

        uint256 commission = pol.balanceOf(address(0x5161));
        uint256 delegatorReward = vs.totalRewardsAdded();
        uint256 totalReward = commission + delegatorReward;

        if (totalReward > 0) {
            // Commission should be exactly (totalReward * rate) / 100.
            uint256 expectedCommission = (totalReward * commissionRate) / 100;
            assertEq(commission, expectedCommission, "Commission mismatch");
        }
    }

    // ─── Invariant: zero commission means signer gets nothing ───

    function testFuzz_ZeroCommissionMeansNoSignerPayment(
        uint256 fundAmount,
        uint256 stake
    ) public {
        fundAmount = bound(fundAmount, 1 ether, 1_000_000_000 ether);
        stake = bound(stake, 1 ether, 100_000_000 ether);

        FuzzMockValidatorShare vs = new FuzzMockValidatorShare();

        stakeManager.setValidator(
            1, address(0x5161), address(vs),
            stake / 5, stake - stake / 5,
            0, // zero commission
            IStakeManager.Status.Active
        );

        pol.mint(address(distributor), fundAmount);
        distributor.distribute();

        assertEq(pol.balanceOf(address(0x5161)), 0, "Signer got paid with 0% commission");
        assertEq(vs.totalRewardsAdded(), fundAmount, "All funds should go to delegators");
    }

    // ─── Invariant: 100% commission means delegators get nothing ───

    function testFuzz_FullCommissionMeansNoDelegatorPayment(
        uint256 fundAmount,
        uint256 stake
    ) public {
        fundAmount = bound(fundAmount, 1 ether, 1_000_000_000 ether);
        stake = bound(stake, 1 ether, 100_000_000 ether);

        FuzzMockValidatorShare vs = new FuzzMockValidatorShare();

        stakeManager.setValidator(
            1, address(0x5161), address(vs),
            stake / 5, stake - stake / 5,
            100, // 100% commission
            IStakeManager.Status.Active
        );

        pol.mint(address(distributor), fundAmount);
        distributor.distribute();

        assertEq(vs.totalRewardsAdded(), 0, "Delegators got paid with 100% commission");
        assertEq(pol.balanceOf(address(0x5161)), fundAmount, "Signer should get everything");
    }

    // ─── Invariant: stake-weighted distribution is proportional ───

    function testFuzz_StakeWeightedProportionality(
        uint256 fundAmount,
        uint256 stake1,
        uint256 stake2,
        uint8 commission
    ) public {
        // Equal commission so we can compare total rewards cleanly.
        fundAmount = bound(fundAmount, 100 ether, 1_000_000_000 ether);
        stake1 = bound(stake1, 1 ether, 50_000_000 ether);
        stake2 = bound(stake2, 1 ether, 50_000_000 ether);
        commission = uint8(bound(commission, 0, 50));

        // Set base reward to 0 for pure proportional test.
        vm.prank(governance);
        distributor.setBaseRewardPerValidator(0);

        FuzzMockValidatorShare vs1 = new FuzzMockValidatorShare();
        FuzzMockValidatorShare vs2 = new FuzzMockValidatorShare();

        stakeManager.setValidator(
            1, address(0x5161), address(vs1),
            stake1 / 5, stake1 - stake1 / 5,
            commission, IStakeManager.Status.Active
        );
        stakeManager.setValidator(
            2, address(0x5162), address(vs2),
            stake2 / 5, stake2 - stake2 / 5,
            commission, IStakeManager.Status.Active
        );

        pol.mint(address(distributor), fundAmount);
        distributor.distribute();

        uint256 total1 = pol.balanceOf(address(0x5161)) + vs1.totalRewardsAdded();
        uint256 total2 = pol.balanceOf(address(0x5162)) + vs2.totalRewardsAdded();

        // total1 / total2 should approximately equal stake1 / stake2.
        // Use cross-multiplication to avoid division: total1 * stake2 ≈ total2 * stake1.
        // Allow for rounding: difference should be at most 1 wei per validator.
        uint256 lhs = total1 * stake2;
        uint256 rhs = total2 * stake1;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;

        // Rounding tolerance: max 1 wei per token per validator, scaled by stakes.
        uint256 tolerance = stake1 + stake2;
        assertLe(diff, tolerance, "Stake proportionality violated");
    }

    // ─── Invariant: distribution with many validators never loses tokens ───

    function testFuzz_ManyValidators_NoTokenLeak(
        uint256 fundAmount,
        uint8 validatorCount
    ) public {
        fundAmount = bound(fundAmount, 1 ether, 10_000_000 ether);
        validatorCount = uint8(bound(validatorCount, 1, 20));

        FuzzMockValidatorShare[] memory shares = new FuzzMockValidatorShare[](validatorCount);
        address[] memory signerAddrs = new address[](validatorCount);

        for (uint256 i = 0; i < validatorCount; i++) {
            shares[i] = new FuzzMockValidatorShare();
            signerAddrs[i] = address(uint160(0xA000 + i));

            stakeManager.setValidator(
                i + 1,
                signerAddrs[i],
                address(shares[i]),
                1_000_000 ether, // equal stakes for simplicity
                4_000_000 ether,
                5, // 5% commission
                IStakeManager.Status.Active
            );
        }

        pol.mint(address(distributor), fundAmount);
        distributor.distribute();

        uint256 totalDistributed;
        for (uint256 i = 0; i < validatorCount; i++) {
            totalDistributed += pol.balanceOf(signerAddrs[i]);
            totalDistributed += shares[i].totalRewardsAdded();
        }

        uint256 remaining = pol.balanceOf(address(distributor));

        // Everything must be accounted for.
        assertEq(
            totalDistributed + remaining,
            fundAmount,
            "Token leak: total != fund amount"
        );

        // Dust remaining should be minimal (rounding from integer division).
        // Max dust = validatorCount (1 wei per division per validator).
        assertLe(remaining, validatorCount, "Too much dust remaining");
    }

    // ─── Invariant: cooldown is enforced ───

    function testFuzz_CooldownEnforced(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 0, COOLDOWN - 1);

        FuzzMockValidatorShare vs = new FuzzMockValidatorShare();
        stakeManager.setValidator(
            1, address(0x5161), address(vs),
            1_000_000 ether, 4_000_000 ether,
            5, IStakeManager.Status.Active
        );

        pol.mint(address(distributor), 100_000 ether);
        distributor.distribute();

        // Fund again and try before cooldown expires.
        pol.mint(address(distributor), 100_000 ether);
        vm.warp(block.timestamp + timeDelta);

        vm.expectRevert();
        distributor.distribute();
    }

    // ─── Invariant: cooldown passes allow distribution ───

    function testFuzz_AfterCooldown_DistributionSucceeds(uint256 extraTime) public {
        extraTime = bound(extraTime, 0, 365 days);

        FuzzMockValidatorShare vs = new FuzzMockValidatorShare();
        stakeManager.setValidator(
            1, address(0x5161), address(vs),
            1_000_000 ether, 4_000_000 ether,
            5, IStakeManager.Status.Active
        );

        pol.mint(address(distributor), 100_000 ether);
        distributor.distribute();

        vm.warp(block.timestamp + COOLDOWN + extraTime);
        pol.mint(address(distributor), 100_000 ether);

        // Should always succeed after cooldown.
        distributor.distribute();
        assertTrue(vs.totalRewardsAdded() > 0);
    }

    // ─── Edge: very small fund amounts ───

    function testFuzz_TinyAmounts(uint256 fundAmount) public {
        fundAmount = bound(fundAmount, 1, 1000); // 1 to 1000 wei

        FuzzMockValidatorShare vs1 = new FuzzMockValidatorShare();
        FuzzMockValidatorShare vs2 = new FuzzMockValidatorShare();

        stakeManager.setValidator(
            1, address(0x5161), address(vs1),
            1_000_000 ether, 4_000_000 ether,
            5, IStakeManager.Status.Active
        );
        stakeManager.setValidator(
            2, address(0x5162), address(vs2),
            1_000_000 ether, 4_000_000 ether,
            5, IStakeManager.Status.Active
        );

        pol.mint(address(distributor), fundAmount);
        distributor.distribute();

        // No tokens should be created or destroyed.
        uint256 totalOut = pol.balanceOf(address(0x5161))
            + pol.balanceOf(address(0x5162))
            + vs1.totalRewardsAdded()
            + vs2.totalRewardsAdded()
            + pol.balanceOf(address(distributor));

        assertEq(totalOut, fundAmount, "Conservation violated with tiny amounts");
    }

    // ─── Edge: huge fund amounts near uint256 limits ───

    function testFuzz_LargeAmounts(uint256 fundAmount) public {
        // Up to 10 billion POL (realistic max supply).
        fundAmount = bound(fundAmount, 1 ether, 10_000_000_000 ether);

        FuzzMockValidatorShare vs = new FuzzMockValidatorShare();
        stakeManager.setValidator(
            1, address(0x5161), address(vs),
            100_000_000 ether, 900_000_000 ether,
            10, IStakeManager.Status.Active
        );

        pol.mint(address(distributor), fundAmount);
        distributor.distribute();

        uint256 commission = pol.balanceOf(address(0x5161));
        uint256 delegator = vs.totalRewardsAdded();

        assertEq(commission + delegator, fundAmount, "Large amount conservation violated");
        assertEq(commission, (fundAmount * 10) / 100, "Large amount commission wrong");
    }

    // ─── Edge: identical stakes should get equal rewards ───

    function testFuzz_EqualStakesEqualRewards(
        uint256 fundAmount,
        uint256 stake,
        uint8 commission
    ) public {
        fundAmount = bound(fundAmount, 100 ether, 1_000_000_000 ether);
        stake = bound(stake, 1 ether, 50_000_000 ether);
        commission = uint8(bound(commission, 0, 100));

        vm.prank(governance);
        distributor.setBaseRewardPerValidator(0);

        FuzzMockValidatorShare vs1 = new FuzzMockValidatorShare();
        FuzzMockValidatorShare vs2 = new FuzzMockValidatorShare();

        stakeManager.setValidator(
            1, address(0x5161), address(vs1),
            stake / 5, stake - stake / 5,
            commission, IStakeManager.Status.Active
        );
        stakeManager.setValidator(
            2, address(0x5162), address(vs2),
            stake / 5, stake - stake / 5,
            commission, IStakeManager.Status.Active
        );

        pol.mint(address(distributor), fundAmount);
        distributor.distribute();

        uint256 total1 = pol.balanceOf(address(0x5161)) + vs1.totalRewardsAdded();
        uint256 total2 = pol.balanceOf(address(0x5162)) + vs2.totalRewardsAdded();

        // With identical stakes and commission, rewards should differ by at most 1 wei.
        uint256 diff = total1 > total2 ? total1 - total2 : total2 - total1;
        assertLe(diff, 1, "Equal stakes got unequal rewards");
    }

    // ─── Governance parameter fuzzing ───

    function testFuzz_SetDistributionCooldown_BoundsEnforced(uint256 value) public {
        vm.prank(governance);
        if (value > 30 days) {
            vm.expectRevert(PriorityFeeDistributor.InvalidParameter.selector);
            distributor.setDistributionCooldown(value);
        } else {
            distributor.setDistributionCooldown(value);
            assertEq(distributor.distributionCooldown(), value);
        }
    }

    function testFuzz_SetMaxValidatorId_ZeroReverts(uint256 value) public {
        vm.prank(governance);
        if (value == 0) {
            vm.expectRevert(PriorityFeeDistributor.InvalidParameter.selector);
            distributor.setMaxValidatorId(value);
        } else {
            distributor.setMaxValidatorId(value);
            assertEq(distributor.maxValidatorId(), value);
        }
    }
}
