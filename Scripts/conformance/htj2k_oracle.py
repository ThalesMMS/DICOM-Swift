#!/usr/bin/env python3
"""Independent check of the own HTJ2K (ISO/IEC 15444-15) codec against OpenJPH, OpenJPEG 2.5 and pydicom (#2330).

OpenJPH's `ojph_compress` writes reference codestreams the own encoder never saw: 8/12/16-bit unsigned and 12/16-bit
signed grayscale (including full-range checkerboards that expose overflow), RGB with and without the RCT, tiles with
tile-parts and TLM markers, precincts and code-block sizes, every progression order and the irreversible 9-7 filter.
Each is wrapped in a Part 10 file with pydicom and decoded by `dicomtool codec decode`; reversible cases must equal the
source exactly and irreversible cases must stay within the documented tolerance of `ojph_expand`. Reduced-resolution
decodes (`--resolution-level`) are compared with `ojph_expand -skip_res`. The own encoder's `.201/.202/.203` outputs are
decoded by both `ojph_expand` and `opj_decompress` (exact for reversible), reopened by pydicom with one fragment per
frame and a raw codestream, and checked against the per-UID rules of PS3.5 8.2.14 and 10.18.1 (`.202`: RPCL, TLM,
base resolution of at most 64 samples). Loss comes from the explicit intent, never from the general UID. Only counts
and maxima are kept.
"""
import argparse
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import numpy as np
import pydicom
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.encaps import encapsulate, generate_frames
from pydicom.uid import ExplicitVRLittleEndian
from image_iod_oracle import require

LOSSLESS = "1.2.840.10008.1.2.4.201"
LOSSLESS_RPCL = "1.2.840.10008.1.2.4.202"
GENERAL = "1.2.840.10008.1.2.4.203"
SOURCE_UID = "2.25.23300011"
IRREVERSIBLE_TOLERANCE = 2  # 9-7 inverse DWT rounding between independent implementations


def run(args, **kwargs):
    completed = subprocess.run([str(a) for a in args], capture_output=True, timeout=600, **kwargs)
    return completed.returncode, completed.stdout, completed.stderr.decode(errors="replace")[:300]


def dataset(array, precision, signed, photometric, frames=1):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = SOURCE_UID
    ds.StudyInstanceUID = "2.25.23300012"
    ds.SeriesInstanceUID = "2.25.23300013"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "HTJ2K^Oracle", "HT-1", "OT", "WSD"
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
    ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = (16 if precision > 8 else 8), precision, precision - 1, 1 if signed else 0
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
    ds.is_little_endian, ds.is_implicit_VR = True, False
    return ds


def dicom_wrap(path, codestream, syntax, array, precision, signed, photometric):
    ds = dataset(array, precision, signed, photometric)
    ds.PixelData = encapsulate([bytes(codestream)])
    ds["PixelData"].is_undefined_length = True
    ds.file_meta.TransferSyntaxUID = syntax
    ds.save_as(path, enforce_file_format=True)


def native_dicom(path, array, precision, signed, photometric, frames=1):
    ds = dataset(array, precision, signed, photometric, frames)
    dtype = ("<i2" if signed else "<u2") if precision > 8 else np.uint8
    ds.PixelData = array.astype(dtype).tobytes()
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.save_as(path, enforce_file_format=True)


def our_decode(binary, dicom_path, work, shape, precision, signed, channels, extra=()):
    raw = work / (dicom_path.stem + "-" + "-".join(str(e).strip("-") for e in extra) + ".raw")
    code, out, err = run([binary, "codec", "decode", dicom_path, "--output", raw, "--format", "json", *extra])
    require(code == 0, f"dicomtool decode failed for {dicom_path.name} {extra}: {err}")
    if extra:
        report = json.loads(out.decode())
        frame = report["frames"][0]
        shape = (frame["height"], frame["width"])
    # `codec decode` writes the frame-reader pixel contract: signed 16-bit samples are offset to unsigned.
    array = np.frombuffer(raw.read_bytes(), dtype="<u2" if precision > 8 else np.uint8).astype(np.int64)
    if signed and precision > 8:
        array = array - 32768
    expected = shape[0] * shape[1] * channels
    require(array.size == expected, f"{dicom_path.name}: decoded {array.size} samples, expected {expected}")
    return array.reshape(shape[0], shape[1], channels) if channels == 3 else array.reshape(shape)


def main_header(codestream):
    markers, cursor = {}, 2
    while cursor + 4 <= len(codestream) and codestream[cursor] == 0xFF and codestream[cursor + 1] != 0x90:
        length = int.from_bytes(codestream[cursor + 2:cursor + 4], "big")
        markers[codestream[cursor + 1]] = codestream[cursor + 4:cursor + 2 + length]
        cursor += 2 + length
    return markers


def ojph_encode(work, name, array, precision, signed, flags):
    channels = 3 if array.ndim == 3 else 1
    out = work / f"{name}.j2c"
    if signed:
        # The raw reader takes the unsigned representation and applies the level shift for `-signed true` itself.
        raw = work / f"{name}.raw"
        raw.write_bytes((array + (1 << (precision - 1))).astype("<u2" if precision > 8 else np.uint8).tobytes())
        args = ["ojph_compress", "-i", raw, "-dims", f"{{{array.shape[1]},{array.shape[0]}}}", "-num_comps", "1", "-signed", "true", "-downsamp", "{1,1}",
                "-bit_depth", str(precision), "-o", out, *flags]
    else:
        pnm = work / (f"{name}.ppm" if channels == 3 else f"{name}.pgm")
        header = f"{'P6' if channels == 3 else 'P5'}\n{array.shape[1]} {array.shape[0]}\n{(1 << precision) - 1}\n".encode()
        pnm.write_bytes(header + array.astype(">u2" if precision > 8 else np.uint8).tobytes())
        args = ["ojph_compress", "-i", pnm, "-o", out, *flags]
    code, _, err = run(args)
    require(code == 0, f"ojph_compress {name}: {err}")
    return out


def read_pnm(path):
    data = path.read_bytes()
    tokens, cursor = [], 0
    while len(tokens) < 4:
        while data[cursor:cursor + 1].isspace():
            cursor += 1
        if data[cursor:cursor + 1] == b"#":
            cursor = data.index(b"\n", cursor) + 1
            continue
        start = cursor
        while not data[cursor:cursor + 1].isspace():
            cursor += 1
        tokens.append(data[start:cursor])
    cursor += 1
    magic, width, height, maximum = tokens[0], int(tokens[1]), int(tokens[2]), int(tokens[3])
    array = np.frombuffer(data[cursor:], dtype=">u2" if maximum > 255 else np.uint8).astype(np.int64)
    return array.reshape(height, width, 3) if magic == b"P6" else array.reshape(height, width)


def ojph_decode(codestream_path, work, shape, precision, signed, channels, skip=0):
    """`ojph_expand` clamps negative samples in PGM output, so signed data goes through the little-endian raw writer."""
    suffix = "raw" if signed else ("ppm" if channels == 3 else "pgm")
    out = work / f"{codestream_path.stem}-ojph-r{skip}.{suffix}"
    args = ["ojph_expand", "-i", codestream_path, "-o", out]
    if skip:
        args += ["-skip_res", f"{skip},{skip}"]
    code, _, err = run(args)
    require(code == 0, f"ojph_expand {codestream_path.name}: {err}")
    if not signed:
        return read_pnm(out)
    factor = 1 << skip
    height, width = (shape[0] + factor - 1) // factor, (shape[1] + factor - 1) // factor
    array = np.frombuffer(out.read_bytes(), dtype="<i2" if precision > 8 else np.int8).astype(np.int64)
    require(array.size == height * width * channels, f"ojph_expand {codestream_path.name}: {array.size} samples")
    return array.reshape(height, width)


def opj_decode(codestream_path, work, shape, precision, signed, channels):
    out = work / (codestream_path.stem + "-opj.rawl")
    code, _, err = run(["opj_decompress", "-i", codestream_path, "-o", out])
    require(code == 0, f"opj_decompress {codestream_path.name}: {err}")
    # opj_decompress writes signed components as their two's-complement codes at the declared precision.
    array = np.frombuffer(out.read_bytes(), dtype="<u2" if precision > 8 else np.uint8).astype(np.int64)
    if signed:
        half = 1 << (precision - 1)
        array = ((array + half) % (1 << precision)) - half
    require(array.size == shape[0] * shape[1] * channels, f"opj_decompress {codestream_path.name}: {array.size} samples")
    if channels == 3:
        return array.reshape(3, shape[0], shape[1]).transpose(1, 2, 0)
    return array.reshape(shape)


def fixture(rng, height, width, precision, channels=1, signed=False, extreme=False):
    limit = 1 << precision
    if extreme:
        gray = np.where((np.arange(width)[None, :] // 3 + np.arange(height)[:, None] // 5) % 2 == 0, 0, limit - 1)
    else:
        ramp = (np.arange(width)[None, :] * limit // (2 * width) + np.arange(height)[:, None] * limit // (4 * height))
        gray = (ramp + rng.integers(0, max(1, limit // 8), (height, width))) % limit
    if signed:
        gray = gray - limit // 2
    if channels == 1:
        return gray.astype(np.int64)
    return np.stack([gray, (gray + limit // 3) % limit, (limit - 1 - gray)], axis=-1).astype(np.int64)


def thumbnail_ok(width, height, levels):
    divisor = 1 << levels
    return min((width + divisor - 1) // divisor, (height + divisor - 1) // divisor) <= 64


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    for tool in ("ojph_compress", "ojph_expand", "opj_decompress"):
        require(shutil.which(tool) is not None, f"{tool} is required")
    rng = np.random.default_rng(2330)
    work = Path(tempfile.mkdtemp(prefix="isis-htj2k-oracle-"))
    results = {}
    try:
        gray8, gray12, gray16 = fixture(rng, 45, 71, 8), fixture(rng, 45, 71, 12), fixture(rng, 45, 71, 16)
        signed12, signed16x = fixture(rng, 45, 71, 12, signed=True), fixture(rng, 45, 71, 16, signed=True, extreme=True)
        gray16x = fixture(rng, 45, 71, 16, extreme=True)
        colour = fixture(rng, 45, 67, 8, channels=3)
        big = fixture(rng, 96, 130, 12)
        # 1. OpenJPH references (independent encoder) decoded by the own backend.
        decode_cases = [
            ("gray8", gray8, 8, False, ["-reversible", "true"], 0),
            ("gray12-levels3-blocks32", gray12, 12, False, ["-reversible", "true", "-num_decomps", "3", "-block_size", "{32,32}"], 0),
            ("gray16-rlcp", gray16, 16, False, ["-reversible", "true", "-prog_order", "RLCP"], 0),
            ("gray16-extremes-cprl-precincts", gray16x, 16, False, ["-reversible", "true", "-prog_order", "CPRL", "-precincts", "{64,64},{32,32}"], 0),
            ("signed12-pcrl", signed12, 12, True, ["-reversible", "true", "-prog_order", "PCRL"], 0),
            ("signed16-extremes", signed16x, 16, True, ["-reversible", "true", "-num_decomps", "2"], 0),
            ("gray12-tiles-tileparts-tlm", big, 12, False, ["-reversible", "true", "-tile_size", "{40,24}", "-tileparts", "R", "-tlm_marker", "true"], 0),
            ("gray12-rpcl-blocks16", big, 12, False, ["-reversible", "true", "-prog_order", "RPCL", "-block_size", "{16,16}"], 0),
            ("gray8-lrcp", gray8, 8, False, ["-reversible", "true", "-prog_order", "LRCP"], 0),
            ("rgb8-rct", colour, 8, False, ["-reversible", "true", "-colour_trans", "true"], 0),
            ("rgb8-no-mct", colour, 8, False, ["-reversible", "true", "-colour_trans", "false"], 0),
            ("gray12-97", gray12, 12, False, ["-reversible", "false", "-qstep", "0.002"], IRREVERSIBLE_TOLERANCE),
            ("rgb8-97-ict", colour, 8, False, ["-reversible", "false", "-colour_trans", "true", "-qstep", "0.005"], IRREVERSIBLE_TOLERANCE),
        ]
        for name, array, precision, signed, flags, tolerance in decode_cases:
            codestream = ojph_encode(work, name, array, precision, signed, flags)
            channels = 3 if array.ndim == 3 else 1
            markers = main_header(codestream.read_bytes())
            require(0x50 in markers and markers[0x52][8] & 0x40, f"{name}: ojph_compress must write an HT codestream")
            # OpenJPH's raw reader/writer treat signed samples inconsistently (level shift and wrap-around); signed inputs
            # are referenced against opj_decompress, unsigned inputs against ojph_expand and the source.
            reference = opj_decode(codestream, work, array.shape[:2], precision, signed, channels) if signed \
                else ojph_decode(codestream, work, array.shape[:2], precision, signed, channels)
            syntax = LOSSLESS if tolerance == 0 else GENERAL
            photometric = "MONOCHROME2" if channels == 1 else ("RGB" if "false" in flags else ("YBR_RCT" if tolerance == 0 else "YBR_ICT"))
            dicom = work / f"{name}.dcm"
            dicom_wrap(dicom, codestream.read_bytes(), syntax, array, precision, signed, photometric)
            ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, signed, channels)
            difference = int(np.max(np.abs(ours - reference)))
            require(difference <= tolerance, f"{name}: own decode differs from the independent decoder by {difference} (> {tolerance})")
            if tolerance == 0 and not signed:
                require(np.array_equal(ours, array), f"{name}: reversible decode differs from the source")
            results[name] = {"maxDifferenceVsIndependentDecoder": difference, "reference": "opj_decompress" if signed else "ojph_expand",
                             "tolerance": tolerance, "codestreamBytes": codestream.stat().st_size}
        # 2. Reduced-resolution decodes against `ojph_expand -skip_res` (unsigned grayscale).
        for name, array, precision, reductions in [("gray12-levels3-blocks32", gray12, 12, [1, 2]), ("gray12-tiles-tileparts-tlm", big, 12, [1, 2])]:
            dicom, codestream = work / f"{name}.dcm", work / f"{name}.j2c"
            for reduce in reductions:
                reference = ojph_decode(codestream, work, array.shape[:2], precision, False, 1, skip=reduce)
                ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, False, 1, extra=["--resolution-level", str(reduce)])
                require(ours.shape == reference.shape, f"{name} r{reduce}: geometry {ours.shape} vs OpenJPH {reference.shape}")
                require(np.array_equal(ours, reference), f"{name} r{reduce}: reduced decode differs from ojph_expand -skip_res")
                results[f"{name}-reduce{reduce}"] = {"exactVsOpenJPH": True, "shape": list(ours.shape)}
        # 3. Own encoder output per UID decoded by OpenJPH and OpenJPEG, reopened by pydicom, checked against PS3.5 rules.
        multi = fixture(rng, 3 * 70, 90, 12, signed=True)
        encode_cases = [
            ("encode-gray8-201", gray8, 8, False, LOSSLESS, [], 1, 0),
            ("encode-gray12-201", gray12, 12, False, LOSSLESS, [], 1, 0),
            ("encode-gray16-extremes-201", gray16x, 16, False, LOSSLESS, [], 1, 0),
            ("encode-signed12-multiframe-202", multi, 12, True, LOSSLESS_RPCL, [], 3, 0),
            ("encode-big-202", big, 12, False, LOSSLESS_RPCL, [], 1, 0),
            ("encode-rgb8-201", colour, 8, False, LOSSLESS, [], 1, 0),
            ("encode-rgb8-202", colour, 8, False, LOSSLESS_RPCL, [], 1, 0),
            ("encode-gray12-203-reversible", gray12, 12, False, GENERAL, [], 1, 0),
            ("encode-gray12-203-lossy", gray12, 12, False, GENERAL, ["--quality", "0.9"], 1, None),
        ]
        for name, array, precision, signed, syntax, flags, frames, tolerance in encode_cases:
            source = work / f"{name}-source.dcm"
            native_dicom(source, array, precision, signed, "RGB" if array.ndim == 3 else "MONOCHROME2", frames)
            output = work / f"{name}.dcm"
            code, _, err = run([args.binary, "codec", "transcode", source, "--output", output, "--transfer-syntax", syntax, "--format", "json", *flags])
            require(code == 0, f"transcode {name}: {err}")
            ds = pydicom.dcmread(output)
            require(str(ds.file_meta.TransferSyntaxUID) == syntax, f"{name}: syntax")
            fragments = list(generate_frames(ds.PixelData, number_of_frames=frames))
            require(len(fragments) == frames, f"{name}: {len(fragments)} frames, expected {frames}")
            rows = array.shape[0] // frames
            channels = 3 if array.ndim == 3 else 1
            worst = 0
            for index, frame in enumerate(fragments):
                require(frame[:4] == b"\xff\x4f\xff\x51", f"{name} frame {index}: raw codestream expected, no JP2 box")
                markers = main_header(frame)
                cod = markers[0x52]
                require(0x50 in markers and 0x59 in markers and cod[8] & 0x40, f"{name} frame {index}: CAP/CPF and HT code-blocks")
                require(0x64 not in markers, f"{name} frame {index}: no private COM signal")
                levels = cod[5]
                if syntax == LOSSLESS_RPCL:
                    require(cod[1] == 2 and 0x55 in markers and thumbnail_ok(array.shape[1], rows, levels),
                            f"{name} frame {index}: PS3.5 10.18.1 needs RPCL, TLM and a <= 64-sample base resolution (levels {levels})")
                else:
                    require(0x55 not in markers, f"{name} frame {index}: TLM is a .202 option")
                require((cod[9] == 1) == (tolerance == 0), f"{name} frame {index}: 5/3 filter iff reversible")
                path = work / f"{name}-{index}.j2c"
                path.write_bytes(frame)
                slab = array[index * rows:(index + 1) * rows]
                for decoder, decoded in (("ojph", ojph_decode(path, work, (rows, array.shape[1]), precision, signed, channels)),
                                         ("opj", opj_decode(path, work, (rows, array.shape[1]), precision, signed, channels))):
                    difference = int(np.max(np.abs(decoded - slab)))
                    worst = max(worst, difference)
                    if tolerance == 0:
                        require(difference == 0, f"{name} frame {index}: {decoder} decode of the own reversible codestream differs by {difference}")
            if tolerance is None:
                require(worst <= (1 << precision) // 16, f"{name}: lossy output {worst} away from the source")
                require(ds.SOPInstanceUID != SOURCE_UID and ds.LossyImageCompression == "01" and "ISO_15444_15" in ds.LossyImageCompressionMethod,
                        f"{name}: lossy provenance")
            else:
                require(ds.SOPInstanceUID == SOURCE_UID and "LossyImageCompression" not in ds, f"{name}: lossless must keep identity (loss is the intent, not the UID)")
            if channels == 3:
                require(ds.PhotometricInterpretation == "YBR_RCT", f"{name}: RCT photometric")
            ours = our_decode(args.binary, output, work, (rows, array.shape[1]), precision, signed, channels) if frames == 1 else None
            if ours is not None and tolerance == 0:
                require(np.array_equal(ours, array), f"{name}: own decode of the own encode")
            results[name] = {"maxDifferenceVsSource": worst, "frames": frames}
        # 4. Rewraps: .201 -> .203 copies the frames; .201 -> .202 re-encodes with the RPCL options.
        lossless = work / "encode-gray12-201.dcm"
        general = work / "rewrap-203.dcm"
        code, _, err = run([args.binary, "codec", "transcode", lossless, "--output", general, "--transfer-syntax", GENERAL, "--format", "json"])
        require(code == 0, f"rewrap to .203: {err}")
        require(next(generate_frames(pydicom.dcmread(general).PixelData, number_of_frames=1)) == next(generate_frames(pydicom.dcmread(lossless).PixelData, number_of_frames=1)),
                ".201 -> .203 must copy the codestream")
        rpcl = work / "reencode-202.dcm"
        code, _, err = run([args.binary, "codec", "transcode", lossless, "--output", rpcl, "--transfer-syntax", LOSSLESS_RPCL, "--format", "json"])
        require(code == 0, f"re-encode to .202: {err}")
        frame = next(generate_frames(pydicom.dcmread(rpcl).PixelData, number_of_frames=1))
        markers = main_header(frame)
        require(markers[0x52][1] == 2 and 0x55 in markers, ".201 -> .202 must re-encode with RPCL and TLM")
        require(np.array_equal(our_decode(args.binary, rpcl, work, gray12.shape, 12, False, 1), gray12), ".202 re-encode keeps the samples")
        results["rewrap-201-to-203"] = {"codestreamCopied": True}
        results["reencode-201-to-202"] = {"rpclOptions": True}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps({"pydicomVersion": version, "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} HTJ2K cases agree with OpenJPH and OpenJPEG (reversible exact, 9-7 within {IRREVERSIBLE_TOLERANCE}, reductions exact, PS3.5 .201/.202/.203 rules held)")


if __name__ == "__main__":
    main()
