// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.23;

import "forge-std/Script.sol";
import {PriorityFeeCollector} from "../src/PriorityFeeCollector.sol";
import {PriorityFeeDistributor} from "../src/PriorityFeeDistributor.sol";

contract DeployCollector is Script {
    // Polygon PoS mainnet
    address constant GOVERNANCE = 0x37D085CA4A24F6b29214204E8A8F390E4b1f8867; // Protocol Council multisig
    address constant POS_BRIDGE = 0x2890bA17EfE978480615e330ecB65333b880928e; // PoS bridge on Polygon

    uint256 constant BRIDGE_THRESHOLD = 500_000 ether;
    uint256 constant MAX_BRIDGE_PERIOD = 3 days;
    uint256 constant TRANSFER_CAP = 1_000_000 ether;
    uint256 constant TIMELOCK_DURATION = 2 hours;

    function run() external returns (PriorityFeeCollector) {
        // ethereumReceiver is set after PriorityFeeDistributor is deployed on Ethereum.
        // Use a placeholder — governance must call setEthereumReceiver() after.
        address ethereumReceiver = vm.envAddress("ETHEREUM_RECEIVER");

        vm.startBroadcast();

        PriorityFeeCollector collector = new PriorityFeeCollector(
            GOVERNANCE,
            ethereumReceiver,
            POS_BRIDGE,
            BRIDGE_THRESHOLD,
            MAX_BRIDGE_PERIOD,
            TRANSFER_CAP,
            TIMELOCK_DURATION
        );

        vm.stopBroadcast();

        console.log("PriorityFeeCollector deployed at:", address(collector));
        console.log("  governance:", GOVERNANCE);
        console.log("  ethereumReceiver:", ethereumReceiver);
        console.log("  bridge:", POS_BRIDGE);

        return collector;
    }
}

contract DeployDistributor is Script {
    // Ethereum mainnet
    address constant GOVERNANCE = 0x37D085CA4A24F6b29214204E8A8F390E4b1f8867; // Protocol Council multisig
    address constant POL_TOKEN = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    address constant STAKE_MANAGER = 0x5e3Ef299fDDf15eAa0432E6e66473ace8c13D908;

    uint256 constant BASE_REWARD_PER_VALIDATOR = 9_500 ether;
    uint256 constant DISTRIBUTION_COOLDOWN = 7 days;
    uint256 constant MAX_VALIDATOR_ID = 105;

    function run() external returns (PriorityFeeDistributor) {
        vm.startBroadcast();

        PriorityFeeDistributor distributor = new PriorityFeeDistributor(
            GOVERNANCE,
            POL_TOKEN,
            STAKE_MANAGER,
            BASE_REWARD_PER_VALIDATOR,
            DISTRIBUTION_COOLDOWN,
            MAX_VALIDATOR_ID
        );

        vm.stopBroadcast();

        console.log("PriorityFeeDistributor deployed at:", address(distributor));
        console.log("  governance:", GOVERNANCE);
        console.log("  polToken:", POL_TOKEN);
        console.log("  stakeManager:", STAKE_MANAGER);

        return distributor;
    }
}
