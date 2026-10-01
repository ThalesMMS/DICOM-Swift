#!/usr/bin/env python3
"""Independent check of the own JPEG XL VarDCT (lossy) codec (ISO/IEC 18181-1) against libjxl and pydicom (#2333).

Two decoders of one codestream separate decoder divergence from legitimate lossy error: `cjxl` writes VarDCT streams
(distances 0.5..4, efforts 3..9, progressive DC levels 1 and 2, resampling, photon noise, lossy Modular XYB, 8/12/16-bit
grey and RGB8), each is wrapped as a `.112` Part 10 file with pydicom and decoded by `dicomtool codec decode`; every
sample must be within one code (8-bit) or two codes (deeper) of `djxl`'s decode of the same stream. The own encoder is
driven through `dicomtool codec transcode --distance`: the derived objects must carry the lossy record (Lossy Image
Compression 01, method ISO_18181_1, ratio, new SOP Instance UID, Source Image and Derivation Code sequences), their
fragments must be accepted by `djxl`, and their PSNR against the source must stay within 3 dB of `cjxl` at the same
distance; `--distance 0` must produce the reversible Modular object without any lossy record. Typed refusals cover a
distance on the lossless-only UID and out-of-range distance/effort. Only counts and maxima are kept.
"""
import argparse
import importlib.metadata
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pydicom
from pydicom.uid import ExplicitVRLittleEndian

from image_iod_oracle import require
from jpegxl_modular_oracle import (GENERAL, LOSSLESS, dicom_wrap, fixture, fragments_of, native_dicom, our_decode,
                                   read_part10, read_pnm, run, write_pnm)


def cjxl(work, name, array, precision, flags):
    src = work / f"{name}.{'ppm' if array.ndim == 3 else 'pgm'}"
    write_pnm(src, array, precision)
    out = work / f"{name}.jxl"
    code, _, err = run(["cjxl", src, out, "--container=0", "--quiet", *flags])
    require(code == 0, f"cjxl {name}: {err}")
    return out


def djxl(work, name, codestream, precision):
    src = work / f"{name}.jxl"
    src.write_bytes(bytes(codestream))
    out = work / f"{name}.pnm"
    code, _, err = run(["djxl", src, out, "--quiet", f"--bits_per_sample={precision}", "--num_threads=1"])
    require(code == 0, f"djxl {name}: {err}")
    decoded, maxval = read_pnm(out)
    require(maxval == (1 << precision) - 1, f"{name}: djxl reports {maxval} for {precision} bits")
    return decoded


def psnr(a, b, precision):
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    return 99.0 if mse == 0 else 10 * np.log10(((1 << precision) - 1) ** 2 / mse)


def tolerance(precision):
    return 1 if precision <= 8 else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(importlib.metadata.version("pydicom") == "3.0.2", "Wrong pydicom version")
    for tool in ("cjxl", "djxl"):
        require(shutil.which(tool) is not None, f"{tool} is required")
    rng = np.random.default_rng(2333)
    work = Path(tempfile.mkdtemp(prefix="isis-jpegxl-vardct-oracle-"))
    results = {"libjxlDecodedByOwn": 0, "maxAbsoluteError8Bit": 0, "maxAbsoluteErrorDeep": 0, "ownAcceptedByLibjxl": 0,
               "lossyObjects": 0, "reversibleObjects": 0, "minPsnrMarginDb": 99.0, "refusals": 0}
    try:
        # 1. libjxl lossy streams through the DICOM layer, judged against djxl on the same stream.
        cases = [
            ("gray8-d1", fixture(rng, 271, 300, 8), 8, ["-d", "1"]),
            ("gray8-d4-e3", fixture(rng, 271, 300, 8), 8, ["-d", "4", "-e", "3"]),
            ("gray12-d1", fixture(rng, 277, 301, 12), 12, ["-d", "1"]),
            ("gray12-resample2", fixture(rng, 299, 301, 12), 12, ["-d", "1", "--resampling=2"]),
            ("gray16-d0.5-e9", fixture(rng, 257, 200, 16), 16, ["-d", "0.5", "-e", "9", "--epf=3"]),
            ("gray16-modular-xyb", fixture(rng, 150, 200, 16), 16, ["-d", "1", "-m", "1"]),
            ("gray8-photon", fixture(rng, 300, 300, 8), 8, ["-d", "1", "--photon_noise_iso=3200"]),
            ("rgb8-d1", fixture(rng, 271, 300, 8, channels=3), 8, ["-d", "1"]),
            ("rgb8-progressive", fixture(rng, 301, 277, 8, channels=3), 8, ["-d", "1", "-p"]),
            ("rgb8-progressive-dc2", fixture(rng, 300, 300, 8, channels=3), 8, ["-d", "1", "--progressive_dc=2"]),
            ("rgb8-noise-resample", fixture(rng, 263, 517, 8, channels=3), 8, ["-d", "2", "--photon_noise_iso=6400", "--resampling=2"]),
            ("rgb8-groups-e8", fixture(rng, 520, 600, 8, channels=3), 8, ["-d", "1", "-g", "1", "-e", "8"]),
        ]
        for name, array, precision, flags in cases:
            codestream = cjxl(work, name, array, precision, flags).read_bytes()
            reference = djxl(work, name + "-ref", codestream, precision)
            path = work / f"{name}.dcm"
            photometric = "RGB" if array.ndim == 3 else "MONOCHROME2"
            dicom_wrap(path, codestream, GENERAL, array, precision, False, photometric)
            decoded = our_decode(args.binary, path, work, array.shape[:2], precision, False, 3 if array.ndim == 3 else 1)
            error = int(np.abs(decoded - reference).max())
            require(error <= tolerance(precision), f"{name}: own decode differs from djxl by {error}")
            key = "maxAbsoluteError8Bit" if precision <= 8 else "maxAbsoluteErrorDeep"
            results[key] = max(results[key], error)
            results["libjxlDecodedByOwn"] += 1

        # 2. Own lossy objects: explicit distance, derivation record, djxl acceptance, fidelity against cjxl.
        own_cases = [
            ("own-gray8", fixture(rng, 271, 300, 8), 8, False, 1.0),
            ("own-gray16-signed", fixture(rng, 200, 257, 16, signed=True), 16, True, 1.0),
            ("own-rgb8", fixture(rng, 277, 301, 8, channels=3), 8, False, 2.0),
        ]
        for name, array, precision, signed, distance in own_cases:
            native = work / f"{name}-native.dcm"
            photometric = "RGB" if array.ndim == 3 else "MONOCHROME2"
            native_dicom(native, array, precision, signed, photometric)
            compressed = work / f"{name}.dcm"
            code, _, err = run([args.binary, "codec", "transcode", native, "--output", compressed, "--transfer-syntax", GENERAL,
                                "--format", "json", "--distance", str(distance)])
            require(code == 0, f"transcode {name}: {err}")
            ds = read_part10(compressed)
            require(ds.file_meta.TransferSyntaxUID == GENERAL, f"{name}: wrong transfer syntax")
            require(str(ds.LossyImageCompression) == "01", f"{name}: Lossy Image Compression not set")
            methods = ds.LossyImageCompressionMethod
            methods = [methods] if isinstance(methods, str) else list(methods)
            require("ISO_18181_1" in methods, f"{name}: method {methods}")
            require("LossyImageCompressionRatio" in ds, f"{name}: no compression ratio")
            require(ds.SOPInstanceUID != pydicom.dcmread(native).SOPInstanceUID, f"{name}: lossy derivation kept the SOP Instance UID")
            require(ds.SourceImageSequence[0].ReferencedSOPInstanceUID == pydicom.dcmread(native).SOPInstanceUID, f"{name}: Source Image Sequence")
            require(ds.DerivationCodeSequence[0].CodeValue == "113040", f"{name}: Derivation Code Sequence")
            require(int(ds.BitsStored) == precision and int(ds.PixelRepresentation) == (1 if signed else 0), f"{name}: pixel module changed")
            frags = fragments_of(ds)
            require(len(frags) == 1, f"{name}: {len(frags)} fragments")
            fragment = frags[0]
            require(fragment[:2] == b"\xff\x0a", f"{name}: not a raw codestream")
            candidates = [fragment[:-1], fragment] if fragment[-1:] == b"\x00" else [fragment]
            decoded = None
            for candidate in candidates:
                try:
                    decoded = djxl(work, f"{name}-djxl", candidate, precision)
                    break
                except (ValueError, SystemExit, RuntimeError):
                    continue
            require(decoded is not None, f"{name}: djxl rejected the own codestream")
            results["ownAcceptedByLibjxl"] += 1
            unsigned = array + (1 << (precision - 1)) if signed else array
            own_psnr = psnr(unsigned, decoded, precision)
            reference = djxl(work, f"{name}-cjxl", cjxl(work, f"{name}-cjxl-src", unsigned, precision, ["-d", str(distance), "-e", "7"]).read_bytes(), precision)
            cjxl_psnr = psnr(unsigned, reference, precision)
            margin = own_psnr - cjxl_psnr
            results["minPsnrMarginDb"] = min(results["minPsnrMarginDb"], round(float(margin), 2))
            require(margin >= -3.0, f"{name}: own PSNR {own_psnr:.2f} dB is more than 3 dB below cjxl {cjxl_psnr:.2f} dB")
            results["lossyObjects"] += 1
            # The reversible route through the same intent (distance 0) is exact and carries no lossy record.
            reversible = work / f"{name}-reversible.dcm"
            code, _, err = run([args.binary, "codec", "transcode", native, "--output", reversible, "--transfer-syntax", GENERAL,
                                "--format", "json", "--distance", "0", "--effort", "5"])
            require(code == 0, f"reversible transcode {name}: {err}")
            rds = read_part10(reversible)
            require("LossyImageCompression" not in rds, f"{name}: reversible object carries a lossy flag")
            require(rds.SOPInstanceUID == pydicom.dcmread(native).SOPInstanceUID, f"{name}: reversible transcode changed the SOP Instance UID")
            rfrag = fragments_of(rds)[0]
            rdecoded = None
            for candidate in ([rfrag[:-1], rfrag] if rfrag[-1:] == b"\x00" else [rfrag]):
                try:
                    rdecoded = djxl(work, f"{name}-rev", candidate, precision)
                    break
                except (ValueError, SystemExit, RuntimeError):
                    continue
            require(rdecoded is not None and np.array_equal(rdecoded, unsigned), f"{name}: reversible object is not exact under djxl")
            results["reversibleObjects"] += 1

        # 3. Typed refusals: distance on the lossless-only UID, out-of-range distance and effort.
        gray = fixture(rng, 37, 53, 8)
        native = work / "refusal-native.dcm"
        native_dicom(native, gray, 8, False, "MONOCHROME2")
        for flags in (["--transfer-syntax", LOSSLESS, "--distance", "1"],
                      ["--transfer-syntax", GENERAL, "--distance", "30"],
                      ["--transfer-syntax", GENERAL, "--distance", "1", "--effort", "0"]):
            code, _, _ = run([args.binary, "codec", "transcode", native, "--output", work / "refusal.dcm", "--format", "json", *flags])
            require(code != 0, f"{flags} must be refused")
            results["refusals"] += 1
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps(results, indent=2))
    print(f"PASS: {results['libjxlDecodedByOwn']} libjxl lossy streams decoded within tolerance of djxl "
          f"(max error {results['maxAbsoluteError8Bit']}/8-bit, {results['maxAbsoluteErrorDeep']}/deep), "
          f"{results['ownAcceptedByLibjxl']} own codestreams accepted by djxl, {results['lossyObjects']} lossy objects with "
          f"derivation records (PSNR margin >= {results['minPsnrMarginDb']} dB vs cjxl), {results['reversibleObjects']} reversible "
          f"objects exact, {results['refusals']} typed refusals")


if __name__ == "__main__":
    main()
