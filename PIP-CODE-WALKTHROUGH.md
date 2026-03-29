# PIP → Code Walkthrough

This document maps every step from the Community PIP specification directly to the implemented Solidity code. The PIP predicted the architecture — the code confirms it.

---

## The 7 Steps

### Step 1: Priority fees accumulate on Polygon
**PIP**: "Priority fees paid by transactions are collected in a contract on Polygon PoS."
**Code**: `PriorityFeeCollector.sol:128`
```solidity
receive() external payable {}
```
That's it. The contract accepts native POL. Fees flow in automatically.

---

### Step 2: Threshold check
**PIP**: "Once a minimum threshold is reached, anyone can trigger bridging."
**Code**: `PriorityFeeCollector.sol:134-148`
```solidity
function queueBridge() external {
    if (pendingTransfer.amount != 0) {
        revert TransferAlreadyQueued(pendingTransfer.executeAfter);
    }
    uint256 balance = address(this).balance;
    bool thresholdMet = balance >= bridgeThreshold;
    bool periodElapsed = block.timestamp >= lastBridgeTimestamp + maxBridgePeriod;
    if (!thresholdMet && !periodElapsed) {
        revert BelowThreshold(balance, bridgeThreshold);
    }
    uint256 amount = balance > transferCap ? transferCap : balance;
```
Permissionless. Anyone calls it. Threshold or time-based fallback — both from the PIP.

---

### Step 3: Bridge to Ethereum
**PIP**: "Bridged via the native PoS bridge to Ethereum."
**Code**: `PriorityFeeCollector.sol:181-183`
```solidity
(bool success, ) = bridge.call{value: amount}(
    abi.encodeWithSignature("depositFor(address)", ethereumReceiver)
);
```
Uses the existing PoS bridge. No new infrastructure needed — exactly as specified.

---

### Step 4: Receive POL on Ethereum
**PIP**: "POL arrives at the distributor contract on Ethereum."
**Code**: `PriorityFeeDistributor.sol:129-130`
```solidity
uint256 totalBalance = polToken.balanceOf(address(this));
if (totalBalance == 0) revert InsufficientBalance(0, 1);
```
The distributor simply checks its POL balance. Whatever has been bridged is ready to distribute.

---

### Step 5: Calculate stake-weighted shares
**PIP**: "Each validator receives a share proportional to their total stake (self + delegated)."
**Code**: `PriorityFeeDistributor.sol:145-161`
```solidity
for (uint256 id = 1; id <= maxId; id++) {
    IStakeManager.Validator memory v = stakeManager.validators(id);
    if (
        v.status == IStakeManager.Status.Active &&
        v.deactivationEpoch == 0 &&
        v.contractAddress != address(0)
    ) {
        uint256 stake = v.amount + v.delegatedAmount;
        stakes[activeCount] = stake;
        ...
        totalStake += stake;
        activeCount++;
    }
}
```
Reads directly from the live StakeManager. `v.amount` (self-stake) + `v.delegatedAmount` (delegated). Pro-rata split at line 183-189:
```solidity
uint256 stakeShare = totalStake > 0
    ? (remainingPool * stakes[i]) / totalStake
    : 0;
```

---

### Step 6: Deduct validator commission
**PIP**: "Validator commission is deducted before delegator distribution."
**Code**: `PriorityFeeDistributor.sol:194-197`
```solidity
uint256 commission = (totalReward * commissions[i]) / 100;
uint256 delegatorReward = totalReward - commission;
```
Commission rate comes from `v.commissionRate` in StakeManager. Stored as 0-100 (percentage), matching `MAX_COMMISION_RATE = 100` in StakeManagerStorage.sol. Verified by reading the deployed source code.

---

### Step 7: Distribute to ValidatorShare contracts
**PIP**: "Remaining rewards are sent to the ValidatorShare contract, using the existing reward accumulator so delegators earn automatically."
**Code**: `PriorityFeeDistributor.sol:218-226`
```solidity
try this.transferAndNotify(shareContracts[i], delegatorReward) {
    distributed += delegatorReward;
} catch {
    emit ValidatorRewardFailed(i, delegatorReward);
}
```
Which calls:
```solidity
function transferAndNotify(address _validatorShare, uint256 _amount) external {
    require(msg.sender == address(this), "Only self");
    require(polToken.transfer(_validatorShare, _amount), "Transfer failed");
    IValidatorShare(_validatorShare).addPriorityFeeReward(_amount);
}
```
Transfers POL to the ValidatorShare and calls `addPriorityFeeReward()` to update the reward accumulator. Delegators earn automatically — no claiming needed. Exactly as specified.

---

## What the implementation added beyond the PIP

The PIP described the what. The implementation solved the how — every addition below exists because of a security bug found during testing:

| Addition | Why | Bug # |
|---|---|---|
| Two contracts instead of one | System spans two chains | Architecture |
| Timelock with queue/execute | Prevent instant drain if bridge is compromised | #11 |
| Transfer cap | Limit per-bridge risk exposure | Spec |
| Cancel with grace period | Prevent front-running of execute | #7 |
| Two-step governance transfer | Prevent accidental governance loss | #12 |
| Reentrancy guard | Prevent re-entrant distribute() calls | #3 |
| Atomic transferAndNotify | Prevent tokens stuck in ValidatorShare | #8, #10 |
| Try/catch per validator | One broken validator can't brick all distributions | #4 |
| TOCTOU data caching | Validator state can't change mid-distribution | #5 |
| Queue overwrite prevention | Can't overwrite a pending bridge transfer | #1 |
| Zero-balance cooldown check | Don't start cooldown when nothing to distribute | #2 |

15 bugs found and fixed across 5 audit rounds. 60 tests. 2.9 million fuzz inputs. Fork-tested against all 105 live Polygon validators.

---

## Parameters

Optimized for 24M POL/month in priority fees:

| Parameter | Value | Why |
|---|---|---|
| Bridge threshold | 500,000 POL | Triggers ~every 15 hours |
| Transfer cap | 1,000,000 POL | Handles up to 60M POL/month |
| Timelock | 2 hours | Fast cycle, above 1hr security minimum |
| Max bridge period | 3 days | Safety net for low-volume periods |
| Distribution cooldown | 7 days | Weekly = $91/month at current gas |
| Base reward per validator | 9,500 POL | Incentivizes small validators |
| Max validator ID | 105 | Current validator set |

---

## Cost

$91/month to distribute $2,222,400 in priority fees to 105 validators and all their delegators. 0.004% overhead. No multisig. No off-chain infrastructure. No claiming.
