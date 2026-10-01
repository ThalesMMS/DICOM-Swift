#!/usr/bin/env python3
"""Qualify the own VarDCT encoder on the retained sources of the libjxl lossy corpus (#2376).

Generate the corpus with DICOM_JPEGXL_KEEP_SOURCE=1. Compare the same source and distance with
effort 7 in both encoders. Decoder-feature flags in the manifest (resampling, progressive passes,
noise, etc.) identify source cases; they do not change this common encoder comparison. Measure
PSNR against the original samples and payload size with even-byte DICOM padding on both sides.
Every own stream must be accepted by djxl, have PSNR >= cjxl - 0.5 dB and size <= 1.25 * cjxl.
The JSON records all cases, including failures, and contains no source or reconstructed pixels.
"""

import argparse
import hashlib
import json
import shutil
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from image_iod_oracle import require
from jpegxl_modular_oracle import GENERAL, fragments_of, native_dicom, read_part10, read_pnm, run
from jpegxl_vardct_oracle import djxl, psnr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for tool in ("cjxl", "djxl"):
        require(shutil.which(tool) is not None, f"{tool} is required")
    cases = json.loads((args.corpus / "manifest.json").read_text())
    require(len(cases) == 68, f"Expected the complete 68-case corpus, found {len(cases)}")
    records = []
    versions = {}
    for tool in ("cjxl", "djxl"):
        _, output, error = run([tool, "--version"])
        versions[tool] = (output.decode("utf-8", errors="replace") + error).strip().splitlines()[0]
    report = {"expectedCases": len(cases), "complete": False, "passed": False,
              "generatedAt": datetime.now(timezone.utc).isoformat(),
              "binarySHA256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "references": versions,
              "protocol": "same source, distance and effort 7; even-byte DICOM payload sizes; PSNR against source",
              "cases": records}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2))
    with tempfile.TemporaryDirectory(prefix="isis-jpegxl-rate-distortion-") as temporary:
        work = Path(temporary)
        for case in cases:
            name, bits, flags = case["name"], case["bits"], case["flags"]
            work = Path(temporary) / name
            work.mkdir()
            source = args.corpus / f"{name}.src.pnm"
            require(source.is_file(), f"Missing {source}; regenerate with DICOM_JPEGXL_KEEP_SOURCE=1")
            array, max_value = read_pnm(source)
            require(max_value == (1 << bits) - 1, f"{name}: unexpected source precision")
            distance = float(flags[flags.index("-d") + 1]) if "-d" in flags else 1.0
            if "-q" in flags:
                quality = float(flags[flags.index("-q") + 1])
                require(quality == 90, f"{name}: unsupported quality-to-distance conversion")
            native, compressed = work / "native.dcm", work / "compressed.dcm"
            native_dicom(native, array, bits, False, "RGB" if case["channels"] == 3 else "MONOCHROME2")
            started = time.perf_counter()
            code, _, error = run([args.binary, "codec", "transcode", native, "--output", compressed,
                                  "--transfer-syntax", GENERAL, "--distance", str(distance), "--effort", "7",
                                  "--format", "json"])
            encode_ms = (time.perf_counter() - started) * 1000
            require(code == 0, f"{name}: own encoder rejected the source: {error}")
            dataset = read_part10(compressed)
            require(int(dataset.BitsStored) == bits, f"{name}: changed Bits Stored")
            require((int(dataset.Rows), int(dataset.Columns)) == array.shape[:2], f"{name}: changed dimensions")
            require(str(dataset.LossyImageCompression) == "01", f"{name}: missing lossy record")
            fragments = fragments_of(dataset)
            require(len(fragments) == 1, f"{name}: unexpected fragment count")
            own = djxl(work, "own", fragments[0], bits)
            reference_stream = work / "reference.jxl"
            code, _, error = run(["cjxl", source, reference_stream, "--container=0", "--quiet",
                                  "-d", str(distance), "-e", "7", "--num_threads=1"])
            require(code == 0, f"{name}: cjxl rejected the source: {error}")
            reference_bytes = reference_stream.read_bytes()
            reference = djxl(work, "reference-decoded", reference_bytes, bits)
            own_psnr, reference_psnr = float(psnr(array, own, bits)), float(psnr(array, reference, bits))
            reference_size = (len(reference_bytes) + 1) & ~1
            ratio = len(fragments[0]) / reference_size
            margin = own_psnr - reference_psnr
            record = {"name": name, "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                      "sourceCaseFlags": flags, "bitsStored": bits, "distance": distance, "effort": 7,
                      "ownPayloadBytes": len(fragments[0]), "referencePayloadBytes": reference_size,
                      "sizeRatio": ratio, "ownPSNR": own_psnr, "referencePSNR": reference_psnr,
                      "psnrMarginDb": margin, "encodeMilliseconds": encode_ms,
                      "djxlAccepted": True, "passed": ratio <= 1.25 and margin >= -0.5}
            records.append(record)
            report["complete"] = len(records) == len(cases)
            report["passed"] = report["complete"] and all(r["passed"] for r in records)
            args.output.write_text(json.dumps(report, indent=2))
            print(f"{name}: ratio={ratio:.3f}, PSNR margin={margin:+.3f} dB, passed={record['passed']}", flush=True)
    failures = [r["name"] for r in records if not r["passed"]]
    require(not failures, f"Rate/fidelity acceptance failed for {len(failures)}/{len(records)} cases: {', '.join(failures)}")
    print(f"PASS: {len(records)} own DICOM payloads meet size, fidelity and independent decode acceptance")


if __name__ == "__main__":
    main()
