#!/usr/bin/env python3
"""Independent check of the SEG pixel encodings written by DicomSegmentationBuilder (Isis issue #2513).

The input directory holds one Segmentation written four times by `DicomSegmentationBuilder.encodedDataSet`:
native.dcm (Explicit VR Little Endian), deflatedDataSet.dcm (1.2.840.10008.1.2.1.99), rleLossless.dcm
(1.2.840.10008.1.2.5) and deflatedFrames.dcm (1.2.840.10008.1.2.8.1). pydicom 3.0.2 must read every file with
the declared transfer syntax, the same attributes as the native file apart from Pixel Data, and every frame
equal to the native frame: dataset deflate through dcmread, RLE through pydicom's own decoder, and frame deflate
(which pydicom 3.0.2 does not know) through its fragment parser and a raw DEFLATE inflate. GDCM, when gdcmconv is
on the PATH, decompresses each file to native bytes as a second reader; GDCM 3.2.7 does not know the Label Map SOP
Class, so it reads a copy whose SOP Class UIDs say Segmentation Storage (the same length, patched in place, so no
offset moves) and its refusals are recorded. Only counts are recorded. Needs no NumPy.
"""
import argparse
import importlib.metadata
import json
import shutil
import subprocess
import tempfile
import zlib
from pathlib import Path

import pydicom
from pydicom.encaps import generate_frames
from pydicom.pixels import get_decoder
from pydicom.uid import RLELossless

EXPECTED = {
    "native": "1.2.840.10008.1.2.1",
    "deflatedDataSet": "1.2.840.10008.1.2.1.99",
    "rleLossless": "1.2.840.10008.1.2.5",
    "deflatedFrames": "1.2.840.10008.1.2.8.1",
}
PIXEL_TAGS = {0x7FE00010, 0x7FE00001, 0x7FE00002}
LABEL_MAP_SOP_CLASS = b"1.2.840.10008.5.1.4.1.1.66.7"
SEGMENTATION_SOP_CLASS = b"1.2.840.10008.5.1.4.1.1.66.4"


def frame_length(ds):
    return ds.Rows * ds.Columns * ds.BitsAllocated // 8


def native_frames(ds):
    data, length = ds.PixelData, frame_length(ds)
    return [data[i * length:(i + 1) * length] for i in range(int(ds.NumberOfFrames))]


def pydicom_frames(ds, name):
    if name in ("native", "deflatedDataSet"):
        return native_frames(ds)
    count = int(ds.NumberOfFrames)
    if name == "rleLossless":
        return [bytes(buffer) for buffer, _ in get_decoder(RLELossless).iter_buffer(ds)]
    # Deflated Image Frame Compression: one raw DEFLATE stream per fragment, one NULL pad on odd lengths.
    return [zlib.decompressobj(wbits=-15).decompress(fragment)[:frame_length(ds)]
            for fragment in generate_frames(ds.PixelData, number_of_frames=count)]


def attributes(ds):
    return {element.tag: element.value for element in ds if element.tag not in PIXEL_TAGS}


def gdcm_frames(path):
    if shutil.which("gdcmconv") is None:
        return None, "gdcmconv not found"
    with tempfile.TemporaryDirectory() as directory:
        source, output = Path(directory) / "seg.dcm", Path(directory) / "raw.dcm"
        source.write_bytes(path.read_bytes().replace(LABEL_MAP_SOP_CLASS, SEGMENTATION_SOP_CLASS))
        completed = subprocess.run(["gdcmconv", "--raw", str(source), str(output)], capture_output=True, timeout=900)
        if completed.returncode != 0 or not output.exists():
            return None, completed.stderr.decode(errors="replace").strip()[:200] or f"exit {completed.returncode}"
        return native_frames(pydicom.dcmread(output)), None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    reference = pydicom.dcmread(args.directory / "native.dcm")
    expected_frames = native_frames(reference)
    expected_attributes = attributes(reference)
    records = {}
    for name, uid in EXPECTED.items():
        path = args.directory / f"{name}.dcm"
        ds = pydicom.dcmread(path)
        frames = pydicom_frames(ds, name)
        gdcm, gdcm_failure = gdcm_frames(path)
        found = attributes(ds)
        records[name] = {
            "bytes": path.stat().st_size,
            "transferSyntax": str(ds.file_meta.TransferSyntaxUID),
            "transferSyntaxMatches": str(ds.file_meta.TransferSyntaxUID) == uid,
            "attributesCompared": len(expected_attributes),
            "attributesDiffering": sum(found.get(tag) != value for tag, value in expected_attributes.items())
                + len(set(found) - set(expected_attributes)),
            "frames": len(frames),
            "pydicomFramesEqual": sum(a == b for a, b in zip(frames, expected_frames)),
            "gdcmFramesEqual": None if gdcm is None else sum(a == b for a, b in zip(gdcm, expected_frames)),
            "gdcmFailure": gdcm_failure,
        }
    passed = all(r["transferSyntaxMatches"] and r["attributesDiffering"] == 0 and r["frames"] == len(expected_frames)
                 and r["pydicomFramesEqual"] == len(expected_frames) for r in records.values())
    gdcm_version = None
    if shutil.which("gdcmconv"):
        gdcm_version = subprocess.run(["gdcmconv", "--version"], capture_output=True, text=True).stdout.split("$")[0].strip()
    summary = {"pydicom": importlib.metadata.version("pydicom"), "gdcm": gdcm_version,
               "referenceFrames": len(expected_frames), "passed": passed, "files": records}
    text = json.dumps(summary, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(text + "\n")
    print(text)
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
