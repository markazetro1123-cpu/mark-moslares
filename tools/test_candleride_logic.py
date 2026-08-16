#!/usr/bin/env python3
"""Pure-python mirrors of Candle Ride Scalper v1.10 rules."""

from __future__ import annotations

import unittest

FLAT, GREEN, RED = 0, 1, 2


def detect_color(mid: float, open_price: float, buffer: float) -> int:
    if mid > open_price + buffer:
        return GREEN
    if mid < open_price - buffer:
        return RED
    return FLAT


def action_on_color(color: int, buys: int, sells: int) -> tuple[str, str]:
    if color == GREEN:
        return ("SELL" if sells > 0 else "NONE", "BUY")
    if color == RED:
        return ("BUY" if buys > 0 else "NONE", "SELL")
    return "NONE", "NONE"


def allowed_entries(equity: float) -> int:
    n = 2
    if equity >= 25:
        n = 3
    if equity >= 50:
        n = 5
    if equity >= 100:
        n = 7
    if equity >= 200:
        n = 10
    if equity >= 400:
        n = 13
    if equity >= 800:
        n = 16
    if equity >= 1500:
        n = 18
    if equity >= 3000:
        n = 20
    return n


def lot_by_equity(equity: float, cap: float = 10.0) -> float:
    lot = 0.01
    if equity >= 25:
        lot = 0.02
    if equity >= 50:
        lot = 0.03
    if equity >= 100:
        lot = 0.05
    if equity >= 200:
        lot = 0.10
    if equity >= 400:
        lot = 0.20
    if equity >= 800:
        lot = 0.40
    if equity >= 1500:
        lot = 0.80
    if equity >= 3000:
        lot = 1.50
    if equity >= 5000:
        lot = 3.00
    if equity >= 10000:
        lot = 6.00
    if equity >= 20000:
        lot = 10.00
    return min(lot, cap)


def is_watched_news(name: str) -> bool:
    u = name.upper()
    keys = (
        "CPI",
        "CONSUMER PRICE",
        "NON-FARM",
        "NONFARM",
        "NON FARM",
        "NFP",
        "PAYROLL",
        "UNEMPLOYMENT",
        "FEDERAL FUNDS",
        "INTEREST RATE",
        "RATE DECISION",
        "FOMC",
    )
    return any(k in u for k in keys)


def in_news_window(now: int, event: int, wait_sec: int = 600) -> bool:
    return event <= now < event + wait_sec


def can_enter(lock_closed_this_bar: bool, cooldown_bars: int, news_block: bool) -> bool:
    if lock_closed_this_bar or cooldown_bars > 0 or news_block:
        return False
    return True


def on_new_candle(lock_closed_this_bar: bool, cooldown_bars: int) -> tuple[bool, int, bool]:
    """Return (wipe_leftovers, new_cooldown, new_lock_closed)."""
    wipe = True
    if lock_closed_this_bar:
        return wipe, cooldown_bars, False
    if cooldown_bars > 0:
        cooldown_bars -= 1
    return wipe, cooldown_bars, False


class ColorTests(unittest.TestCase):
    def test_green_buy_and_flip_from_sell(self):
        self.assertEqual(detect_color(4401.20, 4401.0, 0.10), GREEN)
        close, enter = action_on_color(GREEN, 0, 2)
        self.assertEqual(close, "SELL")
        self.assertEqual(enter, "BUY")

    def test_red_closes_buy_opens_sell(self):
        close, enter = action_on_color(RED, 2, 0)
        self.assertEqual(close, "BUY")
        self.assertEqual(enter, "SELL")


class CapitalTests(unittest.TestCase):
    def test_locked_table(self):
        self.assertEqual((lot_by_equity(10), allowed_entries(10)), (0.01, 2))
        self.assertEqual((lot_by_equity(25), allowed_entries(25)), (0.02, 3))
        self.assertEqual((lot_by_equity(50), allowed_entries(50)), (0.03, 5))
        self.assertEqual((lot_by_equity(200), allowed_entries(200)), (0.10, 10))
        self.assertEqual((lot_by_equity(20000), allowed_entries(20000)), (10.0, 20))
        self.assertEqual(lot_by_equity(50000), 10.0)


class CycleTests(unittest.TestCase):
    def test_lock_then_one_candle_cooldown(self):
        self.assertFalse(can_enter(True, 1, False))
        wipe, cd, lock = on_new_candle(True, 1)
        self.assertTrue(wipe)
        self.assertEqual(cd, 1)
        self.assertFalse(lock)
        self.assertFalse(can_enter(lock, cd, False))
        wipe, cd, lock = on_new_candle(False, 1)
        self.assertEqual(cd, 0)
        self.assertTrue(can_enter(lock, cd, False))

    def test_new_candle_wipes_then_can_enter(self):
        wipe, cd, lock = on_new_candle(False, 0)
        self.assertTrue(wipe)
        self.assertTrue(can_enter(lock, cd, False))


class NewsTests(unittest.TestCase):
    def test_watched_names(self):
        self.assertTrue(is_watched_news("CPI y/y"))
        self.assertTrue(is_watched_news("Non-Farm Payrolls"))
        self.assertTrue(is_watched_news("Unemployment Rate"))
        self.assertTrue(is_watched_news("Fed Interest Rate Decision"))
        self.assertFalse(is_watched_news("Retail Sales"))

    def test_enter_only_after_10_minutes(self):
        event = 1000
        self.assertTrue(in_news_window(1000, event, 600))
        self.assertTrue(in_news_window(1599, event, 600))
        self.assertFalse(in_news_window(1600, event, 600))
        self.assertFalse(can_enter(False, 0, True))
        self.assertTrue(can_enter(False, 0, False))


if __name__ == "__main__":
    unittest.main(verbosity=2)
