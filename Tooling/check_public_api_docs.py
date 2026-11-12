#!/usr/bin/env python3
"""Check that public Swift declarations have DocC comments."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


PUBLIC_DECLARATION = re.compile(
    r"^\s*public\s+(?:final\s+|open\s+|static\s+|class\s+|struct\s+|enum\s+|actor\s+|protocol\s+|"
    r"func\s+|var\s+|let\s+|init\b)"
)
DECLARATION_NAME = re.compile(
    r"\b(?:class|struct|enum|actor|protocol|func|var|let|init)\s+([A-Za-z_][A-Za-z0-9_]*)?"
)


def has_doc_comment(lines: list[str], index: int) -> bool:
    cursor = index - 1
    while cursor >= 0:
        stripped = lines[cursor].strip()
        if not stripped:
            cursor -= 1
            continue
        return stripped.startswith("///")
    return False


def declaration_name(line: str) -> str:
    match = DECLARATION_NAME.search(line)
    if not match:
        return line.strip()
    return match.group(1) or "init"


def check_file(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    failures: list[str] = []

    for index, line in enumerate(lines):
        if not PUBLIC_DECLARATION.search(line):
            continue
        if has_doc_comment(lines, index):
            continue
        failures.append(
            f"{path}:{index + 1}: public API declaration needs a DocC comment: {declaration_name(line)}"
        )

    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--paths", nargs="+", required=True)
    args = parser.parse_args()

    failures: list[str] = []
    for raw_path in args.paths:
        path = Path(raw_path)
        if path.suffix == ".swift":
            failures.extend(check_file(path))

    if failures:
        for failure in failures:
            print(failure)
        return 1

    print("public API documentation gate passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
