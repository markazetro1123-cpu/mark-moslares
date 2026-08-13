#!/usr/bin/env python3
"""Pure-python mirrors of NY Sweep Hunter clock / sweep rules."""

from __future__ import annotations

import unittest


def in_minute_window(now_min: int, start_min: int, end_min: int) -> bool:
    if start_min == end_min:
        return True
    if start_min < end_min:
        return start_min <= now_min < end_min
    return now_min >= start_min or now_min < end_min


def active_range_day(local_day: int, now_min: int, trade_start: int, trade_end: int) -> int:
    day = local_day
    if trade_start > trade_end and now_min < trade_end:
        day -= 1
    return day


def range_window_closed(local_day: int, now_min: int, range_day: int, range_end: int) -> bool:
    if local_day > range_day:
        return True
    if local_day < range_day:
        return False
    return now_min >= range_end


def detect_setup(
    high: float,
    low: float,
    close: float,
    range_high: float,
    range_low: float,
    min_sweep: float,
    require_close_inside: bool,
    allow_breakout: bool,
) -> str | None:
    pierce_high = high - range_high
    pierce_low = range_low - low
    sell_sweep = pierce_high >= min_sweep
    buy_sweep = pierce_low >= min_sweep
    if require_close_inside:
        if close >= range_high:
            sell_sweep = False
        if close <= range_low:
            buy_sweep = False
    if sell_sweep:
        return "SELL_SWEEP"
    if buy_sweep:
        return "BUY_SWEEP"
    if allow_breakout:
        if close > range_high and pierce_high >= min_sweep:
            return "SELL_BREAK"
        if close < range_low and pierce_low >= min_sweep:
            return "BUY_BREAK"
    return None


def is_us30(symbol: str) -> bool:
    u = symbol.upper()
    if "US30" in u or "DJ30" in u or "DJIA" in u:
        return True
    if "WALLSTREET30" in u or "WST30" in u or "DOWJONES" in u:
        return True
    if "WALL" in u and "30" in u:
        return True
    return False


class ClockTests(unittest.TestCase):
    def test_ny_session_wraps_midnight(self):
        start, end = 20 * 60, 5 * 60
        self.assertTrue(in_minute_window(20 * 60, start, end))
        self.assertTrue(in_minute_window(23 * 60 + 59, start, end))
        self.assertTrue(in_minute_window(2 * 60, start, end))
        self.assertTrue(in_minute_window(4 * 60 + 59, start, end))
        self.assertFalse(in_minute_window(5 * 60, start, end))
        self.assertFalse(in_minute_window(12 * 60, start, end))
        self.assertFalse(in_minute_window(19 * 60 + 59, start, end))

    def test_overnight_uses_yesterday_range(self):
        start, end = 20 * 60, 5 * 60
        self.assertEqual(active_range_day(10, 21 * 60, start, end), 10)
        self.assertEqual(active_range_day(11, 2 * 60, start, end), 10)
        self.assertEqual(active_range_day(11, 5 * 60, start, end), 11)

    def test_range_closes_after_1600(self):
        self.assertFalse(range_window_closed(10, 15 * 60, 10, 16 * 60))
        self.assertTrue(range_window_closed(10, 16 * 60, 10, 16 * 60))
        self.assertTrue(range_window_closed(11, 2 * 60, 10, 16 * 60))


class SweepTests(unittest.TestCase):
    def test_buy_sweep_rejects_then_closes_inside(self):
        self.assertEqual(
            detect_setup(2650.2, 2648.2, 2649.4, 2652.0, 2649.0, 0.50, True, False),
            "BUY_SWEEP",
        )

    def test_sell_sweep_rejects_then_closes_inside(self):
        self.assertEqual(
            detect_setup(2652.8, 2650.5, 2651.2, 2652.0, 2649.0, 0.50, True, False),
            "SELL_SWEEP",
        )

    def test_close_outside_is_not_a_sweep(self):
        self.assertIsNone(
            detect_setup(2653.5, 2651.0, 2652.4, 2652.0, 2649.0, 0.50, True, False)
        )

    def test_breakout_optional(self):
        self.assertEqual(
            detect_setup(2653.5, 2651.0, 2652.4, 2652.0, 2649.0, 0.50, True, True),
            "SELL_BREAK",
        )

    def test_tiny_wick_ignored(self):
        self.assertIsNone(
            detect_setup(2652.2, 2649.1, 2650.0, 2652.0, 2649.0, 0.50, True, False)
        )


class SymbolTests(unittest.TestCase):
    def test_deriv_and_tickmill_aliases(self):
        self.assertTrue(is_us30("US30"))
        self.assertTrue(is_us30("Wall Street 30"))
        self.assertTrue(is_us30("WST30"))
        self.assertFalse(is_us30("XAUUSD"))
        self.assertFalse(is_us30("EURUSD"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
