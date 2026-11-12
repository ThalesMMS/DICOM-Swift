#!/usr/bin/env python3
"""Generate small synthetic #2380 JPEG pairs; djpeg must give identical pixels for every scan layout."""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


def run(args):
    return subprocess.check_output([str(x) for x in args], stderr=subprocess.PIPE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    out = parser.parse_args().output
    out.mkdir(parents=True, exist_ok=True)
    records = []
    with tempfile.TemporaryDirectory(prefix="jpeg-sequential-scans-") as directory:
        work = Path(directory)
        for sampling, width, height in [("1x1", 17, 19), ("2x2", 17, 19), ("2x1", 33, 9),
                                        ("1x2", 9, 33), ("4x1", 33, 17)]:
            pixels = bytes((x * (11 + c * 3) + y * (7 + c * 5) + x * y * (c + 1)) % 256
                           for y in range(height) for x in range(width) for c in range(3))
            source = work / "source.ppm"
            source.write_bytes(f"P6\n{width} {height}\n255\n".encode() + pixels)
            layouts = {"interleaved": "0 1 2: 0-63 0 0;", "separate": "0: 0-63 0 0; 1: 0-63 0 0; 2: 0-63 0 0;"}
            if sampling == "2x2":
                layouts.update({"mixed_y": "0: 0-63 0 0; 1 2: 0-63 0 0;",
                                "mixed_ycb": "0 1: 0-63 0 0; 2: 0-63 0 0;"})
            reference = None
            for layout, script in layouts.items():
                name = f"sequential_{sampling}_{layout}"
                scans = work / "scans.txt"
                scans.write_text(script + "\n")
                jpeg = out / f"{name}.jpg"
                # One MCU row per restart: DRI changes with the scan's component grid.
                run(["cjpeg", "-quality", "83", "-sample", sampling, "-optimize", "-restart", "1",
                     "-scans", scans, "-outfile", jpeg, source])
                decoded = run(["djpeg", "-dct", "int", jpeg])
                if reference is None:
                    reference = decoded
                if decoded != reference:
                    raise RuntimeError(f"Independent decoder pixels differ for {name}")
                records.append({"name": name, "reference": f"sequential_{sampling}_interleaved",
                                "width": width, "height": height, "scans": script,
                                "jpegSHA256": hashlib.sha256(jpeg.read_bytes()).hexdigest(),
                                "djpegPPMSHA256": hashlib.sha256(decoded).hexdigest()})
    report = {"generator": "jpeg_sequential_scans_corpus.py", "cjpeg": subprocess.check_output(["cjpeg", "-version"], stderr=subprocess.STDOUT).decode().strip(),
              "cases": records}
    (out / "JPEGSequentialScans.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {len(records)} JPEGs; every layout matches its interleaved reference in djpeg")


if __name__ == "__main__":
    main()
