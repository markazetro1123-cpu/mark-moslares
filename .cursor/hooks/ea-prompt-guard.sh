#!/usr/bin/env bash
# beforeSubmitPrompt: reinforce EA brain when trading/EA prompts arrive
set -euo pipefail
input=$(cat)
printf '%s' "$input" | python3 -c '
import json, re, sys
try:
    data = json.loads(sys.stdin.read() or "{}")
except Exception:
    data = {}

prompt = data.get("prompt") or data.get("text") or data.get("content") or ""
if isinstance(data.get("args"), dict):
    prompt = prompt or data["args"].get("prompt") or ""

p = prompt.lower() if isinstance(prompt, str) else ""
keywords = (
    "ea", "scalp", "xau", "gold", "us30", "wall street", "deriv",
    "lot", "martingale", "bulk close", "impulse", "expertgold", "mt5", "mql"
)
hit = any(k in p for k in keywords)

out = {}
if hit:
    out["additional_context"] = (
        "Apply limitless-scalp-brain + ea-north-star: "
        "video-style impulse stack + bulk close, but $10-safe MM, "
        "direction confirmation before entry, MaxLayers 1-2, "
        "symbols XAUUSD + Wall Street 30 (Deriv), no martingale defaults."
    )
    if re.search(r"\b(1\.0{0,2}\s*lot|lot\s*1\b|martingale|unlimited\s+entr)", p):
        out["additional_context"] += (
            " WARNING: user asked for high-risk sizing — require explicit opt-in "
            "and keep hard caps; do not silently enable."
        )
print(json.dumps(out))
'
