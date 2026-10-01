#!/usr/bin/env python3
"""Generate tiny non-PHI pydicom fixtures or independently check Swift rewrites.

Test tooling only. Install pydicom==3.0.1 and NumPy in an isolated environment;
this script never downloads fixtures and has no application runtime role.
"""

import argparse
import hashlib
import json
import shutil
import tempfile
from pathlib import Path

import numpy as np
import pydicom
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian


PROFILES = [
    ("gray8", 8, 8, False, "MONOCHROME2", 1, None),
    ("gray12-signed", 16, 12, True, "MONOCHROME2", 1, None),
    ("gray16", 16, 16, False, "MONOCHROME2", 1, None),
    ("gray8-inverted", 8, 8, False, "MONOCHROME1", 1, None),
    ("rgb-interleaved", 8, 8, False, "RGB", 3, 0),
    ("rgb-planar", 8, 8, False, "RGB", 3, 1),
]


def metadata(dataset):
    return {
        str(tag): dataset[tag].to_json_dict(None, 1024)
        for tag in sorted(dataset.keys()) if tag.group != 0x0002 and tag != 0x7FE00010
    }


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    fixtures = []
    for index, (name, allocated, stored, signed, photo, components, planar) in enumerate(PROFILES):
        rows, columns, frames = 3, 5, 3
        count = rows * columns * frames * components
        values = (np.arange(count, dtype=np.int64) * 37 + 11) % (1 << stored)
        if signed:
            values -= 1 << (stored - 1)
        shape = (frames, rows, columns, components) if components > 1 else (frames, rows, columns)
        values = values.reshape(shape)
        dtype = ("<i" if signed else "<u") + str(allocated // 8)
        storage = values.transpose(0, 3, 1, 2) if planar == 1 else values
        meta = FileMetaDataset()
        meta.TransferSyntaxUID = ExplicitVRLittleEndian
        meta.MediaStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
        meta.MediaStorageSOPInstanceUID = f"2.25.236600{index + 1}"
        meta.ImplementationClassUID = "2.25.2366999"
        meta.ImplementationVersionName = "ISIS_QA_2366"
        dataset = FileDataset(None, {}, file_meta=meta, preamble=bytes(128))
        dataset.SOPClassUID = meta.MediaStorageSOPClassUID
        dataset.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
        dataset.StudyInstanceUID = "2.25.2366000"
        dataset.SeriesInstanceUID = f"2.25.236610{index + 1}"
        dataset.Modality = "OT"
        dataset.SpecificCharacterSet = "ISO_IR 192"
        dataset.PatientID = "SYNTHETIC2366"
        dataset.PatientName = "SYNTHETIC^CORPUS"
        dataset.StudyDescription = "Sintético Δ — nenhum paciente real"
        dataset.Rows, dataset.Columns = rows, columns
        dataset.NumberOfFrames = frames
        dataset.SamplesPerPixel = components
        dataset.PhotometricInterpretation = photo
        dataset.BitsAllocated, dataset.BitsStored = allocated, stored
        dataset.HighBit, dataset.PixelRepresentation = stored - 1, int(signed)
        if planar is not None:
            dataset.PlanarConfiguration = planar
        dataset.PixelSpacing = ["0.7", "1.3"]
        dataset.ImagePositionPatient = ["-3.5", "4.25", "6.75"]
        dataset.ImageOrientationPatient = ["1", "0", "0", "0", "1", "0"]
        dataset.RescaleSlope, dataset.RescaleIntercept = "2", "-1024"
        dataset.PixelData = storage.astype(dtype).tobytes()
        path = output / f"{name}.dcm"
        dataset.save_as(path, enforce_file_format=True)
        decoded = pydicom.dcmread(path)
        np.testing.assert_array_equal(decoded.pixel_array, values)
        display = values + 32768 if signed else values.copy()
        if photo == "MONOCHROME1":
            display = (1 << allocated) - 1 - display
        fixtures.append({
            "id": name, "path": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "provenance": "Generated independently with pydicom; arithmetic synthetic sample pattern.",
            "license": "Repository license", "deidentification": "Synthetic non-PHI; no patient source.",
            "rows": rows, "columns": columns, "frames": frames, "components": components,
            "bitsAllocated": allocated, "bitsStored": stored, "signed": signed,
            "photometricInterpretation": photo, "planarConfiguration": planar,
            "transferSyntaxUID": str(ExplicitVRLittleEndian),
            "geometry": {"pixelSpacing": [0.7, 1.3], "position": [-3.5, 4.25, 6.75],
                         "orientation": [1, 0, 0, 0, 1, 0]},
            "metadata": metadata(decoded),
            "storedSamples": values.reshape(frames, -1).tolist(),
            "displaySamples": display.reshape(frames, -1).tolist(),
        })
    manifest = {"version": 1, "issue": 2366, "oracle": {"name": "pydicom", "version": pydicom.__version__,
                "numpyVersion": np.__version__}, "fixtures": fixtures}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"Generated and independently decoded {len(fixtures)} synthetic fixtures.")


def first_difference(expected, actual, path):
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(set(expected) | set(actual)):
            if key not in expected or key not in actual:
                return {"path": f"{path}.{key}", "expected": expected.get(key), "actual": actual.get(key)}
            difference = first_difference(expected[key], actual[key], f"{path}.{key}")
            if difference:
                return difference
        return None
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            return {"path": f"{path}.count", "expected": len(expected), "actual": len(actual)}
        for index, (reference, candidate) in enumerate(zip(expected, actual)):
            difference = first_difference(reference, candidate, f"{path}[{index}]")
            if difference:
                return difference
        return None
    return None if expected == actual else {"path": path, "expected": expected, "actual": actual}


def verify(manifest_path, rewritten, report_path=None):
    manifest = json.loads(manifest_path.read_text())
    samples_compared = 0
    frames_compared = 0
    first = None
    maximum_error = 0
    for fixture in manifest["fixtures"]:
        source = manifest_path.parent / fixture["path"]
        if hashlib.sha256(source.read_bytes()).hexdigest() != fixture["sha256"]:
            raise ValueError(f"source checksum mismatch: {fixture['id']}")
        dataset = pydicom.dcmread(rewritten / fixture["path"])
        actual_frames = int(getattr(dataset, "NumberOfFrames", 1))
        actual = dataset.pixel_array.reshape(actual_frames, -1).astype(np.int64)
        expected = np.asarray(fixture["storedSamples"], dtype=np.int64)
        difference = first_difference(fixture["metadata"], metadata(dataset), f"{fixture['id']}.metadata")
        if actual.shape != expected.shape:
            difference = difference or {"path": f"{fixture['id']}.sampleShape",
                                        "expected": list(expected.shape), "actual": list(actual.shape)}
        else:
            errors = np.abs(actual - expected)
            maximum_error = max(maximum_error, int(errors.max()))
            locations = np.argwhere(errors != 0)
            if locations.size:
                frame, sample = map(int, locations[0])
                pixel, component = divmod(sample, fixture["components"])
                row, column = divmod(pixel, fixture["columns"])
                difference = difference or {
                    "path": f"{fixture['id']}.frame[{frame}].row[{row}].column[{column}].component[{component}]",
                    "expected": int(expected[frame, sample]), "actual": int(actual[frame, sample]),
                }
            samples_compared += actual.size
            frames_compared += actual_frames
        first = first or difference
        print(f"Independent Swift rewrite comparison {'mismatched' if difference else 'passed'}: {fixture['id']}.")
    if report_path:
        report_path.write_text(json.dumps({
            "caseID": "independent-native-rewrite", "result": "mismatched" if first else "passed",
            "encoderVersion": "workspace DicomDataSetWriter", "decoderVersion": f"pydicom {pydicom.__version__}",
            "metadataValidation": "all non-file-meta attributes compared with the independent source",
            "metrics": {"samplesCompared": samples_compared, "framesCompared": frames_compared,
                        "maximumAbsoluteError": maximum_error}, "firstDifference": first,
            "failureLocation": first["path"] if first else None,
        }, sort_keys=True) + "\n")
    if first:
        raise ValueError(f"Independent disagreement: {first['path']}")


def verify_mutation_detection(manifest_path, rewritten):
    for mutation in ("pixel", "frame-order", "geometry"):
        with tempfile.TemporaryDirectory(prefix="dicom-differential-mutation-") as directory:
            root = Path(directory)
            candidate = root / "rewrites"
            shutil.copytree(rewritten, candidate)
            path = candidate / "rgb-interleaved.dcm"
            dataset = pydicom.dcmread(path)
            if mutation == "geometry":
                dataset.PixelSpacing = ["0.7", "9.9"]
            else:
                pixels = dataset.pixel_array.copy()
                if mutation == "pixel":
                    pixels[2, 2, 4, 1] ^= 1
                else:
                    pixels = pixels[[0, 2, 1]]
                dataset.PixelData = pixels.tobytes()
            dataset.save_as(path, enforce_file_format=True)
            evidence = root / "mismatch.jsonl"
            try:
                verify(manifest_path, candidate, evidence)
            except ValueError as error:
                if not str(error).startswith("Independent disagreement:"):
                    raise
            else:
                raise AssertionError(f"Undetected {mutation} mutation")
            record = json.loads(evidence.read_text())
            if record["result"] != "mismatched" or not record["firstDifference"]:
                raise AssertionError(f"Missing first-difference evidence for {mutation}")
            print(f"Deliberate {mutation} mutation detected: {record['firstDifference']['path']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--generate", type=Path)
    mode.add_argument("--verify-swift-output", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--self-test-mutations", action="store_true")
    args = parser.parse_args()
    if args.generate:
        generate(args.generate)
    else:
        if not args.manifest:
            parser.error("--verify-swift-output requires --manifest")
        verify(args.manifest, args.verify_swift_output, args.report)
        if args.self_test_mutations:
            result = "failed"
            try:
                verify_mutation_detection(args.manifest, args.verify_swift_output)
                result = "passed"
            finally:
                if args.report:
                    with args.report.open("a") as stream:
                        stream.write(json.dumps({"caseID": "independent-mutation-detection", "result": result,
                                                 "decoderVersion": f"pydicom {pydicom.__version__}",
                                                 "metrics": {"mutationsDetected": 3 if result == "passed" else None}}) + "\n")


if __name__ == "__main__":
    main()
