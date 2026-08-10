#!/usr/bin/env bash
# afterFileEdit: warn on unsafe EA lot/martingale patterns in MQL5 edits
set -euo pipefail
input=$(cat)
printf '%s' "$input" | python3 -c '
import json, re, sys
try:
    data = json.loads(sys.stdin.read() or "{}")
except Exception:
    data = {}

path = data.get("file_path") or data.get("path") or data.get("file") or ""
for key in ("args", "tool_input", "input"):
    nested = data.get(key) or {}
    if isinstance(nested, dict):
        path = path or nested.get("path") or nested.get("file_path") or ""

text = data.get("content") or data.get("diff") or ""
if isinstance(data.get("args"), dict):
    text = text or data["args"].get("content") or ""

blob = text if isinstance(text, str) else ""
try:
    if path:
        blob += "\n" + open(path, "r", errors="ignore").read()
except Exception:
    pass

is_mql = bool(re.search(r"\.(mq5|mqh)$", path or "", re.I)) or bool(
    re.search(r"\b(OnTick|CTrade|OrderSend)\b", blob)
)

warnings = []
if is_mql and blob:
    if re.search(r"\b(lot|Lots|InpLot)\b[^\n;=]{0,40}[= ]+1(\.0+)?\b", blob):
        warnings.append(
            "Hardcoded ~1.0 lot detected — forbidden on $10 capital profile; use MoneyManager min/normalized lot."
        )
    if re.search(r"martingale|lot\s*\*=\s*2|LotMultiplier|double_down", blob, re.I):
        warnings.append("Martingale-like sizing pattern detected — default policy is OFF.")
    if re.search(r"MaxLayers\s*=\s*([5-9]|\d{2,})", blob):
        warnings.append("High MaxLayers — keep 1-2 on small capital unless explicitly opted in.")

out = {}
if warnings:
    out["additional_context"] = "EA risk lint: " + " ".join(warnings) + " Follow ea-north-star + limitless-scalp-brain."
print(json.dumps(out))
'
