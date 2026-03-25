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
- **Minimum threshold** — Configurable minimum stake to be eligible (default: 500 POL)
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

## Getting Started

The entire setup takes about 10 minutes. You need Python installed — that's it.

### Step 1: Install Python

**Mac** — Open Terminal and run:
```bash
brew install python3
```
If you don't have Homebrew: visit [brew.sh](https://brew.sh) and follow the one-line install, then run the command above.

**Windows** — Download Python from [python.org/downloads](https://www.python.org/downloads/). Run the installer and **check "Add Python to PATH"** before clicking Install.

**Linux** — Python is usually preinstalled. Verify with:
```bash
python3 --version
```

### Step 2: Download the tool

Open a terminal (Mac/Linux) or Command Prompt (Windows) and run:

```bash
git clone https://github.com/justhopmans/polygon-fee-sharing.git
cd polygon-fee-sharing
pip install -r requirements.txt
```

### Step 3: Configure for your validator

```bash
cp config.example.json config.json
```

Open `config.json` in any text editor and change these fields:

```json
{
  "validator_id": 118,        ← your validator ID (find it on staking.polygon.technology)
  "validator_name": "Stakebaby",  ← your validator name
  "infra_cost_pol": 10000,    ← monthly infrastructure cost to deduct
  "min_stake_pol": 500,       ← minimum delegation to be eligible
  "flat_share_pct": null      ← set a number (e.g. 30) for flat %, or leave null for tiers
}
```

If you use `flat_share_pct`, the `sharing_tiers` are ignored. If you leave it `null`, configure the tiers to match your sharing policy.

### Step 4: Take your first snapshot

```bash
python fee_sharing.py snapshot --validator 118
```

You should see something like:
```
Fetching delegators for validator #118...
Snapshot taken: 247 active delegators, 8,241,092.48 POL total
```

This pulls all your current delegators from the Polygon Staking API and stores them locally. Run this every day — the more snapshots you have, the more accurate your distributions.

### Step 5: Automate daily snapshots

You don't want to run this manually every day. Set up a scheduled task:

**Mac / Linux** — Open your crontab:
```bash
crontab -e
```
Add this line (change the path and validator ID):
```
5 0 * * * cd /path/to/polygon-fee-sharing && python3 fee_sharing.py snapshot --validator 118
```
This runs every day at 00:05 UTC.

**Windows** — Open Task Scheduler, create a new task:
- Trigger: Daily at 00:05
- Action: Start a program
- Program: `python`
- Arguments: `fee_sharing.py snapshot --validator 118`
- Start in: `C:\path\to\polygon-fee-sharing`

### Step 6: Monthly distribution (5 minutes)

At the end of each month, when you know how much POL you received in priority fees:

```bash
# 1. Compare start and end of month — see who's eligible
python fee_sharing.py compare --from 2026-04-01 --to 2026-05-01

# 2. Calculate distribution — enter the POL you received
python fee_sharing.py distribute --config config.json --received 45000 --from 2026-04-01 --to 2026-05-01

# 3. Export for disperse.app
python fee_sharing.py export --config config.json --from 2026-04-01 --to 2026-05-01
```

This creates a file in the `output/` folder called `disperse_YYYY-MM-DD.txt`.

### Step 7: Send the payouts

1. Open [disperse.app](https://disperse.app)
2. Connect your validator wallet
3. Select POL as the token
4. Paste the contents of `disperse_YYYY-MM-DD.txt`
5. Confirm and send the transaction

Done. Your delegators have been paid.

### Check status anytime

```bash
python fee_sharing.py status --validator 118
```

### All commands

| Command | What it does |
|---------|-------------|
| `snapshot --validator ID` | Take a daily snapshot of all delegators |
| `compare --from DATE --to DATE` | Compare two snapshots, show eligible delegators |
| `distribute --config FILE --received AMOUNT --from DATE --to DATE` | Calculate the distribution |
| `export --config FILE --from DATE --to DATE` | Export disperse.app file |
| `status --validator ID` | Show snapshot and distribution history |

## Data Sources

|Source             |Endpoint                                                          |Purpose                 |
|-------------------|------------------------------------------------------------------|------------------------|
|Polygon Staking API|`staking-api.polygon.technology/api/v2/validators/{id}/delegators`|Delegator snapshots     |
|PolygonScan        |Multisig TX history                                               |Fee analytics, burn data|

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
Delegator C (5K POL, 0.05% of pool):    7.60 POL
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
- Sandeep Nailwal — Public endorsement of the Priority Fee Sharing PIP
