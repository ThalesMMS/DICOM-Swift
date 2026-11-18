#!/usr/bin/env python3
"""Independent pydicom/numpy checks of the engine's PHI-free geometry corpus sidecars.

No DICOM-Swift code is imported. Native SEG samples are decoded by pydicom, including
continuous 1-bit packing across odd-sized frames. Mesh metrics use numpy alone.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import pydicom


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def vector_data(item, keyword):
    return np.frombuffer(getattr(item, keyword), dtype="<f4").astype(np.float64).reshape(-1, 3)


def check(path):
    facts = json.loads(path.with_name(path.name + ".json").read_text())
    ds = pydicom.dcmread(path)
    agreements = 0

    def equal(actual, expected, label):
        nonlocal agreements
        require(actual == expected, f"{path.name}: {label} disagreement")
        agreements += 1

    def close(actual, expected, label):
        nonlocal agreements
        actual, expected = np.asarray(actual), np.asarray(expected)
        require(actual.shape == expected.shape, f"{path.name}: {label} shape disagreement")
        require(np.allclose(actual, expected, rtol=1e-6, atol=1e-9), f"{path.name}: {label} disagreement")
        agreements += 1

    if facts["kind"] == "SEG":
        equal(str(ds.SegmentationType), facts["segmentation_type"], "segmentation type")
        pixels = ds.pixel_array.reshape(int(ds.NumberOfFrames), int(ds.Rows), int(ds.Columns))
        equal(len(pixels), len(facts["frames"]), "frame count")
        for index, (pixels, frame) in enumerate(zip(pixels, facts["frames"])):
            values = pixels.astype(np.int64).ravel()
            equal(values.tolist(), frame["values"], f"frame {index} samples")
            labels, counts = np.unique(values, return_counts=True)
            equal({str(int(label)): int(count) for label, count in zip(labels, counts)},
                  frame["histogram"], f"frame {index} label histogram")
            equal(int(np.count_nonzero(values)), frame["nonzero_count"], f"frame {index} voxel count")
            segment_counts = ({str(int(label)): int(count) for label, count in zip(labels, counts)}
                              if ds.SegmentationType == "LABELMAP"
                              else {str(frame["segment"]): int(np.count_nonzero(values))})
            equal(segment_counts, frame["segment_voxel_counts"], f"frame {index} segment voxel counts")
            equal(int(np.sum(values)), frame["fractional_sum"], f"frame {index} stored sum")
            if ds.SegmentationType != "LABELMAP":
                group = ds.PerFrameFunctionalGroupsSequence[index]
                identification = getattr(group, "SegmentIdentificationSequence", None)
                if identification is None:
                    identification = ds.SharedFunctionalGroupsSequence[0].SegmentIdentificationSequence
                equal(int(identification[0].ReferencedSegmentNumber), frame["segment"], f"frame {index} segment")
    elif facts["kind"] == "RTSTRUCT":
        contours = []
        for roi in ds.ROIContourSequence:
            for contour in roi.ContourSequence:
                contours.append((int(roi.ReferencedROINumber), contour))
        equal(len(contours), len(facts["contours"]), "contour count")
        for index, ((roi, contour), expected) in enumerate(zip(contours, facts["contours"])):
            equal(roi, expected["roi"], f"contour {index} ROI")
            equal(str(contour.ContourGeometricType), expected["type"], f"contour {index} type")
            points = np.array(contour.ContourData, dtype=np.float64).reshape(-1, 3)
            equal(len(points), int(contour.NumberOfContourPoints), f"contour {index} declared count")
            close(points, expected["points"], f"contour {index} points")
            equal([str(ref.ReferencedSOPInstanceUID) for ref in getattr(contour, "ContourImageSequence", [])],
                  expected["references"], f"contour {index} references")
    elif facts["kind"] == "SURFACE":
        equal(len(ds.SurfaceSequence), len(facts["surfaces"]), "surface count")
        for index, (surface, expected) in enumerate(zip(ds.SurfaceSequence, facts["surfaces"])):
            points = vector_data(surface.SurfacePointsSequence[0], "PointCoordinatesData")
            normals = vector_data(surface.SurfacePointsNormalsSequence[0], "VectorCoordinateData")
            primitives = surface.SurfaceMeshPrimitivesSequence[0]
            if "LongTrianglePointIndexList" in primitives:
                indices = np.frombuffer(primitives.LongTrianglePointIndexList, dtype="<u4").astype(np.int64)
            else:
                indices = np.frombuffer(primitives.TrianglePointIndexList, dtype="<u2").astype(np.int64)
            close(points, expected["points"], f"surface {index} points")
            close(normals, expected["normals"], f"surface {index} normals")
            equal(indices.tolist(), expected["triangles"], f"surface {index} triangles")
            require(np.all(indices >= 1) and np.all(indices <= len(points)), "Index outside point array")
            triangles = points[indices.reshape(-1, 3) - 1]
            p0, p1, p2 = triangles[:, 0], triangles[:, 1], triangles[:, 2]
            area = np.linalg.norm(np.cross(p1 - p0, p2 - p0), axis=1).sum() / 2
            volume = np.einsum("ij,ij->i", p0, np.cross(p1, p2)).sum() / 6
            close(area, expected["expected_area"], f"surface {index} area")
            close(volume, expected["expected_volume"], f"surface {index} signed volume")
            require(volume > 0, "Cube winding must point outward")
            require(np.all(np.einsum("ij,ij->i", normals, points - points.mean(axis=0)) > 0),
                    "Cube vertex normals must point outward")
    else:
        raise AssertionError(f"Unknown geometry kind: {facts['kind']}")
    return {"name": path.name, "agreements": agreements, "gaps": facts.get("gaps", [])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    paths = sorted(args.corpus.glob("*.dcm"))
    require(bool(paths), "Empty geometry corpus")
    results = [check(path) for path in paths]
    agreements = sum(case["agreements"] for case in results)
    gaps = sum(len(case["gaps"]) for case in results)
    summary = f"PASS: {len(results)} geometry cases, {agreements} agreements, {gaps} documented gaps"
    args.output.write_text(json.dumps({"summary": summary, "pydicom": pydicom.__version__, "numpy": np.__version__,
                                       "cases": results}, indent=2) + "\n")
    print(summary)


if __name__ == "__main__":
    main()
