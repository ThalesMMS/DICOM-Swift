#!/usr/bin/env python3
"""Independent check of the own JPEG 2000 Part 1 codec (vendored J2KSwift core, #2329) against OpenJPEG and pydicom.

OpenJPEG's `opj_compress` writes reference codestreams from raw samples that the own encoder never saw: 8/12/16-bit
unsigned and 12-bit signed grayscale, 8-bit RGB with the multiple component transform, tiles, precincts, code-block
sizes, every progression order, SOP/EPH markers, several decomposition levels, multiple quality layers and the
irreversible 9-7 filter. Each is wrapped in a Part 10 file with pydicom and decoded by `dicomtool codec decode`;
reversible cases must equal `opj_decompress` exactly and irreversible cases must stay within the documented
tolerance of it. Reduced-resolution decodes (`--resolution-level`) are compared with `opj_decompress -r`, and
quality-layer decodes with `opj_decompress -l`. The own encoder's `.90`/`.91` outputs are decoded by
`opj_decompress` (exact for reversible), reopened by pydicom, and their provenance is checked. A JP2-wrapped frame
is unwrapped by the transcoder without re-encoding. Only counts and maxima are kept.
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

LOSSLESS = "1.2.840.10008.1.2.4.90"
LOSSY = "1.2.840.10008.1.2.4.91"
SOURCE_UID = "2.25.23290011"
IRREVERSIBLE_TOLERANCE = 2  # 9-7 inverse DWT rounding between independent implementations


def run(args, **kwargs):
    completed = subprocess.run([str(a) for a in args], capture_output=True, timeout=600, **kwargs)
    return completed.returncode, completed.stdout, completed.stderr.decode(errors="replace")[:300]


def dataset(array, precision, signed, photometric, frames=1):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = SOURCE_UID
    ds.StudyInstanceUID = "2.25.23290012"
    ds.SeriesInstanceUID = "2.25.23290013"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "J2K^Oracle", "J2K-1", "OT", "WSD"
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


def stored_dtype(precision, signed):
    return ("<i2" if signed else "<u2") if precision > 8 else np.uint8


def our_decode(binary, dicom_path, work, shape, precision, signed, channels, extra=()):
    raw = work / (dicom_path.stem + "-" + "-".join(str(e).strip("-") for e in extra) + ".raw")
    code, out, err = run([binary, "codec", "decode", dicom_path, "--output", raw, "--format", "json", *extra])
    require(code == 0, f"dicomtool decode failed for {dicom_path.name} {extra}: {err}")
    if extra:
        # The partial path follows the frame-reader contract: 16-bit samples are offset to unsigned for signed data.
        report = json.loads(out.decode())
        frame = report["frames"][0]
        shape = (frame["height"], frame["width"])
        array = np.frombuffer(raw.read_bytes(), dtype="<u2" if precision > 8 else np.uint8).astype(np.int64)
        if signed and precision > 8:
            array = array - 32768
    else:
        # `codec decode` writes the frame-reader pixel contract as well: signed 16-bit samples are offset to unsigned.
        array = np.frombuffer(raw.read_bytes(), dtype="<u2" if precision > 8 else stored_dtype(precision, signed)).astype(np.int64)
        if signed and precision > 8:
            array = array - 32768
    expected = shape[0] * shape[1] * channels
    require(array.size == expected, f"{dicom_path.name}: decoded {array.size} samples, expected {expected}")
    return array.reshape(shape[0], shape[1], channels) if channels == 3 else array.reshape(shape)


def opj_decode(codestream_path, work, shape, precision, signed, channels, reduce=0, layers=None, area=None):
    out = work / (codestream_path.stem + f"-r{reduce}-l{layers}-d{area}.rawl")
    args = ["opj_decompress", "-i", codestream_path, "-o", out]
    if reduce:
        args += ["-r", str(reduce)]
    if layers:
        args += ["-l", str(layers)]
    if area:
        x, y, w, h = area
        args += ["-d", f"{x},{y},{x + w},{y + h}"]
    code, _, err = run(args)
    require(code == 0, f"opj_decompress {codestream_path.name}: {err}")
    # opj_decompress writes signed components as their two's-complement codes at the declared precision.
    array = np.frombuffer(out.read_bytes(), dtype="<u2" if precision > 8 else np.uint8).astype(np.int64)
    if signed:
        half = 1 << (precision - 1)
        array = ((array + half) % (1 << precision)) - half
    factor = 1 << reduce
    if area:
        shape = (area[3], area[2])
    height, width = (shape[0] + factor - 1) // factor, (shape[1] + factor - 1) // factor
    require(array.size == height * width * channels, f"opj_decompress {codestream_path.name}: {array.size} samples for {height}x{width}x{channels}")
    if channels == 3:
        # .rawl writes component planes.
        return array.reshape(3, height, width).transpose(1, 2, 0)
    return array.reshape(height, width)


def opj_encode(work, name, array, precision, signed, flags):
    raw = work / f"{name}.rawl"
    dtype = ("<i2" if signed else "<u2") if precision > 8 else (np.int8 if signed else np.uint8)
    data = array.astype(dtype)
    if array.ndim == 3:
        data = np.ascontiguousarray(data.transpose(2, 0, 1))  # planes
    raw.write_bytes(data.tobytes())
    channels = 3 if array.ndim == 3 else 1
    out = work / f"{name}.j2k"
    code, _, err = run(["opj_compress", "-i", raw, "-o", out, "-F", f"{array.shape[1]},{array.shape[0]},{channels},{precision},{'s' if signed else 'u'}", *flags])
    require(code == 0, f"opj_compress {name}: {err}")
    return out


def fixture(rng, height, width, precision, channels=1, signed=False):
    limit = 1 << precision
    ramp = (np.arange(width)[None, :] * limit // (2 * width) + np.arange(height)[:, None] * limit // (4 * height))
    noise = rng.integers(0, max(1, limit // 8), (height, width))
    gray = (ramp + noise) % limit
    if signed:
        gray = gray - limit // 2
    if channels == 1:
        return gray.astype(np.int64)
    return np.stack([gray, (gray + limit // 3) % limit, (limit - 1 - gray)], axis=-1).astype(np.int64)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    for tool in ("opj_compress", "opj_decompress"):
        require(shutil.which(tool) is not None, f"{tool} (OpenJPEG) is required")
    opj_version = subprocess.run(["opj_decompress", "-h"], capture_output=True, text=True).stdout.split("\n")[0][:60]
    rng = np.random.default_rng(2329)
    work = Path(tempfile.mkdtemp(prefix="isis-jpeg2000-oracle-"))
    results = {}
    try:
        gray8, gray12, gray16 = fixture(rng, 37, 53, 8), fixture(rng, 37, 53, 12), fixture(rng, 37, 53, 16)
        signed12 = fixture(rng, 37, 53, 12, signed=True)
        colour = fixture(rng, 45, 67, 8, channels=3)
        big = fixture(rng, 96, 130, 12)
        # 1. OpenJPEG references (independent encoder) decoded by the own backend.
        decode_cases = [
            ("gray8-53", gray8, 8, False, [], 0),
            ("gray12-53", gray12, 12, False, [], 0),
            ("gray16-53", gray16, 16, False, [], 0),
            ("signed12-53", signed12, 12, True, [], 0),
            ("rgb8-mct-53", colour, 8, False, ["-mct", "1"], 0),
            ("rgb8-nomct-53", colour, 8, False, ["-mct", "0"], 0),
            ("gray12-tiles", big, 12, False, ["-t", "32,48"], 0),
            ("gray12-precincts-cblk", big, 12, False, ["-c", "[64,64],[32,32],[16,16]", "-b", "16,16"], 0),
            ("gray12-rpcl-sop-eph", big, 12, False, ["-p", "RPCL", "-SOP", "-EPH"], 0),
            ("gray12-cprl-levels2", big, 12, False, ["-p", "CPRL", "-n", "3"], 0),
            ("gray12-pcrl-tiles-tp", big, 12, False, ["-p", "PCRL", "-t", "64,64", "-TP", "R"], 0),
            ("gray12-rlcp-layers", big, 12, False, ["-p", "RLCP", "-r", "8,4,1"], 0),
            ("gray16-97", gray16, 16, False, ["-I", "-r", "1"], IRREVERSIBLE_TOLERANCE),
            ("gray12-97-layers", big, 12, False, ["-I", "-r", "20,10,4"], IRREVERSIBLE_TOLERANCE),
            ("rgb8-ict-97", colour, 8, False, ["-I", "-mct", "1", "-r", "4"], IRREVERSIBLE_TOLERANCE),
        ]
        for name, array, precision, signed, flags, tolerance in decode_cases:
            codestream = opj_encode(work, name, array, precision, signed, flags)
            channels = 3 if array.ndim == 3 else 1
            reference = opj_decode(codestream, work, array.shape[:2], precision, signed, channels)
            syntax = LOSSLESS if "-I" not in flags else LOSSY
            dicom = work / f"{name}.dcm"
            photometric = ("YBR_ICT" if "-I" in flags else "YBR_RCT") if (channels == 3 and "0" not in flags[flags.index("-mct") + 1:flags.index("-mct") + 2]) else ("RGB" if channels == 3 else "MONOCHROME2")
            dicom_wrap(dicom, codestream.read_bytes(), syntax, array, precision, signed, photometric)
            ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, signed, channels)
            difference = int(np.max(np.abs(ours - reference)))
            require(difference <= tolerance, f"{name}: own decode differs from opj_decompress by {difference} (> {tolerance})")
            if tolerance == 0:
                require(np.array_equal(ours, array), f"{name}: reversible decode differs from the source")
            results[name] = {"maxDifferenceVsOpenJPEG": difference, "tolerance": tolerance, "codestreamBytes": codestream.stat().st_size}
        # 2. Reduced-resolution and quality-layer decodes against opj_decompress -r / -l (unsigned grayscale).
        partial_cases = [("gray12-cprl-levels2", big, 12, [1, 2], []), ("gray12-tiles", big, 12, [1, 3], []), ("gray12-rlcp-layers", big, 12, [], [1, 2])]
        for name, array, precision, reductions, layer_counts in partial_cases:
            dicom = work / f"{name}.dcm"
            codestream = work / f"{name}.j2k"
            for reduce in reductions:
                reference = opj_decode(codestream, work, array.shape[:2], precision, False, 1, reduce=reduce)
                ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, False, 1, extra=["--resolution-level", str(reduce)])
                require(ours.shape == reference.shape, f"{name} r{reduce}: geometry {ours.shape} vs OpenJPEG {reference.shape}")
                require(np.array_equal(ours, reference), f"{name} r{reduce}: reduced decode differs from opj_decompress -r")
                results[f"{name}-reduce{reduce}"] = {"exactVsOpenJPEG": True, "shape": list(ours.shape)}
            for layers in layer_counts:
                reference = opj_decode(codestream, work, array.shape[:2], precision, False, 1, layers=layers)
                ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, False, 1, extra=["--max-layer", str(layers - 1)])
                require(np.array_equal(ours, reference), f"{name} l{layers}: quality-layer decode differs from opj_decompress -l")
                results[f"{name}-layers{layers}"] = {"exactVsOpenJPEG": True}
                # Issue #2382: quality layers combined with resolution reduction and with a decoding area.
                reference = opj_decode(codestream, work, array.shape[:2], precision, False, 1, reduce=1, layers=layers)
                ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, False, 1, extra=["--max-layer", str(layers - 1), "--resolution-level", "1"])
                require(ours.shape == reference.shape, f"{name} l{layers} r1: geometry {ours.shape} vs OpenJPEG {reference.shape}")
                require(np.array_equal(ours, reference), f"{name} l{layers} r1: layer+resolution decode differs from opj_decompress -l -r")
                results[f"{name}-layers{layers}-reduce1"] = {"exactVsOpenJPEG": True, "shape": list(ours.shape)}
                area = (24, 16, 40, 32)
                reference = opj_decode(codestream, work, array.shape[:2], precision, False, 1, layers=layers, area=area)
                ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, False, 1, extra=["--max-layer", str(layers - 1), "--region", ",".join(map(str, area))])
                require(ours.shape == reference.shape, f"{name} l{layers} area: geometry {ours.shape} vs OpenJPEG {reference.shape}")
                require(np.array_equal(ours, reference), f"{name} l{layers} area: layer+region decode differs from opj_decompress -l -d")
                results[f"{name}-layers{layers}-area"] = {"exactVsOpenJPEG": True, "shape": list(ours.shape)}
        # 3. Own encoder output decoded by OpenJPEG and reopened by pydicom.
        multi = fixture(rng, 3 * 24, 31, 16)
        encode_cases = [
            ("encode-gray8-90", gray8, 8, False, LOSSLESS, [], 1, 0),
            ("encode-gray12-90", gray12, 12, False, LOSSLESS, [], 1, 0),
            ("encode-signed12-90", signed12, 12, True, LOSSLESS, [], 1, 0),
            ("encode-gray16-multiframe-90", multi, 16, False, LOSSLESS, [], 3, 0),
            ("encode-rgb8-90", colour, 8, False, LOSSLESS, [], 1, 0),
            ("encode-gray12-91", gray12, 12, False, LOSSY, ["--quality", "0.9"], 1, None),
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
                path = work / f"{name}-{index}.j2k"
                path.write_bytes(frame)
                decoded = opj_decode(path, work, (rows, array.shape[1]), precision, signed, channels)
                worst = max(worst, int(np.max(np.abs(decoded - array[index * rows:(index + 1) * rows]))))
            if tolerance is None:
                require(worst <= (1 << precision) // 16, f"{name}: lossy output {worst} away from the source")
                require(ds.SOPInstanceUID != SOURCE_UID and ds.LossyImageCompression == "01" and "ISO_15444_1" in ds.LossyImageCompressionMethod, f"{name}: lossy provenance")
            else:
                require(worst == 0, f"{name}: OpenJPEG decode of the own reversible codestream differs by {worst}")
                require(ds.SOPInstanceUID == SOURCE_UID and "LossyImageCompression" not in ds, f"{name}: lossless must keep identity")
            if channels == 3:
                require(ds.PhotometricInterpretation in ("YBR_RCT", "YBR_ICT"), f"{name}: MCT photometric")
            results[name] = {"maxDifferenceVsSource": worst, "frames": frames}
        # 4. JP2-wrapped frames: decoded by the own backend and unwrapped by the transcoder without re-encoding.
        codestream = (work / "gray12-53.j2k").read_bytes()
        jp2 = (bytes.fromhex("0000000c6a5020200d0a870a") + (20).to_bytes(4, "big") + b"ftyp" + b"jp2 " + (0).to_bytes(4, "big") + b"jp2 "
               + (8 + len(codestream)).to_bytes(4, "big") + b"jp2c" + codestream)
        wrapped = work / "gray12-jp2.dcm"
        dicom_wrap(wrapped, jp2, LOSSLESS, gray12, 12, False, "MONOCHROME2")
        ours = our_decode(args.binary, wrapped, work, gray12.shape, 12, False, 1)
        require(np.array_equal(ours, gray12), "JP2-wrapped frame must decode to the same samples")
        unwrapped = work / "gray12-unwrapped.dcm"
        code, plan_out, err = run([args.binary, "codec", "transcode", wrapped, "--output", unwrapped, "--transfer-syntax", LOSSLESS, "--format", "json", "--plan"])
        require(code == 0 and "unwrap-containers" in plan_out.decode(errors="replace"), f"the plan must name the unwrap step: {err}")
        code, out, err = run([args.binary, "codec", "transcode", wrapped, "--output", unwrapped, "--transfer-syntax", LOSSLESS, "--format", "json"])
        require(code == 0, f"unwrap transcode: {err}")
        ds = pydicom.dcmread(unwrapped)
        frame = list(generate_frames(ds.PixelData, number_of_frames=1))[0]
        require(bytes(frame[:len(codestream)]) == codestream and len(frame) - len(codestream) <= 1,
                "the unwrapped frame must be the original codestream byte for byte (plus the even-length pad)")
        results["jp2-unwrap"] = {"rawCodestreamRestored": True}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps({"pydicomVersion": version, "openjpeg": opj_version, "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} JPEG 2000 cases agree with OpenJPEG (reversible exact, 9-7 within {IRREVERSIBLE_TOLERANCE}, reductions/layers exact, JP2 unwrapped)")


if __name__ == "__main__":
    main()
