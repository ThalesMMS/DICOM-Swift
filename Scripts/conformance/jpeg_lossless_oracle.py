#!/usr/bin/env python3
"""Independent check of the own JPEG lossless (SOF3) codec against libjpeg-turbo (cjpeg/djpeg 3.x) and pydicom (#2327).

libjpeg-turbo writes reference SOF3 codestreams — 4/8/12/16-bit grayscale over predictors 1...7, point transforms,
restart intervals in rows, and 8-bit RGB — each wrapped in a Part 10 file with pydicom and decoded by
`dicomtool codec decode`; the samples must equal djpeg's decode exactly (and the source shifted by the point
transform). `dicomtool codec transcode` then encodes native sources (single and multiframe, 8/12/16-bit and RGB)
with explicit predictor, point transform and restart options; djpeg must decode every produced frame exactly,
pydicom reopens the objects, and lossless output keeps the SOP Instance UID while a point transform records the
loss (Lossy Image Compression 01, ISO_10918_1). Only counts and maxima are kept.
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

LOSSLESS = "1.2.840.10008.1.2.4.57"
LOSSLESS_SV1 = "1.2.840.10008.1.2.4.70"
SOURCE_UID = "2.25.23270011"


def run(args, **kwargs):
    completed = subprocess.run([str(a) for a in args], capture_output=True, timeout=600, **kwargs)
    return completed.returncode, completed.stdout, completed.stderr.decode(errors="replace")[:300]


def write_pnm(path, array, precision):
    maxval = (1 << precision) - 1
    if array.ndim == 2:
        header = f"P5\n{array.shape[1]} {array.shape[0]}\n{maxval}\n"
    else:
        header = f"P6\n{array.shape[1]} {array.shape[0]}\n{maxval}\n"
    data = array.astype(">u2").tobytes() if precision > 8 else array.astype(np.uint8).tobytes()
    path.write_bytes(header.encode() + data)


def read_pnm(data):
    parts = data.split(b"\n", 3)
    magic, dims, body = parts[0], parts[1], parts[3]
    width, height = map(int, dims.split())
    channels = 3 if magic == b"P6" else 1
    count = width * height * channels
    dtype = ">u2" if len(body) >= count * 2 else np.uint8
    array = np.frombuffer(body, dtype=dtype, count=count).astype(np.int64)
    return array.reshape(height, width, channels) if channels == 3 else array.reshape(height, width)


def dataset(array, precision, photometric, frames=1):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = SOURCE_UID
    ds.StudyInstanceUID = "2.25.23270012"
    ds.SeriesInstanceUID = "2.25.23270013"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "JPEG^Lossless", "JL-1", "OT", "WSD"
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
    ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = (16 if precision > 8 else 8), precision, precision - 1, 0
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
    ds.is_little_endian, ds.is_implicit_VR = True, False
    return ds


def dicom_wrap(path, codestream, syntax, array, precision, photometric):
    ds = dataset(array, precision, photometric)
    ds.PixelData = encapsulate([codestream])
    ds["PixelData"].is_undefined_length = True
    ds.file_meta.TransferSyntaxUID = syntax
    ds.save_as(path, enforce_file_format=True)


def native_dicom(path, array, precision, photometric, frames=1):
    ds = dataset(array, precision, photometric, frames)
    ds.PixelData = array.astype("<u2" if precision > 8 else np.uint8).tobytes()
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.save_as(path, enforce_file_format=True)


def our_decode(binary, dicom_path, work, shape, precision, channels):
    raw = work / (dicom_path.stem + ".raw")
    code, _, err = run([binary, "codec", "decode", dicom_path, "--output", raw, "--format", "json"])
    require(code == 0, f"dicomtool decode failed for {dicom_path.name}: {err}")
    dtype = "<u2" if precision > 8 else np.uint8
    array = np.frombuffer(raw.read_bytes(), dtype=dtype).astype(np.int64)
    expected = shape[0] * shape[1] * channels
    require(array.size == expected, f"{dicom_path.name}: decoded {array.size} samples, expected {expected}")
    return array.reshape(shape[0], shape[1], channels) if channels == 3 else array.reshape(shape)


def fixture(rng, height, width, precision, channels=1):
    limit = 1 << precision
    ramp = (np.arange(width)[None, :] * limit // (2 * width) + np.arange(height)[:, None] * limit // (4 * height))
    noise = rng.integers(0, max(1, limit // 8), (height, width))
    gray = (ramp + noise) % limit
    if channels == 1:
        return gray.astype(np.uint16 if precision > 8 else np.uint8)
    return np.stack([gray, (gray + limit // 3) % limit, (limit - 1 - gray)], axis=-1).astype(np.uint8)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    for tool in ("cjpeg", "djpeg"):
        require(shutil.which(tool) is not None, f"{tool} (libjpeg-turbo) is required")
    rng = np.random.default_rng(2327)
    work = Path(tempfile.mkdtemp(prefix="isis-jpeg-lossless-oracle-"))
    results = {}
    try:
        # 1. libjpeg-turbo references decoded by the own backend, exact against djpeg and the (point-transformed) source.
        decode_cases = []
        for precision in (4, 8, 12, 16):
            array = fixture(rng, 23, 37, precision)
            for predictor in range(1, 8):
                for point_transform in (0, 2) if predictor in (1, 4, 7) else (0,):
                    for restart_rows in (0, 3) if predictor in (1, 6) else (0,):
                        decode_cases.append((f"gray{precision}-sv{predictor}-pt{point_transform}-rst{restart_rows}", array, precision, predictor, point_transform, restart_rows, "MONOCHROME2"))
        colour = fixture(rng, 19, 29, 8, channels=3)
        decode_cases.append(("rgb8-sv1-pt0-rst0", colour, 8, 1, 0, 0, "RGB"))
        decode_cases.append(("rgb8-sv5-pt0-rst2", colour, 8, 5, 0, 2, "RGB"))
        for name, array, precision, predictor, point_transform, restart_rows, photometric in decode_cases:
            pnm = work / f"{name}.pnm"
            write_pnm(pnm, array, precision)
            flags = ["-lossless", f"{predictor},{point_transform}" if point_transform else str(predictor), "-precision", str(precision)]
            if restart_rows:
                flags += ["-restart", str(restart_rows)]
            if array.ndim == 3:
                flags += ["-rgb"]
            code, codestream, err = run(["cjpeg", *flags, pnm])
            require(code == 0, f"cjpeg {name}: {err}")
            code, reference_raw, err = run(["djpeg", "-pnm"], input=codestream)
            require(code == 0, f"djpeg {name}: {err}")
            reference = read_pnm(reference_raw)
            syntax = LOSSLESS_SV1 if predictor == 1 and point_transform == 0 else LOSSLESS
            dicom = work / f"{name}.dcm"
            dicom_wrap(dicom, codestream, syntax, array, precision, photometric)
            ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, 3 if array.ndim == 3 else 1)
            require(np.array_equal(ours, reference), f"{name}: own decode differs from djpeg")
            expected = (array.astype(np.int64) >> point_transform) << point_transform
            require(np.array_equal(ours, expected), f"{name}: own decode differs from the point-transformed source")
            results[name] = {"exactVsLibjpegTurbo": True, "codestreamBytes": len(codestream)}
        # 2. Own encoder output decoded by libjpeg-turbo, reopened by pydicom, provenance checked.
        gray8, gray12, gray16 = fixture(rng, 21, 33, 8), fixture(rng, 21, 33, 12), fixture(rng, 21, 33, 16)
        multi12 = fixture(rng, 3 * 15, 27, 12)
        encode_cases = [
            ("encode-gray8-sv1", gray8, 8, LOSSLESS_SV1, [], 1, "MONOCHROME2"),
            ("encode-gray8-sv7-rst4", gray8, 8, LOSSLESS, ["--predictor", "7", "--restart-rows", "4"], 1, "MONOCHROME2"),
            ("encode-gray12-sv4", gray12, 12, LOSSLESS, ["--predictor", "4"], 1, "MONOCHROME2"),
            ("encode-gray12-multiframe-sv6-rst2", multi12, 12, LOSSLESS, ["--predictor", "6", "--restart-rows", "2"], 3, "MONOCHROME2"),
            ("encode-gray16-sv1-rst1", gray16, 16, LOSSLESS_SV1, ["--restart-rows", "1"], 1, "MONOCHROME2"),
            ("encode-gray16-sv2", gray16, 16, LOSSLESS, ["--predictor", "2"], 1, "MONOCHROME2"),
            ("encode-rgb8-sv1", colour, 8, LOSSLESS_SV1, [], 1, "RGB"),
            ("encode-rgb8-sv3-rst5", colour, 8, LOSSLESS, ["--predictor", "3", "--restart-rows", "5"], 1, "RGB"),
            ("encode-gray12-pt3-lossy", gray12, 12, LOSSLESS, ["--predictor", "1", "--point-transform", "3"], 1, "MONOCHROME2"),
        ]
        for name, array, precision, syntax, flags, frames, photometric in encode_cases:
            source = work / f"{name}-source.dcm"
            native_dicom(source, array, precision, photometric, frames)
            output = work / f"{name}.dcm"
            code, _, err = run([args.binary, "codec", "transcode", source, "--output", output, "--transfer-syntax", syntax, "--format", "json", *flags])
            require(code == 0, f"transcode {name}: {err}")
            ds = pydicom.dcmread(output)
            require(str(ds.file_meta.TransferSyntaxUID) == syntax, f"{name}: syntax")
            fragments = list(generate_frames(ds.PixelData, number_of_frames=frames))
            require(len(fragments) == frames, f"{name}: {len(fragments)} frames, expected {frames}")
            point_transform = int(flags[flags.index("--point-transform") + 1]) if "--point-transform" in flags else 0
            rows = array.shape[0] // frames
            for index, frame in enumerate(fragments):
                code, decoded_raw, err = run(["djpeg", "-pnm"], input=frame)
                require(code == 0, f"djpeg on our {name} frame {index}: {err}")
                decoded = read_pnm(decoded_raw)
                expected = (array[index * rows:(index + 1) * rows].astype(np.int64) >> point_transform) << point_transform
                require(np.array_equal(decoded, expected), f"{name}: libjpeg-turbo decode of frame {index} differs from the source")
            if point_transform:
                require(ds.SOPInstanceUID != SOURCE_UID and ds.LossyImageCompression == "01" and "ISO_10918_1" in ds.LossyImageCompressionMethod, f"{name}: lossy provenance")
            else:
                require(ds.SOPInstanceUID == SOURCE_UID and "LossyImageCompression" not in ds, f"{name}: lossless must keep identity")
            results[name] = {"exactVsLibjpegTurbo": True, "frames": frames, "pointTransform": point_transform}
        # 3. SV1 refuses a predictor other than 1; the restart interval must fit DRI.
        code, _, _ = run([args.binary, "codec", "transcode", work / "encode-gray8-sv1-source.dcm", "--output", work / "refused.dcm", "--transfer-syntax", LOSSLESS_SV1, "--predictor", "3"])
        require(code != 0, "SV1 with predictor 3 must be refused")
        code, _, _ = run([args.binary, "codec", "transcode", work / "encode-gray8-sv1-source.dcm", "--output", work / "refused.dcm", "--transfer-syntax", LOSSLESS, "--restart-rows", "3000"])
        require(code != 0, "an oversized restart interval must be refused")
        results["refusals"] = {"sv1Predictor": True, "driOverflow": True}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps({"pydicomVersion": version, "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} JPEG lossless cases decode exactly against libjpeg-turbo (predictors, point transform, restarts, colour, multiframe)")


if __name__ == "__main__":
    main()
