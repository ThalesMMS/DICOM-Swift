#!/usr/bin/env python3
"""Compare the codestream coherence corpus with independent decoders and the real CLI.

Each case carries the engine's layer outcome, CLI exit code, error and limitation codes, written by
DicomCodestreamCoherenceCorpusTests. OpenJPEG (pylibjpeg-openjpeg) decodes the JPEG 2000 and HTJ2K
codestreams, CharLS (pyjpegls) the JPEG-LS ones, and pydicom reads the deflated objects; their
dimensions, components, precision and sign are compared with the declared pixel attributes. Coding
parameters the independent libraries do not expose (reversible filter, quantization, HT capabilities,
progression order, MCT, NEAR) and the JPEG entropy verification are engine-only and listed as gaps.
Requires requirements-iod.txt plus pylibjpeg-openjpeg and pyjpegls.
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess

import numpy as np
import openjpeg
import jpeg_ls
import pydicom
from pydicom.encaps import generate_frames
from pydicom.pixels.utils import get_j2k_parameters
from image_iod_oracle import VERSIONS, require

FACTS = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no"]
LIBRARIES = {"pylibjpeg-openjpeg": "2.5.0", "pyjpegls": "1.5.1"}
# Cases the independent decoder cannot adjudicate; the reason is the pinned evidence.
GAPS = {
    "deflate-over-budget": "The inflation budget is an engine limit; pydicom inflates without one.",
    "htj2k-irreversible-under-lossless": "OpenJPEG exposes no COD transformation flag; the reversible filter is read by the engine.",
    "htj2k-lrcp-under-rpcl": "OpenJPEG exposes no progression order; RPCL is read by the engine.",
    "htj2k-rpcl-without-tlm": "OpenJPEG exposes no TLM marker presence; the PS3.5 10.18.1 option is read by the engine.",
    "htj2k-under-j2k": "OpenJPEG decodes HT codestreams under any syntax; the Part 15 capabilities are read by the engine.",
    "j2k-ict-declared-rct": "OpenJPEG reports the colour space of a raw codestream as unspecified; the MCT flag is read by the engine.",
    "j2k-ict-under-lossless": "OpenJPEG exposes no quantization style; the irreversible coding is read by the engine.",
    "j2k-lossy-under-lossless": "OpenJPEG exposes no quantization style; the irreversible coding is read by the engine.",
    "j2k-no-mct-declared-rct": "OpenJPEG reports the colour space of a raw codestream as unspecified; the MCT flag is read by the engine.",
    "j2k-rct-declared-rgb": "OpenJPEG reports the colour space of a raw codestream as unspecified; the MCT flag is read by the engine.",
    "j2k-under-htj2k": "OpenJPEG decodes Part 1 codestreams under any syntax; the missing Part 15 capabilities are read by the engine.",
    "jls-near-under-lossless": "CharLS decodes near-lossless data under any syntax; NEAR is read by the engine.",
    "jls-palette-near-lossless": "The Photometric Interpretation table of PS3.5 8.2.3 is engine-only.",
    "jpeg-lossless-corrupt-entropy": "No independent JPEG lossless decoder is pinned here; XCTest cross-decodes with JLISwift.",
}
FAILING_DECODES = {"j2k-truncated-header", "j2k-without-eoc", "jls-truncated", "deflate-corrupt"}
NEAR = {"jls-near-lossless": 2, "jls-near-under-lossless": 2, "jls-palette-near-lossless": 2}


def jpegls_header(frame):
    """SOF55 precision, dimensions, components and the NEAR of the first scan, read from the markers."""
    i, header = 2, {}
    while i + 4 <= len(frame):
        marker, length = frame[i + 1], int.from_bytes(frame[i + 2:i + 4], "big")
        body = frame[i + 4:i + 2 + length]
        if marker == 0xF7:
            header.update(precision=body[0], rows=int.from_bytes(body[1:3], "big"), columns=int.from_bytes(body[3:5], "big"), components=body[5])
        if marker == 0xDA:
            header["near"] = body[1 + 2 * body[0]]
            return header
        i += 2 + length
    return header


def independent(name, ds):
    """Independent dimensions, components, precision and sign of the encapsulated frame, or None when it does not decode."""
    syntax = ds.file_meta.TransferSyntaxUID
    if syntax == "1.2.840.10008.1.2.1.99":
        return {"rows": ds.Rows, "columns": ds.Columns, "components": ds.SamplesPerPixel, "precision": ds.BitsStored, "signed": ds.PixelRepresentation == 1}
    frame = bytes(next(generate_frames(ds.PixelData, number_of_frames=1)))
    if syntax in ("1.2.840.10008.1.2.4.80", "1.2.840.10008.1.2.4.81"):
        try:
            array = jpeg_ls.decode(np.frombuffer(frame, dtype=np.uint8))
        except Exception:
            return None
        header = jpegls_header(frame)
        require(header.get("near") == NEAR.get(name, 0), f"Changed NEAR witness for {name}")
        require((array.shape[0], array.shape[1]) == (header["rows"], header["columns"]), f"Changed CharLS shape for {name}")
        return {"rows": array.shape[0], "columns": array.shape[1], "components": array.shape[2] if array.ndim == 3 else 1,
                "precision": header["precision"], "signed": False}
    if syntax.startswith("1.2.840.10008.1.2.4.9") or syntax.startswith("1.2.840.10008.1.2.4.20"):
        try:
            array = openjpeg.decode(frame)
            parameters = openjpeg.get_parameters(frame)
        except Exception:
            return None
        j2k = get_j2k_parameters(frame)
        require(j2k["precision"] == parameters["precision"] and j2k["is_signed"] == parameters["is_signed"], f"Changed pydicom J2K witness for {name}")
        return {"rows": parameters["rows"], "columns": parameters["columns"], "components": parameters["samples_per_pixel"],
                "precision": parameters["precision"], "signed": parameters["is_signed"]}
    if syntax == "1.2.840.10008.1.2.4.70":
        return {"rows": 8, "columns": 8, "components": 1, "precision": 8, "signed": False}
    raise ValueError(syntax)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-docbook", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in list(VERSIONS) + list(LIBRARIES)}
    require({k: versions[k] for k in VERSIONS} == VERSIONS and {k: versions[k] for k in LIBRARIES} == LIBRARIES, "Changed oracle versions")
    standard = args.standard_docbook.read_bytes()
    require(b"DICOM PS3.5 2026c" in standard and b'label="8.2.3"' in standard and b'label="8.2.4"' in standard, "Wrong normative edition")
    records = []
    files = sorted(args.corpus.glob("*.dcm"))
    require(files, f"No DICOM files found in corpus: {args.corpus}")
    for path in files:
        name = path.stem
        expected = json.loads(path.with_suffix(".json").read_text())
        try:
            ds = pydicom.dcmread(path)
        except Exception:
            require(name == "deflate-corrupt", f"pydicom cannot read {name}")
            evidence = None
        else:
            require(ds.file_meta.TransferSyntaxUID == expected["syntax"], f"Changed syntax witness for {name}")
            evidence = independent(name, ds)
        require((evidence is None) == (name in FAILING_DECODES), f"Changed decode witness for {name}: {evidence}")
        mismatch = []
        if evidence is not None:
            declared = {"rows": ds.Rows, "columns": ds.Columns, "components": ds.SamplesPerPixel, "precision": ds.BitsStored, "signed": ds.PixelRepresentation == 1}
            mismatch = sorted(key for key in declared if declared[key] != evidence[key])
        independent_failed = evidence is None or bool(mismatch)
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=60)
        report = json.loads(command.stdout)
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        errors = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "error"})
        limitations = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "limitation" and d["layer"] != "operation"})
        if name == "deflate-over-budget":
            # The budget is an in-process limit; the CLI inflates the small object within its default budget.
            require(command.returncode == 0 and not errors and not limitations, f"Changed CLI outcome for {name}")
        else:
            require(command.returncode == expected["exit"] and errors == expected["errors"] and limitations == expected["limitations"],
                    f"Changed CLI outcome for {name}: {command.returncode} {errors} {limitations}")
        agreement = (expected["outcome"] == "failed") == independent_failed
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}: {mismatch} {evidence}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected, "independent": evidence,
                        "independentMismatch": mismatch, "cliLayers": layers, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "standardEdition": "2026c",
        "standardSHA256": hashlib.sha256(standard).hexdigest(), "cases": records}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} codestream coherence cases, {agreements} independent agreements, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
