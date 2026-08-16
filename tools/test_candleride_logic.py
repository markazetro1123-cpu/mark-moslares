#!/usr/bin/env python3
"""Pure-python mirrors of Candle Ride Scalper rules."""

from __future__ import annotations

import unittest

FLAT, GREEN, RED = 0, 1, 2
MAX_ENTRIES = 20


def detect_color(mid: float, open_price: float, buffer: float) -> int:
    if mid > open_price + buffer:
        return GREEN
    if mid < open_price - buffer:
        return RED
    return FLAT


def action_on_color(color: int, buys: int, sells: int) -> tuple[str, str]:
    """Return (close_side, enter_side)."""
    if color == GREEN:
        close = "SELL" if sells > 0 else "NONE"
        enter = "BUY"
        return close, enter
    if color == RED:
        close = "BUY" if buys > 0 else "NONE"
        enter = "SELL"
        return close, enter
    return "NONE", "NONE"


def allowed_entries(
    equity: float,
    min_n: int = 2,
    mid_n: int = 5,
    max_n: int = 20,
    mid_eq: float = 50.0,
    max_eq: float = 800.0,
) -> int:
    if equity <= 10.0:
        n = min_n
    elif equity <= mid_eq:
        t = (equity - 10.0) / (mid_eq - 10.0)
        n = int(round(min_n + t * (mid_n - min_n)))
    elif equity >= max_eq:
        n = max_n
    else:
        t = (equity - mid_eq) / (max_eq - mid_eq)
        n = int(round(mid_n + t * (max_n - mid_n)))
    n = max(1, min(max_n, n))
    return n


def lot_by_equity(equity: float, min_lot: float = 0.01) -> float:
    lot = min_lot
    if equity >= 25.0:
        lot = min_lot * 2.0
    if equity >= 50.0:
        lot = min_lot * 3.0
    if equity >= 100.0:
        lot = min_lot * 5.0
    if equity >= 200.0:
        lot = min_lot * 8.0
    if equity >= 400.0:
        lot = min_lot * 12.0
    if equity >= 800.0:
        lot = min_lot * 18.0
    if equity >= 1500.0:
        lot = min_lot * 25.0
    if equity >= 3000.0:
        lot = min_lot * 40.0
    return lot


def should_close(
    price_profit: float,
    trigger: float,
    lock: float,
    armed: bool,
    pullback: bool,
) -> tuple[bool, bool]:
    """Return (close_now, new_armed)."""
    new_armed = armed or price_profit >= trigger
    if not pullback:
        return price_profit >= trigger, new_armed
    return (new_armed and price_profit <= lock), new_armed


class ColorTests(unittest.TestCase):
    def test_green_buy_only(self):
        self.assertEqual(detect_color(4401.20, 4401.0, 0.10), GREEN)
        close, enter = action_on_color(GREEN, 0, 2)
        self.assertEqual(close, "SELL")
        self.assertEqual(enter, "BUY")

    def test_red_sell_only(self):
        self.assertEqual(detect_color(4400.80, 4401.0, 0.10), RED)
        close, enter = action_on_color(RED, 2, 0)
        self.assertEqual(close, "BUY")
        self.assertEqual(enter, "SELL")

    def test_buffer_is_flat(self):
        self.assertEqual(detect_color(4401.05, 4401.0, 0.10), FLAT)
        close, enter = action_on_color(FLAT, 1, 0)
        self.assertEqual(close, "NONE")
        self.assertEqual(enter, "NONE")


class CapitalTests(unittest.TestCase):
    def test_ten_to_fifty_is_two_to_five(self):
        self.assertEqual(allowed_entries(10.0), 2)
        self.assertEqual(allowed_entries(50.0), 5)
        for eq in (15.0, 20.0, 30.0, 40.0, 50.0):
            n = allowed_entries(eq)
            self.assertGreaterEqual(n, 2)
            self.assertLessEqual(n, 5)

    def test_max_is_twenty(self):
        self.assertEqual(allowed_entries(800.0), 20)
        self.assertEqual(allowed_entries(5000.0), 20)

    def test_lot_grows_with_equity(self):
        self.assertEqual(lot_by_equity(10.0), 0.01)
        self.assertGreater(lot_by_equity(50.0), lot_by_equity(10.0))
        self.assertGreater(lot_by_equity(400.0), lot_by_equity(50.0))


class LockTests(unittest.TestCase):
    def test_example_buy_4401_close_at_4401_5(self):
        # BUY 4401, price 4401.5 -> profit 0.50, close at trigger
        close, armed = should_close(0.50, 0.50, 0.20, False, False)
        self.assertTrue(armed)
        self.assertTrue(close)

    def test_pullback_lock_to_4401_2(self):
        close, armed = should_close(0.50, 0.50, 0.20, False, True)
        self.assertTrue(armed)
        self.assertFalse(close)
        close, armed = should_close(0.20, 0.50, 0.20, armed, True)
        self.assertTrue(close)

    def test_not_positive_yet(self):
        close, armed = should_close(0.05, 0.50, 0.20, False, False)
        self.assertFalse(close)
        self.assertFalse(armed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
