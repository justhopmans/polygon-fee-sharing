"""Tests for the Polygon Validator Priority Fee Sharing Tool."""

import json
import os
import sqlite3
import tempfile
import unittest
from decimal import Decimal
from unittest.mock import patch, MagicMock

# Ensure fee_sharing can be imported
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import fee_sharing


class TestWeiConversion(unittest.TestCase):
    """Test wei to POL conversion accuracy."""

    def test_basic_conversion(self):
        stake_wei = Decimal("1500000000000000000000000")
        stake_pol = float(stake_wei / fee_sharing.WEI_PER_POL)
        self.assertAlmostEqual(stake_pol, 1500000.0, places=6)

    def test_small_amount(self):
        stake_wei = Decimal("100000000000000000000")  # 100 POL
        stake_pol = float(stake_wei / fee_sharing.WEI_PER_POL)
        self.assertAlmostEqual(stake_pol, 100.0, places=6)

    def test_fractional_amount(self):
        stake_wei = Decimal("1500000000000000000")  # 1.5 POL
        stake_pol = float(stake_wei / fee_sharing.WEI_PER_POL)
        self.assertAlmostEqual(stake_pol, 1.5, places=6)


class TestFilterDelegators(unittest.TestCase):
    """Test that snapshot correctly filters inactive delegators."""

    @patch("fee_sharing.requests.get")
    def test_filters_inactive_delegators(self, mock_get):
        """Delegators with deactivationEpoch != '0' should be excluded."""
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_resp.json.return_value = {
            "result": [
                {"address": "0xactive1", "stake": "1000000000000000000000", "deactivationEpoch": "0"},
                {"address": "0xinactive", "stake": "2000000000000000000000", "deactivationEpoch": "100"},
                {"address": "0xactive2", "stake": "500000000000000000000", "deactivationEpoch": "0"},
                {"address": "0xzerostake", "stake": "0", "deactivationEpoch": "0"},
            ]
        }
        mock_resp.raise_for_status = MagicMock()
        mock_get.return_value = mock_resp

        delegators = fee_sharing.fetch_delegators(118)
        addresses = [d["address"] for d in delegators]

        self.assertEqual(len(delegators), 2)
        self.assertIn("0xactive1", addresses)
        self.assertIn("0xactive2", addresses)
        self.assertNotIn("0xinactive", addresses)
        self.assertNotIn("0xzerostake", addresses)

    @patch("fee_sharing.requests.get")
    def test_pagination(self, mock_get):
        """Should handle pagination when API returns 500 results."""
        # First page: 500 results
        page1 = [{"address": f"0x{i:040x}", "stake": "1000000000000000000000", "deactivationEpoch": "0"}
                  for i in range(500)]
        # Second page: 10 results
        page2 = [{"address": f"0x{i:040x}", "stake": "1000000000000000000000", "deactivationEpoch": "0"}
                  for i in range(500, 510)]

        mock_resp1 = MagicMock()
        mock_resp1.json.return_value = {"result": page1}
        mock_resp1.raise_for_status = MagicMock()

        mock_resp2 = MagicMock()
        mock_resp2.json.return_value = {"result": page2}
        mock_resp2.raise_for_status = MagicMock()

        mock_get.side_effect = [mock_resp1, mock_resp2]

        delegators = fee_sharing.fetch_delegators(118)
        self.assertEqual(len(delegators), 510)


class TestDatabaseSetup(unittest.TestCase):
    """Test database operations."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.orig_db = fee_sharing.DB_PATH
        self.orig_db_dir = fee_sharing.DB_DIR
        fee_sharing.DB_DIR = self.tmpdir
        fee_sharing.DB_PATH = os.path.join(self.tmpdir, "test.db")

    def tearDown(self):
        fee_sharing.DB_PATH = self.orig_db
        fee_sharing.DB_DIR = self.orig_db_dir

    def _insert_snapshot(self, conn, validator_id, date, delegators):
        for addr, stake in delegators.items():
            conn.execute(
                "INSERT INTO snapshots (validator_id, delegator_address, stake_pol, timestamp, snapshot_date) "
                "VALUES (?, ?, ?, ?, ?)",
                (validator_id, addr, stake, f"{date}T00:00:00+00:00", date),
            )
        conn.commit()

    def test_minimum_stake_between_snapshots(self):
        """The minimum stake between two snapshots should be used."""
        conn = fee_sharing.get_db()
        self._insert_snapshot(conn, 118, "2026-04-01", {
            "0xaaa": 100000.0,
            "0xbbb": 50000.0,
        })
        self._insert_snapshot(conn, 118, "2026-05-01", {
            "0xaaa": 80000.0,  # decreased
            "0xbbb": 70000.0,  # increased
        })

        data_from = fee_sharing._get_snapshot_data(conn, 118, "2026-04-01")
        data_to = fee_sharing._get_snapshot_data(conn, 118, "2026-05-01")
        conn.close()

        for addr in set(data_from.keys()) & set(data_to.keys()):
            min_stake = min(data_from[addr], data_to[addr])
            if addr == "0xaaa":
                self.assertEqual(min_stake, 80000.0)  # decreased: use lower
            elif addr == "0xbbb":
                self.assertEqual(min_stake, 50000.0)  # increased: use original

    def test_delegator_only_in_one_snapshot_excluded(self):
        """A delegator present in only one snapshot should be excluded."""
        conn = fee_sharing.get_db()
        self._insert_snapshot(conn, 118, "2026-04-01", {
            "0xaaa": 100000.0,
            "0xonly_from": 50000.0,
        })
        self._insert_snapshot(conn, 118, "2026-05-01", {
            "0xaaa": 100000.0,
            "0xonly_to": 30000.0,
        })

        data_from = fee_sharing._get_snapshot_data(conn, 118, "2026-04-01")
        data_to = fee_sharing._get_snapshot_data(conn, 118, "2026-05-01")
        conn.close()

        common = set(data_from.keys()) & set(data_to.keys())
        self.assertIn("0xaaa", common)
        self.assertNotIn("0xonly_from", common)
        self.assertNotIn("0xonly_to", common)

    def test_delegator_below_minimum_excluded(self):
        """A delegator below minimum stake should be excluded."""
        conn = fee_sharing.get_db()
        self._insert_snapshot(conn, 118, "2026-04-01", {
            "0xbig": 10000.0,
            "0xsmall": 50.0,
        })
        self._insert_snapshot(conn, 118, "2026-05-01", {
            "0xbig": 10000.0,
            "0xsmall": 50.0,
        })

        data_from = fee_sharing._get_snapshot_data(conn, 118, "2026-04-01")
        data_to = fee_sharing._get_snapshot_data(conn, 118, "2026-05-01")
        conn.close()

        min_stake_threshold = 100
        eligible = {}
        for addr in set(data_from.keys()) & set(data_to.keys()):
            min_s = min(data_from[addr], data_to[addr])
            if min_s >= min_stake_threshold:
                eligible[addr] = min_s

        self.assertIn("0xbig", eligible)
        self.assertNotIn("0xsmall", eligible)


class TestDistributionMath(unittest.TestCase):
    """Test that distribution math is correct."""

    def test_payouts_sum_to_total(self):
        """Individual payouts should sum to total_distributed (within rounding)."""
        received = 50000.0
        infra_cost = 10000.0
        share_pct = 38.0

        net = received - infra_cost
        to_distribute = Decimal(str(net)) * Decimal(str(share_pct)) / Decimal("100")

        delegators = {
            "0xa": 1000000.0,
            "0xb": 500000.0,
            "0xc": 250000.0,
            "0xd": 100000.0,
            "0xe": 50000.0,
            "0xf": 10000.0,
            "0xg": 1000.0,
            "0xh": 500.0,
            "0xi": 100.0,
        }
        total_stake = sum(delegators.values())

        total_paid = Decimal("0")
        payouts = {}
        for addr, stake in delegators.items():
            share = Decimal(str(stake)) / Decimal(str(total_stake))
            payout = (share * to_distribute).quantize(Decimal("0.000001"))
            payouts[addr] = payout
            total_paid += payout

        # Rounding difference should be negligible
        diff = abs(float(to_distribute - total_paid))
        self.assertLess(diff, 0.01)  # Less than 0.01 POL difference

        # All payouts positive
        for payout in payouts.values():
            self.assertGreater(payout, 0)

    def test_proportional_distribution(self):
        """Delegator with 2x stake should get 2x payout."""
        to_distribute = Decimal("15200")
        delegators = {"0xa": 2000.0, "0xb": 1000.0}
        total = sum(delegators.values())

        payout_a = Decimal(str(delegators["0xa"])) / Decimal(str(total)) * to_distribute
        payout_b = Decimal(str(delegators["0xb"])) / Decimal(str(total)) * to_distribute

        self.assertAlmostEqual(float(payout_a), float(payout_b) * 2, places=6)


class TestTierSelection(unittest.TestCase):
    """Test tier selection based on pool size."""

    def setUp(self):
        self.config = {
            "sharing_tiers": [
                {"min_pool": 0, "max_pool": 5000000, "share_pct": 0},
                {"min_pool": 5000000, "max_pool": 10000000, "share_pct": 30},
                {"min_pool": 10000000, "max_pool": 20000000, "share_pct": 38},
                {"min_pool": 20000000, "max_pool": 30000000, "share_pct": 45},
                {"min_pool": 50000000, "max_pool": None, "share_pct": 55},
            ],
            "flat_share_pct": None,
        }

    def test_lowest_tier(self):
        self.assertEqual(fee_sharing._get_share_pct(self.config, 3000000), 0)

    def test_mid_tier(self):
        self.assertEqual(fee_sharing._get_share_pct(self.config, 15000000), 38)

    def test_highest_tier_no_max(self):
        self.assertEqual(fee_sharing._get_share_pct(self.config, 200000000), 55)

    def test_tier_boundary(self):
        """Pool size exactly at tier boundary goes to higher tier."""
        self.assertEqual(fee_sharing._get_share_pct(self.config, 10000000), 38)

    def test_minimum_pool_between_snapshots(self):
        """Tier should be determined by the minimum pool size between snapshots."""
        pool_from = 12000000  # 10-20M tier (38%)
        pool_to = 8000000    # 5-10M tier (30%)
        min_pool = min(pool_from, pool_to)

        share_pct = fee_sharing._get_share_pct(self.config, min_pool)
        self.assertEqual(share_pct, 30)  # Should use the lower tier

    def test_flat_share_overrides_tiers(self):
        """flat_share_pct should override tier-based sharing."""
        config = {
            "sharing_tiers": [
                {"min_pool": 0, "max_pool": None, "share_pct": 30},
            ],
            "flat_share_pct": 50,
        }
        self.assertEqual(fee_sharing._get_share_pct(config, 100000000), 50)


class TestDisperseFormat(unittest.TestCase):
    """Test disperse.app export format."""

    def test_format(self):
        """Output should be 'address amount' with no headers."""
        lines = []
        data = [
            ("0x1234567890abcdef1234567890abcdef12345678", 1520.5),
            ("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", 760.25),
            ("0x0000000000000000000000000000000000000001", 0.123456),
        ]

        for addr, payout in data:
            payout_dec = Decimal(str(payout)).quantize(Decimal("0.000001"))
            payout_str = f"{payout_dec:f}".rstrip("0").rstrip(".")
            lines.append(f"{addr} {payout_str}")

        # Verify format
        for line in lines:
            parts = line.split(" ")
            self.assertEqual(len(parts), 2)
            self.assertTrue(parts[0].startswith("0x"))
            float(parts[1])  # Should be parseable as float

        self.assertEqual(lines[0], "0x1234567890abcdef1234567890abcdef12345678 1520.5")
        self.assertEqual(lines[1], "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd 760.25")
        self.assertEqual(lines[2], "0x0000000000000000000000000000000000000001 0.123456")


class TestEndToEnd(unittest.TestCase):
    """End-to-end test: snapshot -> compare -> distribute -> export."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.orig_db = fee_sharing.DB_PATH
        self.orig_db_dir = fee_sharing.DB_DIR
        self.orig_output_dir = fee_sharing.OUTPUT_DIR
        fee_sharing.DB_DIR = self.tmpdir
        fee_sharing.DB_PATH = os.path.join(self.tmpdir, "test.db")
        fee_sharing.OUTPUT_DIR = os.path.join(self.tmpdir, "output")

    def tearDown(self):
        fee_sharing.DB_PATH = self.orig_db
        fee_sharing.DB_DIR = self.orig_db_dir
        fee_sharing.OUTPUT_DIR = self.orig_output_dir

    def test_full_flow(self):
        """Test the complete workflow with sample data."""
        conn = fee_sharing.get_db()

        # Insert "from" snapshot
        delegators_from = {
            "0xaaa": 1000000.0,
            "0xbbb": 500000.0,
            "0xccc": 250000.0,
            "0xddd": 50.0,       # below minimum
            "0xeee": 100000.0,   # only in from
        }
        for addr, stake in delegators_from.items():
            conn.execute(
                "INSERT INTO snapshots VALUES (NULL, 118, ?, ?, '2026-04-01T00:00:00+00:00', '2026-04-01')",
                (addr, stake),
            )

        # Insert "to" snapshot
        delegators_to = {
            "0xaaa": 800000.0,   # decreased
            "0xbbb": 700000.0,   # increased
            "0xccc": 250000.0,   # same
            "0xddd": 50.0,       # below minimum
            "0xfff": 200000.0,   # only in to
        }
        for addr, stake in delegators_to.items():
            conn.execute(
                "INSERT INTO snapshots VALUES (NULL, 118, ?, ?, '2026-05-01T00:00:00+00:00', '2026-05-01')",
                (addr, stake),
            )
        conn.commit()
        conn.close()

        # Write config
        config_path = os.path.join(self.tmpdir, "config.json")
        config = {
            "validator_id": 118,
            "validator_name": "TestValidator",
            "infra_cost_pol": 10000,
            "min_stake_pol": 100,
            "flat_share_pct": 30,
        }
        with open(config_path, "w") as f:
            json.dump(config, f)

        # Run distribute
        args = MagicMock()
        args.config = config_path
        args.received = 50000.0
        args.date_from = "2026-04-01"
        args.date_to = "2026-05-01"
        fee_sharing.cmd_distribute(args)

        # Verify distribution was stored
        conn = fee_sharing.get_db()
        dist = conn.execute("SELECT * FROM distributions").fetchone()
        self.assertIsNotNone(dist)

        details = conn.execute(
            "SELECT delegator_address, min_stake, payout FROM distribution_details ORDER BY payout DESC"
        ).fetchall()

        # Should have 3 eligible (0xaaa, 0xbbb, 0xccc) — not 0xddd (below min) or 0xeee/0xfff (not in both)
        self.assertEqual(len(details), 3)

        addresses = [d[0] for d in details]
        self.assertIn("0xaaa", addresses)
        self.assertIn("0xbbb", addresses)
        self.assertIn("0xccc", addresses)
        self.assertNotIn("0xddd", addresses)
        self.assertNotIn("0xeee", addresses)
        self.assertNotIn("0xfff", addresses)

        # Check min stakes used
        for addr, min_stake, payout in details:
            if addr == "0xaaa":
                self.assertEqual(min_stake, 800000.0)  # min(1M, 800K)
            elif addr == "0xbbb":
                self.assertEqual(min_stake, 500000.0)  # min(500K, 700K)
            elif addr == "0xccc":
                self.assertEqual(min_stake, 250000.0)  # same

        # Verify total distributed
        total_paid = sum(d[2] for d in details)
        expected = (50000 - 10000) * 0.30  # 12000
        self.assertAlmostEqual(total_paid, expected, places=2)

        # Run export
        args_export = MagicMock()
        args_export.config = config_path
        args_export.date_from = "2026-04-01"
        args_export.date_to = "2026-05-01"
        fee_sharing.cmd_export(args_export)

        # Check disperse file exists and format
        output_files = os.listdir(fee_sharing.OUTPUT_DIR)
        disperse_files = [f for f in output_files if f.startswith("disperse_")]
        self.assertEqual(len(disperse_files), 1)

        with open(os.path.join(fee_sharing.OUTPUT_DIR, disperse_files[0])) as f:
            lines = f.read().strip().split("\n")

        self.assertEqual(len(lines), 3)
        for line in lines:
            parts = line.split(" ")
            self.assertEqual(len(parts), 2)
            self.assertTrue(parts[0].startswith("0x"))
            float(parts[1])  # parseable

        conn.close()


if __name__ == "__main__":
    unittest.main()
