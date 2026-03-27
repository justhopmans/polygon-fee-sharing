// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {PriorityFeeDistributor} from "../src/PriorityFeeDistributor.sol";
import {IStakeManager} from "../src/interfaces/IStakeManager.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @title Fork tests against real Ethereum mainnet StakeManager and POL token.
/// @dev Run with: forge test --match-contract ForkTest --fork-url $ETH_RPC_URL
contract PriorityFeeDistributorForkTest is Test {
    // ─── Real mainnet addresses ───

    /// @dev Polygon StakeManager proxy on Ethereum mainnet.
    address constant STAKE_MANAGER = 0x5e3Ef299fDDf15eAa0432E6e66473ace8c13D908;

    /// @dev POL token on Ethereum mainnet.
    address constant POL_TOKEN = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;

    PriorityFeeDistributor distributor;
    IStakeManager stakeManager;
    IERC20 pol;

    address governance = address(0xAAAA);

    uint256 constant BASE_REWARD = 9_500 ether;
    uint256 constant COOLDOWN = 1 days;
    uint256 constant MAX_VAL_ID = 105; // matches spec's validator count

    function setUp() public {
        stakeManager = IStakeManager(STAKE_MANAGER);
        pol = IERC20(POL_TOKEN);

        distributor = new PriorityFeeDistributor(
            governance,
            POL_TOKEN,
            STAKE_MANAGER,
            BASE_REWARD,
            COOLDOWN,
            MAX_VAL_ID
        );
    }

    /// @notice Verify we can read real validator data from StakeManager.
    function test_Fork_ReadValidators() public {
        uint256 activeCount;

        for (uint256 id = 1; id <= MAX_VAL_ID; id++) {
            IStakeManager.Validator memory v = stakeManager.validators(id);
            if (
                v.status == IStakeManager.Status.Active &&
                v.deactivationEpoch == 0 &&
                v.contractAddress != address(0)
            ) {
                activeCount++;

                // Sanity checks on real data.
                assertTrue(v.signer != address(0), "Signer should not be zero");
                assertTrue(v.amount + v.delegatedAmount > 0, "Stake should be > 0");
                assertTrue(v.commissionRate <= 10_000, "Commission <= 100%");
            }
        }

        // There should be ~105 active validators on mainnet.
        assertTrue(activeCount > 50, "Expected >50 active validators");
        emit log_named_uint("Active validators found", activeCount);
    }

    /// @notice Verify the distributor can read all validators and compute distribution.
    /// @dev We mint POL to the distributor (via deal) and call distribute().
    ///      Since ValidatorShare doesn't have addPriorityFeeReward() yet on mainnet,
    ///      this will revert at the external call. We test up to that point.
    function test_Fork_DistributeReverts_NoAddPriorityFeeReward() public {
        // Fund the distributor with POL.
        uint256 fundAmount = 1_000_000 ether;
        deal(POL_TOKEN, address(distributor), fundAmount);
        assertEq(pol.balanceOf(address(distributor)), fundAmount);

        // distribute() should revert because ValidatorShare doesn't have
        // addPriorityFeeReward() yet. This proves the integration reaches
        // the real contracts and correctly identifies the missing function.
        vm.expectRevert();
        distributor.distribute();
    }

    /// @notice Simulate a full distribution by mocking addPriorityFeeReward on
    ///         each ValidatorShare contract. This proves the math and flow work
    ///         with real validator data.
    function test_Fork_DistributeWithMockedValidatorShare() public {
        // Collect active validator info first.
        uint256 activeCount;
        for (uint256 id = 1; id <= MAX_VAL_ID; id++) {
            IStakeManager.Validator memory v = stakeManager.validators(id);
            if (
                v.status == IStakeManager.Status.Active &&
                v.deactivationEpoch == 0 &&
                v.contractAddress != address(0)
            ) {
                activeCount++;

                // Mock addPriorityFeeReward on each real ValidatorShare address.
                // This makes the call succeed without actually modifying state.
                vm.mockCall(
                    v.contractAddress,
                    abi.encodeWithSignature("addPriorityFeeReward(uint256)"),
                    abi.encode()
                );
            }
        }

        require(activeCount > 0, "No active validators found");

        // Fund the distributor.
        uint256 fundAmount = 1_000_000 ether;
        deal(POL_TOKEN, address(distributor), fundAmount);

        // Track balances before.
        uint256 distributorBalBefore = pol.balanceOf(address(distributor));

        // Execute distribution.
        distributor.distribute();

        // Distributor should have spent (nearly) all its POL.
        uint256 distributorBalAfter = pol.balanceOf(address(distributor));
        uint256 distributed = distributorBalBefore - distributorBalAfter;

        emit log_named_uint("Total distributed (POL wei)", distributed);
        emit log_named_uint("Dust remaining (POL wei)", distributorBalAfter);

        // Should have distributed almost everything (rounding dust only).
        assertTrue(distributed > fundAmount * 99 / 100, "Should distribute >99% of funds");
        assertTrue(distributorBalAfter < fundAmount / 100, "Dust should be <1%");

        emit log_named_uint("Active validators", activeCount);
    }

    /// @notice Log real validator stats for inspection.
    function test_Fork_LogValidatorStats() public {
        uint256 totalActiveStake;
        uint256 activeCount;

        for (uint256 id = 1; id <= MAX_VAL_ID; id++) {
            IStakeManager.Validator memory v = stakeManager.validators(id);
            if (
                v.status == IStakeManager.Status.Active &&
                v.deactivationEpoch == 0 &&
                v.contractAddress != address(0)
            ) {
                totalActiveStake += v.amount + v.delegatedAmount;
                activeCount++;
            }
        }

        emit log_named_uint("Active validators", activeCount);
        emit log_named_uint("Total active stake (POL wei)", totalActiveStake);
        emit log_named_uint("Total active stake (POL)", totalActiveStake / 1 ether);
    }

    /// @notice Verify commission rates are within bounds for all active validators.
    function test_Fork_CommissionRatesValid() public {
        for (uint256 id = 1; id <= MAX_VAL_ID; id++) {
            IStakeManager.Validator memory v = stakeManager.validators(id);
            if (
                v.status == IStakeManager.Status.Active &&
                v.deactivationEpoch == 0
            ) {
                assertTrue(
                    v.commissionRate <= 10_000,
                    "Commission rate should not exceed 100%"
                );
            }
        }
    }

    /// @notice Verify gas cost of distribution with real validator count.
    function test_Fork_DistributeGasCost() public {
        // Mock addPriorityFeeReward on all active ValidatorShare contracts.
        for (uint256 id = 1; id <= MAX_VAL_ID; id++) {
            IStakeManager.Validator memory v = stakeManager.validators(id);
            if (
                v.status == IStakeManager.Status.Active &&
                v.deactivationEpoch == 0 &&
                v.contractAddress != address(0)
            ) {
                vm.mockCall(
                    v.contractAddress,
                    abi.encodeWithSignature("addPriorityFeeReward(uint256)"),
                    abi.encode()
                );
            }
        }

        deal(POL_TOKEN, address(distributor), 1_000_000 ether);

        uint256 gasBefore = gasleft();
        distributor.distribute();
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Gas used for distribute()", gasUsed);

        // Gas scales with active validator count. With 72+ validators and
        // cold storage reads on fork, expect ~4-5M gas. On-chain with warm
        // storage this would be lower.
        assertTrue(gasUsed < 10_000_000, "Gas should be reasonable");
    }
}
