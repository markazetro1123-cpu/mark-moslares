#!/usr/bin/env python3
"""Static checks for a single-file MQL5 Expert Advisor (no MetaEditor in this VM)."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REQUIRED_HANDLERS = ("OnInit", "OnDeinit", "OnTick")
FORBIDDEN = (
    "OrderSend(",  # MT4
    "OrderSelect(i, SELECT_BY_POS",
    "Ask",
    "Bid",
    "Point",
    "Digits",
)


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    lines = []
    for line in src.splitlines():
        if "//" in line:
            line = line[: line.find("//")]
        lines.append(line)
    return "\n".join(lines)


def brace_balance(src: str) -> int:
    return src.count("{") - src.count("}")


def paren_balance(src: str) -> int:
    return src.count("(") - src.count(")")


def check(path: Path) -> list[str]:
    errors: list[str] = []
    raw = path.read_text(encoding="utf-8")
    code = strip_comments(raw)

    if "#include <Trade/Trade.mqh>" not in raw:
        errors.append("missing #include <Trade/Trade.mqh>")
    if '#property copyright "Mark Moslares"' not in raw:
        errors.append("missing Mark Moslares copyright")

    for name in REQUIRED_HANDLERS:
        if not re.search(rf"\b{name}\s*\(", code):
            errors.append(f"missing handler {name}()")

    bal = brace_balance(code)
    if bal != 0:
        errors.append(f"unbalanced braces: {bal:+d}")
    pbal = paren_balance(code)
    if pbal != 0:
        errors.append(f"unbalanced parentheses: {pbal:+d}")

    # Crude MT4 leftovers outside strings
    for token in ("OrderSend(", "SELECT_BY_POS"):
        if token in code:
            errors.append(f"MT4-style call found: {token}")

    if "CTrade" not in code:
        errors.append("CTrade is not used")

    inputs = re.findall(r"^\s*input\s+", raw, flags=re.M)
    if len(inputs) < 20:
        errors.append(f"too few inputs: {len(inputs)}")

    if "InpMagic" not in raw:
        errors.append("missing InpMagic")

    return errors


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_mql5_syntax.py <file.mq5> [...]")
        return 2
    failed = 0
    for arg in sys.argv[1:]:
        path = Path(arg)
        if not path.is_file():
            print(f"FAIL {path}: not a file")
            failed += 1
            continue
        errors = check(path)
        if errors:
            print(f"FAIL {path}")
            for err in errors:
                print(f"  - {err}")
            failed += 1
        else:
            print(f"OK   {path} ({path.stat().st_size} bytes)")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
