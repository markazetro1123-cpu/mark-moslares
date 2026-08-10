#!/usr/bin/env python3
"""Validate the design-stage Cursor configuration without external packages."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CURSOR = ROOT / ".cursor"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"ERROR: {message}")


def frontmatter(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    require(text.startswith("---\n"), f"{path} has no YAML frontmatter")
    parts = text.split("---\n", 2)
    require(len(parts) == 3, f"{path} has malformed frontmatter")
    values: dict[str, str] = {}
    for line in parts[1].splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            values[key.strip()] = value.strip().strip("\"'")
    return values


def validate_environment() -> None:
    data = json.loads((CURSOR / "environment.json").read_text(encoding="utf-8"))
    require(data.get("name") == "Limitless Scalp EA", "unexpected environment name")
    require("install" in data, "environment install command is missing")


def validate_skills() -> None:
    for path in sorted((CURSOR / "skills").glob("*/SKILL.md")):
        meta = frontmatter(path)
        name = meta.get("name", "")
        require(
            re.fullmatch(r"[a-z0-9-]{1,64}", name) is not None,
            f"{path} has invalid skill name",
        )
        require(bool(meta.get("description")), f"{path} has no description")
        require(
            len(path.read_text(encoding="utf-8").splitlines()) < 500,
            f"{path} exceeds 500 lines",
        )


def validate_rules() -> None:
    for path in sorted((CURSOR / "rules").glob("*.mdc")):
        meta = frontmatter(path)
        require(bool(meta.get("description")), f"{path} has no description")
        require(
            "alwaysApply" in meta or "globs" in meta,
            f"{path} has neither alwaysApply nor globs",
        )


def validate_hooks() -> None:
    hooks = json.loads((CURSOR / "hooks.json").read_text(encoding="utf-8"))
    require(hooks.get("version") == 1, "hooks.json must use version 1")
    for path in sorted((CURSOR / "hooks").glob("*.sh")):
        subprocess.run(["bash", "-n", str(path)], check=True)


def validate_behavior_contract() -> None:
    spec = ROOT / "docs" / "FINAL_BEHAVIOR_SPEC.md"
    require(spec.exists(), "final behavior specification is missing")
    text = spec.read_text(encoding="utf-8")
    for phrase in (
        "The EA must **not** enter on every fluctuation",
        "Phase 1 entry threshold: **75/100**",
        "For equity below $20, the default is **one layer**",
        "Wall Street 30",
    ):
        require(phrase in text, f"behavior contract missing: {phrase}")

    audit = ROOT / "docs" / "REPLICATION_AUDIT.md"
    require(audit.exists(), "replication audit is missing")
    audit_text = audit.read_text(encoding="utf-8")
    for phrase in (
        "100% specification fidelity",
        "We must not claim 100% profit fidelity",
        "Telemetry and Replay Engine",
        "Pre-code acceptance gate",
    ):
        require(phrase in audit_text, f"replication audit missing: {phrase}")


def main() -> None:
    validate_environment()
    validate_skills()
    validate_rules()
    validate_hooks()
    validate_behavior_contract()
    print("Workspace validation passed.")


if __name__ == "__main__":
    main()
