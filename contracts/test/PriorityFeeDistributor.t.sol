// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PriorityFeeDistributor} from "../src/PriorityFeeDistributor.sol";
import {IStakeManager} from "../src/interfaces/IStakeManager.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @dev Mock ERC-20 token for testing.
contract MockPOL {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Mock ValidatorShare that tracks addPriorityFeeReward calls.
contract MockValidatorShare {
    uint256 public lastRewardAmount;
    uint256 public totalRewardsAdded;

    function addPriorityFeeReward(uint256 _amount) external {
        lastRewardAmount = _amount;
        totalRewardsAdded += _amount;
    }
}

/// @dev Mock StakeManager returning configurable validator data.
contract MockStakeManager {
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

contract PriorityFeeDistributorTest is Test {
    PriorityFeeDistributor distributor;
    MockPOL pol;
    MockStakeManager stakeManager;
    MockValidatorShare vs1;
    MockValidatorShare vs2;

    address governance = address(0x600);
    address signer1 = address(0x5161);
    address signer2 = address(0x5162);

    uint256 constant BASE_REWARD = 9_500 ether; // 9,500 POL
    uint256 constant COOLDOWN = 1 days;
    uint256 constant MAX_VAL_ID = 10;

    function setUp() public {
        // Warp to a realistic timestamp so cooldown checks pass.
        vm.warp(100_000);

        pol = new MockPOL();
        stakeManager = new MockStakeManager();
        vs1 = new MockValidatorShare();
        vs2 = new MockValidatorShare();

        distributor = new PriorityFeeDistributor(
            governance,
            address(pol),
            address(stakeManager),
            BASE_REWARD,
            COOLDOWN,
            MAX_VAL_ID
        );

        // Validator 1: 10M POL stake, 5% commission
        stakeManager.setValidator(
            1, signer1, address(vs1),
            2_000_000 ether, 8_000_000 ether,
            500, // 5%
            IStakeManager.Status.Active
        );

        // Validator 2: 5M POL stake, 10% commission
        stakeManager.setValidator(
            2, signer2, address(vs2),
            1_000_000 ether, 4_000_000 ether,
            1000, // 10%
            IStakeManager.Status.Active
        );
    }

    function test_Distribute_Basic() public {
        uint256 totalFund = 100_000 ether;
        pol.mint(address(distributor), totalFund);

        distributor.distribute();

        // Both validators should receive rewards.
        assertTrue(vs1.totalRewardsAdded() > 0);
        assertTrue(vs2.totalRewardsAdded() > 0);

        // Signers should receive commission.
        assertTrue(pol.balanceOf(signer1) > 0);
        assertTrue(pol.balanceOf(signer2) > 0);
    }

    function test_Distribute_StakeWeighted() public {
        uint256 totalFund = 100_000 ether;
        pol.mint(address(distributor), totalFund);

        distributor.distribute();

        // Validator 1 has 10M stake, validator 2 has 5M.
        // After base rewards, val1 should get ~2x the stake-weighted portion of val2.
        uint256 val1Total = pol.balanceOf(signer1) + vs1.totalRewardsAdded();
        uint256 val2Total = pol.balanceOf(signer2) + vs2.totalRewardsAdded();

        // val1 should get more than val2 (roughly 2:1 on the stake-weighted part).
        assertTrue(val1Total > val2Total);
    }

    function test_Distribute_CommissionCorrect() public {
        // Single validator scenario for precision.
        // Remove validator 2.
        stakeManager.setValidator(
            2, signer2, address(vs2),
            0, 0, 0, IStakeManager.Status.Inactive
        );

        uint256 totalFund = 50_000 ether;
        pol.mint(address(distributor), totalFund);

        distributor.distribute();

        uint256 commission = pol.balanceOf(signer1);
        uint256 delegatorReward = vs1.totalRewardsAdded();
        uint256 total = commission + delegatorReward;

        // 5% commission.
        assertEq(commission, (total * 500) / 10_000);
    }

    function test_Distribute_RevertsCooldown() public {
        pol.mint(address(distributor), 100_000 ether);
        distributor.distribute();

        pol.mint(address(distributor), 100_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriorityFeeDistributor.DistributionTooFrequent.selector,
                block.timestamp + COOLDOWN,
                block.timestamp
            )
        );
        distributor.distribute();
    }

    function test_Distribute_AfterCooldown() public {
        pol.mint(address(distributor), 100_000 ether);
        distributor.distribute();

        vm.warp(block.timestamp + COOLDOWN + 1);
        pol.mint(address(distributor), 50_000 ether);
        distributor.distribute(); // Should succeed.
    }

    function test_Distribute_NoActiveValidators() public {
        // Deactivate both.
        stakeManager.setValidator(
            1, signer1, address(vs1), 0, 0, 0, IStakeManager.Status.Inactive
        );
        stakeManager.setValidator(
            2, signer2, address(vs2), 0, 0, 0, IStakeManager.Status.Inactive
        );

        pol.mint(address(distributor), 100_000 ether);

        vm.expectRevert(PriorityFeeDistributor.NoActiveValidators.selector);
        distributor.distribute();
    }

    function test_Distribute_RevertsOnZeroBalance() public {
        // No POL in the distributor — should revert, not start cooldown.
        vm.expectRevert(
            abi.encodeWithSelector(
                PriorityFeeDistributor.InsufficientBalance.selector, 0, 1
            )
        );
        distributor.distribute();

        // Cooldown should NOT have started.
        assertEq(distributor.lastDistribution(), 0);
    }

    function test_OnlyGovernance_SetBaseReward() public {
        vm.expectRevert(PriorityFeeDistributor.OnlyGovernance.selector);
        distributor.setBaseRewardPerValidator(10_000 ether);

        vm.prank(governance);
        distributor.setBaseRewardPerValidator(10_000 ether);
        assertEq(distributor.baseRewardPerValidator(), 10_000 ether);
    }

    function test_RecoverTokens() public {
        MockPOL other = new MockPOL();
        other.mint(address(distributor), 1000 ether);

        address dest = address(0xDEAD);

        vm.prank(governance);
        distributor.recoverTokens(address(other), dest, 1000 ether);

        assertEq(other.balanceOf(dest), 1000 ether);
    }

    function test_Distribute_InsufficientForBaseRewards_FallsBackToProRata() public {
        // Fund less than BASE_REWARD * 2 validators = 19,000 POL.
        uint256 smallFund = 1_000 ether;
        pol.mint(address(distributor), smallFund);

        distributor.distribute();

        // Should still distribute — falls back to pure pro-rata.
        uint256 val1Total = pol.balanceOf(signer1) + vs1.totalRewardsAdded();
        uint256 val2Total = pol.balanceOf(signer2) + vs2.totalRewardsAdded();

        // All funds should be distributed.
        assertApproxEqAbs(val1Total + val2Total, smallFund, 1);
    }

    function test_Distribute_ResilientToRevertingValidator() public {
        // Add a third validator whose signer is a contract that reverts on receive.
        // Use address(distributor) as the signer — it has no fallback for POL tokens.
        MockValidatorShare vs3 = new MockValidatorShare();
        RevertingReceiver badSigner = new RevertingReceiver();
        stakeManager.setValidator(
            3, address(badSigner), address(vs3),
            1_000_000 ether, 4_000_000 ether,
            500,
            IStakeManager.Status.Active
        );

        pol.mint(address(distributor), 100_000 ether);

        // Should succeed despite the bad signer — skips that transfer.
        distributor.distribute();

        // Good validators still got their rewards.
        assertTrue(vs1.totalRewardsAdded() > 0);
        assertTrue(vs2.totalRewardsAdded() > 0);
    }
}

/// @dev Helper contract that always reverts on token receipt.
contract RevertingReceiver {
    fallback() external payable {
        revert("no");
    }
}
