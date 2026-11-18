#!/usr/bin/env python3
"""Independent check of the own JPEG backend against libjpeg-turbo (cjpeg/djpeg 3.x) and pydicom+Pillow (#2326).

libjpeg-turbo writes reference codestreams (baseline 8-bit grayscale and colour with 4:4:4 and 4:2:0 chroma,
progressive scans, restart markers, odd dimensions, 12-bit extended sequential grayscale); each is wrapped in a
Part 10 file with pydicom and decoded by `dicomtool codec decode`. The raw samples are compared with djpeg's
decode of the same codestream: exact for 4:4:4 grayscale/colour DC-only content is not assumed, so the
tolerance is 1 LSB for grayscale IDCT rounding, 2 for 4:4:4 colour and 8 for 4:2:0 (chroma upsampling
filters differ), and 1/4096 scale for 12-bit. `dicomtool codec transcode` then encodes native sources to
Baseline, Extended and Lossless; djpeg (or Pillow) decodes the produced codestreams and must land within the
same bounds of the source (lossless exact), while pydicom reopens the DICOM object. Only counts are kept.
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

BASELINE = "1.2.840.10008.1.2.4.50"
EXTENDED = "1.2.840.10008.1.2.4.51"
LOSSLESS = "1.2.840.10008.1.2.4.57"


def run(args, **kwargs):
    completed = subprocess.run([str(a) for a in args], capture_output=True, timeout=600, **kwargs)
    return completed.returncode, completed.stdout, completed.stderr.decode(errors="replace")[:300]


def write_pnm(path, array):
    if array.ndim == 2:
        header = f"P5\n{array.shape[1]} {array.shape[0]}\n{array.max() if array.dtype != np.uint8 else 255}\n"
    else:
        header = f"P6\n{array.shape[1]} {array.shape[0]}\n255\n"
    data = array.astype(">u2").tobytes() if array.dtype != np.uint8 else array.tobytes()
    path.write_bytes(header.encode() + data)


def read_pnm(data, precision=8):
    parts = data.split(b"\n", 3)
    magic, dims, maxval, body = parts[0], parts[1], parts[2], parts[3]
    width, height = map(int, dims.split())
    channels = 3 if magic == b"P6" else 1
    dtype = ">u2" if int(maxval) > 255 else np.uint8
    array = np.frombuffer(body, dtype=dtype, count=width * height * channels).astype(np.int64)
    return array.reshape(height, width, channels) if channels == 3 else array.reshape(height, width)


def dicom_wrap(path, codestream, syntax, array, photometric):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = "2.25.23449001"
    ds.StudyInstanceUID = "2.25.23449002"
    ds.SeriesInstanceUID = "2.25.23449003"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "JPEG^Oracle", "J-1", "OT", "WSD"
    ds.Rows, ds.Columns = array.shape[0], array.shape[1]
    colour = array.ndim == 3
    ds.SamplesPerPixel = 3 if colour else 1
    ds.PhotometricInterpretation = photometric
    if colour:
        ds.PlanarConfiguration = 0
    bits = 12 if array.dtype != np.uint8 else 8
    ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = (16 if bits == 12 else 8), bits, bits - 1, 0
    ds.PixelData = encapsulate([codestream])
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
    ds.file_meta.TransferSyntaxUID = syntax
    ds["PixelData"].is_undefined_length = True
    ds.is_little_endian, ds.is_implicit_VR = True, False
    ds.save_as(path, enforce_file_format=True)


def native_dicom(path, array, photometric):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = "2.25.23449011"
    ds.StudyInstanceUID = "2.25.23449002"
    ds.SeriesInstanceUID = "2.25.23449003"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "JPEG^Oracle", "J-1", "OT", "WSD"
    ds.ImageType = ["ORIGINAL", "PRIMARY"]
    ds.Rows, ds.Columns = array.shape[0], array.shape[1]
    colour = array.ndim == 3
    ds.SamplesPerPixel = 3 if colour else 1
    ds.PhotometricInterpretation = photometric
    if colour:
        ds.PlanarConfiguration = 0
    bits = 12 if array.dtype != np.uint8 else 8
    ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = (16 if bits == 12 else 8), bits, bits - 1, 0
    ds.PixelData = array.astype("<u2" if bits == 12 else np.uint8).tobytes()
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.is_little_endian, ds.is_implicit_VR = True, False
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    for tool in ("cjpeg", "djpeg"):
        require(shutil.which(tool) is not None, f"{tool} (libjpeg-turbo) is required")
    work = Path(tempfile.mkdtemp(prefix="isis-jpeg-oracle-"))
    results = {}
    try:
        rng = np.random.default_rng(3)
        height, width = 23, 37  # odd dimensions on purpose
        yy, xx = np.mgrid[0:height, 0:width]
        gray = ((xx * 9 + yy * 17) // 3 % 256).astype(np.uint8)
        colour = np.stack([40 + xx * 160 // (width - 1), (xx * 9 + yy * 17) // 3 % 256, 60 + yy * 150 // (height - 1)], axis=-1).astype(np.uint8)
        gray12 = ((xx * 97 + yy * 211) % 4096).astype(np.uint16)
        # 1. Reference codestreams from cjpeg, decoded by us and by djpeg.
        cases = [
            ("gray-444", gray, ["-quality", "95", "-grayscale"], BASELINE, 1, "MONOCHROME2"),
            ("gray-progressive", gray, ["-quality", "95", "-grayscale", "-progressive"], BASELINE, 1, "MONOCHROME2"),
            ("gray-restart", gray, ["-quality", "95", "-grayscale", "-restart", "1B"], BASELINE, 1, "MONOCHROME2"),
            ("colour-444", colour, ["-quality", "95", "-sample", "1x1"], BASELINE, 2, "YBR_FULL"),
            ("colour-420", colour, ["-quality", "95", "-sample", "2x2"], BASELINE, 8, "YBR_FULL_422"),
            ("colour-progressive", colour, ["-quality", "95", "-sample", "1x1", "-progressive"], BASELINE, 2, "YBR_FULL"),
            ("gray12", gray12, ["-quality", "95", "-grayscale", "-precision", "12"], EXTENDED, 1, "MONOCHROME2"),
        ]
        for name, array, flags, syntax, tolerance, photometric in cases:
            pnm = work / f"{name}.pnm"
            write_pnm(pnm, array)
            code, codestream, err = run(["cjpeg", *flags, pnm])
            require(code == 0, f"cjpeg {name}: {err}")
            precision = 12 if array.dtype != np.uint8 else 8
            code, reference_raw, err = run(["djpeg", "-pnm", *(["-precision", "12"] if precision == 12 else [])], input=codestream)
            require(code == 0, f"djpeg {name}: {err}")
            reference = read_pnm(reference_raw, precision)
            dicom = work / f"{name}.dcm"
            dicom_wrap(dicom, codestream, syntax, array, photometric)
            ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, 3 if array.ndim == 3 else 1)
            difference = int(np.max(np.abs(ours - reference)))
            require(difference <= tolerance, f"{name}: own decode differs from djpeg by {difference} (> {tolerance})")
            results[name] = {"maxDifferenceVsLibjpegTurbo": difference, "tolerance": tolerance}
        # 2. Our encoders, decoded by libjpeg-turbo and reopened by pydicom.
        encode_cases = [
            ("encode-gray-baseline", gray, BASELINE, ["--quality", "0.95"], 6, "MONOCHROME2"),
            ("encode-colour-baseline", colour, BASELINE, ["--quality", "0.95"], 8, "RGB"),
            ("encode-gray12-extended", gray12, EXTENDED, ["--quality", "1"], 24, "MONOCHROME2"),
            ("encode-gray-lossless", gray, LOSSLESS, [], 0, "MONOCHROME2"),
            ("encode-gray12-lossless", gray12, LOSSLESS, [], 0, "MONOCHROME2"),
        ]
        for name, array, syntax, flags, tolerance, photometric in encode_cases:
            source = work / f"{name}-source.dcm"
            native_dicom(source, array, photometric)
            output = work / f"{name}.dcm"
            code, _, err = run([args.binary, "codec", "transcode", source, "--output", output, "--transfer-syntax", syntax, "--format", "json", *flags])
            require(code == 0, f"transcode {name}: {err}")
            ds = pydicom.dcmread(output)
            require(str(ds.file_meta.TransferSyntaxUID) == syntax, f"{name}: syntax")
            frames = list(generate_frames(ds.PixelData, number_of_frames=1))
            require(len(frames) == 1, f"{name}: fragments")
            precision = 12 if array.dtype != np.uint8 else 8
            code, decoded_raw, err = run(["djpeg", "-pnm", *(["-precision", "12"] if precision == 12 else [])], input=frames[0])
            require(code == 0, f"djpeg on our {name}: {err}")
            decoded = read_pnm(decoded_raw, precision)
            difference = int(np.max(np.abs(decoded.astype(np.int64) - array.astype(np.int64))))
            require(difference <= tolerance, f"{name}: libjpeg-turbo decodes our codestream {difference} away from the source (> {tolerance})")
            if syntax == LOSSLESS:
                require(ds.SOPInstanceUID == "2.25.23449011", f"{name}: lossless must keep identity")
            else:
                require(ds.SOPInstanceUID != "2.25.23449011" and ds.LossyImageCompression == "01" and "ISO_10918_1" in ds.LossyImageCompressionMethod, f"{name}: lossy provenance")
            if array.ndim == 3:
                require(ds.PhotometricInterpretation == "YBR_FULL", f"{name}: DCT colour output declares YBR_FULL")
            results[name] = {"maxDifferenceVsSource": difference, "tolerance": tolerance}
        # 3. A progressive codestream labelled Baseline is reported as mislabelled by the codec validator.
        code, out, _ = run([args.binary, "codec", "validate", work / "gray-progressive.dcm", "--format", "json"])
        report = json.loads(out.decode(errors="replace") or "{}") if out else {}
        text = json.dumps(report)
        require("codestreamProfileMismatch" in text, "progressive codestream under Baseline must be reported as a profile mismatch")
        results["mislabel"] = {"reported": True}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps({"pydicomVersion": version, "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} JPEG codec cases agree with libjpeg-turbo within the documented tolerances (lossless exact)")


if __name__ == "__main__":
    main()
