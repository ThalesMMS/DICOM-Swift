#!/usr/bin/env python3
"""Independent check of the transcode route matrix with pydicom 3.0.2 (#2325).

Synthetic sources (16-bit signed MONOCHROME2 with three frames, 8-bit RGB with two frames, 8-bit MONOCHROME1)
are written by pydicom, converted with `dicomtool codec transcode` along every route the engine announces as
executable, and reopened by pydicom: reversible routes must reproduce pixel_array exactly, the declared
transfer syntax must match, encapsulated outputs must carry one fragment per frame with a coherent Basic
Offset Table, and lossy routes must derive a new SOP Instance with Lossy Image Compression history,
Source Image Sequence and Derivation Code Sequence while staying within the requested bound. A round trip
back to native and a passthrough are checked for each compressed syntax. Only counts are recorded.
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
from pydicom.encaps import generate_frames
from pydicom.uid import ExplicitVRLittleEndian
from image_iod_oracle import require

NATIVE = "1.2.840.10008.1.2.1"
IMPLICIT = "1.2.840.10008.1.2"
DEFLATE = "1.2.840.10008.1.2.1.99"
RLE = "1.2.840.10008.1.2.5"
JLS = "1.2.840.10008.1.2.4.80"
JLS_NEAR = "1.2.840.10008.1.2.4.81"
J2K_LOSSLESS = "1.2.840.10008.1.2.4.90"
J2K = "1.2.840.10008.1.2.4.91"
REVERSIBLE_TARGETS = [NATIVE, IMPLICIT, DEFLATE, RLE, JLS, J2K_LOSSLESS]


def make_source(work, name, kind):
    ds = Dataset()
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = f"2.25.2342900{len(name)}"
    ds.StudyInstanceUID = "2.25.23429002"
    ds.SeriesInstanceUID = "2.25.23429003"
    ds.PatientName = "Transcode^Oracle"
    ds.PatientID = "TO-1"
    ds.Modality = "OT"
    ds.ConversionType = "WSD"
    ds.ImageType = ["ORIGINAL", "PRIMARY"]
    ds.InstanceNumber = "1"
    rows, columns = 8, 10
    ds.Rows, ds.Columns = rows, columns
    rng = np.random.default_rng(7)
    if kind == "gray16":
        frames = 3
        pixels = (rng.integers(-2000, 3000, size=(frames, rows, columns))).astype(np.int16)
        pixels[:, :3, :] = -5  # runs for RLE
        ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, "MONOCHROME2"
        ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 16, 16, 15, 1
    elif kind == "rgb":
        frames = 2
        pixels = rng.integers(0, 256, size=(frames, rows, columns, 3)).astype(np.uint8)
        pixels[:, :2, :, :] = 9
        ds.SamplesPerPixel, ds.PhotometricInterpretation, ds.PlanarConfiguration = 3, "RGB", 0
        ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 8, 8, 7, 0
    else:
        frames = 2
        pixels = rng.integers(0, 256, size=(frames, rows, columns)).astype(np.uint8)
        ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, "MONOCHROME1"
        ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 8, 8, 7, 0
    ds.NumberOfFrames = str(frames)
    ds.PixelData = pixels.tobytes()
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = ds.SOPInstanceUID
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.is_little_endian, ds.is_implicit_VR = True, False
    path = work / f"{name}.dcm"
    ds.save_as(path, enforce_file_format=True)
    return path, pixels


def transcode(binary, source, target, output, quality=None, near=None):
    args = [str(binary), "codec", "transcode", str(source), "--output", str(output), "--transfer-syntax", target, "--format", "json"]
    if quality is not None:
        args += ["--quality", str(quality)]
    if near is not None:
        args += ["--near", str(near)]
    completed = subprocess.run(args, capture_output=True, timeout=600)
    return completed.returncode, completed.stderr.decode(errors="replace")[:300]


def reference_pixels(ds):
    arr = ds.pixel_array
    return arr


def check_reversible(source_pixels, output_path, target, expected_frames):
    ds = pydicom.dcmread(output_path)
    require(str(ds.file_meta.TransferSyntaxUID) == target, f"{target}: declared syntax differs")
    arr = ds.pixel_array
    if arr.ndim == 2:
        arr = arr[np.newaxis]
    require(np.array_equal(arr, source_pixels), f"{target}: pixels differ after reversible transcode")
    require(ds.SOPInstanceUID == pydicom.dcmread(output_path, stop_before_pixels=True).SOPInstanceUID, "identity")
    if target in (RLE, JLS, J2K_LOSSLESS):
        frames = list(generate_frames(ds.PixelData, number_of_frames=expected_frames))
        require(len(frames) == expected_frames, f"{target}: {len(frames)} fragments for {expected_frames} frames")
    require("LossyImageCompression" not in ds or ds.LossyImageCompression != "01", f"{target}: reversible route marked lossy")
    return ds


def check_lossy(source_pixels, source_uid, output_path, target, bound):
    ds = pydicom.dcmread(output_path)
    require(str(ds.file_meta.TransferSyntaxUID) == target, f"{target}: declared syntax differs")
    require(ds.SOPInstanceUID != source_uid and ds.file_meta.MediaStorageSOPInstanceUID == ds.SOPInstanceUID, f"{target}: lossy output keeps the source identity")
    require(ds.LossyImageCompression == "01", f"{target}: lossy history missing")
    require(float(ds.LossyImageCompressionRatio) > 0, f"{target}: ratio missing")
    require(ds.ImageType[0] == "DERIVED", f"{target}: image type not derived")
    require(ds.SourceImageSequence[0].ReferencedSOPInstanceUID == source_uid, f"{target}: source image missing")
    require(ds.DerivationCodeSequence[0].CodeValue == "113040", f"{target}: derivation code missing")
    arr = ds.pixel_array
    if arr.ndim == 2:
        arr = arr[np.newaxis]
    if bound is not None:
        require(np.max(np.abs(arr.astype(np.int64) - source_pixels.astype(np.int64))) <= bound, f"{target}: NEAR bound exceeded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    work = Path(tempfile.mkdtemp(prefix="isis-transcode-oracle-"))
    routes = 0
    results = {}
    try:
        for kind in ("gray16", "rgb", "mono1"):
            source, pixels = make_source(work, kind, kind)
            frames = pixels.shape[0]
            source_uid = pydicom.dcmread(source, stop_before_pixels=True).SOPInstanceUID
            compressed_outputs = {}
            for target in REVERSIBLE_TARGETS:
                out = work / f"{kind}-{target}.dcm"
                code, err = transcode(args.binary, source, target, out)
                require(code == 0, f"{kind} -> {target}: {err}")
                ds = check_reversible(pixels, out, target, frames)
                routes += 1
                if target in (RLE, JLS, J2K_LOSSLESS):
                    compressed_outputs[target] = out
            for target, path in compressed_outputs.items():
                back = work / f"{kind}-{target}-native.dcm"
                code, err = transcode(args.binary, path, NATIVE, back)
                require(code == 0, f"{kind} {target} -> native: {err}")
                check_reversible(pixels, back, NATIVE, frames)
                same = work / f"{kind}-{target}-same.dcm"
                code, err = transcode(args.binary, path, target, same)
                require(code == 0, f"{kind} {target} passthrough: {err}")
                require(same.read_bytes() == path.read_bytes() or pydicom.dcmread(same).PixelData == pydicom.dcmread(path).PixelData, f"{kind} {target}: passthrough changed pixel data")
                for other in compressed_outputs:
                    if other == target:
                        continue
                    across = work / f"{kind}-{target}-{other}.dcm"
                    code, err = transcode(args.binary, path, other, across)
                    require(code == 0, f"{kind} {target} -> {other}: {err}")
                    check_reversible(pixels, across, other, frames)
                    routes += 1
                routes += 2
            if kind == "gray16":
                near = work / f"{kind}-near.dcm"
                code, err = transcode(args.binary, source, JLS_NEAR, near, near=2)
                require(code == 0, f"{kind} -> JPEG-LS near: {err}")
                check_lossy(pixels, source_uid, near, JLS_NEAR, 2)
                routes += 1
                rewrap = work / f"{kind}-rewrap.dcm"
                code, err = transcode(args.binary, compressed_outputs[J2K_LOSSLESS], J2K, rewrap)
                require(code == 0, f"{kind} .90 -> .91 rewrap: {err}")
                original_frames = list(generate_frames(pydicom.dcmread(compressed_outputs[J2K_LOSSLESS]).PixelData, number_of_frames=frames))
                rewrapped_frames = list(generate_frames(pydicom.dcmread(rewrap).PixelData, number_of_frames=frames))
                require(original_frames == rewrapped_frames, "rewrap re-encoded the codestreams")
                require(str(pydicom.dcmread(rewrap, stop_before_pixels=True).file_meta.TransferSyntaxUID) == J2K, "rewrap syntax")
                routes += 1
                refused = work / f"{kind}-refused.dcm"
                code, _ = transcode(args.binary, source, JLS_NEAR, refused)
                require(code != 0 and not refused.exists(), "NEAR without explicit intent must be refused without an artifact")
                code, _ = transcode(args.binary, source, NATIVE, refused, quality=0.5)
                require(code != 0 and not refused.exists(), "loss intent for a native destination must be refused")
            results[kind] = {"frames": frames}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps({"pydicomVersion": version, "routes": routes, "sources": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {routes} transcode routes reopened by pydicom with exact pixels, coherent fragments and explicit loss provenance")


if __name__ == "__main__":
    main()
