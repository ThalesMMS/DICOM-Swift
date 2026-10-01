#!/usr/bin/env python3
"""Independent check of the own JPEG 2000 Part 2 Multi-component codec (`.92/.93`, PS3.5 8.2.4) with OpenJPEG 2.5, numpy and
pydicom (#2331).

No independent ISO/IEC 15444-2 Annex J decoder is available locally (OpenJPEG writes but rejects the T.801 SGcod value 2),
so the evidence is assembled from independent pieces. Part 2 streams are *built* here: numpy applies a forward array-based
transformation across frames, `opj_compress` codes the transformed components as a plain Part 1 stream, and this script
writes the CBD/MCT/MCC/MCO marker segments from the T.801 layout (as OpenJPEG's writer emits them) — then `dicomtool
codec decode` must return the original frames exactly (integer transformations) or within rounding (float matrices),
including permuted output collections. Own `.92/.93` objects written by `dicomtool codec transcode` are taken apart the
other way: the Annex J signalling is stripped, `opj_decompress` decodes the coded components, and numpy applies the
decoding matrix and offsets parsed from the markers — the result must equal the source frames. The DICOM layer is checked
with pydicom: one fragment per collection of at most 64 frames, an empty Basic Offset Table, Number of Frames equal to the
component total, loss provenance only under `.93` with an explicit irreversible intent, and `.92 → .93` as a copy.
Malformed objects must fail typed. Only counts and maxima are kept.
"""
import argparse
import importlib.metadata
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

import numpy as np
import pydicom
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.encaps import encapsulate, generate_fragments
from pydicom.uid import ExplicitVRLittleEndian
from image_iod_oracle import require

LOSSLESS = "1.2.840.10008.1.2.4.92"
GENERAL = "1.2.840.10008.1.2.4.93"
SOURCE_UID = "2.25.23310011"


def run(args, **kwargs):
    completed = subprocess.run([str(a) for a in args], capture_output=True, timeout=900, **kwargs)
    return completed.returncode, completed.stdout, completed.stderr.decode(errors="replace")[:400]


def dataset(frames, precision, signed):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = SOURCE_UID
    ds.StudyInstanceUID = "2.25.23310012"
    ds.SeriesInstanceUID = "2.25.23310013"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "PART2^Oracle", "P2-1", "OT", "WSD"
    ds.ImageType = ["ORIGINAL", "PRIMARY"]
    ds.Rows, ds.Columns = frames.shape[1], frames.shape[2]
    ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, "MONOCHROME2"
    if frames.shape[0] > 1:
        ds.NumberOfFrames = frames.shape[0]
    ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = (16 if precision > 8 else 8), precision, precision - 1, 1 if signed else 0
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
    ds.is_little_endian, ds.is_implicit_VR = True, False
    return ds


def native_dicom(path, frames, precision, signed):
    ds = dataset(frames, precision, signed)
    ds.PixelData = frames.astype(("<i2" if signed else "<u2") if precision > 8 else np.uint8).tobytes()
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.save_as(path, enforce_file_format=True)


def part2_dicom(path, collections, frames, precision, signed, syntax):
    ds = dataset(frames, precision, signed)
    ds.PixelData = encapsulate([bytes(c) for c in collections], has_bot=False)
    ds["PixelData"].is_undefined_length = True
    ds.file_meta.TransferSyntaxUID = syntax
    ds.save_as(path, enforce_file_format=True)


def fragments(ds):
    return [bytes(f) for f in generate_fragments(ds.PixelData) if len(f) > 4]


def our_decode(binary, dicom_path, work, frames_shape, precision, signed):
    raw = work / (dicom_path.stem + ".decoded")
    code, _, err = run([binary, "codec", "decode", dicom_path, "--output", raw, "--format", "json"])
    require(code == 0, f"dicomtool decode failed for {dicom_path.name}: {err}")
    # `codec decode` writes the frame-reader pixel contract: signed 16-bit samples are offset to unsigned.
    array = np.frombuffer(raw.read_bytes(), dtype="<u2" if precision > 8 else np.uint8).astype(np.int64)
    if signed and precision > 8:
        array = array - 32768
    require(array.size == int(np.prod(frames_shape)), f"{dicom_path.name}: decoded {array.size} samples, expected {np.prod(frames_shape)}")
    return array.reshape(frames_shape)


def main_header(codestream):
    markers, cursor = {}, 2
    while cursor + 4 <= len(codestream) and codestream[cursor] == 0xFF and codestream[cursor + 1] != 0x90:
        length = int.from_bytes(codestream[cursor + 2:cursor + 4], "big")
        markers.setdefault(codestream[cursor + 1], []).append(codestream[cursor + 4:cursor + 2 + length])
        cursor += 2 + length
    return markers, cursor


def strip_annex_j(codestream):
    """Removes the Annex J segments, the Part 2 capabilities and the SGcod value so a Part 1 decoder sees the coded components."""
    out, cursor = bytearray(codestream[:2]), 2
    while cursor + 4 <= len(codestream) and codestream[cursor] == 0xFF and codestream[cursor + 1] != 0x90:
        length = int.from_bytes(codestream[cursor + 2:cursor + 4], "big")
        segment = bytearray(codestream[cursor:cursor + 2 + length])
        if codestream[cursor + 1] == 0x51:
            segment[4:6] = (0).to_bytes(2, "big")
        if codestream[cursor + 1] == 0x52:
            segment[8] = 0
        if codestream[cursor + 1] not in (0x75, 0x76, 0x77, 0x78):
            out += segment
        cursor += 2 + length
    out += codestream[cursor:]
    return bytes(out)


def parse_annex_j(markers):
    arrays = {}
    for segment in markers.get(0x75, []):
        imct = int.from_bytes(segment[2:4], "big")
        kind, element = (imct >> 8) & 3, (imct >> 10) & 3
        fmt = {0: "h", 1: "i", 2: "f", 3: "d"}[element]
        count = (len(segment) - 6) // struct.calcsize(fmt)
        arrays[imct & 0xFF] = (kind, np.array(struct.unpack(f">{count}{fmt}", segment[6:6 + count * struct.calcsize(fmt)]), dtype=float))
    mcc = markers[0x77][0]
    require(int.from_bytes(mcc[5:7], "big") == 1, "one collection per MCC expected")
    offset = 7
    kind = mcc[offset]; offset += 1
    n = int.from_bytes(mcc[offset:offset + 2], "big"); wide = 2 if n & 0x8000 else 1; n &= 0x7FFF; offset += 2
    inputs = [int.from_bytes(mcc[offset + k * wide:offset + (k + 1) * wide], "big") for k in range(n)]; offset += n * wide
    m = int.from_bytes(mcc[offset:offset + 2], "big"); wide2 = 2 if m & 0x8000 else 1; m &= 0x7FFF; offset += 2
    outputs = [int.from_bytes(mcc[offset + k * wide2:offset + (k + 1) * wide2], "big") for k in range(m)]; offset += m * wide2
    tmcc = int.from_bytes(mcc[offset:offset + 3], "big")
    stages = list(markers[0x76][0][1:])
    cbd = markers[0x78][0]
    ncbd = int.from_bytes(cbd[:2], "big") & 0x7FFF
    depths = [(int(x & 0x7F) + 1, bool(x & 0x80)) for x in cbd[2:2 + ncbd]]
    require(kind == 1 and stages == [1], "array-based single-stage collection expected")
    decorrelation, offsets = arrays[tmcc & 0xFF], arrays.get((tmcc >> 8) & 0xFF)
    require(decorrelation[0] == 1 and (offsets is None or offsets[0] == 2), "decorrelation and offset arrays expected")
    return dict(inputs=inputs, outputs=outputs, reversible=(tmcc >> 16) & 1, matrix=decorrelation[1].reshape(m, n),
                offsets=offsets[1] if offsets is not None else np.zeros(m), depths=depths)


def opj_coded_components(codestream, work, name):
    """Decodes a Part 1 stream with opj_decompress into PGX components (raw output refuses more than 16 bits)."""
    path = work / f"{name}.j2k"
    path.write_bytes(codestream)
    out = work / f"{name}.pgx"
    code, _, err = run(["opj_decompress", "-i", path, "-o", out])
    require(code == 0, f"opj_decompress {name}: {err}")
    planes = []
    index = 0
    while (work / f"{name}_{index}.pgx").exists():
        data = (work / f"{name}_{index}.pgx").read_bytes()
        newline = data.index(b"\n")
        header = data[:newline].split()
        depth, width, height = int(header[3]), int(header[4]), int(header[5])
        signed = header[2] == b"-"
        dtype = {1: ">i1" if signed else ">u1", 2: ">i2" if signed else ">u2", 4: ">i4" if signed else ">u4"}[1 if depth <= 8 else (2 if depth <= 16 else 4)]
        planes.append(np.frombuffer(data[newline + 1:], dtype=dtype).astype(np.int64).reshape(height, width))
        index += 1
    require(planes, f"opj_decompress {name}: no PGX component")
    return np.stack(planes)


def opj_encode_components(components, precision, work, name):
    """Codes signed components as a plain Part 1 stream (little-endian raw planes; opj rejects >16-bit raw input)."""
    require(precision <= 16, "opj_compress reads raw components of at most 16 bits")
    raw = work / f"{name}.rawl"
    raw.write_bytes(components.astype("<i2" if precision > 8 else np.int8).tobytes())
    out = work / f"{name}-coded.j2k"
    code, _, err = run(["opj_compress", "-i", raw, "-o", out, "-F", f"{components.shape[2]},{components.shape[1]},{components.shape[0]},{precision},s",
                        "-mct", "0", "-n", "3"])
    require(code == 0, f"opj_compress {name}: {err}")
    return out.read_bytes()


def segment(marker, payload):
    return marker.to_bytes(2, "big") + (len(payload) + 2).to_bytes(2, "big") + payload


def build_annex_j(codestream, matrix, integer_matrix, offsets, inputs, outputs, output_depth, output_signed, reversible):
    """Inserts CBD, MCT (decorrelation + offsets), MCC and MCO written from the T.801 layout; Rsiz gains the Part 2 and
    Annex J bits and SGcod becomes 2 (T.801 Table A.8)."""
    n = len(outputs)
    extra = segment(0xFF78, n.to_bytes(2, "big") + bytes([(0x80 if output_signed else 0) | (output_depth - 1)] * n))
    imct = 1 | (1 << 8) | ((1 if integer_matrix else 2) << 10)
    coefficients = struct.pack(f">{n * n}i", *[int(v) for v in matrix.flatten()]) if integer_matrix else struct.pack(f">{n * n}f", *matrix.flatten())
    extra += segment(0xFF75, (0).to_bytes(2, "big") + imct.to_bytes(2, "big") + (0).to_bytes(2, "big") + coefficients)
    ioff = 2 | (2 << 8) | (1 << 10)
    extra += segment(0xFF75, (0).to_bytes(2, "big") + ioff.to_bytes(2, "big") + (0).to_bytes(2, "big") + struct.pack(f">{n}i", *offsets))
    mcc = (0).to_bytes(2, "big") + bytes([1]) + (0).to_bytes(2, "big") + (1).to_bytes(2, "big") + bytes([1])
    mcc += len(inputs).to_bytes(2, "big") + bytes(inputs) + len(outputs).to_bytes(2, "big") + bytes(outputs)
    mcc += (1 | (2 << 8) | ((1 if reversible else 0) << 16)).to_bytes(3, "big")
    extra += segment(0xFF77, mcc) + segment(0xFF76, bytes([1, 1]))
    out, cursor = bytearray(codestream[:2]), 2
    while cursor + 4 <= len(codestream) and codestream[cursor] == 0xFF and codestream[cursor + 1] != 0x90:
        length = int.from_bytes(codestream[cursor + 2:cursor + 4], "big")
        seg = bytearray(codestream[cursor:cursor + 2 + length])
        if codestream[cursor + 1] == 0x51:
            seg[4:6] = (int.from_bytes(seg[4:6], "big") | 0x8001).to_bytes(2, "big")
        if codestream[cursor + 1] == 0x52:
            seg[8] = 2
        out += seg
        cursor += 2 + length
    return bytes(out) + extra + codestream[cursor:]


def fixture(rng, count, height, width, precision, signed=False):
    limit = 1 << precision
    base = rng.integers(0, limit, (height, width))
    frames = np.stack([np.clip(base + np.cumsum(rng.integers(-limit // 64, limit // 64, (k + 1, height, width)), axis=0)[-1], 0, limit - 1)
                       for k in range(count)]).astype(np.int64)
    return frames - limit // 2 if signed else frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    for tool in ("opj_compress", "opj_decompress"):
        require(shutil.which(tool) is not None, f"{tool} (OpenJPEG) is required")
    rng = np.random.default_rng(2331)
    work = Path(tempfile.mkdtemp(prefix="isis-jpeg2000-part2-oracle-"))
    results = {}
    try:
        # 1. Built Part 2 streams (numpy transformation, OpenJPEG-coded components, markers written here) decoded by dicomtool.
        # Widths and heights keep opj_compress's raw check happy (it rejects geometries whose bitwise AND with the component
        # count and depth is non-zero).
        built_cases = [
            ("built-difference-3x12", fixture(rng, 3, 40, 48, 12), 12, "difference", [0, 1, 2], [0, 1, 2], True, 0),
            ("built-difference-6x8", fixture(rng, 6, 32, 48, 8), 8, "difference", list(range(6)), list(range(6)), True, 0),
            ("built-permuted-outputs", fixture(rng, 3, 40, 48, 12), 12, "difference", [0, 1, 2], [2, 1, 0], True, 0),
            ("built-float-mix-3x12", fixture(rng, 3, 40, 48, 12), 12, "float", [0, 1, 2], [0, 1, 2], False, 1),
        ]
        for name, frames, precision, kind, inputs, outputs, reversible, tolerance in built_cases:
            count, height, width = frames.shape
            half = 1 << (precision - 1)
            if kind == "difference":
                forward = np.eye(count, dtype=int) - np.eye(count, k=-1, dtype=int)
                decoding = np.tril(np.ones((count, count), dtype=int))
            else:
                forward = np.array([[0.5, 0.5, 0], [-0.5, 0.5, 0], [0, 0, 1.0]])
                decoding = np.array([[1, -1, 0], [1, 1, 0], [0, 0, 1.0]])
            coded = np.einsum("ij,jhw->ihw", forward, frames - half)
            coded = np.round(coded).astype(np.int64)
            part1 = opj_encode_components(coded, precision + 1, work, name)
            stream = build_annex_j(part1, decoding, kind == "difference", [half] * count, inputs, outputs, precision, False, reversible)
            dicom = work / f"{name}.dcm"
            part2_dicom(dicom, [stream], frames, precision, False, LOSSLESS if reversible else GENERAL)
            # Output component outputs[i] receives row i of the decoding matrix applied to the inputs.
            reconstructed = np.zeros_like(frames)
            for i, component in enumerate(outputs):
                reconstructed[component] = np.einsum("j,jhw->hw", decoding[i], coded) + half
            reconstructed = np.clip(np.round(reconstructed), 0, (1 << precision) - 1).astype(np.int64)
            ours = our_decode(args.binary, dicom, work, frames.shape, precision, False)
            difference = int(np.max(np.abs(ours - reconstructed)))
            require(difference <= tolerance, f"{name}: own decode differs from the Annex J reconstruction by {difference}")
            results[name] = {"maxDifferenceVsReconstruction": difference, "tolerance": tolerance, "components": count}
        # 2. Own objects: transcode, take apart (markers → numpy inverse of OpenJPEG-decoded coded components) and reopen.
        encode_cases = [
            ("own-92-gray8-5", fixture(rng, 5, 36, 48, 8), 8, False, LOSSLESS, [], 0),
            ("own-92-signed12-70", fixture(rng, 70, 24, 40, 12, signed=True), 12, True, LOSSLESS, [], 0),
            ("own-92-gray16-4", fixture(rng, 4, 40, 52, 16), 16, False, LOSSLESS, [], 0),
            ("own-93-signed12-7-reversible", fixture(rng, 7, 36, 48, 12, signed=True), 12, True, GENERAL, [], 0),
            ("own-93-gray12-5-lossy", fixture(rng, 5, 36, 48, 12), 12, False, GENERAL, ["--quality", "0.9"], None),
        ]
        for name, frames, precision, signed, syntax, flags, tolerance in encode_cases:
            count, height, width = frames.shape
            source = work / f"{name}-source.dcm"
            native_dicom(source, frames, precision, signed)
            output = work / f"{name}.dcm"
            code, _, err = run([args.binary, "codec", "transcode", source, "--output", output, "--transfer-syntax", syntax, "--format", "json", *flags])
            require(code == 0, f"transcode {name}: {err}")
            ds = pydicom.dcmread(output)
            require(str(ds.file_meta.TransferSyntaxUID) == syntax and int(ds.NumberOfFrames) == count, f"{name}: syntax/frames")
            collections = fragments(ds)
            expected_collections = (count + 63) // 64
            require(len(collections) == expected_collections, f"{name}: {len(collections)} fragments for {count} frames (64 per collection)")
            require(ds.PixelData[4:8] == b"\x00\x00\x00\x00", f"{name}: the Basic Offset Table must be empty (fragments are collections, not frames)")
            first = 0
            worst = 0
            for index, collection in enumerate(collections):
                markers, _ = main_header(collection)
                siz = markers[0x51][0]
                require(int.from_bytes(siz[:2], "big") == 0x8001 and markers[0x52][0][4] == 2, f"{name}: Rsiz/SGcod of collection {index}")
                annex = parse_annex_j(markers)
                n = int.from_bytes(siz[34:36], "big")
                require(annex["inputs"] == list(range(n)) and annex["outputs"] == list(range(n)), f"{name}: identity collection lists")
                require(annex["reversible"] == 1, f"{name}: the integer difference transformation is flagged reversible (loss, if any, comes from the 9-7 coding)")
                require(annex["depths"] == [(precision, signed)] * n, f"{name}: CBD depths")
                coded = opj_coded_components(strip_annex_j(collection), work, f"{name}-{index}")
                require(coded.shape == (n, height, width), f"{name}: coded shape {coded.shape}")
                reconstructed = np.einsum("ij,jhw->ihw", annex["matrix"], coded)
                if annex["reversible"]:
                    reconstructed = np.round(reconstructed)
                reconstructed = reconstructed + annex["offsets"][:, None, None]
                slab = frames[first:first + n]
                difference = int(np.max(np.abs(np.round(reconstructed) - slab)))
                worst = max(worst, difference)
                first += n
            require(first == count, f"{name}: collections carry {first} components for {count} frames")
            if tolerance is None:
                require(worst <= (1 << precision) // 16, f"{name}: lossy reconstruction {worst} away from the source")
                require(ds.SOPInstanceUID != SOURCE_UID and ds.LossyImageCompression == "01", f"{name}: lossy provenance")
            else:
                require(worst == 0, f"{name}: the numpy inverse of the OpenJPEG-decoded components differs from the source by {worst}")
                require(ds.SOPInstanceUID == SOURCE_UID and "LossyImageCompression" not in ds, f"{name}: lossless keeps the identity")
            ours = our_decode(args.binary, output, work, frames.shape, precision, signed)
            own_difference = int(np.max(np.abs(ours - frames)))
            require(own_difference <= (0 if tolerance == 0 else (1 << precision) // 16), f"{name}: own decode differs by {own_difference}")
            results[name] = {"collections": len(collections), "maxDifferenceVsSource": worst, "ownDecodeMaxDifference": own_difference}
        # 3. .92 → .93 copies the collections; .93 irreversible under .92 is refused; a wrong frame count fails typed.
        lossless = work / "own-92-gray8-5.dcm"
        general = work / "rewrap-93.dcm"
        code, _, err = run([args.binary, "codec", "transcode", lossless, "--output", general, "--transfer-syntax", GENERAL, "--format", "json"])
        require(code == 0, f"rewrap to .93: {err}")
        require(fragments(pydicom.dcmread(general)) == fragments(pydicom.dcmread(lossless)), ".92 -> .93 must copy the collections")
        code, _, err = run([args.binary, "codec", "transcode", work / "own-92-gray8-5-source.dcm", "--output", work / "refused.dcm",
                            "--transfer-syntax", LOSSLESS, "--quality", "0.9", "--format", "json"])
        require(code != 0, "an irreversible request under .92 must be refused")
        ds = pydicom.dcmread(lossless)
        ds.NumberOfFrames = 6
        ds.save_as(work / "wrong-frames.dcm", enforce_file_format=True)
        code, _, err = run([args.binary, "codec", "decode", work / "wrong-frames.dcm", "--output", work / "wrong.raw", "--format", "json"])
        require(code != 0, "a frame count that disagrees with the collections must fail typed")
        results["rewrap-92-to-93"] = {"collectionsCopied": True}
        results["refusals"] = {"irreversibleUnder92": True, "frameCountMismatch": True}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps({"pydicomVersion": version, "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} JPEG 2000 Part 2 cases — built Annex J streams decoded exactly, own collections inverted from OpenJPEG-decoded components exactly, PS3.5 collection/fragment rules held")


if __name__ == "__main__":
    main()
