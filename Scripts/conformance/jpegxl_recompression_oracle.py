#!/usr/bin/env python3
"""Independent check of JPEG XL JPEG recompression (`1.2.840.10008.1.2.4.111`) against libjxl and pydicom (#2334).

JPEG Baseline objects built with pydicom from Pillow/libjpeg-turbo streams (4:2:0, 4:4:4, grey,
restart intervals, COM/Exif segments, odd sizes, three frames with odd fragment lengths) are transcoded by
`dicomtool codec transcode` to `.111`: the object must keep its SOP Instance UID and lossy history, carry one JPEG XL
container per frame with even fragment lengths, and every fragment must be reconstructed by `djxl` to the exact source
JPEG bytes. Progressive SOF2 mislabeled as Baseline is refused. The same valid objects come back to `.50` through the reconstruction route with byte-identical fragments, and the
pixels of the `.111` object decoded by `dicomtool` equal those of the `.50` object. `cjxl --lossless_jpeg=1` streams
wrapped as `.111` objects are reconstructed by `dicomtool` to the source bytes. Typed refusals cover 12-bit and
arithmetic-coded sources and lossy intent. Only counts and maxima are kept.
"""
import argparse
import importlib.metadata
import io
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pydicom
from PIL import Image
from pydicom.encaps import encapsulate
from pydicom.uid import ExplicitVRLittleEndian

# The .50 pixels must come from the same own JPEG backend the .111 route uses.
os.environ["DICOM_JPEGSWIFT_MODE"] = "preferred"

from image_iod_oracle import require
from jpegxl_modular_oracle import dataset, fragments_of, read_part10, run, write_part10

BASELINE = "1.2.840.10008.1.2.4.50"
RECOMPRESSION = "1.2.840.10008.1.2.4.111"


def photo(h, w, seed, gray=False):
    r = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    ch = [127 + 100 * np.sin(x / 31) * np.cos(y / 17), 127 + 80 * np.cos(x / 23) * np.sin(y / 29), 127 + 110 * np.sin((x + y) / 41)]
    a = (np.stack(ch, -1) + r.normal(0, 4, (h, w, 3))).clip(0, 255).astype("u1")
    return Image.fromarray(a[..., 0], "L") if gray else Image.fromarray(a, "RGB")


def pil_jpeg(img, **kw):
    buffer = io.BytesIO()
    img.save(buffer, "JPEG", **kw)
    return buffer.getvalue()


def cjpeg(work, name, img, args, optional=False):
    src = work / f"{name}.ppm"
    img.save(src)
    out = work / f"{name}.jpg"
    code, _, err = run(["cjpeg", *args, "-outfile", out, src])
    if code != 0 and optional:
        print(f"SKIP optional refusal fixture {name}: cjpeg exited {code}: {err.strip()}")
        return None
    require(code == 0, f"cjpeg {name}: {err}")
    return out.read_bytes()


def jpeg_object(path, frames, syntax, width, height, gray, lossy_history=False):
    array = np.zeros((height * len(frames), width) if gray else (height * len(frames), width, 3), dtype=np.int64)
    ds = dataset(array, 8, False, "MONOCHROME2" if gray else "YBR_FULL_422", frames=len(frames))
    if lossy_history:
        ds.LossyImageCompression, ds.LossyImageCompressionRatio, ds.LossyImageCompressionMethod = "01", "12.5", "ISO_10918_1"
    ds.PixelData = encapsulate([bytes(f) for f in frames])
    ds["PixelData"].is_undefined_length = True
    write_part10(path, ds, syntax)


def djxl_reconstruct(work, name, stream):
    src = work / f"{name}.jxl"
    src.write_bytes(bytes(stream))
    out = work / f"{name}.jpg"
    code, _, err = run(["djxl", src, out, "--quiet"])
    require(code == 0, f"djxl {name}: {err}")
    return out.read_bytes()


def unpadded(fragment, expected_len):
    require(len(fragment) >= expected_len, "fragment shorter than the source")
    require(all(b == 0 for b in fragment[expected_len:]), "non-padding bytes after the frame")
    return fragment[:expected_len]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(importlib.metadata.version("pydicom") == "3.0.2", "Wrong pydicom version")
    for tool in ("cjxl", "djxl", "cjpeg"):
        require(shutil.which(tool) is not None, f"{tool} is required")
    work = Path(tempfile.mkdtemp(prefix="isis-jpegxl-recompression-oracle-"))
    results = {"framesRecompressed": 0, "framesReconstructedByLibjxl": 0, "framesRestoredToBaseline": 0,
               "libjxlStreamsReconstructedByOwn": 0, "pixelObjectsEqual": 0, "refusals": 0, "maxRatio": 0.0,
               "optionalRefusalsSkipped": 0}
    try:
        rgb = photo(277, 301, 1)
        cases = [
            ("baseline-420", [pil_jpeg(rgb, quality=75)], 301, 277, False),
            ("baseline-444-comment-exif", [pil_jpeg(rgb, quality=90, subsampling=0, comment=b"oracle", exif=Image.Exif().tobytes())], 301, 277, False),
            ("gray-restart", [cjpeg(work, "gray-restart", photo(277, 301, 2, gray=True), ["-quality", "70", "-restart", "3"])], 301, 277, True),
            ("progressive", [pil_jpeg(rgb, quality=80, progressive=True)], 301, 277, False),
            ("noninterleaved", [cjpeg(work, "noninter", rgb, ["-quality", "80", "-scans", str(scans(work))])], 301, 277, False),
            ("mixed-y", [cjpeg(work, "mixed-y", rgb, ["-quality", "80", "-scans",
                str(scans(work, "0: 0-63 0 0; 1 2: 0-63 0 0;"))])], 301, 277, False),
            ("mixed-ycb", [cjpeg(work, "mixed-ycb", rgb, ["-quality", "80", "-scans",
                str(scans(work, "0 1: 0-63 0 0; 2: 0-63 0 0;"))])], 301, 277, False),
            ("odd-17x9", [cjpeg(work, "odd", photo(9, 17, 3), ["-quality", "80"])], 17, 9, False),
            ("three-frames", [pil_jpeg(photo(51, 75, 10 + i), quality=80 + i) for i in range(3)], 75, 51, False),
        ]
        interleaved = work / "interleaved-reference.dcm"
        jpeg_object(interleaved, [cjpeg(work, "interleaved-reference", rgb, ["-quality", "80"])], BASELINE, 301, 277, False)
        reference_raw = work / "interleaved-reference.raw"
        code, _, err = run([args.binary, "codec", "decode", interleaved, "--output", reference_raw, "--format", "json"])
        require(code == 0, f"decode interleaved reference: {err}")
        for name, frames, width, height, gray in cases:
            source = work / f"{name}.dcm"
            jpeg_object(source, frames, BASELINE, width, height, gray, lossy_history=True)
            recompressed = work / f"{name}-111.dcm"
            code, _, err = run([args.binary, "codec", "transcode", source, "--output", recompressed, "--transfer-syntax", RECOMPRESSION, "--format", "json"])
            if name == "progressive":
                require(code != 0 and not recompressed.exists(), "SOF2 must be refused under the Baseline UID")
                results["refusals"] += 1
                continue
            require(code == 0, f"transcode {name}: {err}")
            ds = read_part10(recompressed)
            require(ds.file_meta.TransferSyntaxUID == RECOMPRESSION, f"{name}: wrong transfer syntax")
            require(ds.SOPInstanceUID == pydicom.dcmread(source).SOPInstanceUID, f"{name}: SOP Instance UID changed")
            require(str(ds.LossyImageCompression) == "01" and "DerivationCodeSequence" not in ds, f"{name}: lossy history altered")
            frags = fragments_of(ds)
            require(len(frags) == len(frames), f"{name}: {len(frags)} fragments for {len(frames)} frames")
            for index, (fragment, jpeg) in enumerate(zip(frags, frames)):
                require(len(fragment) % 2 == 0, f"{name}: odd fragment length")
                require(fragment[:12] == b"\x00\x00\x00\x0cJXL \r\n\x87\n", f"{name}: fragment {index} is not a JPEG XL container")
                candidates = [fragment[:-1], fragment] if fragment[-1:] == b"\x00" else [fragment]
                back = None
                for candidate in candidates:
                    try:
                        back = djxl_reconstruct(work, f"{name}-{index}", candidate)
                        break
                    except ValueError:
                        continue
                require(back == jpeg, f"{name}: djxl does not reproduce frame {index}")
                results["framesReconstructedByLibjxl"] += 1
                results["maxRatio"] = max(results["maxRatio"], round(len(candidate) / len(jpeg), 3))
                results["framesRecompressed"] += 1
            restored = work / f"{name}-50.dcm"
            code, _, err = run([args.binary, "codec", "transcode", recompressed, "--output", restored, "--transfer-syntax", BASELINE, "--format", "json"])
            require(code == 0, f"restore {name}: {err}")
            back_ds = pydicom.dcmread(restored)
            require(back_ds.file_meta.TransferSyntaxUID == BASELINE and back_ds.SOPInstanceUID == ds.SOPInstanceUID, f"{name}: restore identity")
            restored_fragments = list(fragments_of(back_ds))
            require(len(restored_fragments) == len(frames), f"{name}: {len(restored_fragments)} restored fragments for {len(frames)} frames")
            for index, (fragment, jpeg) in enumerate(zip(restored_fragments, frames, strict=True)):
                require(unpadded(fragment, len(jpeg)) == jpeg, f"{name}: restored frame {index} differs")
                results["framesRestoredToBaseline"] += 1
            # Pixels: the .111 object decodes to the same samples as the .50 object.
            pixels = []
            for label, path in (("50", source), ("111", recompressed)):
                raw = work / f"{name}-{label}.raw"
                code, _, err = run([args.binary, "codec", "decode", path, "--output", raw, "--format", "json"])
                require(code == 0, f"decode {name} ({label}): {err}")
                pixels.append(raw.read_bytes())
            require(pixels[0] == pixels[1] and len(pixels[0]) > 0, f"{name}: pixels of .111 differ from .50")
            if name in ("noninterleaved", "mixed-y", "mixed-ycb"):
                require(pixels[0] == reference_raw.read_bytes(), f"{name}: pixels differ from the interleaved equivalent")
                results["sequentialLayoutsEqual"] = results.get("sequentialLayoutsEqual", 0) + 1
            results["pixelObjectsEqual"] += 1

        # cjxl streams wrapped as .111 objects come back to the source bytes through dicomtool.
        for name, jpeg, width, height, gray in (("cjxl-420", pil_jpeg(rgb, quality=75), 301, 277, False),
                                                 ("cjxl-progressive", pil_jpeg(rgb, quality=80, progressive=True), 301, 277, False)):
            src = work / f"{name}.jpg"
            src.write_bytes(jpeg)
            out = work / f"{name}.jxl"
            code, _, err = run(["cjxl", src, out, "--lossless_jpeg=1", "--quiet"])
            require(code == 0, f"cjxl {name}: {err}")
            wrapped = work / f"{name}-111.dcm"
            jpeg_object(wrapped, [out.read_bytes()], RECOMPRESSION, width, height, gray)
            restored = work / f"{name}-50.dcm"
            code, _, err = run([args.binary, "codec", "transcode", wrapped, "--output", restored, "--transfer-syntax", BASELINE, "--format", "json"])
            if name == "cjxl-progressive":
                require(code != 0 and not restored.exists(), "SOF2 reconstruction must be refused under Baseline")
                results["refusals"] += 1
                continue
            require(code == 0, f"restore {name}: {err}")
            fragment = fragments_of(pydicom.dcmread(restored))[0]
            require(unpadded(fragment, len(jpeg)) == jpeg, f"{name}: own reconstruction of the cjxl stream differs")
            results["libjxlStreamsReconstructedByOwn"] += 1

        # Refusals: 12-bit source, arithmetic-coded source, lossy intent.
        twelve = cjpeg(work, "twelve", rgb, ["-quality", "80", "-precision", "12"], optional=True)
        arith = cjpeg(work, "arith", rgb, ["-quality", "80", "-arithmetic"], optional=True)
        for name, jpeg, extra in (("refuse-12bit", twelve, []), ("refuse-arith", arith, []), ("refuse-lossy", pil_jpeg(rgb, quality=75), ["--quality", "0.5"])):
            if jpeg is None:
                results["optionalRefusalsSkipped"] += 1
                continue
            source = work / f"{name}.dcm"
            jpeg_object(source, [jpeg], BASELINE, 301, 277, False)
            code, _, _ = run([args.binary, "codec", "transcode", source, "--output", work / f"{name}-out.dcm", "--transfer-syntax", RECOMPRESSION, "--format", "json", *extra])
            require(code != 0, f"{name} must be refused")
            require(not (work / f"{name}-out.dcm").exists(), f"{name}: output written despite the refusal")
            results["refusals"] += 1
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps(results, indent=2))
    print(f"PASS: {results['framesRecompressed']} JPEG frames recompressed to .111, {results['framesReconstructedByLibjxl']} reconstructed "
          f"byte-exact by djxl, {results['framesRestoredToBaseline']} restored to .50 byte-exact by dicomtool, "
          f"{results['libjxlStreamsReconstructedByOwn']} cjxl streams reconstructed by the own core, {results['pixelObjectsEqual']} "
          f"objects with identical .50/.111 pixels, {results['refusals']} typed refusals (max ratio {results['maxRatio']}), "
          f"{results['optionalRefusalsSkipped']} optional refusal fixtures skipped")


def scans(work, script="0: 0-63 0 0;\n1: 0-63 0 0;\n2: 0-63 0 0;"):
    path = work / "scans.txt"
    path.write_text(script + "\n")
    return path


if __name__ == "__main__":
    main()
