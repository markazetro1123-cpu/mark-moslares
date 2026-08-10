#!/usr/bin/env bash
# sessionStart: inject Limitless Scalp EA project context
set -euo pipefail
cat >/dev/null
python3 - <<'PY'
import json
print(json.dumps({
    "additional_context": (
        "Project: Limitless Scalp EA (MT5/Deriv). "
        "Behavior class: impulse/fluctuation scalp + capped same-side stack + bulk close on profit "
        "(ExpertGold1-style, safer MM). "
        "Defaults: start capital $10, min/micro lots, MaxLayers 1-2, no martingale. "
        "Symbols: XAUUSD/gold alias + Wall Street 30 (US30 on Deriv). "
        "Skills: limitless-scalp-brain, impulse-scalp-ea, expertgold1-video-scalp. "
        "Rules: ea-north-star, mql5-ea-standards. "
        "Runtime: desktop/VPS EA; mobile monitor-only."
    )
}))
PY
