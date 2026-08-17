#!/usr/bin/env python3
"""Grid level rules for EA_CandleGridTrail — tester values == live values."""

from __future__ import annotations

import unittest


def buy_level(open_price: float, n: int, step: float) -> float:
    return open_price + n * step


def sell_level(open_price: float, n: int, step: float) -> float:
    return open_price - n * step


def crossed_buy_levels(open_price: float, ask: float, step: float, next_n: int) -> list[int]:
    hit = []
    n = next_n
    while ask >= buy_level(open_price, n, step):
        hit.append(n)
        n += 1
    return hit


def crossed_sell_levels(open_price: float, bid: float, step: float, next_n: int) -> list[int]:
    hit = []
    n = next_n
    while bid <= sell_level(open_price, n, step):
        hit.append(n)
        n += 1
    return hit


def trail_buy(bid: float, distance: float) -> float:
    return bid - distance


def trail_sell(ask: float, distance: float) -> float:
    return ask + distance


class GridTests(unittest.TestCase):
    def test_no_entry_at_open(self):
        self.assertEqual(crossed_buy_levels(4400.0, 4400.0, 0.2, 1), [])
        self.assertEqual(crossed_sell_levels(4400.0, 4400.0, 0.2, 1), [])

    def test_buy_steps_from_open(self):
        self.assertEqual(buy_level(4400.0, 1, 0.2), 4400.2)
        self.assertEqual(buy_level(4400.0, 2, 0.2), 4400.4)
        self.assertEqual(crossed_buy_levels(4400.0, 4400.2, 0.2, 1), [1])
        self.assertEqual(crossed_buy_levels(4400.0, 4400.61, 0.2, 1), [1, 2, 3])

    def test_sell_steps_from_open(self):
        self.assertEqual(sell_level(4400.0, 1, 0.2), 4399.8)
        self.assertEqual(sell_level(4400.0, 2, 0.2), 4399.6)
        self.assertEqual(crossed_sell_levels(4400.0, 4399.8, 0.2, 1), [1])

    def test_level_once(self):
        self.assertEqual(crossed_buy_levels(4400.0, 4400.5, 0.2, 3), [])

    def test_tester_step_is_live_step(self):
        step = 0.5
        self.assertEqual(buy_level(4400.0, 1, step), 4400.5)
        self.assertEqual(sell_level(4400.0, 1, step), 4399.5)


class TrailTests(unittest.TestCase):
    def test_trail_from_current_price(self):
        self.assertAlmostEqual(trail_buy(4401.0, 0.3), 4400.7)
        self.assertAlmostEqual(trail_sell(4399.0, 0.3), 4399.3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
