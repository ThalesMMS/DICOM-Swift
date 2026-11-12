#!/usr/bin/env python3
"""Clinical qualification gate of the own JPEG XL codec against libjxl 0.12 (#3245).

Every Part 10 file of --corpus (clinical CT/MR/PET/CR/XA/SC objects: 8 to 16 bits stored, signed and unsigned,
MONOCHROME1/2, RGB8, multi-frame, odd dimensions, any source syntax the own toolkit decodes) is taken to its native
pixels with `dicomtool codec transcode` and then checked in both directions for the three JPEG XL syntaxes:

* `.110` (and reversible `.112`): the own encoder's fragments decode exactly with `djxl`; a `cjxl -d 0` codestream of
  the same frame, wrapped in a Part 10 object, decodes exactly with `dicomtool codec decode`.
* `.112` irreversible VarDCT: a `cjxl -d 1` codestream decodes with the own decoder within one code of `djxl`; where
  the own encoder qualifies (Bits Stored equal to Bits Allocated), its `--distance 1` output decodes the same way.
* `.111`: each 8-bit frame is compressed by libjpeg (`cjpeg`, baseline, with and without restart intervals), wrapped
  as `.50`, recompressed to `.111` by the own codec; `djxl` must reconstruct the original JPEG byte for byte and the
  own `.111` -> `.50` route must give back the same fragment.

Tolerances: exact for Modular and `.111`, one stored-sample code for VarDCT. Byte sizes are compared with
`cjxl -e 7`. Only counts, maxima and sizes are written, never identifiers.
"""
import argparse
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

import numpy as np
import pydicom
from pydicom.encaps import encapsulate
from pydicom.uid import ExplicitVRLittleEndian

from image_iod_oracle import require
import jpegxl_modular_oracle
from jpegxl_modular_oracle import (GENERAL, LOSSLESS, dicom_wrap, djxl_decode, fragments_of, our_decode, read_part10,
                                   read_pnm, run, write_part10, write_pnm)

RECOMPRESSION = "1.2.840.10008.1.2.4.111"
BASELINE = "1.2.840.10008.1.2.4.50"
if RECOMPRESSION not in pydicom.uid.AllTransferSyntaxes:
    pydicom.uid.register_transfer_syntax(RECOMPRESSION, implicit_vr=False, little_endian=True)
# The gate runs the codec as shipped: no DICOM_JXLSWIFT_MODE, so the default (preferred) applies.
jpegxl_modular_oracle.ENVIRONMENT.pop("DICOM_JXLSWIFT_MODE", None)


def frames_of(ds):
    """Native frames as int64 arrays (rows, columns[, 3]), signed values as stored."""
    rows, columns = int(ds.Rows), int(ds.Columns)
    frames = int(getattr(ds, "NumberOfFrames", 1) or 1)
    samples = int(getattr(ds, "SamplesPerPixel", 1))
    signed = int(getattr(ds, "PixelRepresentation", 0)) == 1
    allocated = int(ds.BitsAllocated)
    dtype = ("<i2" if signed else "<u2") if allocated == 16 else np.uint8
    count = rows * columns * samples * frames
    array = np.frombuffer(bytes(ds.PixelData)[:count * (2 if allocated == 16 else 1)], dtype=dtype).astype(np.int64)
    shape = (frames, rows, columns, samples) if samples == 3 else (frames, rows, columns)
    return array.reshape(shape)


def stored(array, precision, signed):
    """Samples as the codestream carries them: Bits Stored wide and unsigned (the sign is a level shift)."""
    mask = (1 << precision) - 1
    if signed:
        return (array + (1 << (precision - 1))) & mask
    return array & mask


def cjxl(work, name, array, precision, flags):
    source = work / f"{name}.{'ppm' if array.ndim == 3 else 'pgm'}"
    write_pnm(source, array, precision)
    out = work / f"{name}.jxl"
    code, _, err = run(["cjxl", source, out, "--container=0", "--quiet", *flags])
    require(code == 0, f"cjxl {name}: {err}")
    return out.read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-frames", type=int, default=4)
    args = parser.parse_args()
    require(importlib.metadata.version("pydicom") == "3.0.2", "Wrong pydicom version")
    for tool in ("cjxl", "djxl", "cjpeg"):
        require(shutil.which(tool) is not None, f"{tool} is required")
    work = Path(tempfile.mkdtemp(prefix="isis-jpegxl-clinical-"))
    results = {"objects": 0, "frames": 0, "modularOwnToLibjxl": 0, "modularLibjxlToOwn": 0,
               "vardctLibjxlToOwn": 0, "vardctOwnToLibjxl": 0, "vardctMaxAbsoluteError": 0,
               "recompressionByteExact": 0, "recompressionRoundTrip": 0, "refusedShapes": {}, "sizes": []}
    try:
        for index, path in enumerate(sorted(args.corpus.glob("*.dcm"))):
            name = f"object{index:03d}"
            native = work / f"{name}-native.dcm"
            code, _, err = run([args.binary, "codec", "transcode", path, "--output", native, "--transfer-syntax",
                                ExplicitVRLittleEndian, "--format", "json"])
            if code != 0:
                results["refusedShapes"][f"source:{err[:60]}"] = results["refusedShapes"].get(f"source:{err[:60]}", 0) + 1
                continue
            ds = pydicom.dcmread(native)
            precision, signed = int(ds.BitsStored), int(getattr(ds, "PixelRepresentation", 0)) == 1
            samples = int(getattr(ds, "SamplesPerPixel", 1))
            photometric = str(ds.PhotometricInterpretation)
            if samples == 3 and (precision != 8 or photometric != "RGB"):
                key = f"colour:{photometric}:{precision}"
                results["refusedShapes"][key] = results["refusedShapes"].get(key, 0) + 1
                continue
            frames = frames_of(ds)[: args.max_frames]
            results["objects"] += 1

            # Modular, own encoder -> djxl.
            compressed = work / f"{name}.110.dcm"
            started = time.perf_counter()
            code, _, err = run([args.binary, "codec", "transcode", native, "--output", compressed,
                                "--transfer-syntax", LOSSLESS, "--format", "json"])
            encode_ms = (time.perf_counter() - started) * 1000
            require(code == 0, f"{name}: .110 transcode failed: {err}")
            fragments = fragments_of(read_part10(compressed))
            for frame_index, frame in enumerate(frames):
                fragment = fragments[frame_index]
                candidates = [fragment[:-1], fragment] if fragment[-1:] == b"\x00" else [fragment]
                decoded = None
                for candidate in candidates:
                    try:
                        decoded, _ = read_pnm(djxl_decode(work, f"{name}-110-{frame_index}", candidate))
                        break
                    except ValueError:
                        continue
                require(decoded is not None, f"{name}: djxl could not decode frame {frame_index}")
                require(np.array_equal(decoded, stored(frame, precision, signed)),
                        f"{name}: djxl output of the own .110 frame {frame_index} differs from the source")
                results["modularOwnToLibjxl"] += 1
                results["frames"] += 1

            # Modular, cjxl -> own decoder (first frame).
            first = frames[0]
            reference = cjxl(work, f"{name}-ref", stored(first, precision, signed), precision, ["-d", "0", "-e", "7"])
            results["sizes"].append({"shape": f"{samples}x{precision}{'s' if signed else 'u'}",
                                     "own110Bytes": len(fragments[0]), "cjxlE7Bytes": len(reference),
                                     "own110EncodeMsWholeObject": round(encode_ms, 1)})
            wrapped = work / f"{name}-cjxl.dcm"
            dicom_wrap(wrapped, reference, LOSSLESS, first, precision, signed, photometric)
            own = our_decode(args.binary, wrapped, work, first.shape[:2], precision, signed, samples)
            require(np.array_equal(own, first), f"{name}: own decode of the cjxl .110 stream differs")
            results["modularLibjxlToOwn"] += 1

            # VarDCT, cjxl -d 1 -> own decoder vs djxl.
            lossy = cjxl(work, f"{name}-lossy", stored(first, precision, signed), precision, ["-d", "1", "-e", "7"])
            lossy_wrapped = work / f"{name}-lossy.dcm"
            dicom_wrap(lossy_wrapped, lossy, GENERAL, first, precision, signed, photometric)
            own = our_decode(args.binary, lossy_wrapped, work, first.shape[:2], precision, signed, samples)
            libjxl, _ = read_pnm(djxl_decode(work, f"{name}-lossy-ref", lossy))
            error = int(np.max(np.abs(stored(own, precision, signed) - libjxl)))
            require(error <= 1, f"{name}: own VarDCT decode is {error} codes from djxl")
            results["vardctMaxAbsoluteError"] = max(results["vardctMaxAbsoluteError"], error)
            results["vardctLibjxlToOwn"] += 1

            # VarDCT, own encoder -> djxl and own decoder, where the encoder qualifies.
            if samples == 1 and precision == int(ds.BitsAllocated):
                encoded = work / f"{name}.112.dcm"
                code, _, err = run([args.binary, "codec", "transcode", native, "--output", encoded, "--transfer-syntax",
                                    GENERAL, "--format", "json", "--distance", "1"])
                require(code == 0, f"{name}: VarDCT encode failed: {err}")
                fragment = fragments_of(read_part10(encoded))[0]
                candidates = [fragment[:-1], fragment] if fragment[-1:] == b"\x00" else [fragment]
                libjxl = None
                for candidate in candidates:
                    try:
                        libjxl, _ = read_pnm(djxl_decode(work, f"{name}-112", candidate))
                        break
                    except ValueError:
                        continue
                require(libjxl is not None, f"{name}: djxl refused the own VarDCT stream")
                own_single = work / f"{name}-112-first.dcm"
                dicom_wrap(own_single, candidate, GENERAL, first, precision, signed, photometric)
                own = our_decode(args.binary, own_single, work, first.shape[:2], precision, signed, samples)
                error = int(np.max(np.abs(stored(own, precision, signed) - libjxl)))
                require(error <= 1, f"{name}: own VarDCT stream decodes {error} codes apart")
                results["vardctMaxAbsoluteError"] = max(results["vardctMaxAbsoluteError"], error)
                results["vardctOwnToLibjxl"] += 1

            # .111 over libjpeg baseline streams of 8-bit frames.
            if precision == 8 and int(ds.BitsAllocated) == 8 and not signed:
                # 4:2:2 for colour, which YBR_FULL_422 names; libjpeg's default 4:2:0 has no DICOM photometric.
                sampling = ["-sample", "2x1"] if samples == 3 else []
                for flags in (["-quality", "90"], ["-quality", "75", "-restart", "2"], ["-quality", "95", "-optimize"]):
                    pnm = work / f"{name}-jpeg.{'ppm' if samples == 3 else 'pgm'}"
                    write_pnm(pnm, first, 8)
                    jpeg = work / f"{name}-jpeg.jpg"
                    code, _, err = run(["cjpeg", *flags, *sampling, "-outfile", jpeg, pnm])
                    require(code == 0, f"{name}: cjpeg failed: {err}")
                    source_jpeg = jpeg.read_bytes()
                    base_ds = read_part10(native)
                    base_ds.NumberOfFrames = 1
                    base_ds.PixelData = encapsulate([source_jpeg])
                    base_ds["PixelData"].is_undefined_length = True
                    if samples == 3:
                        base_ds.PhotometricInterpretation = "YBR_FULL_422"
                    baseline = work / f"{name}-50.dcm"
                    write_part10(baseline, base_ds, BASELINE)
                    recompressed = work / f"{name}-111.dcm"
                    code, _, err = run([args.binary, "codec", "transcode", baseline, "--output", recompressed,
                                        "--transfer-syntax", RECOMPRESSION, "--format", "json"])
                    require(code == 0, f"{name}: .111 transcode failed: {err}")
                    fragment = fragments_of(read_part10(recompressed))[0]
                    candidates = [fragment[:-1], fragment] if fragment[-1:] == b"\x00" else [fragment]
                    reconstructed = None
                    for candidate in candidates:
                        source = work / f"{name}-111.jxl"
                        source.write_bytes(candidate)
                        out = work / f"{name}-111.jpg"
                        if run(["djxl", source, out, "--quiet"])[0] == 0:
                            reconstructed = out.read_bytes()
                            break
                    require(reconstructed == source_jpeg, f"{name}: djxl did not reconstruct the JPEG byte for byte")
                    results["recompressionByteExact"] += 1
                    back = work / f"{name}-111-50.dcm"
                    code, _, err = run([args.binary, "codec", "transcode", recompressed, "--output", back,
                                        "--transfer-syntax", BASELINE, "--format", "json"])
                    require(code == 0, f"{name}: .111 -> .50 failed: {err}")
                    restored = fragments_of(read_part10(back))[0]
                    require(restored[:len(source_jpeg)] == source_jpeg and len(restored) - len(source_jpeg) in (0, 1),
                            f"{name}: .111 -> .50 did not give back the JPEG")
                    results["recompressionRoundTrip"] += 1
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps(results, indent=2))
    print(f"PASS: {results['objects']} objects / {results['frames']} frames; Modular own->djxl "
          f"{results['modularOwnToLibjxl']}, cjxl->own {results['modularLibjxlToOwn']}; VarDCT cjxl->own "
          f"{results['vardctLibjxlToOwn']}, own->djxl {results['vardctOwnToLibjxl']} (max {results['vardctMaxAbsoluteError']}"
          f" code); .111 byte-exact {results['recompressionByteExact']}, round trips {results['recompressionRoundTrip']}")


if __name__ == "__main__":
    main()
