#!/usr/bin/env python3
"""Independent check of the own JPEG XL Modular lossless codec (ISO/IEC 18181-1 Annex C) against libjxl and pydicom (#2332).
`cjxl` writes reference codestreams the own decoder never saw — 8/10/12/16-bit unsigned and 12/16-bit signed grayscale
(the sign lives in Pixel Representation, the codestream stays unsigned), RGB8 with the RCT the encoder picks (colour above 8 bits is codec-level only: the DICOM frame contract carries RGB8),
palettes, Squeeze (responsive), multiple groups, progressive passes and efforts 1..9 — each wrapped in a Part 10 file
with pydicom and decoded by `dicomtool codec decode`; every sample must equal the source. The own encoder's `.110`/`.112`
objects are taken apart with pydicom (one raw codestream per frame, even fragment lengths, Basic Offset Table), decoded
by `djxl` exactly, and reopened natively through `dicomtool codec transcode`. An ICC Profile (0028,2000) must survive
inside every codestream (djxl re-emits it in PNG) and in the data set. Typed refusals cover Bits Stored/codestream
disagreement, lossy intent on the lossless-only UID and a decompression bomb. Only counts and maxima are kept.
"""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zlib

import numpy as np
import pydicom
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.encaps import encapsulate, generate_fragments
from pydicom.uid import ExplicitVRLittleEndian

from image_iod_oracle import require

LOSSLESS = "1.2.840.10008.1.2.4.110"
GENERAL = "1.2.840.10008.1.2.4.112"
# pydicom 3.0.2 predates the JPEG XL transfer syntaxes (PS3.5 2024c): register them as private explicit VR little
# endian syntaxes and pass the encoding explicitly when writing.
for _uid in (LOSSLESS, GENERAL):
    if _uid not in pydicom.uid.AllTransferSyntaxes:
        pydicom.uid.register_transfer_syntax(_uid, implicit_vr=False, little_endian=True)
SOURCE_UID = "2.25.23320011"
ENVIRONMENT = {**os.environ, "DICOM_JXLSWIFT_MODE": "experimental"}


def run(args, **kwargs):
    completed = subprocess.run([str(a) for a in args], capture_output=True, timeout=600, env=ENVIRONMENT, **kwargs)
    return completed.returncode, completed.stdout, completed.stderr.decode(errors="replace")[:300]


def dataset(array, precision, signed, photometric, frames=1, icc=None):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = SOURCE_UID
    ds.StudyInstanceUID = "2.25.23320012"
    ds.SeriesInstanceUID = "2.25.23320013"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "JPEGXL^Oracle", "JXL-1", "OT", "WSD"
    ds.ImageType = ["ORIGINAL", "PRIMARY"]
    rows = array.shape[0] // frames
    ds.Rows, ds.Columns = rows, array.shape[1]
    colour = array.ndim == 3
    ds.SamplesPerPixel = 3 if colour else 1
    ds.PhotometricInterpretation = photometric
    if colour:
        ds.PlanarConfiguration = 0
    if frames > 1:
        ds.NumberOfFrames = frames
    ds.BitsAllocated, ds.BitsStored, ds.HighBit = (16 if precision > 8 else 8), precision, precision - 1
    ds.PixelRepresentation = 1 if signed else 0
    if icc is not None:
        ds.ICCProfile = icc
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
    ds.is_little_endian, ds.is_implicit_VR = True, False
    return ds


def write_part10(path, ds, syntax):
    """Writes explicit VR little endian Part 10 bytes for a transfer syntax pydicom 3.0.2 does not list."""
    from pydicom.filebase import DicomBytesIO
    from pydicom.filewriter import write_dataset, write_file_meta_info
    ds.file_meta.TransferSyntaxUID = syntax
    buffer = DicomBytesIO()
    buffer.is_little_endian, buffer.is_implicit_VR = True, False
    buffer.write(b"\x00" * 128 + b"DICM")
    write_file_meta_info(buffer, ds.file_meta, enforce_standard=True)
    write_dataset(buffer, ds)
    path.write_bytes(buffer.getvalue())


def read_part10(path):
    """Reads a Part 10 file whose transfer syntax pydicom 3.0.2 does not list (explicit VR little endian)."""
    from pydicom.filereader import _read_file_meta_info, read_dataset
    with open(path, "rb") as fp:
        fp.seek(128)
        require(fp.read(4) == b"DICM", f"{path.name}: not a Part 10 file")
        meta = _read_file_meta_info(fp)
        ds = read_dataset(fp, is_implicit_VR=False, is_little_endian=True)
    ds.file_meta = meta
    return ds


def dicom_wrap(path, codestream, syntax, array, precision, signed, photometric):
    ds = dataset(array, precision, signed, photometric)
    ds.PixelData = encapsulate([bytes(codestream)])
    ds["PixelData"].is_undefined_length = True
    write_part10(path, ds, syntax)


def native_dicom(path, array, precision, signed, photometric, frames=1, icc=None):
    ds = dataset(array, precision, signed, photometric, frames, icc)
    dtype = ("<i2" if signed else "<u2") if precision > 8 else np.uint8
    ds.PixelData = array.astype(dtype).tobytes()
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.save_as(path, enforce_file_format=True)


def our_decode(binary, dicom_path, work, shape, precision, signed, channels):
    raw = work / (dicom_path.stem + ".raw")
    code, out, err = run([binary, "codec", "decode", dicom_path, "--output", raw, "--format", "json"])
    require(code == 0, f"dicomtool decode failed for {dicom_path.name}: {err}")
    # `codec decode` writes the frame-reader pixel contract: signed samples are offset to unsigned by 2^15 (16-bit
    # containers) or 2^7 (8-bit containers).
    array = np.frombuffer(raw.read_bytes(), dtype="<u2" if precision > 8 else np.uint8).astype(np.int64)
    if signed:
        array = array - (32768 if precision > 8 else 128)
    expected = shape[0] * shape[1] * channels
    require(array.size == expected, f"{dicom_path.name}: decoded {array.size} samples, expected {expected}")
    return array.reshape(shape[0], shape[1], channels) if channels == 3 else array.reshape(shape)


def write_pnm(path, array, precision):
    channels = 3 if array.ndim == 3 else 1
    header = f"{'P6' if channels == 3 else 'P5'}\n{array.shape[1]} {array.shape[0]}\n{(1 << precision) - 1}\n".encode()
    path.write_bytes(header + array.astype(">u2" if precision > 8 else np.uint8).tobytes())


def read_pnm(path):
    data = path.read_bytes()
    tokens, cursor = [], 0
    while len(tokens) < 4:
        while data[cursor:cursor + 1].isspace():
            cursor += 1
        start = cursor
        while not data[cursor:cursor + 1].isspace():
            cursor += 1
        tokens.append(data[start:cursor])
    cursor += 1
    magic, width, height, maxval = tokens[0].decode(), int(tokens[1]), int(tokens[2]), int(tokens[3])
    dtype = ">u2" if maxval > 255 else np.uint8
    array = np.frombuffer(data[cursor:], dtype=dtype).astype(np.int64)
    if magic == "P6":
        return array.reshape(height, width, 3), maxval
    return array.reshape(height, width), maxval


def cjxl_encode(work, name, array, precision, flags):
    src = work / f"{name}.{'ppm' if array.ndim == 3 else 'pgm'}"
    write_pnm(src, array, precision)
    out = work / f"{name}.jxl"
    code, _, err = run(["cjxl", src, out, "-d", "0", "-m", "1", "--container=0", "--quiet", *flags])
    require(code == 0, f"cjxl {name}: {err}")
    return out


def djxl_decode(work, name, codestream, png=False):
    src = work / f"{name}.jxl"
    src.write_bytes(bytes(codestream))
    out = work / f"{name}.{'png' if png else 'pnm'}"
    code, _, err = run(["djxl", src, out, "--quiet"])
    require(code == 0, f"djxl {name}: {err}")
    return out


def png_icc(path):
    data = path.read_bytes()
    cursor = 8
    while cursor + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[cursor:cursor + 8])
        body = data[cursor + 8:cursor + 8 + length]
        if kind == b"iCCP":
            zero = body.index(0)
            return zlib.decompress(body[zero + 2:])
        cursor += 12 + length
    return None


def fixture(rng, height, width, precision, signed=False, channels=1, seed=0):
    low = -(1 << (precision - 1)) if signed else 0
    high = (1 << (precision - 1)) - 1 if signed else (1 << precision) - 1
    y, x = np.mgrid[0:height, 0:width]
    planes = []
    for c in range(channels):
        base = low + (high - low) * (0.5 + 0.4 * np.sin(x / (5 + width / 40) + 0.7 * c) * np.cos(y / (4 + height / 33)))
        noise = rng.normal(0, max(1, (high - low) / 300), (height, width))
        planes.append(np.clip(np.rint(base + noise), low, high).astype(np.int64))
    return np.stack(planes, -1) if channels == 3 else planes[0]


def fragments_of(ds):
    """The encapsulated fragments after the Basic Offset Table item (pydicom yields the table as the first item)."""
    if not ds["PixelData"].is_undefined_length:
        return []
    return list(generate_fragments(ds.PixelData))[1:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(importlib.metadata.version("pydicom") == "3.0.2", "Wrong pydicom version")
    for tool in ("cjxl", "djxl"):
        require(shutil.which(tool) is not None, f"{tool} is required")
    rng = np.random.default_rng(2332)
    work = Path(tempfile.mkdtemp(prefix="isis-jpegxl-oracle-"))
    results = {"libjxlDecodedByOwn": 0, "ownDecodedByLibjxl": 0, "dicomObjects": 0, "iccPassthrough": 0, "refusals": 0}
    try:
        # 1. libjxl codestreams decoded by the own core through the DICOM layer.
        cases = [
            ("gray8", fixture(rng, 37, 53, 8), 8, False, ["-e", "7"]),
            ("gray10", fixture(rng, 37, 53, 10), 10, False, ["-e", "7"]),
            ("gray12", fixture(rng, 277, 301, 12), 12, False, ["-e", "7"]),
            ("gray12-e9", fixture(rng, 271, 300, 12), 12, False, ["-e", "9"]),
            ("gray12-e1", fixture(rng, 271, 300, 12), 12, False, ["-e", "1"]),
            ("gray12-groups", fixture(rng, 520, 600, 12), 12, False, ["-e", "7", "-g", "1"]),
            ("gray12-squeeze", fixture(rng, 271, 300, 12), 12, False, ["-e", "7", "-R", "1"]),
            ("gray12-progressive", fixture(rng, 520, 600, 12), 12, False, ["-e", "7", "-p"]),
            ("gray16", fixture(rng, 257, 513, 16), 16, False, ["-e", "7"]),
            ("gray12-signed", fixture(rng, 271, 300, 12, signed=True), 12, True, ["-e", "7"]),
            ("gray16-signed", fixture(rng, 271, 300, 16, signed=True), 16, True, ["-e", "7"]),
            ("gray8-palette", (rng.integers(0, 12, (271, 300)) * 21).astype(np.int64), 8, False, ["-e", "7"]),
            ("rgb8", fixture(rng, 271, 300, 8, channels=3), 8, False, ["-e", "7"]),
            ("rgb8-rct13", fixture(rng, 150, 200, 8, channels=3), 8, False, ["-e", "7", "-C", "13"]),
        ]
        for name, array, precision, signed, flags in cases:
            unsigned = array + (1 << (precision - 1)) if signed else array
            codestream = cjxl_encode(work, name, unsigned, precision, flags).read_bytes()
            path = work / f"{name}.dcm"
            photometric = "RGB" if array.ndim == 3 else "MONOCHROME2"
            dicom_wrap(path, codestream, LOSSLESS, array, precision, signed, photometric)
            decoded = our_decode(args.binary, path, work, array.shape[:2], precision, signed, 3 if array.ndim == 3 else 1)
            require(np.array_equal(decoded, array), f"{name}: own decode differs from the cjxl source")
            results["libjxlDecodedByOwn"] += 1

        # 2. Own objects: fragments, djxl exactness, native round trip, ICC passthrough.
        gray_icc = Path("/System/Library/ColorSync/Profiles/Generic Gray Profile.icc")
        rgb_icc = Path("/System/Library/ColorSync/Profiles/sRGB Profile.icc")
        icc_bytes = gray_icc.read_bytes() if gray_icc.is_file() else None
        rgb_icc_bytes = rgb_icc.read_bytes() if rgb_icc.is_file() else None
        own_cases = [
            ("own-gray8", fixture(rng, 37, 53, 8), 8, False, LOSSLESS, 1, None),
            ("own-gray12-signed-frames", np.concatenate([fixture(rng, 45, 71, 12, signed=True, seed=i) for i in range(3)]), 12, True, LOSSLESS, 3, icc_bytes),
            ("own-gray16", fixture(rng, 257, 513, 16), 16, False, LOSSLESS, 1, None),
            ("own-gray16-signed-general", fixture(rng, 271, 300, 16, signed=True), 16, True, GENERAL, 1, None),
            ("own-gray4", (fixture(rng, 37, 53, 4)), 4, False, LOSSLESS, 1, None),
            ("own-rgb8", fixture(rng, 271, 300, 8, channels=3), 8, False, LOSSLESS, 1, None),
            ("own-rgb8-general", fixture(rng, 301, 277, 8, channels=3), 8, False, GENERAL, 1, rgb_icc_bytes),
            ("own-gray12-groups", fixture(rng, 520, 600, 12), 12, False, LOSSLESS, 1, None),
        ]
        for name, array, precision, signed, syntax, frames, profile in own_cases:
            native = work / f"{name}-native.dcm"
            photometric = "RGB" if array.ndim == 3 else "MONOCHROME2"
            native_dicom(native, array, precision, signed, photometric, frames, profile)
            compressed = work / f"{name}.dcm"
            code, _, err = run([args.binary, "codec", "transcode", native, "--output", compressed, "--transfer-syntax", syntax, "--format", "json"])
            require(code == 0, f"transcode {name}: {err}")
            ds = read_part10(compressed)
            require(ds.file_meta.TransferSyntaxUID == syntax, f"{name}: wrong transfer syntax")
            frags = fragments_of(ds)
            require(len(frags) == frames, f"{name}: {len(frags)} fragments for {frames} frames")
            require(all(len(f) % 2 == 0 for f in frags), f"{name}: odd fragment length")
            require(int(ds.BitsStored) == precision and int(ds.PixelRepresentation) == (1 if signed else 0), f"{name}: pixel module changed")
            rows = array.shape[0] // frames
            for index, fragment in enumerate(frags):
                # PS3.5 pads odd codestreams with one trailing 0x00; a trailing zero may also be codestream data.
                candidates = [fragment[:-1], fragment] if fragment[-1:] == b"\x00" else [fragment]
                require(fragment[:2] == b"\xff\x0a", f"{name}: fragment {index} is not a raw codestream")
                decoded = maxval = codestream = None
                for candidate in candidates:
                    try:
                        decoded, maxval = read_pnm(djxl_decode(work, f"{name}-{index}", candidate))
                        codestream = candidate
                        break
                    except ValueError:
                        continue
                require(codestream is not None, f"{name}: djxl could not decode fragment {index}")
                require(maxval == (1 << precision) - 1, f"{name}: djxl reports {maxval} for {precision} bits")
                expected = array[index * rows:(index + 1) * rows]
                if signed:
                    expected = expected + (1 << (precision - 1))
                require(np.array_equal(decoded, expected), f"{name}: djxl output differs at frame {index}")
                results["ownDecodedByLibjxl"] += 1
                if profile is not None:
                    require(png_icc(djxl_decode(work, f"{name}-{index}-icc", codestream, png=True)) == profile,
                            f"{name}: the ICC profile did not survive inside the codestream")
                    results["iccPassthrough"] += 1
            if profile is not None:
                require(bytes(ds.ICCProfile) == profile, f"{name}: ICC Profile element lost")
            restored = work / f"{name}-restored.dcm"
            code, _, err = run([args.binary, "codec", "transcode", compressed, "--output", restored, "--transfer-syntax", ExplicitVRLittleEndian, "--format", "json"])
            require(code == 0, f"restore {name}: {err}")
            back = pydicom.dcmread(restored)
            dtype = ("<i2" if signed else "<u2") if precision > 8 else np.uint8
            expected_native = array.astype(dtype).tobytes()
            # Native Pixel Data is padded to an even length.
            require(len(back.PixelData) - len(expected_native) in (0, 1) and back.PixelData[:len(expected_native)] == expected_native,
                    f"{name}: native round trip differs")
            if profile is not None:
                require(bytes(back.ICCProfile) == profile, f"{name}: ICC Profile element lost on the way back")
            results["dicomObjects"] += 1

        # 3. Typed refusals.
        gray12 = fixture(rng, 37, 53, 12)
        stream = cjxl_encode(work, "refusal-12", gray12, 12, ["-e", "3"]).read_bytes()
        mismatch = work / "refusal-bits.dcm"
        dicom_wrap(mismatch, stream, LOSSLESS, gray12, 16, False, "MONOCHROME2")
        code, _, _ = run([args.binary, "codec", "decode", mismatch, "--output", work / "refusal.raw", "--format", "json"])
        require(code != 0, "a 12-bit codestream under Bits Stored 16 must be refused")
        results["refusals"] += 1
        native = work / "refusal-native.dcm"
        native_dicom(native, gray12, 12, False, "MONOCHROME2")
        code, _, _ = run([args.binary, "codec", "transcode", native, "--output", work / "refusal-lossy.dcm", "--transfer-syntax", LOSSLESS, "--format", "json", "--quality", "0.5"])
        require(code != 0, "irreversible intent on the lossless-only UID must be refused")
        results["refusals"] += 1
        bomb_source = fixture(rng, 8, 8, 8)
        bomb = bytearray(cjxl_encode(work, "bomb", bomb_source, 8, ["-e", "3"]).read_bytes())
        big = fixture(rng, 8, 8, 8)
        wrapped = work / "bomb.dcm"
        dicom_wrap(wrapped, bytes(bomb), LOSSLESS, np.zeros((4096, 4096), dtype=np.int64), 8, False, "MONOCHROME2")
        code, _, _ = run([args.binary, "codec", "decode", wrapped, "--output", work / "bomb.raw", "--format", "json"])
        require(code != 0, "a codestream whose size disagrees with Rows/Columns must be refused")
        results["refusals"] += 1
        _ = big
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps(results, indent=2))
    print(f"PASS: {results['libjxlDecodedByOwn']} libjxl streams decoded exactly by the own core, "
          f"{results['ownDecodedByLibjxl']} own frames decoded exactly by djxl, {results['dicomObjects']} DICOM objects "
          f"reopened by pydicom, {results['iccPassthrough']} ICC passthroughs, {results['refusals']} typed refusals")


if __name__ == "__main__":
    main()
