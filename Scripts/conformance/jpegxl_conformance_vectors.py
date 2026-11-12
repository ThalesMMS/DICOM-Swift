#!/usr/bin/env python3
"""Prepare the official libjxl conformance vectors for `JPEGXLConformanceVectorTests` (#3245).

`--directory` holds `<name>/input.jxl` and `<name>/test.json` from https://github.com/libjxl/conformance
(`testcases/`). For every vector this writes the djxl 0.12 reference decode (`reference.pnm`, colour channels at the
codestream's bit depth, alpha dropped) and, when the vector carries a JPEG reconstruction, the JPEG djxl rebuilds
(`reference.jpg`). The Swift test compares the own decoder against these files; set
DICOM_JPEGXL_CONFORMANCE_DIRECTORY to the same directory.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if shutil.which("djxl") is None:
        raise SystemExit("djxl is required")
    summary = {}
    for case in sorted(p for p in args.directory.iterdir() if (p / "input.jxl").is_file()):
        meta = json.loads((case / "test.json").read_text()) if (case / "test.json").is_file() else {}
        status = []
        pnm = subprocess.run(["djxl", case / "input.jxl", case / "reference.pnm", "--quiet"], capture_output=True)
        status.append("pnm" if pnm.returncode == 0 else "pnm-refused")
        if meta.get("reconstructed_jpeg"):
            jpg = subprocess.run(["djxl", case / "input.jxl", case / "reference.jpg", "--quiet"], capture_output=True)
            status.append("jpeg" if jpg.returncode == 0 else "jpeg-refused")
        summary[case.name] = status
    (args.directory / "references.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
