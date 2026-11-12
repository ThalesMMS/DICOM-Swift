#!/usr/bin/env python3
"""Regenerates the compressed Segmentation fixtures of Isis issue #2520 with third-party encoders.

The inputs are the synthetic native SEGs in the fixture directory (native-binary.dcm, native-labelmap8.dcm,
native-labelmap16.dcm, native-fractional.dcm, written by DicomSegmentationBuilder). Each compressed copy keeps every
attribute but the transfer syntax and Pixel Data, and is decoded back by an independent path and compared with the
native frames before it is written:

- GDCM gdcmconv: JPEG-LS Lossless (.4.80), JPEG 2000 Lossless (.4.90) and RLE Lossless (.5). GDCM does not know Label
  Map Segmentation Storage (.66.7), so a copy declared .66.4 is transcoded and declared back; the pixels are untouched.
- OpenJPH ojph_compress: HTJ2K Lossless (.4.201) codestreams, one fragment per frame, checked with ojph_expand.
- dcmjs (the OHIF SEG writer), rleSingleSamplePerPixel.encode run under node from a dcmjs checkout (--dcmjs): with RLE,
  dcmjs rewrites a BINARY SEG as FRACTIONAL PROBABILITY, 8 bits, one byte (0/1) per pixel, Maximum Fractional Value 255.
- pydicom's RLE encoder: BINARY (1 bit declared) with each frame's RLE segment holding either the frame's packed bits or
  one byte per pixel, the two forms a reader may meet.

Usage: seg_compressed_fixtures.py FIXTURE_DIR [--dcmjs DCMJS_CHECKOUT]
Tools used for the committed files: GDCM 3.2.7, OpenJPH 0.32.0, dcmjs 0.49.2 (commit 81e7e11), pydicom 3.0.2, node 26.
"""
import argparse
import base64
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import pydicom
from pydicom.encaps import encapsulate, generate_frames
from pydicom.pixels import get_decoder, get_encoder
from pydicom.uid import RLELossless

LABEL_MAP = "1.2.840.10008.5.1.4.1.1.66.7"
SEGMENTATION = "1.2.840.10008.5.1.4.1.1.66.4"
HTJ2K_LOSSLESS = "1.2.840.10008.1.2.4.201"


def run(*args):
    subprocess.run([str(a) for a in args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def native_frames(ds):
    """Frames of a native SEG as bytes; BINARY frames are unpacked to one byte per pixel."""
    pixels, count = ds.Rows * ds.Columns, int(ds.NumberOfFrames)
    if ds.BitsAllocated == 1:
        bits = [(ds.PixelData[i // 8] >> (i % 8)) & 1 for i in range(pixels * count)]
        return [bytes(bits[f * pixels:(f + 1) * pixels]) for f in range(count)]
    size = pixels * ds.BitsAllocated // 8
    return [ds.PixelData[f * size:(f + 1) * size] for f in range(count)]


def set_sop(ds, sop):
    ds.SOPClassUID = sop
    ds.file_meta.MediaStorageSOPClassUID = sop


def encapsulated(ds, fragments, transfer_syntax):
    ds.file_meta.TransferSyntaxUID = transfer_syntax
    ds.PixelData = encapsulate(fragments)
    ds["PixelData"].VR = "OB"
    ds["PixelData"].is_undefined_length = True


def unpack_rle_segment(fragment):
    """The single byte segment of an RLE fragment, decoded (PackBits)."""
    count, offset = int.from_bytes(fragment[:4], "little"), int.from_bytes(fragment[4:8], "little")
    assert count == 1
    out, data, i = bytearray(), fragment[offset:], 0
    while i < len(data):
        n = data[i]
        i += 1
        if n < 128:
            out += data[i:i + n + 1]
            i += n + 1
        elif n > 128:
            out += bytes([data[i]]) * (257 - n)
            i += 1
    return bytes(out)


class Generator:
    def __init__(self, directory, dcmjs, work):
        self.directory, self.dcmjs, self.work = directory, dcmjs, work
        self.report = {}

    def native(self, name):
        return pydicom.dcmread(self.directory / f"native-{name}.dcm")

    def save(self, ds, filename, equal):
        if not equal:
            raise SystemExit(f"{filename}: decoded frames differ from the native frames")
        ds.save_as(self.directory / filename, enforce_file_format=True)
        self.report[filename] = str(ds.file_meta.TransferSyntaxUID)

    def gdcm(self, name, mode):
        source = self.native(name)
        sop = str(source.SOPClassUID)
        set_sop(source, SEGMENTATION)
        relabeled, encoded, raw = (self.work / f"{name}-{suffix}.dcm" for suffix in ("seg", mode, "raw"))
        source.save_as(relabeled, enforce_file_format=True)
        run("gdcmconv", f"--{mode}", relabeled, encoded)
        run("gdcmconv", "--raw", encoded, raw)
        result = pydicom.dcmread(encoded)
        set_sop(result, sop)
        self.save(result, f"gdcm-{mode}-{name}.dcm", pydicom.dcmread(raw).PixelData == self.native(name).PixelData)

    def htj2k(self, name):
        ds = self.native(name)
        wide, codestreams, equal = ds.BitsAllocated == 16, [], True
        for index, frame in enumerate(native_frames(ds)):
            samples = frame if not wide else b"".join(frame[i:i + 2][::-1] for i in range(0, len(frame), 2))
            pgm, j2c, back = (self.work / f"{name}-{index}.{ext}" for ext in ("pgm", "j2c", "back.pgm"))
            pgm.write_bytes(f"P5\n{ds.Columns} {ds.Rows}\n{65535 if wide else 255}\n".encode() + samples)
            run("ojph_compress", "-i", pgm, "-o", j2c, "-reversible", "true")
            run("ojph_expand", "-i", j2c, "-o", back)
            equal &= back.read_bytes() == pgm.read_bytes()
            codestreams.append(j2c.read_bytes())
        encapsulated(ds, codestreams, HTJ2K_LOSSLESS)
        self.save(ds, f"openjph-htj2k-{name}.dcm", equal)

    def dcmjs_binary(self):
        source = (self.dcmjs / "src/utilities/compression/rleSingleSamplePerPixel.js").read_text()
        body = source[source.index("/**\n * Encodes a non-bitpacked frame"):source.index("function decode(")]
        script = self.work / "dcmjs-rle-encode.mjs"
        script.write_text(body + """
import { readFileSync, writeFileSync } from "node:fs";
const [input, rows, cols, frames, output] = process.argv.slice(2);
const bytes = readFileSync(input);
const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
writeFileSync(output, JSON.stringify(encode(buffer, Number(frames), Number(rows), Number(cols))
    .map(frame => Buffer.from(frame).toString("base64"))));
""")
        ds = self.native("binary")
        frames = native_frames(ds)
        raw, encoded = self.work / "binary.raw", self.work / "dcmjs.json"
        raw.write_bytes(b"".join(frames))
        run("node", script, raw, ds.Rows, ds.Columns, len(frames), encoded)
        fragments = [base64.b64decode(f) for f in json.loads(encoded.read_text())]
        ds.BitsAllocated, ds.BitsStored, ds.HighBit = 8, 8, 7
        ds.SegmentationType, ds.SegmentationFractionalType, ds.MaximumFractionalValue = "FRACTIONAL", "PROBABILITY", 255
        encapsulated(ds, fragments, RLELossless)
        decoded = [bytes(b) for b, _ in get_decoder(RLELossless).iter_buffer(ds)]
        self.save(ds, "dcmjs-rle-binary-as-fractional.dcm", decoded == frames)

    def binary_rle(self, packed):
        ds = self.native("binary")
        encoder, fragments, equal = get_encoder(RLELossless), [], True
        for frame in native_frames(ds):
            if packed:
                payload = bytes(sum(frame[i + b] << b for b in range(8) if i + b < len(frame))
                                for i in range(0, len(frame), 8))
                rows, columns = 1, len(payload)
            else:
                payload, rows, columns = frame, ds.Rows, ds.Columns
            fragment = encoder.encode(payload, rows=rows, columns=columns, samples_per_pixel=1, bits_allocated=8,
                                      bits_stored=8, pixel_representation=0, photometric_interpretation="MONOCHROME2",
                                      number_of_frames=1, planar_configuration=0)
            decoded = unpack_rle_segment(fragment)
            equal &= decoded[:len(payload)] == payload and len(decoded) - len(payload) in (0, 1)
            fragments.append(fragment)
        encapsulated(ds, fragments, RLELossless)
        self.save(ds, f"pydicom-rle-binary-{'packed' if packed else 'bytes'}.dcm", equal)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--dcmjs", type=Path, help="a dcmjs checkout; without it the dcmjs fixture is not rewritten")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        generator = Generator(args.directory, args.dcmjs, Path(temporary))
        for mode in ("jpegls", "j2k", "rle"):
            generator.gdcm("fractional", mode)
        for name in ("labelmap8", "labelmap16"):
            for mode in ("jpegls", "j2k"):
                generator.gdcm(name, mode)
        for name in ("labelmap8", "labelmap16", "fractional"):
            generator.htj2k(name)
        if args.dcmjs:
            generator.dcmjs_binary()
        generator.binary_rle(packed=True)
        generator.binary_rle(packed=False)
    print(json.dumps(generator.report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
