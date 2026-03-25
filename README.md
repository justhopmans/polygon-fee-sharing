# Polygon Validator Priority Fee Sharing Tool

An open-source tool for Polygon PoS validators to share priority fees with their delegators.

## The Problem

Since the Rio hardfork (PIP-65), Polygon PoS priority fees are distributed exclusively to validators. Delegators provide 99.66% of staked capital and receive 0% of priority fees.

The multisig distributing these fees has no published schedule, no documented methodology, and no public payout periods. Validators who want to share fees with delegators cannot calculate a fair distribution — they are forced to estimate.

This tool solves the operational problem: given a payout, how do you fairly distribute a share to your delegators?

A PIP to fix this at protocol level is in review: [PIP: Priority Fee Sharing for Delegators](https://forum.polygon.technology/t/pip-priority-fee-sharing-for-delegators/21793)

Until then, this tool enables any validator to start sharing voluntarily.

## How It Works

### The System

1. **Daily snapshots** — The tool records every delegator’s stake daily via the Polygon Staking API
1. **Monthly cadence** — At the end of each calendar month, all priority fee payouts received that month are combined
1. **Infrastructure deduction** — A fixed amount (default: 10,000 POL, ~$929/month) is deducted for validator infrastructure costs
1. **Share percentage** — The validator chooses what percentage to distribute (can be tiered by pool size)
1. **Eligibility check** — Only delegators who staked the full month are eligible. The minimum staked amount between snapshots is used for calculation
1. **Proportional distribution** — Each eligible delegator receives: `(their_min_stake / total_eligible_stake) × amount_to_distribute`
1. **Payout** — Distribution via [disperse.app](https://disperse.app) in a single transaction

### Anti-Gaming Protection

- **Full month requirement** — Delegators must be present in both the start-of-month and end-of-month snapshots
- **Minimum stake used** — If a delegator decreases their stake mid-month, only the lower amount counts
- **Minimum threshold** — Configurable minimum stake to be eligible (default: 100 POL)
- **Daily snapshots** — Continuous monitoring prevents flash staking (stake day before snapshot, unstake day after)

### Tiered Sharing Model

Validators can configure tiered sharing that increases with pool size:

|Pool Size   |Share %|
|------------|-------|
|5-10M POL   |30%    |
|10-20M POL  |38%    |
|20-30M POL  |45%    |
|30-50M POL  |51%    |
|50-100M POL |55%    |
|100-150M POL|58%    |
|150M+ POL   |60%    |

The tier is determined by the pool size that was maintained for the entire month.

## Quick Start

### Requirements

- Python 3.8+
- `requests` library
- SQLite (included in Python)

### Installation

```bash
git clone https://github.com/[your-handle]/polygon-fee-sharing.git
cd polygon-fee-sharing
pip install requests
```

### Usage

```bash
# Take a daily snapshot for your validator
python fee_sharing.py snapshot --validator 118

# Compare two months and find eligible delegators
python fee_sharing.py compare --from 2026-04-01 --to 2026-05-01 --min-stake 100

# Calculate distribution
python fee_sharing.py distribute --amount 45000 --share-pct 30 --infra-cost 10000

# Export for disperse.app
python fee_sharing.py export --format disperse
```

### Automate Daily Snapshots

Set up a cron job to take snapshots automatically:

```bash
# Run daily at 00:05 UTC
5 0 * * * cd /path/to/polygon-fee-sharing && python fee_sharing.py snapshot --validator 118
```

## Data Sources

|Source             |Endpoint                                                          |Purpose                 |
|-------------------|------------------------------------------------------------------|------------------------|
|Polygon Staking API|`staking-api.polygon.technology/api/v2/validators/{id}/delegators`|Delegator snapshots     |
|PolygonScan        |Multisig TX history                                               |Payout verification     |
|Poltrack           |`poltrack.tech`                                                   |Fee analytics, burn data|

## Monthly Report

Alongside the tool, a monthly Priority Fee Sharing Report is published on the [Polygon Governance Forum](https://forum.polygon.technology). Each report includes:

- All priority fee payouts received by validators that month
- Which validators shared, how much, to how many delegators
- On-chain verification of delegator payouts
- Concentration metrics (top 5, top 20 share)

## Dashboard (Coming Soon)

A public dashboard showing:

- All 105 validators
- What each received in priority fees (monthly)
- What each shared with delegators
- Verified on-chain

Validators who share will be visible. Validators who don’t will show zeros.

## Validators Currently Sharing

|Validator               |ID  |Start Date    |First Payout|Status  |
|------------------------|----|--------------|------------|--------|
|Stakebaby (LEGEND Nodes)|#118|March 31, 2026|May 1, 2026 |✅ Active|
|PathrockNetwork         |#45 |March 31, 2026|May 1, 2026 |✅ Active|

### Want to Join?

Two options:

1. **Self-serve** — Use this tool. Run your own snapshots, calculations, and payouts independently.
1. **Managed service** — Contact [@LegendNodes](https://x.com/LegendNodes) who will handle snapshots, calculations, and distribution for your validator. Free of charge.

For questions or to join: [@HopmansJust](https://x.com/HopmansJust) on X or on the [Polygon Governance Forum](https://forum.polygon.technology).

## Background

### Why This Exists

- 105 validators receive 100% of priority fees
- 30,757+ delegators receive 0%
- Top 5 validators take 45% of every payout
- Top 20 take 89.8%
- 47 validators can’t cover infrastructure costs
- The multisig has no published schedule or methodology

### Related PIPs

- [PIP: Priority Fee Sharing for Delegators](https://forum.polygon.technology/t/pip-priority-fee-sharing-for-delegators/21793) — Protocol-level mandatory fee sharing (Status: Review)
- [Pre-PIP: Base Reward for Priority Fee Distribution](https://forum.polygon.technology/t/pre-pip-base-reward-for-priority-fee-distribution/21815) — Base reward ensuring all performing validators cover infrastructure costs (Status: Draft)

### Payout Reports

- [February 28, 2026 Payout Report](https://forum.polygon.technology/t/polygon-validator-priority-fee-payout-report-february-28/21812)
- [March 17, 2026 Payout Report](https://forum.polygon.technology/t/polygon-validator-priority-fee-payout-report-march-17/21xxx)

## How the Math Works

### Example

A validator with 10M POL pool receives 50,000 POL in priority fees for April.

```
Total received:     50,000 POL
Infrastructure:    -10,000 POL
Net:                40,000 POL
Share % (10-20M):       38%
To distribute:      15,200 POL

Delegator A (1M POL, 10% of pool):  1,520 POL
Delegator B (500K POL, 5% of pool):   760 POL
Delegator C (100 POL, 0.001%):        0.15 POL
...
```

### Why Monthly

The priority fee multisig distributes at irregular intervals (37 days, then 17 days between the first three payouts). By operating on a monthly cadence, this tool:

- Makes reporting consistent and comparable
- Aligns with how validators operate (monthly infrastructure costs)
- Removes dependency on multisig timing
- Combines multiple payouts if they occur within one month

## License

MIT License — use it, fork it, improve it.

## Authors

- Just Hopmans ([@HopmansJust](https://x.com/HopmansJust)) — Tool, dashboard, monthly reports
- LEGEND Nodes ([@LegendNodes](https://x.com/LegendNodes)) — Fee sharing system design, managed service, Stakebaby validator #118

## Acknowledgments

- PathrockNetwork ([@Pathrock2](https://x.com/Pathrock2)) — Early adopter, validator #45
- Poltrack ([poltrack.tech](https://poltrack.tech)) — Fee analytics and methodology
- Sandeep Nailwal — Public endorsement of the Priority Fee Sharing PIP
