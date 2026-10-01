#!/usr/bin/env python3
"""Independent check of the BINARY copy of a Label Map Segmentation (Isis issue #2514).

Given a label map (1.2.840.10008.5.1.4.1.1.66.7, native or RLE Lossless) and the BINARY copy the app sends to a
destination without Label Map Segmentation Storage, pydicom 3.0.2 must read the copy as Segmentation Storage
(1.2.840.10008.5.1.4.1.1.66.4, BINARY, 1 bit, native) with the source's patient and study; its segments must be the
label map's declared, non-background labels that some frame holds, in label order, numbered from 1, with the same
labels and property codes; and it must hold one frame per segment and label map frame that holds the label, each
equal, bit for bit, to that label map frame tested against the label. Bits are unpacked in pure Python through a
byte table, so no NumPy is needed. Only counts are recorded.
"""
import argparse
import importlib.metadata
import json
from pathlib import Path

import pydicom
from pydicom.pixels import get_decoder
from pydicom.uid import RLELossless

LABEL_MAP = "1.2.840.10008.5.1.4.1.1.66.7"
SEGMENTATION = "1.2.840.10008.5.1.4.1.1.66.4"
NATIVE = {"1.2.840.10008.1.2", "1.2.840.10008.1.2.1"}
UNPACKED = [bytes((byte >> bit) & 1 for bit in range(8)) for byte in range(256)]


def label_frames(ds):
    """Every label map frame as a list of label values."""
    width = ds.BitsAllocated // 8
    if str(ds.file_meta.TransferSyntaxUID) == RLELossless:
        buffers = [bytes(buffer) for buffer, _ in get_decoder(RLELossless).iter_buffer(ds)]
    else:
        size = ds.Rows * ds.Columns * width
        buffers = [ds.PixelData[i * size:(i + 1) * size] for i in range(int(ds.NumberOfFrames))]
    if width == 1:
        return buffers
    return [[int.from_bytes(b[i:i + 2], "little") for i in range(0, len(b), 2)] for b in buffers]


def positions(ds):
    shared = ds.get("SharedFunctionalGroupsSequence", [None])[0]
    result = []
    for item in ds.PerFrameFunctionalGroupsSequence:
        plane = item.get("PlanePositionSequence") or (shared.get("PlanePositionSequence") if shared else None)
        result.append(tuple(round(float(v), 4) for v in plane[0].ImagePositionPatient))
    return result


def code(item, keyword):
    sequence = item.get(keyword)
    return (sequence[0].CodeValue, sequence[0].CodingSchemeDesignator) if sequence else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("labelmap", type=Path)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    source = pydicom.dcmread(args.labelmap)
    copy = pydicom.dcmread(args.binary)
    background = int(source.get("PixelPaddingValue", -1)) if "PixelPaddingValue" in source else None
    planes = label_frames(source)
    source_positions = positions(source)
    frame_of_position = {position: index for index, position in enumerate(source_positions)}
    declared = {int(s.SegmentNumber): s for s in source.SegmentSequence if int(s.SegmentNumber) != background}
    present = sorted(label for label in declared if any(label in plane for plane in planes))

    record = {
        "pydicom": importlib.metadata.version("pydicom"),
        "sopClass": str(copy.SOPClassUID) == SEGMENTATION and str(source.SOPClassUID) == LABEL_MAP,
        "binaryOneBitNative": copy.SegmentationType == "BINARY" and int(copy.BitsAllocated) == 1
            and str(copy.file_meta.TransferSyntaxUID) in NATIVE,
        "identity": all(str(copy.get(k, "")) == str(source.get(k, "")) for k in
                        ("PatientName", "PatientID", "PatientBirthDate", "PatientSex", "StudyInstanceUID",
                         "AccessionNumber", "StudyID", "FrameOfReferenceUID")),
        "newSeriesAndInstance": copy.SeriesInstanceUID != source.SeriesInstanceUID
            and copy.SOPInstanceUID != source.SOPInstanceUID,
    }
    segments = list(copy.SegmentSequence)
    record["segments"] = len(segments)
    record["segmentsMatchPresentLabels"] = [int(s.SegmentNumber) for s in segments] == list(range(1, len(present) + 1)) \
        and all(s.SegmentLabel == declared[label].SegmentLabel
                and code(s, "SegmentedPropertyTypeCodeSequence") == code(declared[label], "SegmentedPropertyTypeCodeSequence")
                and code(s, "SegmentedPropertyCategoryCodeSequence") == code(declared[label], "SegmentedPropertyCategoryCodeSequence")
                for s, label in zip(segments, present))
    expected_frames = sum(sum(1 for plane in planes if label in plane) for label in present)
    pixels = int(copy.Rows) * int(copy.Columns)
    data = copy.PixelData
    equal = 0
    copy_positions = positions(copy)
    for index, item in enumerate(copy.PerFrameFunctionalGroupsSequence):
        label = present[int(item.SegmentIdentificationSequence[0].ReferencedSegmentNumber) - 1]
        plane = planes[frame_of_position[copy_positions[index]]]
        first = index * pixels
        chunk = data[first // 8:(first + pixels + 7) // 8 + 1]
        bits = b"".join(UNPACKED[b] for b in chunk)[first % 8:first % 8 + pixels]
        expected = bytes(1 if value == label else 0 for value in plane) if not isinstance(plane, bytes) \
            else plane.translate(bytes(1 if value == label else 0 for value in range(256)))
        equal += bits == expected
    record.update(frames=int(copy.NumberOfFrames), expectedFrames=expected_frames, framesEqual=equal)
    record["passed"] = all([record["sopClass"], record["binaryOneBitNative"], record["identity"],
                            record["newSeriesAndInstance"], record["segmentsMatchPresentLabels"],
                            record["frames"] == expected_frames, equal == expected_frames])
    text = json.dumps(record, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(text + "\n")
    print(text)
    raise SystemExit(0 if record["passed"] else 1)


if __name__ == "__main__":
    main()
