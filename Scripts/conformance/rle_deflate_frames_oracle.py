#!/usr/bin/env python3
"""Independent check of the own RLE codec and the Deflated Image Frame Compression routes with pydicom 3.0.2 (#2335).

RLE: pydicom's Annex G encoder produces RLE Lossless objects (16-bit signed with three frames, 8-bit RGB, 8-bit
MONOCHROME1, odd 7x5 frames) that `dicomtool codec transcode` decodes to Explicit VR Little Endian; pydicom must
read the identical stored samples. The reverse direction (dicomtool encodes, pydicom decodes) is checked on the same
sources, and pydicom-encoded 32-bit and 16-bit colour RLE objects must be refused typed rather than decoded wrongly.

Deflated Image Frame Compression (1.2.840.10008.1.2.8.1, PS3.5 8.2.16): objects are built with pydicom and Python's
zlib as raw DEFLATE streams (one fragment per frame, single NULL pad on odd lengths) for 16-bit signed, 8-bit RGB in
both planar configurations, 1-bit bilevel, 32-bit grey and MONOCHROME1 frames; dicomtool inflates them to native
objects whose Pixel Data bytes equal the source bytes, deflates native objects into fragments that zlib inflates to
the native frame bytes with even lengths and a kept SOP Instance UID, and transcodes between the two deflate
mechanisms (dataset deflate 1.2.840.10008.1.2.1.99 and frame deflate) without confusing them. A truncated fragment
is refused with no output. Only counts are recorded.
"""
import argparse
import importlib.metadata
import json
import subprocess
import tempfile
import zlib
from pathlib import Path

import numpy as np
import pydicom
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.encaps import encapsulate, generate_fragments
from pydicom.uid import DeflatedExplicitVRLittleEndian, ExplicitVRLittleEndian, RLELossless
from image_iod_oracle import require
from jpegxl_modular_oracle import read_part10, write_part10

NATIVE = "1.2.840.10008.1.2.1"
DEFLATED_FRAMES = "1.2.840.10008.1.2.8.1"
SOURCE_UID = "2.25.23350100"


def run(args):
    completed = subprocess.run([str(a) for a in args], capture_output=True, timeout=600)
    return completed.returncode, completed.stdout, completed.stderr.decode(errors="replace")[:300]


def make_dataset(rows, columns, frames, samples, bits, signed, photometric, planar=None):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = SOURCE_UID
    ds.StudyInstanceUID = "2.25.23350101"
    ds.SeriesInstanceUID = "2.25.23350102"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "Deflate^Oracle", "DF-1", "OT", "WSD"
    ds.ImageType = ["ORIGINAL", "PRIMARY"]
    ds.InstanceNumber = "1"
    ds.Rows, ds.Columns = rows, columns
    ds.SamplesPerPixel = samples
    ds.PhotometricInterpretation = photometric
    if samples > 1:
        ds.PlanarConfiguration = 0 if planar is None else planar
    if frames > 1:
        ds.NumberOfFrames = frames
    ds.BitsAllocated, ds.BitsStored, ds.HighBit = bits, bits, bits - 1
    ds.PixelRepresentation = 1 if signed else 0
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
    return ds


def frame_bytes(rows, columns, frames, samples, bits, signed, planar, seed):
    """Deterministic native frame bytes (little endian), one bytes object per frame."""
    rng = np.random.default_rng(seed)
    out = []
    for frame in range(frames):
        if bits == 1:
            values = (rng.random((rows * columns,)) < 0.3).astype(np.uint8)
            out.append(np.packbits(values, bitorder="little").tobytes())
            continue
        dtype = {8: np.int8 if signed else np.uint8, 16: np.int16 if signed else np.uint16, 32: np.int32 if signed else np.uint32}[bits]
        info = np.iinfo(dtype)
        array = rng.integers(info.min, info.max, size=(rows, columns, samples), dtype=np.int64)
        array[:2, :, :] = -3 if signed else 5  # runs for RLE
        array = array.astype(dtype)
        if planar == 1:
            array = np.transpose(array, (2, 0, 1))
        out.append(array.astype(array.dtype.newbyteorder("<")).tobytes())
    return out


def deflate_fragment(frame):
    compressor = zlib.compressobj(wbits=-15)
    stream = compressor.compress(frame) + compressor.flush()
    return stream + (b"\x00" if len(stream) % 2 else b"")


def inflate_fragment(fragment, expected):
    decompressor = zlib.decompressobj(wbits=-15)
    data = decompressor.decompress(fragment, expected + 1)
    require(decompressor.eof, "fragment does not end its DEFLATE stream")
    require(len(decompressor.unused_data) <= 1 and all(b == 0 for b in decompressor.unused_data), "trailing bytes after the stream")
    return data


def packbits_row(row):
    out = bytearray()
    i = 0
    while i < len(row):
        run = 1
        while i + run < len(row) and row[i + run] == row[i] and run < 128:
            run += 1
        if run >= 2:
            out += bytes([(257 - run) & 0xFF, row[i]])
            i += run
            continue
        start = i
        while i < len(row) and i - start < 128 and not (i + 2 < len(row) and row[i] == row[i + 1] == row[i + 2]):
            i += 1
        out += bytes([i - start - 1]) + row[start:i]
    return bytes(out)


def rle_encode_frame(frame, rows, columns, samples, bytes_per_sample):
    """Independent PS3.5 Annex G encoder: one segment per (sample, byte) with the most significant byte first."""
    pixels = rows * columns
    segments = []
    for sample in range(samples):
        for byte in reversed(range(bytes_per_sample)):
            plane = bytes(frame[(p * samples + sample) * bytes_per_sample + byte] for p in range(pixels))
            packed = b"".join(packbits_row(plane[r * columns:(r + 1) * columns]) for r in range(rows))
            segments.append(packed + (b"\x00" if len(packed) % 2 else b""))
    header = [len(segments)] + [0] * 15
    offset = 64
    for index, segment in enumerate(segments):
        header[index + 1] = offset
        offset += len(segment)
    return b"".join(int(v).to_bytes(4, "little") for v in header) + b"".join(segments)


def fragments_of(ds):
    return list(generate_fragments(ds.PixelData))[1:]


def native_pixel_bytes(path):
    ds = pydicom.dcmread(path)
    return bytes(ds.PixelData), ds


def transcode(binary, source, destination, syntax, extra=()):
    return run([binary, "codec", "transcode", source, "--output", destination, "--transfer-syntax", syntax, "--format", "json", *extra])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(importlib.metadata.version("pydicom") == "3.0.2", "Wrong pydicom version")
    work = Path(tempfile.mkdtemp(prefix="isis-rle-deflate-oracle-"))
    results = {"rleObjectsDecodedFromPydicom": 0, "rleObjectsEncodedForPydicom": 0, "rleTypedRefusals": 0,
               "deflatedFrameObjectsInflated": 0, "deflatedFramesEncoded": 0, "deflatedFrameFragmentsChecked": 0,
               "deflateMechanismsComposed": 0, "malformedRefusals": 0}

    # --- RLE both directions -------------------------------------------------------------------
    rle_cases = [
        ("gray16-signed", 8, 10, 3, 1, 16, True, "MONOCHROME2"),
        ("rgb8", 8, 10, 2, 3, 8, False, "RGB"),
        ("mono1-8", 7, 5, 2, 1, 8, False, "MONOCHROME1"),
        ("gray16-odd", 7, 5, 1, 1, 16, False, "MONOCHROME2"),
    ]
    for name, rows, columns, frames, samples, bits, signed, photometric in rle_cases:
        ds = make_dataset(rows, columns, frames, samples, bits, signed, photometric)
        raw = b"".join(frame_bytes(rows, columns, frames, samples, bits, signed, 0, seed=len(name)))
        ds.PixelData = raw + (b"\x00" if len(raw) % 2 else b"")
        native = work / f"{name}-native.dcm"
        ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
        ds.save_as(native, enforce_file_format=True)
        ds.compress(RLELossless, encoding_plugin="pydicom")
        rle = work / f"{name}-pydicom-rle.dcm"
        ds.save_as(rle, enforce_file_format=True)
        # pydicom RLE → dicomtool → native
        decoded = work / f"{name}-from-rle.dcm"
        code, _, err = transcode(args.binary, rle, decoded, NATIVE)
        require(code == 0, f"{name}: RLE decode failed: {err}")
        got, got_ds = native_pixel_bytes(decoded)
        require(got_ds.file_meta.TransferSyntaxUID == NATIVE and got[:len(raw)] == raw, f"{name}: RLE decode differs from the stored samples")
        require(np.array_equal(got_ds.pixel_array, pydicom.dcmread(native).pixel_array), f"{name}: pixel arrays differ")
        results["rleObjectsDecodedFromPydicom"] += 1
        # native → dicomtool RLE → pydicom
        ours = work / f"{name}-dicomtool-rle.dcm"
        code, _, err = transcode(args.binary, native, ours, RLELossless)
        require(code == 0, f"{name}: RLE encode failed: {err}")
        ours_ds = pydicom.dcmread(ours)
        require(ours_ds.file_meta.TransferSyntaxUID == RLELossless and ours_ds.SOPInstanceUID == SOURCE_UID, f"{name}: RLE object identity")
        require(len(fragments_of(ours_ds)) == frames, f"{name}: one fragment per frame expected")
        require(np.array_equal(ours_ds.pixel_array, pydicom.dcmread(native).pixel_array), f"{name}: pydicom does not reproduce our RLE")
        results["rleObjectsEncodedForPydicom"] += 1
    # The independent Annex G encoder above must agree with pydicom's on an accepted shape before it is trusted for
    # the shapes pydicom refuses to encode (32-bit) or the decoder contract excludes (16-bit colour).
    check = frame_bytes(8, 10, 1, 1, 16, True, 0, seed=3)[0]
    check_ds = make_dataset(8, 10, 1, 1, 16, True, "MONOCHROME2")
    check_ds.PixelData = encapsulate([rle_encode_frame(check, 8, 10, 1, 2)])
    check_ds["PixelData"].is_undefined_length = True
    check_path = work / "encoder-check-rle.dcm"
    write_part10(check_path, check_ds, RLELossless)
    require(pydicom.dcmread(check_path).pixel_array.tobytes() == np.frombuffer(check, dtype="<i2").reshape(8, 10).tobytes(),
            "independent RLE encoder is not read back by pydicom")
    for name, samples, bits in [("gray32", 1, 32), ("rgb16", 3, 16)]:
        ds = make_dataset(4, 6, 1, samples, bits, False, "RGB" if samples == 3 else "MONOCHROME2")
        frame = frame_bytes(4, 6, 1, samples, bits, False, 0, seed=9)[0]
        ds.PixelData = encapsulate([rle_encode_frame(frame, 4, 6, samples, bits // 8)])
        ds["PixelData"].is_undefined_length = True
        rle = work / f"{name}-rle.dcm"
        write_part10(rle, ds, RLELossless)
        refused = work / f"{name}-refused.dcm"
        code, _, _ = transcode(args.binary, rle, refused, NATIVE)
        require(code != 0 and not refused.exists(), f"{name}: an RLE shape outside the decoder contract must be refused typed")
        results["rleTypedRefusals"] += 1

    # --- Deflated Image Frame Compression ------------------------------------------------------
    deflate_cases = [
        ("gray16-signed", 8, 10, 3, 1, 16, True, "MONOCHROME2", None),
        ("rgb8-planar0", 8, 10, 2, 3, 8, False, "RGB", 0),
        ("rgb8-planar1", 8, 10, 2, 3, 8, False, "RGB", 1),
        ("bilevel", 8, 9, 2, 1, 1, False, "MONOCHROME2", None),
        ("gray32", 5, 7, 2, 1, 32, False, "MONOCHROME2", None),
        ("mono1-8", 7, 5, 3, 1, 8, False, "MONOCHROME1", None),
    ]
    for name, rows, columns, frames, samples, bits, signed, photometric, planar in deflate_cases:
        # dicomtool's decoded-pixel verification runs through the typed frame pipeline (8/16-bit grey, 8-bit RGB);
        # 1-bit and 32-bit objects are transcoded without it and their bytes are compared here instead.
        verify = [] if bits in (8, 16) else ["--no-verify-decoded-pixels"]
        frames_bytes = frame_bytes(rows, columns, frames, samples, bits, signed, planar, seed=100 + len(name))
        raw = b"".join(frames_bytes)
        ds = make_dataset(rows, columns, frames, samples, bits, signed, photometric, planar)
        ds.PixelData = encapsulate([deflate_fragment(f) for f in frames_bytes])
        ds["PixelData"].is_undefined_length = True
        source = work / f"{name}-81.dcm"
        write_part10(source, ds, DEFLATED_FRAMES)
        # .8.1 → native: byte-exact frames and untouched attributes
        native = work / f"{name}-native.dcm"
        code, _, err = transcode(args.binary, source, native, NATIVE, verify)
        require(code == 0, f"{name}: inflate failed: {err}")
        got, got_ds = native_pixel_bytes(native)
        require(got_ds.file_meta.TransferSyntaxUID == NATIVE and got[:len(raw)] == raw and len(got) == len(raw) + len(raw) % 2, f"{name}: native bytes differ")
        require(got_ds.SOPInstanceUID == SOURCE_UID and got_ds.PhotometricInterpretation == photometric, f"{name}: attributes changed")
        require(got_ds.get("PlanarConfiguration") == planar, f"{name}: planar configuration changed")
        require(got_ds.pixel_array.size == rows * columns * frames * samples, f"{name}: pydicom cannot read the native object")
        results["deflatedFrameObjectsInflated"] += 1
        # native → .8.1: one raw DEFLATE fragment per frame, even lengths, exact inflation
        back = work / f"{name}-back-81.dcm"
        code, _, err = transcode(args.binary, native, back, DEFLATED_FRAMES, verify)
        require(code == 0, f"{name}: deflate failed: {err}")
        back_ds = read_part10(back)
        require(back_ds.file_meta.TransferSyntaxUID == DEFLATED_FRAMES and back_ds.SOPInstanceUID == SOURCE_UID, f"{name}: identity")
        require(back_ds.PhotometricInterpretation == photometric and back_ds.get("PlanarConfiguration") == planar, f"{name}: attributes changed on encode")
        frags = fragments_of(back_ds)
        require(len(frags) == frames, f"{name}: {len(frags)} fragments for {frames} frames")
        for index, (fragment, frame) in enumerate(zip(frags, frames_bytes)):
            require(len(fragment) % 2 == 0, f"{name}: odd fragment {index}")
            require(len(fragment) < len(frame) or len(frame) < 64, f"{name}: fragment {index} is not compressed")
            require(inflate_fragment(bytes(fragment), len(frame)) == frame, f"{name}: fragment {index} does not inflate to the frame")
            results["deflatedFrameFragmentsChecked"] += 1
        results["deflatedFramesEncoded"] += 1
        # Between the two deflate mechanisms: dataset deflate ↔ frame deflate (pydicom reads the deflated dataset).
        dataset_deflated = work / f"{name}-199.dcm"
        code, _, err = transcode(args.binary, source, dataset_deflated, DeflatedExplicitVRLittleEndian, verify)
        require(code == 0, f"{name}: .8.1 → .1.99 failed: {err}")
        dd = pydicom.dcmread(dataset_deflated)
        require(dd.file_meta.TransferSyntaxUID == DeflatedExplicitVRLittleEndian and bytes(dd.PixelData)[:len(raw)] == raw, f"{name}: dataset deflate differs")
        again = work / f"{name}-199-81.dcm"
        code, _, err = transcode(args.binary, dataset_deflated, again, DEFLATED_FRAMES, verify)
        require(code == 0, f"{name}: .1.99 → .8.1 failed: {err}")
        again_frags = fragments_of(read_part10(again))
        require([inflate_fragment(bytes(f), len(fr)) for f, fr in zip(again_frags, frames_bytes)] == frames_bytes, f"{name}: frames after both mechanisms")
        results["deflateMechanismsComposed"] += 1
    # A truncated fragment is refused with no output.
    frames_bytes = frame_bytes(8, 10, 2, 1, 16, True, None, seed=7)
    fragments = [deflate_fragment(f) for f in frames_bytes]
    fragments[1] = fragments[1][: len(fragments[1]) // 2]
    ds = make_dataset(8, 10, 2, 1, 16, True, "MONOCHROME2")
    ds.PixelData = encapsulate(fragments)
    ds["PixelData"].is_undefined_length = True
    broken = work / "broken-81.dcm"
    write_part10(broken, ds, DEFLATED_FRAMES)
    refused = work / "broken-native.dcm"
    code, _, _ = transcode(args.binary, broken, refused, NATIVE)
    require(code != 0 and not refused.exists(), "a truncated fragment must be refused without output")
    results["malformedRefusals"] += 1

    args.output.write_text(json.dumps(results, indent=2))
    print(f"PASS: {results['rleObjectsDecodedFromPydicom']} pydicom RLE objects decoded, {results['rleObjectsEncodedForPydicom']} own RLE objects read by pydicom, "
          f"{results['deflatedFrameObjectsInflated']} Deflated Image Frame objects inflated, {results['deflatedFrameFragmentsChecked']} fragments verified by zlib")


if __name__ == "__main__":
    main()
