#!/usr/bin/env python3
"""Independent check of file-sets, merges and splits produced by dicomtool (#2323), with pydicom 3.0.2.

A file-set built with `dicomtool dcmdir build` from real sample files is opened with pydicom's FileSet: every
record must resolve to a Part 10 file inside the root whose SOP Instance UID matches the record, and the
instance count must equal the number of inputs. A classic CT series merged with `dicomtool merge` is read by
pydicom: NumberOfFrames, per-frame Image Position (Patient) and Conversion Source references must match the
sources, and every frame of pixel_array must equal the source pixel_array. The merged object split again with
`dicomtool split` must reproduce every source frame's pixels and position. Only counts and hashes are recorded.
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import numpy as np
import pydicom
from pydicom.fileset import FileSet
from image_iod_oracle import require


def run(binary, *args):
    completed = subprocess.run([str(binary), *map(str, args)], capture_output=True, timeout=600)
    require(completed.returncode == 0, f"dicomtool {args[0]} failed: {completed.stderr.decode(errors='replace')[:300]}")
    return completed.stdout.decode(errors="replace")


def part10_files(directory, limit):
    files = sorted(p for p in Path(directory).rglob("*") if p.is_file() and not p.name.startswith(".") and p.stat().st_size > 132
                   and p.open("rb").read(132)[128:] == b"DICM")
    return files[:limit]


def check_fileset(binary, files, work):
    root = work / "FILESET"
    run(binary, "dcmdir", "build", *files, "--output", root, "--id", "ORACLE")
    run(binary, "dcmdir", "validate", root)
    fs = FileSet(root / "DICOMDIR")
    instances = list(fs)
    require(len(instances) == len(files), f"FileSet lists {len(instances)} instances for {len(files)} inputs")
    expected = {pydicom.dcmread(f, stop_before_pixels=True).SOPInstanceUID for f in files}
    seen = set()
    for instance in instances:
        path = Path(instance.path).resolve()
        require(root.resolve() in path.parents, "record resolves outside the root")
        ds = pydicom.dcmread(path, stop_before_pixels=True)
        require(ds.SOPInstanceUID == instance.SOPInstanceUID, "record SOP Instance UID differs from the file")
        require(ds.file_meta.MediaStorageSOPInstanceUID == instance.SOPInstanceUID, "file meta differs from the record")
        seen.add(ds.SOPInstanceUID)
    require(seen == expected, "file-set instances differ from the inputs")
    return {"instances": len(instances), "dicomdirSHA256": hashlib.sha256((root / "DICOMDIR").read_bytes()).hexdigest()}


def check_merge_and_split(binary, files, work):
    sources = {}
    for f in files:
        ds = pydicom.dcmread(f)
        sources[ds.SOPInstanceUID] = ds
    merged_path = work / "merged.dcm"
    run(binary, "merge", *files, "--output", merged_path)
    merged = pydicom.dcmread(merged_path)
    frames = int(merged.NumberOfFrames)
    require(frames == len(files), f"merged NumberOfFrames {frames} != {len(files)}")
    require(merged.SOPClassUID in ("1.2.840.10008.5.1.4.1.1.2.2", "1.2.840.10008.5.1.4.1.1.4.4"), "merged SOP Class is not Legacy Converted")
    pixels = merged.pixel_array
    require(pixels.shape[0] == frames, "pixel_array frame count differs")
    order = []
    for index, group in enumerate(merged.PerFrameFunctionalGroupsSequence):
        uid = group.ConversionSourceAttributesSequence[0].ReferencedSOPInstanceUID
        require(uid in sources, "Conversion Source references an unknown instance")
        source = sources[uid]
        position = [float(v) for v in group.PlanePositionSequence[0].ImagePositionPatient]
        require(np.allclose(position, [float(v) for v in source.ImagePositionPatient], atol=1e-4), f"frame {index + 1} position differs")
        require(np.array_equal(pixels[index], source.pixel_array), f"frame {index + 1} pixels differ")
        order.append(uid)
    require(len(set(order)) == frames, "a source is referenced twice")
    shared = merged.SharedFunctionalGroupsSequence[0]
    first = sources[order[0]]
    require(np.allclose([float(v) for v in shared.PlaneOrientationSequence[0].ImageOrientationPatient], [float(v) for v in first.ImageOrientationPatient]), "orientation differs")
    require(np.allclose([float(v) for v in shared.PixelMeasuresSequence[0].PixelSpacing], [float(v) for v in first.PixelSpacing]), "pixel spacing differs")
    split_dir = work / "SPLIT"
    run(binary, "split", merged_path, "--output", split_dir)
    outputs = sorted(split_dir.glob("*.dcm"))
    require(len(outputs) == frames, "split produced a different number of instances")
    for index, path in enumerate(outputs):
        ds = pydicom.dcmread(path)
        source = sources[order[index]]
        require(ds.SOPClassUID == source.SOPClassUID, "split SOP Class differs from the source")
        require(np.array_equal(ds.pixel_array, source.pixel_array), f"split instance {index + 1} pixels differ")
        require(np.allclose([float(v) for v in ds.ImagePositionPatient], [float(v) for v in source.ImagePositionPatient], atol=1e-4), "split position differs")
        require(ds.SourceImageSequence[0].ReferencedSOPInstanceUID == merged.SOPInstanceUID, "split provenance differs")
        require(ds.SOPInstanceUID not in sources and ds.SOPInstanceUID != merged.SOPInstanceUID, "split instance reuses an identity")
    return {"frames": frames, "mergedSHA256": hashlib.sha256(merged_path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=Path, required=True, help="Directory of real DICOM files (read locally, never copied into the repository)")
    parser.add_argument("--ct-series", type=Path, required=True, help="Directory holding one classic CT series with native pixels")
    parser.add_argument("--sample-limit", type=int, default=24)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    work = Path(tempfile.mkdtemp(prefix="isis-fileset-oracle-"))
    try:
        samples = part10_files(args.samples, args.sample_limit)
        require(len(samples) >= 2, "not enough sample files")
        series = part10_files(args.ct_series, args.sample_limit)
        require(len(series) >= 3, "not enough CT slices")
        records = {"pydicomVersion": version, "fileSet": check_fileset(args.binary, samples, work),
                   "mergeSplit": check_merge_and_split(args.binary, series, work)}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps(records, indent=2, sort_keys=True) + "\n")
    print(f"PASS: file-set of {records['fileSet']['instances']} instances opened by pydicom FileSet; "
          f"merge/split of {records['mergeSplit']['frames']} CT slices agree with pydicom pixel_array and geometry")


if __name__ == "__main__":
    main()
