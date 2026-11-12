#!/usr/bin/env python3
"""Independent check of the own JPEG-LS codec (vendored JLSwift core, #2328) against CharLS through pyjpegls and pydicom.

pyjpegls (CharLS 2.x) writes reference codestreams — 8/12/16-bit grayscale lossless and NEAR, 8-bit RGB with
ILV none/line/sample — each wrapped in a Part 10 file with pydicom and decoded by `dicomtool codec decode`; lossless
samples must be exact and near-lossless samples must equal CharLS's own decode and stay within NEAR of the source.
`dicomtool codec transcode` then encodes native sources (grayscale, RGB per interleave, multiframe, restart lines,
NEAR) and CharLS decodes every produced frame (exact for lossless, within NEAR otherwise); pydicom reopens the
objects and the loss provenance is checked. Invalid option combinations are refused. Only counts are kept.
"""
import argparse
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import jpeg_ls
import numpy as np
import pydicom
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.encaps import encapsulate, generate_frames
from pydicom.uid import ExplicitVRLittleEndian
from image_iod_oracle import require

LOSSLESS = "1.2.840.10008.1.2.4.80"
NEAR_LOSSLESS = "1.2.840.10008.1.2.4.81"
SOURCE_UID = "2.25.23280011"


def run(args, **kwargs):
    completed = subprocess.run([str(a) for a in args], capture_output=True, timeout=600, **kwargs)
    return completed.returncode, completed.stdout, completed.stderr.decode(errors="replace")[:300]


def dataset(array, precision, photometric, frames=1):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = SOURCE_UID
    ds.StudyInstanceUID = "2.25.23280012"
    ds.SeriesInstanceUID = "2.25.23280013"
    ds.PatientName, ds.PatientID, ds.Modality, ds.ConversionType = "JPEGLS^Oracle", "JLS-1", "OT", "WSD"
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
    ds.PixelData = encapsulate([bytes(codestream)])
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


def charls_decode(codestream, shape, channels):
    decoded, info = jpeg_ls.decode_buffer(bytes(codestream))
    dtype = "<u2" if info["bits_per_sample"] > 8 else np.uint8
    array = np.frombuffer(bytes(decoded), dtype=dtype).astype(np.int64)
    require(info["components"] == channels and info["width"] == shape[1] and info["height"] == shape[0], "CharLS header disagrees with the case")
    if channels == 3:
        if info["interleave_mode"] == 0:
            # CharLS returns colour planes for ILV none.
            return array.reshape(3, shape[0], shape[1]).transpose(1, 2, 0)
        return array.reshape(shape[0], shape[1], 3)
    return array.reshape(shape)


def charls_encode(array, precision, near, interleave):
    data = array.astype("<u2" if precision > 8 else np.uint8)
    if array.ndim == 3 and interleave == 0:
        data = np.ascontiguousarray(data.transpose(2, 0, 1))  # planes
    return jpeg_ls.encode_buffer(data.tobytes(), array.shape[0], array.shape[1], 3 if array.ndim == 3 else 1, precision,
                                 lossy_error=near, interleave_mode=interleave)


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
    charls_version = importlib.metadata.version("pyjpegls")
    rng = np.random.default_rng(2328)
    work = Path(tempfile.mkdtemp(prefix="isis-jpegls-oracle-"))
    results = {}
    try:
        # 1. CharLS references decoded by the own backend.
        gray8, gray12, gray16 = fixture(rng, 23, 37, 8), fixture(rng, 23, 37, 12), fixture(rng, 23, 37, 16)
        colour = fixture(rng, 19, 29, 8, channels=3)
        decode_cases = [("gray8-lossless", gray8, 8, 0, 0), ("gray12-lossless", gray12, 12, 0, 0), ("gray16-lossless", gray16, 16, 0, 0),
                        ("gray8-near2", gray8, 8, 2, 0), ("gray12-near3", gray12, 12, 3, 0), ("gray16-near5", gray16, 16, 5, 0),
                        ("rgb8-ilv-none", colour, 8, 0, 0), ("rgb8-ilv-line", colour, 8, 0, 1), ("rgb8-ilv-sample", colour, 8, 0, 2),
                        ("rgb8-ilv-sample-near2", colour, 8, 2, 2), ("rgb8-ilv-line-near1", colour, 8, 1, 1)]
        for name, array, precision, near, interleave in decode_cases:
            codestream = charls_encode(array, precision, near, interleave)
            reference = charls_decode(codestream, array.shape[:2], 3 if array.ndim == 3 else 1)
            syntax = LOSSLESS if near == 0 else NEAR_LOSSLESS
            dicom = work / f"{name}.dcm"
            dicom_wrap(dicom, codestream, syntax, array, precision, "RGB" if array.ndim == 3 else "MONOCHROME2")
            ours = our_decode(args.binary, dicom, work, array.shape[:2], precision, 3 if array.ndim == 3 else 1)
            require(np.array_equal(ours, reference), f"{name}: own decode differs from CharLS")
            error = int(np.max(np.abs(ours - array.astype(np.int64))))
            require(error <= near, f"{name}: error {error} exceeds NEAR {near}")
            results[name] = {"exactVsCharLS": True, "maxErrorVsSource": error, "near": near}
        # 2. Own encoder output decoded by CharLS, reopened by pydicom.
        multi12 = fixture(rng, 3 * 15, 27, 12)
        encode_cases = [
            ("encode-gray8", gray8, 8, LOSSLESS, [], 1, 0),
            ("encode-gray12-restart4", gray12, 12, LOSSLESS, ["--restart-lines", "4"], 1, 0),
            ("encode-gray16", gray16, 16, LOSSLESS, [], 1, 0),
            ("encode-gray12-multiframe", multi12, 12, LOSSLESS, [], 3, 0),
            ("encode-gray12-near3", gray12, 12, NEAR_LOSSLESS, ["--near", "3"], 1, 3),
            ("encode-rgb8-none", colour, 8, LOSSLESS, ["--interleave", "none"], 1, 0),
            ("encode-rgb8-line", colour, 8, LOSSLESS, ["--interleave", "line"], 1, 0),
            ("encode-rgb8-sample", colour, 8, LOSSLESS, ["--interleave", "sample"], 1, 0),
            ("encode-rgb8-none-restart3", colour, 8, LOSSLESS, ["--interleave", "none", "--restart-lines", "3"], 1, 0),
            ("encode-rgb8-sample-near2", colour, 8, NEAR_LOSSLESS, ["--near", "2", "--interleave", "sample"], 1, 2),
        ]
        for name, array, precision, syntax, flags, frames, near in encode_cases:
            source = work / f"{name}-source.dcm"
            native_dicom(source, array, precision, "RGB" if array.ndim == 3 else "MONOCHROME2", frames)
            output = work / f"{name}.dcm"
            code, _, err = run([args.binary, "codec", "transcode", source, "--output", output, "--transfer-syntax", syntax, "--format", "json", *flags])
            require(code == 0, f"transcode {name}: {err}")
            ds = pydicom.dcmread(output)
            require(str(ds.file_meta.TransferSyntaxUID) == syntax, f"{name}: syntax")
            fragments = list(generate_frames(ds.PixelData, number_of_frames=frames))
            require(len(fragments) == frames, f"{name}: {len(fragments)} frames, expected {frames}")
            rows = array.shape[0] // frames
            for index, frame in enumerate(fragments):
                decoded = charls_decode(frame, (rows, array.shape[1]), 3 if array.ndim == 3 else 1)
                error = int(np.max(np.abs(decoded - array[index * rows:(index + 1) * rows].astype(np.int64))))
                require(error <= near, f"{name}: CharLS decode of frame {index} is {error} from the source (NEAR {near})")
            if near:
                require(ds.SOPInstanceUID != SOURCE_UID and ds.LossyImageCompression == "01" and "ISO_14495_1" in ds.LossyImageCompressionMethod, f"{name}: lossy provenance")
            else:
                require(ds.SOPInstanceUID == SOURCE_UID and "LossyImageCompression" not in ds, f"{name}: lossless must keep identity")
            if array.ndim == 3:
                require(int(ds.PlanarConfiguration) == 0, f"{name}: Planar Configuration shall be 0 (PS3.5 8.2.3)")
                # pydicom + pyjpegls read the object back to RGBRGB.
                require(ds.pixel_array.shape == (rows, array.shape[1], 3), f"{name}: pydicom pixel_array shape")
            results[name] = {"withinNearVsCharLS": True, "frames": frames, "near": near}
        # 3. Refused combinations: restart with NEAR, restart with interleaved scans, NEAR under the lossless syntax.
        source = work / "encode-gray12-restart4-source.dcm"
        for label, syntax, flags in [("restart-near", NEAR_LOSSLESS, ["--near", "2", "--restart-lines", "2"]),
                                     ("near-under-lossless", LOSSLESS, ["--near", "2", "--interleave", "none"]),
                                     ("dri-overflow", LOSSLESS, ["--restart-lines", "70000"])]:
            code, _, _ = run([args.binary, "codec", "transcode", source, "--output", work / "refused.dcm", "--transfer-syntax", syntax, *flags])
            require(code != 0, f"{label} must be refused")
        colour_source = work / "encode-rgb8-sample-source.dcm"
        code, _, _ = run([args.binary, "codec", "transcode", colour_source, "--output", work / "refused.dcm", "--transfer-syntax", LOSSLESS, "--interleave", "sample", "--restart-lines", "2"])
        require(code != 0, "restart with sample interleave must be refused")
        results["refusals"] = {"restartNear": True, "nearUnderLossless": True, "driOverflow": True, "restartInterleaved": True}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps({"pydicomVersion": version, "pyjpeglsVersion": charls_version, "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} JPEG-LS cases agree with CharLS (pyjpegls {charls_version}): lossless exact, near-lossless within NEAR, interleave none/line/sample, restarts, multiframe")


if __name__ == "__main__":
    main()
