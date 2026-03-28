# PIP Parameter Update — Priority Fee Sharing

## Summary

After building and testing the full implementation, the following parameters need to be adjusted from the original PIP to handle real-world throughput. The original PIP assumed a single-transfer model. The implementation revealed a bottleneck: with 24M POL/month in priority fees (800k POL/day), the original 100k transfer cap + 1-day timelock could only bridge 100k/day — 8x slower than inflow.

---

## Updated Parameters

### PriorityFeeCollector (Polygon)

| Parameter | PIP Value | Updated Value | Rationale |
|---|---|---|---|
| Bridge threshold | 100,000 POL | 500,000 POL | Triggers ~every 15 hours at 24M/month. Reduces bridge frequency from ~8/day to ~1-2/day while keeping funds moving. |
| Transfer cap | 100,000 POL | 1,000,000 POL | Original cap created a bottleneck. At 100k/bridge with a single pending transfer, throughput maxed at 100k per timelock cycle. 1M cap handles up to 60M POL/month. |
| Timelock duration | 1 day | 2 hours | Original 1-day timelock meant only 1 bridge per day. At 2 hours, the system can cycle up to 12 bridges/day if needed. Still above the 1-hour security minimum that prevents reentrant drain attacks. |
| Max bridge period | 7 days | 3 days | Safety net for low-volume periods. If threshold isn't reached in 3 days, bridge whatever has accumulated. Prevents funds sitting idle. |

### PriorityFeeDistributor (Ethereum)

| Parameter | PIP Value | Updated Value | Rationale |
|---|---|---|---|
| Distribution cooldown | 1 day | 7 days | Weekly distribution is the optimal gas/cost tradeoff. At current gas prices (~0.1-5 gwei), weekly costs $91/month to distribute $2.2M. Daily would cost 7x more with no meaningful benefit to delegators. |
| Max validator ID | 10 (test) | 105 | Matches the current Polygon validator set. Must be updated via governance if new validators are added. |

---

## Why These Parameters Work

### Throughput math

The collector can only have one pending transfer at a time (prevents queue-overwrite attacks). This means throughput = transfer cap / timelock cycle time.

```
Old:  100,000 POL / 24 hours = 100,000 POL/day  (but 800,000 arrives/day)
New:  1,000,000 POL / 2 hours = 12,000,000 POL/day capacity
```

The new parameters have 15x headroom above the 800k/day inflow rate.

### Volume range

These parameters work without governance changes across a wide range:

| Monthly Volume | Daily Inflow | Time to Threshold | Bridges/Day | Status |
|---|---|---|---|---|
| 3M POL | 100k | 5 days (max period triggers) | 0.3 | Works |
| 6M POL | 200k | 2.5 days | 0.4 | Works |
| 12M POL | 400k | 30 hours | 0.8 | Works |
| 24M POL | 800k | 15 hours | 1.6 | Optimal |
| 48M POL | 1.6M | 7.5 hours | 3.2 | Works |
| 60M POL | 2M | 6 hours | 4 | Works |

Below 3M: the 3-day max bridge period forces a bridge regardless of threshold.
Above 60M: governance raises the transfer cap. This is a rare event.

### Gas cost at 24M POL/month

Distribution gas: ~6,000,000 (fork-tested with 105 validators)

| Strategy | Txs/Month | Monthly Cost | % of Fees |
|---|---|---|---|
| Weekly, smart timing (1-3 gwei) | 4 | $91 | 0.004% |
| Weekly, normal gas (15 gwei) | 4 | $728 | 0.033% |
| Weekly, mixed (realistic) | 4 | $825 | 0.037% |
| Daily, normal gas | 30 | $5,458 | 0.246% |

Break-even: gas would need to sustain 458 gwei (never happened) before costs reach 1% of fees.

### Why not auto-adjust parameters?

On-chain adaptive parameters add attack surface. If the contract auto-adjusts the transfer cap based on volume, an attacker can manipulate volume to raise the cap. Every self-tuning mechanism is a new exploit vector.

The chosen parameters handle a 20x volume range (3M-60M). If volume moves outside that range, governance adjusts once. Simple systems are secure systems.

---

## Security considerations for these values

- **2-hour timelock** is above the 1-hour minimum. The minimum exists to prevent an attacker from queuing and executing in the same block via bridge callback reentrancy.
- **1M transfer cap** limits maximum loss per bridge to 1M POL (~$92,600) if the bridge contract is compromised.
- **3-day max bridge period** ensures funds don't accumulate indefinitely on Polygon, reducing the honeypot.
- **7-day distribution cooldown** means at most ~6M POL sits in the distributor between cycles. This is the maximum at-risk amount on Ethereum.

---

## Changes to PIP text

1. Replace "100,000 POL threshold" with "500,000 POL threshold"
2. Replace "100,000 POL transfer cap" with "1,000,000 POL transfer cap"
3. Replace "24-hour timelock" with "2-hour timelock"
4. Add: "Distribution occurs weekly (7-day cooldown) for optimal gas efficiency"
5. Add: "Parameters handle 3M-60M POL/month without governance intervention"
6. Add cost analysis: "$91/month at current gas to distribute $2.2M in priority fees"
7. Note: the system uses two contracts (one per chain), not one as described in the original pseudocode
