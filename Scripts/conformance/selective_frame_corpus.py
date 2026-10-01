#!/usr/bin/env python3
"""Generate non-PHI selective-frame fixtures using an independent pydicom oracle.

Test tooling only: pydicom 3.0.1 and NumPy are installed in an isolated environment.
All sample values are synthetic arithmetic patterns, licensed with this repository.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path

import numpy as np
import pydicom
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.encaps import encapsulate
from pydicom.uid import ExplicitVRBigEndian, ExplicitVRLittleEndian, RLELossless, JPEGBaseline8Bit
from PIL import Image, __version__ as pillow_version


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    profiles = [
        ("packed1", 1, "bits"), ("unsigned32", 32, "unsigned"),
        ("signed32", 32, "signed"), ("unsigned64", 64, "unsigned"),
        ("float32", 32, "float"), ("float64", 64, "float"),
        ("big-endian16", 16, "unsigned"), ("rle8", 8, "unsigned"),
        ("jpeg-fragmented", 8, "jpeg"),
    ]
    fixtures = []
    for index, (name, bits, kind) in enumerate(profiles):
        meta = FileMetaDataset()
        meta.TransferSyntaxUID = ExplicitVRBigEndian if name == "big-endian16" else ExplicitVRLittleEndian
        meta.MediaStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
        meta.MediaStorageSOPInstanceUID = f"2.25.231900{index + 1}"
        meta.ImplementationClassUID = "2.25.2319999"
        meta.ImplementationVersionName = "ISIS_QA_2319"
        ds = FileDataset(None, {}, file_meta=meta, preamble=bytes(128))
        ds.SOPClassUID, ds.SOPInstanceUID = meta.MediaStorageSOPClassUID, meta.MediaStorageSOPInstanceUID
        ds.Rows, ds.Columns, ds.NumberOfFrames, ds.SamplesPerPixel = 3, 5, 3, 1
        ds.PhotometricInterpretation = "MONOCHROME2"
        ds.BitsAllocated = bits
        values = np.arange(45, dtype=np.uint64)
        byte_order = ">" if name == "big-endian16" else "<"
        if kind == "float":
            values = (values.astype(np.float64) * 0.25 - 3.5).astype(byte_order + "f" + str(bits // 8))
            tag = 0x7FE00008 if bits == 32 else 0x7FE00009
            ds.add_new(tag, "OF" if bits == 32 else "OD", values.tobytes())
        else:
            ds.BitsStored, ds.HighBit, ds.PixelRepresentation = bits, bits - 1, int(kind == "signed")
            tag = 0x7FE00010
            if kind == "bits":
                values = ((values * 7 + values // 3) % 2).astype(np.uint8)
                ds.PixelData = np.packbits(values, bitorder="little").tobytes()
            elif kind == "signed":
                values = (values.astype(np.int64) * 65539 - (1 << 30)).astype("<i4")
                ds.PixelData = values.tobytes()
            else:
                base = 1 << (bits - 1) if bits > 16 else 0
                modulus = 1 << bits if bits < 64 else None
                values = values * (37 if bits <= 16 else 65539) + base + 11
                if modulus:
                    values %= modulus
                values = values.astype(byte_order + "u" + str(bits // 8))
                ds.PixelData = values.tobytes()
            ds[0x7FE00010].VR = "OB" if bits <= 8 else "OW"
        if name == "rle8":
            ds.compress(RLELossless, generate_instance_uid=False)
        elif name == "jpeg-fragmented":
            values = np.repeat(np.array([19, 137, 241], dtype=np.uint8), 15)
            codestreams = []
            for frame in values.reshape(3, 3, 5):
                buffer = io.BytesIO()
                Image.fromarray(frame).save(buffer, format="JPEG", quality=100)
                jpeg = buffer.getvalue()
                # False EOI/SOI bytes inside a length-delimited APP15 payload.
                app = bytes.fromhex("FF EF 00 08 01 FF D9 FF D8 02")
                codestreams.append(jpeg[:2] + app + jpeg[2:])
            ds.PixelData = encapsulate(codestreams, fragments_per_frame=3, has_bot=False)
            ds[0x7FE00010].is_undefined_length = True
            ds.file_meta.TransferSyntaxUID = JPEGBaseline8Bit
            ds.LossyImageCompression = "01"
            ds.LossyImageCompressionMethod = "ISO_10918_1"
        path = output / (name + ".dcm")
        pydicom.dcmwrite(path, ds, enforce_file_format=True)
        reread = pydicom.dcmread(path)
        decoded = reread.pixel_array.reshape(-1)
        np.testing.assert_array_equal(decoded, values)
        fixtures.append({
            "id": name, "path": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bitsAllocated": bits, "kind": kind, "pixelDataTag": tag,
            "rows": 3, "columns": 5, "frames": 3,
            "transferSyntaxUID": str(reread.file_meta.TransferSyntaxUID),
            "samples": [[str(value.item()) for value in frame] for frame in decoded.reshape(3, 15)],
        })
    manifest = {"version": 1, "issue": 2319, "license": "Repository license",
                "provenance": "Arithmetic synthetic pixels; pydicom writer and independent pixel_array decode.",
                "oracle": {"name": "pydicom", "version": pydicom.__version__, "numpyVersion": np.__version__,
                           "pillowVersion": pillow_version},
                "fixtures": fixtures}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Generated and independently decoded {len(fixtures)} fixtures, {len(fixtures) * 3} frames and {len(fixtures) * 45} samples.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    generate(parser.parse_args().output)
