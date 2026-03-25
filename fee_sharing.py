#!/usr/bin/env python3
"""Polygon Validator Priority Fee Sharing Tool.

Enables any Polygon PoS validator to share priority fees with their delegators.
Takes daily snapshots, compares monthly, calculates fair distribution,
and exports a file ready for disperse.app.
"""

import argparse
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
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


def cmd_compare(args):
    """Compare two snapshots to find eligible delegators."""
    conn = get_db()

    # Determine validator_id from existing snapshots or config
    validator_id = args.validator
    if validator_id is None:
        row = conn.execute("SELECT DISTINCT validator_id FROM snapshots LIMIT 1").fetchone()
        if row:
            validator_id = row[0]
        else:
            print("Error: No snapshots found. Specify --validator.")
            conn.close()
            raise SystemExit(1)

    from_date = args.date_from
    to_date = args.date_to
    min_stake = args.min_stake

    # Find closest snapshots
    snap_from = _get_closest_snapshot(conn, validator_id, from_date)
    snap_to = _get_closest_snapshot(conn, validator_id, to_date)

    if not snap_from or not snap_to:
        print("Error: Not enough snapshots found. Take snapshots first.")
        conn.close()
        raise SystemExit(1)

    if snap_from == snap_to:
        print(f"Error: Both dates resolve to the same snapshot ({snap_from}). Need two different snapshots.")
        conn.close()
        raise SystemExit(1)

    print(f"Comparing snapshots: {snap_from} -> {snap_to}")

    data_from = _get_snapshot_data(conn, validator_id, snap_from)
    data_to = _get_snapshot_data(conn, validator_id, snap_to)
    conn.close()

    # Find eligible delegators (present in both, min stake met)
    eligible = {}
    not_in_both = 0
    below_min = 0

    all_addresses = set(data_from.keys()) | set(data_to.keys())
    for addr in all_addresses:
        if addr not in data_from or addr not in data_to:
            not_in_both += 1
            continue
        min_s = min(data_from[addr], data_to[addr])
        if min_s < min_stake:
            below_min += 1
            continue
        eligible[addr] = {
            "stake_from": data_from[addr],
            "stake_to": data_to[addr],
            "min_stake": min_s,
        }

    total_eligible = sum(e["min_stake"] for e in eligible.values())

    print(f"\nEligible: {len(eligible)} delegators, {total_eligible:,.2f} POL")
    print(f"Excluded: {not_in_both} not in both snapshots, {below_min} below minimum ({min_stake} POL)")

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
    min_stake = config.get("min_stake_pol", 100)

    conn = get_db()

    snap_from = _get_closest_snapshot(conn, validator_id, from_date)
    snap_to = _get_closest_snapshot(conn, validator_id, to_date)

    if not snap_from or not snap_to:
        print("Error: Not enough snapshots found.")
        conn.close()
        raise SystemExit(1)

    if snap_from == snap_to:
        print(f"Error: Both dates resolve to the same snapshot ({snap_from}).")
        conn.close()
        raise SystemExit(1)

    print(f"Distribution period: {snap_from} -> {snap_to}")

    data_from = _get_snapshot_data(conn, validator_id, snap_from)
    data_to = _get_snapshot_data(conn, validator_id, snap_to)

    # Calculate eligible delegators
    eligible = {}
    for addr in set(data_from.keys()) & set(data_to.keys()):
        min_s = min(data_from[addr], data_to[addr])
        if min_s >= min_stake:
            eligible[addr] = {
                "stake_from": data_from[addr],
                "stake_to": data_to[addr],
                "min_stake": min_s,
            }

    if not eligible:
        print("No eligible delegators found.")
        conn.close()
        raise SystemExit(1)

    total_eligible_stake = sum(e["min_stake"] for e in eligible.values())

    # Determine pool size and tier using minimum between snapshots
    pool_from = sum(data_from.values())
    pool_to = sum(data_to.values())
    min_pool = min(pool_from, pool_to)

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
    cmp_parser.add_argument("--min-stake", type=float, default=100, help="Minimum stake in POL (default: 100)")
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
    exp_parser.add_argument("--min-payout", type=float, default=500, help="Minimum payout in POL to include (default: 500)")

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
        "status": cmd_status,
    }
    commands[args.command](args)


if __name__ == "__main__":
    main()
