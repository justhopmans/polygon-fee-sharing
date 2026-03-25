#!/usr/bin/env python3
"""Polygon Validator Priority Fee Sharing Tool.

Enables any Polygon PoS validator to share priority fees with their delegators.
Takes daily snapshots, compares monthly, calculates fair distribution,
and exports a file ready for disperse.app.
"""

import argparse
import calendar
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone, timedelta
from decimal import Decimal, ROUND_HALF_UP

import requests

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_DIR = os.path.join(BASE_DIR, "db")
OUTPUT_DIR = os.path.join(BASE_DIR, "output")
DB_PATH = os.path.join(DB_DIR, "snapshots.db")

STAKING_API_URL = (
    "https://staking-api.polygon.technology/api/v2/validators/{validator_id}"
    "/delegators?limit=500&offset={offset}"
)
VALIDATOR_API_URL = (
    "https://staking-api.polygon.technology/api/v2/validators/{validator_id}"
)
POLYGONSCAN_API_URL = "https://api.polygonscan.com/api"
MULTISIG_ADDRESS = "0x7Ee41D8A25641000661B1EF5E6AE8A00400466B0"

WEI_PER_POL = Decimal("1000000000000000000")


def ensure_dirs():
    """Create db/ and output/ directories if they don't exist."""
    os.makedirs(DB_DIR, exist_ok=True)
    os.makedirs(OUTPUT_DIR, exist_ok=True)


def get_db():
    """Get a SQLite database connection, creating tables if needed."""
    ensure_dirs()
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            validator_id INTEGER NOT NULL,
            delegator_address TEXT NOT NULL,
            stake_pol REAL NOT NULL,
            timestamp TEXT NOT NULL,
            snapshot_date TEXT NOT NULL,
            UNIQUE(validator_id, delegator_address, snapshot_date)
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS distributions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            validator_id INTEGER NOT NULL,
            period_from TEXT NOT NULL,
            period_to TEXT NOT NULL,
            total_received REAL NOT NULL,
            infra_cost REAL NOT NULL,
            share_pct REAL NOT NULL,
            total_distributed REAL NOT NULL,
            eligible_delegators INTEGER NOT NULL,
            timestamp TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS distribution_details (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            distribution_id INTEGER NOT NULL,
            delegator_address TEXT NOT NULL,
            stake_from REAL NOT NULL,
            stake_to REAL NOT NULL,
            min_stake REAL NOT NULL,
            payout REAL NOT NULL,
            FOREIGN KEY (distribution_id) REFERENCES distributions(id)
        )
    """)
    conn.commit()
    return conn


def fetch_delegators(validator_id):
    """Fetch all active delegators from the Polygon Staking API with pagination and retries."""
    all_delegators = []
    offset = 0

    while True:
        url = STAKING_API_URL.format(validator_id=validator_id, offset=offset)
        data = None

        for attempt in range(3):
            try:
                resp = requests.get(url, timeout=30)
                resp.raise_for_status()
                data = resp.json()
                break
            except (requests.RequestException, ValueError) as e:
                if attempt < 2:
                    print(f"  API request failed (attempt {attempt + 1}/3): {e}")
                    time.sleep(5)
                else:
                    print(f"  API request failed after 3 attempts: {e}")
                    raise SystemExit(1)

        results = data.get("result", [])
        if not results:
            break

        for d in results:
            # Only include active delegators with stake > 0
            if d.get("deactivationEpoch") == "0" and d.get("stake", "0") != "0":
                stake_wei = Decimal(d["stake"])
                stake_pol = float(stake_wei / WEI_PER_POL)
                if stake_pol > 0:
                    all_delegators.append({
                        "address": d["address"].lower(),
                        "stake_pol": stake_pol,
                    })

        if len(results) < 500:
            break
        offset += 500

    return all_delegators


def fetch_validator_signer(validator_id):
    """Fetch the signer address for a validator from the Polygon Staking API."""
    url = VALIDATOR_API_URL.format(validator_id=validator_id)
    for attempt in range(3):
        try:
            resp = requests.get(url, timeout=30)
            resp.raise_for_status()
            data = resp.json()
            result = data.get("result", {})
            signer = result.get("signerAddress") or result.get("signer")
            if signer:
                return signer.lower()
            print(f"Error: Could not find signer address for validator #{validator_id}")
            raise SystemExit(1)
        except (requests.RequestException, ValueError) as e:
            if attempt < 2:
                time.sleep(5)
            else:
                print(f"Error: Failed to fetch validator info: {e}")
                raise SystemExit(1)


def fetch_payouts_from_multisig(signer_address, date_from, date_to, api_key=None):
    """Fetch POL payouts from the multisig to a validator's signer address.

    Checks both normal and internal transactions on PolygonScan.
    Returns total POL received in the date range.
    """
    from_ts = int(datetime.strptime(date_from, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp())
    to_ts = int((datetime.strptime(date_to, "%Y-%m-%d").replace(tzinfo=timezone.utc) +
                 timedelta(days=1)).timestamp()) - 1

    total = Decimal("0")
    multisig_lower = MULTISIG_ADDRESS.lower()
    tx_hashes = set()

    # Check both normal transactions and internal transactions
    for action in ["txlist", "txlistinternal"]:
        params = {
            "module": "account",
            "action": action,
            "address": signer_address,
            "startblock": 0,
            "endblock": 99999999,
            "sort": "asc",
        }
        if api_key:
            params["apikey"] = api_key

        for attempt in range(3):
            try:
                resp = requests.get(POLYGONSCAN_API_URL, params=params, timeout=30)
                resp.raise_for_status()
                data = resp.json()
                break
            except (requests.RequestException, ValueError) as e:
                if attempt < 2:
                    time.sleep(5)
                else:
                    print(f"  Warning: Failed to fetch {action} from PolygonScan: {e}")
                    data = {"result": []}

        results = data.get("result", [])
        if not isinstance(results, list):
            continue

        for tx in results:
            ts = int(tx.get("timeStamp", 0))
            if ts < from_ts or ts > to_ts:
                continue
            if tx.get("from", "").lower() != multisig_lower:
                continue
            if tx.get("to", "").lower() != signer_address.lower():
                continue
            if tx.get("isError", "0") == "1":
                continue

            # Avoid counting the same tx twice (normal + internal)
            tx_hash = tx.get("hash", "")
            if tx_hash in tx_hashes:
                continue
            tx_hashes.add(tx_hash)

            value_wei = Decimal(tx.get("value", "0"))
            if value_wei > 0:
                value_pol = value_wei / WEI_PER_POL
                total += value_pol

    return float(total), len(tx_hashes)


def cmd_snapshot(args):
    """Take a snapshot of all delegators for a validator."""
    validator_id = args.validator
    print(f"Fetching delegators for validator #{validator_id}...")

    delegators = fetch_delegators(validator_id)
    if not delegators:
        print("No active delegators found.")
        return

    now = datetime.now(timezone.utc)
    timestamp = now.isoformat()
    snapshot_date = now.strftime("%Y-%m-%d")

    conn = get_db()
    try:
        # Delete existing snapshot for this validator/date to avoid stale delegators
        conn.execute(
            "DELETE FROM snapshots WHERE validator_id = ? AND snapshot_date = ?",
            (validator_id, snapshot_date),
        )
        for d in delegators:
            conn.execute(
                """INSERT INTO snapshots (validator_id, delegator_address, stake_pol, timestamp, snapshot_date)
                   VALUES (?, ?, ?, ?, ?)""",
                (validator_id, d["address"], d["stake_pol"], timestamp, snapshot_date),
            )
        conn.commit()
    except sqlite3.OperationalError as e:
        print(f"Database error: {e}")
        raise SystemExit(1)
    finally:
        conn.close()

    total_stake = sum(d["stake_pol"] for d in delegators)
    print(f"Snapshot taken: {len(delegators)} active delegators, {total_stake:,.2f} POL total")


def _get_closest_snapshot(conn, validator_id, target_date, warn_days=3):
    """Find the snapshot date closest to the target date for a validator.

    Prints a warning if the closest snapshot is more than warn_days away.
    """
    row = conn.execute(
        """SELECT snapshot_date, ABS(JULIANDAY(snapshot_date) - JULIANDAY(?)) as diff_days
           FROM snapshots
           WHERE validator_id = ?
           GROUP BY snapshot_date
           ORDER BY diff_days
           LIMIT 1""",
        (target_date, validator_id),
    ).fetchone()
    if not row:
        return None
    snapshot_date, diff_days = row[0], row[1]
    if diff_days > warn_days:
        print(f"  Warning: Closest snapshot to {target_date} is {snapshot_date} ({int(diff_days)} days away)")
    elif snapshot_date != target_date:
        print(f"  Note: Using snapshot from {snapshot_date} (closest to {target_date})")
    return snapshot_date


def _get_snapshot_data(conn, validator_id, snapshot_date):
    """Get all delegators from a specific snapshot date."""
    rows = conn.execute(
        """SELECT delegator_address, stake_pol FROM snapshots
           WHERE validator_id = ? AND snapshot_date = ?""",
        (validator_id, snapshot_date),
    ).fetchall()
    return {row[0]: row[1] for row in rows}


def _resolve_config_path(config_path):
    """Resolve config path: if relative, check cwd first, then BASE_DIR."""
    if os.path.isabs(config_path):
        return config_path
    # Check relative to cwd first
    if os.path.exists(config_path):
        return os.path.abspath(config_path)
    # Fall back to relative to script directory
    base_path = os.path.join(BASE_DIR, config_path)
    if os.path.exists(base_path):
        return base_path
    return config_path  # Return as-is, will fail with clear error


def _load_config(config_path):
    """Load and validate configuration file."""
    resolved = _resolve_config_path(config_path)
    if not os.path.exists(resolved):
        print(f"Error: Config file not found: {config_path}")
        print(f"  Searched: {os.path.abspath(config_path)}")
        print(f"  Searched: {os.path.join(BASE_DIR, config_path)}")
        print(f"  Copy config.example.json to config.json and edit it.")
        raise SystemExit(1)
    with open(resolved) as f:
        return json.load(f)


def _get_share_pct(config, pool_size):
    """Determine the sharing percentage based on config and pool size."""
    if config.get("flat_share_pct") is not None:
        return config["flat_share_pct"]

    tiers = config.get("sharing_tiers", [])
    for tier in tiers:
        min_pool = tier["min_pool"]
        max_pool = tier["max_pool"]
        if pool_size >= min_pool and (max_pool is None or pool_size < max_pool):
            return tier["share_pct"]

    # If no tier matches, return 0
    return 0


def _get_snapshot_dates_in_range(conn, validator_id, date_from, date_to):
    """Get all snapshot dates for a validator between two dates (inclusive)."""
    rows = conn.execute(
        """SELECT DISTINCT snapshot_date FROM snapshots
           WHERE validator_id = ? AND snapshot_date >= ? AND snapshot_date <= ?
           ORDER BY snapshot_date""",
        (validator_id, date_from, date_to),
    ).fetchall()
    return [row[0] for row in rows]


def _calculate_eligible(conn, validator_id, date_from, date_to, min_stake):
    """Calculate eligible delegators across all snapshots in a date range.

    A delegator must be present in EVERY snapshot between date_from and date_to.
    Their payout stake is the MINIMUM across all snapshots (anti-gaming).
    """
    snap_from = _get_closest_snapshot(conn, validator_id, date_from)
    snap_to = _get_closest_snapshot(conn, validator_id, date_to)

    if not snap_from or not snap_to:
        return None, None, None, "Not enough snapshots found. Take snapshots first."

    if snap_from == snap_to:
        return None, None, None, f"Both dates resolve to the same snapshot ({snap_from}). Need two different snapshots."

    # Get all snapshot dates in the range
    all_dates = _get_snapshot_dates_in_range(conn, validator_id, snap_from, snap_to)
    if len(all_dates) < 2:
        return None, None, None, "Need at least 2 snapshots in the date range."

    # Load all snapshots
    all_snapshots = {}
    for date in all_dates:
        all_snapshots[date] = _get_snapshot_data(conn, validator_id, date)

    # Find delegators present in ALL snapshots
    addresses_per_snapshot = [set(snap.keys()) for snap in all_snapshots.values()]
    present_in_all = set.intersection(*addresses_per_snapshot)

    # Get all unique addresses across all snapshots
    all_addresses = set.union(*addresses_per_snapshot)

    # Calculate eligible: present in all snapshots, min stake met
    eligible = {}
    not_in_all = 0
    below_min = 0

    for addr in all_addresses:
        if addr not in present_in_all:
            not_in_all += 1
            continue
        # Minimum stake across ALL snapshots
        min_s = min(all_snapshots[date][addr] for date in all_dates)
        if min_s < min_stake:
            below_min += 1
            continue
        eligible[addr] = {
            "stake_from": all_snapshots[all_dates[0]][addr],
            "stake_to": all_snapshots[all_dates[-1]][addr],
            "min_stake": min_s,
        }

    # Pool sizes: minimum across all snapshots
    pool_sizes = [sum(snap.values()) for snap in all_snapshots.values()]
    min_pool = min(pool_sizes)

    stats = {
        "snap_from": snap_from,
        "snap_to": snap_to,
        "snapshot_count": len(all_dates),
        "not_in_all": not_in_all,
        "below_min": below_min,
        "min_pool": min_pool,
    }

    return eligible, stats, all_dates, None


def cmd_compare(args):
    """Compare snapshots to find eligible delegators."""
    conn = get_db()

    validator_id = args.validator
    if validator_id is None:
        row = conn.execute("SELECT DISTINCT validator_id FROM snapshots LIMIT 1").fetchone()
        if row:
            validator_id = row[0]
        else:
            print("Error: No snapshots found. Specify --validator.")
            conn.close()
            raise SystemExit(1)

    min_stake = args.min_stake
    eligible, stats, all_dates, error = _calculate_eligible(
        conn, validator_id, args.date_from, args.date_to, min_stake
    )
    conn.close()

    if error:
        print(f"Error: {error}")
        raise SystemExit(1)

    total_eligible = sum(e["min_stake"] for e in eligible.values())

    print(f"Comparing {stats['snapshot_count']} snapshots: {stats['snap_from']} -> {stats['snap_to']}")
    print(f"\nEligible: {len(eligible)} delegators, {total_eligible:,.2f} POL")
    print(f"Excluded: {stats['not_in_all']} not in all snapshots, {stats['below_min']} below minimum ({min_stake} POL)")

    if eligible:
        print("\nTop 10 by stake:")
        sorted_eligible = sorted(eligible.items(), key=lambda x: x[1]["min_stake"], reverse=True)
        for i, (addr, info) in enumerate(sorted_eligible[:10]):
            print(f"  {i+1}. {addr} — {info['min_stake']:,.2f} POL")


def cmd_distribute(args):
    """Calculate the distribution for eligible delegators."""
    config = _load_config(args.config)
    validator_id = config["validator_id"]
    received = args.received
    from_date = args.date_from
    to_date = args.date_to
    min_stake = config.get("min_stake_pol", 500)

    conn = get_db()

    eligible, stats, all_dates, error = _calculate_eligible(
        conn, validator_id, from_date, to_date, min_stake
    )

    if error:
        print(f"Error: {error}")
        conn.close()
        raise SystemExit(1)

    if not eligible:
        print("No eligible delegators found.")
        conn.close()
        raise SystemExit(1)

    print(f"Distribution period: {stats['snap_from']} -> {stats['snap_to']} ({stats['snapshot_count']} snapshots)")

    total_eligible_stake = sum(e["min_stake"] for e in eligible.values())
    min_pool = stats["min_pool"]

    infra_cost = config.get("infra_cost_pol", 0)
    share_pct = _get_share_pct(config, min_pool)

    net = received - infra_cost
    if net <= 0:
        print(f"Error: Received ({received:,.2f}) does not cover infrastructure cost ({infra_cost:,.2f}).")
        conn.close()
        raise SystemExit(1)

    to_distribute = Decimal(str(net)) * Decimal(str(share_pct)) / Decimal("100")

    # Calculate individual payouts
    total_distributed = Decimal("0")
    for addr, info in eligible.items():
        share = Decimal(str(info["min_stake"])) / Decimal(str(total_eligible_stake))
        payout = (share * to_distribute).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
        info["payout"] = float(payout)
        total_distributed += payout

    # Store distribution in database
    now = datetime.now(timezone.utc).isoformat()
    cursor = conn.execute(
        """INSERT INTO distributions
           (validator_id, period_from, period_to, total_received, infra_cost,
            share_pct, total_distributed, eligible_delegators, timestamp)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (validator_id, from_date, to_date, received, infra_cost,
         share_pct, float(total_distributed), len(eligible), now),
    )
    dist_id = cursor.lastrowid

    for addr, info in eligible.items():
        conn.execute(
            """INSERT INTO distribution_details
               (distribution_id, delegator_address, stake_from, stake_to, min_stake, payout)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (dist_id, addr, info["stake_from"], info["stake_to"], info["min_stake"], info["payout"]),
        )
    conn.commit()
    conn.close()

    # Print summary
    print(f"\n{'='*50}")
    print(f"  Distribution Summary — {config.get('validator_name', f'Validator #{validator_id}')}")
    print(f"{'='*50}")
    print(f"  Received:            {received:>14,.2f} POL")
    print(f"  Infrastructure cost: {infra_cost:>14,.2f} POL")
    print(f"  Net:                 {net:>14,.2f} POL")
    print(f"  Pool size (min):     {min_pool:>14,.2f} POL")
    print(f"  Share percentage:    {share_pct:>13}%")
    print(f"  To distribute:       {float(to_distribute):>14,.6f} POL")
    print(f"  Eligible delegators: {len(eligible):>14}")
    print(f"  Total distributed:   {float(total_distributed):>14,.6f} POL")

    rounding_diff = float(to_distribute - total_distributed)
    if abs(rounding_diff) > 0:
        print(f"  Rounding difference: {rounding_diff:>14,.6f} POL")

    print(f"\nTop 10 payouts:")
    sorted_eligible = sorted(eligible.items(), key=lambda x: x[1]["payout"], reverse=True)
    for i, (addr, info) in enumerate(sorted_eligible[:10]):
        print(f"  {i+1}. {addr} — {info['payout']:,.6f} POL (stake: {info['min_stake']:,.2f})")

    # Save CSV report
    ensure_dirs()
    report_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    report_path = os.path.join(OUTPUT_DIR, f"report_{report_date}.csv")
    with open(report_path, "w") as f:
        f.write("delegator_address,stake_from,stake_to,min_stake,payout\n")
        for addr, info in sorted(eligible.items(), key=lambda x: x[1]["payout"], reverse=True):
            f.write(f"{addr},{info['stake_from']:.2f},{info['stake_to']:.2f},{info['min_stake']:.2f},{info['payout']:.6f}\n")
    print(f"\nReport saved: {report_path}")


def cmd_export(args):
    """Export the distribution for disperse.app."""
    config = _load_config(args.config)
    validator_id = config["validator_id"]
    conn = get_db()

    from_date = args.date_from
    to_date = args.date_to

    # Find the latest distribution matching the period and validator
    row = conn.execute(
        """SELECT id, total_distributed, eligible_delegators FROM distributions
           WHERE validator_id = ? AND period_from = ? AND period_to = ?
           ORDER BY timestamp DESC LIMIT 1""",
        (validator_id, from_date, to_date),
    ).fetchone()

    if not row:
        print(f"Error: No distribution found for validator #{validator_id}, period {from_date} to {to_date}.")
        print("Run the distribute command first.")
        conn.close()
        raise SystemExit(1)

    dist_id = row[0]

    min_payout = args.min_payout

    details = conn.execute(
        """SELECT delegator_address, payout FROM distribution_details
           WHERE distribution_id = ? AND payout > 0
           ORDER BY payout DESC""",
        (dist_id,),
    ).fetchall()
    conn.close()

    if not details:
        print("No delegators with payout > 0 found.")
        raise SystemExit(1)

    ensure_dirs()
    export_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    export_path = os.path.join(OUTPUT_DIR, f"disperse_{export_date}.txt")

    total = Decimal("0")
    included = 0
    skipped = 0
    skipped_total = Decimal("0")
    with open(export_path, "w") as f:
        for addr, payout in details:
            if payout < min_payout:
                skipped += 1
                skipped_total += Decimal(str(payout))
                continue
            payout_dec = Decimal(str(payout)).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
            payout_str = f"{payout_dec:f}".rstrip("0").rstrip(".")
            f.write(f"{addr} {payout_str}\n")
            total += payout_dec
            included += 1

    print(f"Disperse file ready: {included} addresses, {float(total):,.6f} POL")
    if skipped > 0:
        print(f"Skipped: {skipped} addresses below {min_payout} POL minimum payout ({float(skipped_total):,.6f} POL)")
    print(f"Saved: {export_path}")


def cmd_status(args):
    """Show current state."""
    conn = get_db()

    validator_id = args.validator
    if validator_id is None:
        row = conn.execute("SELECT DISTINCT validator_id FROM snapshots LIMIT 1").fetchone()
        if row:
            validator_id = row[0]
        else:
            print("No snapshots found. Specify --validator.")
            conn.close()
            return

    # Snapshot stats
    row = conn.execute(
        """SELECT COUNT(DISTINCT snapshot_date), MIN(snapshot_date), MAX(snapshot_date)
           FROM snapshots WHERE validator_id = ?""",
        (validator_id,),
    ).fetchone()

    snapshot_count, first_date, last_date = row
    print(f"Validator #{validator_id} Status")
    print(f"{'='*40}")
    print(f"  Snapshots taken:  {snapshot_count}")

    if snapshot_count > 0:
        print(f"  Date range:       {first_date} to {last_date}")

        # Latest snapshot stats
        latest = conn.execute(
            """SELECT COUNT(*), SUM(stake_pol) FROM snapshots
               WHERE validator_id = ? AND snapshot_date = ?""",
            (validator_id, last_date),
        ).fetchone()
        print(f"\n  Latest snapshot ({last_date}):")
        print(f"    Delegators:     {latest[0]}")
        print(f"    Total stake:    {latest[1]:,.2f} POL")

    # Distribution stats
    dist_count = conn.execute(
        "SELECT COUNT(*) FROM distributions WHERE validator_id = ?",
        (validator_id,),
    ).fetchone()[0]
    if dist_count > 0:
        print(f"\n  Distributions:    {dist_count}")
        latest_dist = conn.execute(
            """SELECT period_from, period_to, total_distributed, eligible_delegators
               FROM distributions WHERE validator_id = ?
               ORDER BY timestamp DESC LIMIT 1""",
            (validator_id,),
        ).fetchone()
        print(f"  Latest: {latest_dist[0]} to {latest_dist[1]}")
        print(f"    Distributed:    {latest_dist[2]:,.2f} POL to {latest_dist[3]} delegators")

    # Config summary
    config_path = _resolve_config_path("config.json")
    if os.path.exists(config_path):
        with open(config_path) as f:
            config = json.load(f)
        if config.get("validator_id") == validator_id:
            print(f"\n  Config ({config.get('validator_name', 'N/A')}):")
            print(f"    Infra cost:     {config.get('infra_cost_pol', 0):,.0f} POL")
            if config.get("flat_share_pct") is not None:
                print(f"    Share:          {config['flat_share_pct']}% (flat)")
            else:
                tiers = config.get("sharing_tiers", [])
                print(f"    Sharing tiers:  {len(tiers)} tiers configured")
                for t in tiers:
                    max_str = f"{t['max_pool']:,.0f}" if t['max_pool'] else "unlimited"
                    print(f"      {t['min_pool']:>12,.0f} - {max_str}: {t['share_pct']}%")

    conn.close()


def cmd_auto_distribute(args):
    """Automatically distribute for the previous calendar month.

    Fetches the received amount from on-chain data (multisig -> validator signer),
    calculates the distribution, and exports the disperse file.
    """
    config = _load_config(args.config)
    validator_id = config["validator_id"]

    if validator_id == 0:
        print("Error: validator_id is still 0. Edit config.json with your validator ID.")
        raise SystemExit(1)

    min_stake = config.get("min_stake_pol", 500)
    min_payout = args.min_payout

    # Determine previous calendar month
    now = datetime.now(timezone.utc)
    first_of_this_month = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    last_month_end = first_of_this_month
    last_month_start = (first_of_this_month - timedelta(days=1)).replace(day=1)

    date_from = last_month_start.strftime("%Y-%m-%d")
    date_to = last_month_end.strftime("%Y-%m-%d")
    month_name = last_month_start.strftime("%B %Y")

    print(f"Auto-distribute for {month_name}")
    print(f"Period: {date_from} -> {date_to}")

    # Check if distribution already exists for this period
    conn = get_db()
    existing = conn.execute(
        """SELECT id, total_received, total_distributed, timestamp FROM distributions
           WHERE validator_id = ? AND period_from = ? AND period_to = ?
           ORDER BY timestamp DESC LIMIT 1""",
        (validator_id, date_from, date_to),
    ).fetchone()
    conn.close()

    if existing:
        print(f"\nDistribution for {month_name} already exists.")
        print(f"  Received:    {existing[1]:,.2f} POL")
        print(f"  Distributed: {existing[2]:,.2f} POL")
        print(f"  Created:     {existing[3]}")
        print(f"\nTo prevent double payouts, this period is skipped.")
        print(f"Check output/ for the existing disperse file.")
        print(f"To force a recalculation, use the manual distribute command.")
        return

    # Step 1: Look up validator signer address
    print(f"\nLooking up signer address for validator #{validator_id}...")
    signer = fetch_validator_signer(validator_id)
    print(f"  Signer: {signer}")

    # Step 2: Fetch payouts from multisig
    print(f"\nFetching payouts from multisig...")
    api_key = config.get("polygonscan_api_key")
    received, tx_count = fetch_payouts_from_multisig(signer, date_from, date_to, api_key)

    if received <= 0:
        print(f"  No payouts found from multisig to {signer} in {month_name}.")
        print(f"  Multisig: {MULTISIG_ADDRESS}")
        print(f"  If you received payouts another way, use the manual distribute command.")
        raise SystemExit(1)

    print(f"  Found {tx_count} payout(s): {received:,.2f} POL")

    # Step 3: Calculate eligible delegators
    conn = get_db()
    eligible, stats, all_dates, error = _calculate_eligible(
        conn, validator_id, date_from, date_to, min_stake
    )

    if error:
        print(f"\nError: {error}")
        conn.close()
        raise SystemExit(1)

    if not eligible:
        print("\nNo eligible delegators found.")
        conn.close()
        raise SystemExit(1)

    print(f"\nDistribution period: {stats['snap_from']} -> {stats['snap_to']} ({stats['snapshot_count']} snapshots)")

    total_eligible_stake = sum(e["min_stake"] for e in eligible.values())
    min_pool = stats["min_pool"]

    infra_cost = config.get("infra_cost_pol", 0)
    share_pct = _get_share_pct(config, min_pool)

    net = received - infra_cost
    if net <= 0:
        print(f"Error: Received ({received:,.2f}) does not cover infrastructure cost ({infra_cost:,.2f}).")
        conn.close()
        raise SystemExit(1)

    to_distribute = Decimal(str(net)) * Decimal(str(share_pct)) / Decimal("100")

    # Calculate individual payouts
    total_distributed = Decimal("0")
    for addr, info in eligible.items():
        share = Decimal(str(info["min_stake"])) / Decimal(str(total_eligible_stake))
        payout = (share * to_distribute).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
        info["payout"] = float(payout)
        total_distributed += payout

    # Store distribution
    now_ts = datetime.now(timezone.utc).isoformat()
    cursor = conn.execute(
        """INSERT INTO distributions
           (validator_id, period_from, period_to, total_received, infra_cost,
            share_pct, total_distributed, eligible_delegators, timestamp)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (validator_id, date_from, date_to, received, infra_cost,
         share_pct, float(total_distributed), len(eligible), now_ts),
    )
    dist_id = cursor.lastrowid

    for addr, info in eligible.items():
        conn.execute(
            """INSERT INTO distribution_details
               (distribution_id, delegator_address, stake_from, stake_to, min_stake, payout)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (dist_id, addr, info["stake_from"], info["stake_to"], info["min_stake"], info["payout"]),
        )
    conn.commit()
    conn.close()

    # Print summary
    print(f"\n{'='*50}")
    print(f"  Distribution Summary — {config.get('validator_name', f'Validator #{validator_id}')}")
    print(f"  {month_name}")
    print(f"{'='*50}")
    print(f"  Received:            {received:>14,.2f} POL ({tx_count} payout{'s' if tx_count != 1 else ''})")
    print(f"  Infrastructure cost: {infra_cost:>14,.2f} POL")
    print(f"  Net:                 {net:>14,.2f} POL")
    print(f"  Pool size (min):     {min_pool:>14,.2f} POL")
    print(f"  Share percentage:    {share_pct:>13}%")
    print(f"  To distribute:       {float(to_distribute):>14,.6f} POL")
    print(f"  Eligible delegators: {len(eligible):>14}")
    print(f"  Total distributed:   {float(total_distributed):>14,.6f} POL")
    print(f"  Snapshots used:      {stats['snapshot_count']:>14}")

    rounding_diff = float(to_distribute - total_distributed)
    if abs(rounding_diff) > 0:
        print(f"  Rounding difference: {rounding_diff:>14,.6f} POL")

    print(f"\nTop 10 payouts:")
    sorted_eligible = sorted(eligible.items(), key=lambda x: x[1]["payout"], reverse=True)
    for i, (addr, info) in enumerate(sorted_eligible[:10]):
        print(f"  {i+1}. {addr} — {info['payout']:,.6f} POL (stake: {info['min_stake']:,.2f})")

    # Save CSV report
    ensure_dirs()
    report_date = last_month_start.strftime("%Y-%m")
    report_path = os.path.join(OUTPUT_DIR, f"report_{report_date}.csv")
    with open(report_path, "w") as f:
        f.write("delegator_address,stake_from,stake_to,min_stake,payout\n")
        for addr, info in sorted(eligible.items(), key=lambda x: x[1]["payout"], reverse=True):
            f.write(f"{addr},{info['stake_from']:.2f},{info['stake_to']:.2f},{info['min_stake']:.2f},{info['payout']:.6f}\n")
    print(f"\nReport saved: {report_path}")

    # Export disperse file
    export_path = os.path.join(OUTPUT_DIR, f"disperse_{report_date}.txt")
    total_export = Decimal("0")
    included = 0
    with open(export_path, "w") as f:
        for addr, info in sorted(eligible.items(), key=lambda x: x[1]["payout"], reverse=True):
            if info["payout"] < min_payout:
                continue
            payout_dec = Decimal(str(info["payout"])).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
            payout_str = f"{payout_dec:f}".rstrip("0").rstrip(".")
            f.write(f"{addr} {payout_str}\n")
            total_export += payout_dec
            included += 1

    print(f"\nDisperse file ready: {included} addresses, {float(total_export):,.6f} POL")
    print(f"Saved: {export_path}")
    print(f"\nNext step: paste the contents of {export_path} into disperse.app")


def main():
    parser = argparse.ArgumentParser(
        description="Polygon Validator Priority Fee Sharing Tool",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # snapshot
    snap_parser = subparsers.add_parser("snapshot", help="Take a delegator snapshot")
    snap_parser.add_argument("--validator", type=int, required=True, help="Validator ID")

    # compare
    cmp_parser = subparsers.add_parser("compare", help="Compare two snapshots")
    cmp_parser.add_argument("--from", dest="date_from", required=True, help="Start date (YYYY-MM-DD)")
    cmp_parser.add_argument("--to", dest="date_to", required=True, help="End date (YYYY-MM-DD)")
    cmp_parser.add_argument("--min-stake", type=float, default=500, help="Minimum stake in POL (default: 500)")
    cmp_parser.add_argument("--validator", type=int, default=None, help="Validator ID (auto-detected if omitted)")

    # distribute
    dist_parser = subparsers.add_parser("distribute", help="Calculate distribution")
    dist_parser.add_argument("--config", default="config.json", help="Config file path (default: config.json)")
    dist_parser.add_argument("--received", type=float, required=True, help="Total POL received from priority fees")
    dist_parser.add_argument("--from", dest="date_from", required=True, help="Period start date (YYYY-MM-DD)")
    dist_parser.add_argument("--to", dest="date_to", required=True, help="Period end date (YYYY-MM-DD)")

    # export
    exp_parser = subparsers.add_parser("export", help="Export for disperse.app")
    exp_parser.add_argument("--config", default="config.json", help="Config file path (default: config.json)")
    exp_parser.add_argument("--from", dest="date_from", required=True, help="Period start date (YYYY-MM-DD)")
    exp_parser.add_argument("--to", dest="date_to", required=True, help="Period end date (YYYY-MM-DD)")
    exp_parser.add_argument("--min-payout", type=float, default=0.01, help="Minimum payout in POL to include (default: 0.01)")

    # auto-distribute
    auto_parser = subparsers.add_parser("auto-distribute", help="Auto-distribute for previous month")
    auto_parser.add_argument("--config", default="config.json", help="Config file path (default: config.json)")
    auto_parser.add_argument("--min-payout", type=float, default=0.01, help="Minimum payout in POL to include (default: 0.01)")

    # status
    stat_parser = subparsers.add_parser("status", help="Show current state")
    stat_parser.add_argument("--validator", type=int, default=None, help="Validator ID (auto-detected if omitted)")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        raise SystemExit(1)

    commands = {
        "snapshot": cmd_snapshot,
        "compare": cmd_compare,
        "distribute": cmd_distribute,
        "export": cmd_export,
        "auto-distribute": cmd_auto_distribute,
        "status": cmd_status,
    }
    commands[args.command](args)


if __name__ == "__main__":
    main()
