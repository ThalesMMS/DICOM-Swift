#!/usr/bin/env python3
"""Compare the waveform and encapsulated document corpus with the independent IOD validator.

Each case carries the engine's expected outcome, CLI exit code, whether it is a waveform and whether
it references other instances, written by DicomWaveformDocumentCorpusTests. The pinned
dicom-validator/PS3.3 2026c cache gives an independent module verdict; pydicom supplies structural
witnesses. The CLI has no target metadata, so every referencing object is incomplete on its
references there. Disagreements are recorded with their reason, never masked. Requires
requirements-iod.txt.
"""
import argparse
import base64
import re
import struct
import xml.etree.ElementTree as ET
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path
import subprocess

import numpy as np
import pydicom
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS as IOD_VERSIONS, require

VERSIONS = {**IOD_VERSIONS, "numpy": "2.5.3"}

FACTS = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no"]
WAVEFORM_MODALITIES = {"ECG", "HD", "EPS", "AU", "RESP", "EEG", "EMG", "EOG"}
# Negatives settled only by the supplied target metadata, which the CLI does not receive.
TARGET_DEPENDENT = {"wf-ecg-source-class-mismatch", "doc-pdf-source-class-mismatch"}
FALSE_POSITIVES = []
INDEPENDENT_ERRORS = {
    "document-m3d-without-units": [("Manufacturing 3D Model", "(0040,08EA)", "TagMissing")],
    "doc-pdf-burned-in-wrong": [("Encapsulated Document", "(0028,0301)", "EnumValueNotAllowed")],
    "doc-pdf-content-sequence": [("Encapsulated Document", "(0040,A730) / (0040,A040)", "TagMissing"), ("Encapsulated Document", "(0040,A730) / (0040,A050)", "TagMissing")],
    "doc-pdf-missing-burned-in": [("Encapsulated Document", "(0028,0301)", "TagMissing")],
    "doc-pdf-missing-conversion-type": [("SC Equipment", "(0008,0064)", "TagMissing")],
    "doc-pdf-missing-document-title": [("Encapsulated Document", "(0042,0010)", "TagMissing")],
    "doc-pdf-missing-series-number": [("Encapsulated Document Series", "(0020,0011)", "TagMissing")],
    "doc-stl-missing-frame-of-reference": [("Frame of Reference", "(0020,0052)", "TagMissing"), ("Frame of Reference", "(0020,1040)", "TagMissing")],
    "doc-stl-missing-serial-number": [("Enhanced General Equipment", "(0018,1000)", "TagMissing")],
    "doc-stl-missing-units": [("Manufacturing 3D Model", "(0040,08EA)", "TagMissing")],
    "wf-ecg-missing-acquisition-context": [("Acquisition Context", "(0040,0555)", "TagMissing")],
    "wf-ecg-missing-acquisition-datetime": [("Waveform Identification", "(0008,002A)", "TagMissing")],
    "wf-ecg-originality-wrong": [("Waveform", "(5400,0100) / (003A,0004)", "EnumValueNotAllowed")],
    "wf-eeg-missing-serial-number": [("Enhanced General Equipment", "(0018,1000)", "TagMissing")],
    "wf-respiratory-without-sync": [("Synchronization", "(0018,106A)", "TagMissing"), ("Synchronization", "(0018,1800)", "TagMissing"), ("Synchronization", "(0020,0200)", "TagMissing")],
}
GAPS = {
    "document-mime-mismatch": "Independent module validator does not tie MIME to SOP Class; explicit MIME witness below.",
    "document-length-mismatch": "Independent module validator does not compare declared length; payload witness preserves the complete value.",
    "document-cda-without-hl7-identifier": "Independent module validator does not derive the CDA HL7 identifier condition.",
    "document-list-of-mime-missing": "Raw profile passes without embedded-component facts; independent XML witness proves the typed envelope failure.",
    "waveform-annotation-unknown-channel": "Independent module validator does not resolve channel ordinals; numpy witness checks the typed diagnostic.",
    "waveform-annotation-samples-out-of-range": "Typed sample-position diagnostic and independent witness supplement unchanged raw validation.",
    "waveform-annotation-temporal-mismatch": "Typed temporal-cardinality diagnostic and independent witness supplement unchanged raw validation.",
    "doc-cda-without-identifier": "Oracle does not derive the HL7 Instance Identifier condition from the CDA SOP Class.",
    "doc-mtl-modality-wrong": "Oracle accepts any Encapsulated Document Series modality; the IOD-specific value is engine-only.",
    "doc-obj-mime-wrong": "Oracle does not tie the MIME type to the SOP Class.",
    "doc-pdf-content-sequence": "The engine leaves the SR content items of an encapsulated document as a limitation; the oracle evaluates the content item macro.",
    "doc-pdf-hl7-identifier": "Oracle does not forbid the HL7 Instance Identifier outside the CDA SOP Class.",
    "doc-pdf-length-wrong": "Oracle does not compare Encapsulated Document Length with the payload.",
    "doc-pdf-mime-wrong": "Oracle does not tie the MIME type to the SOP Class.",
    "doc-pdf-modality-wrong": "Oracle accepts any Encapsulated Document Series modality; the IOD-specific value is engine-only.",
    "doc-pdf-source-class-mismatch": "Oracle has no target metadata for the referenced source instance.",
    "doc-stl-source-without-reference-module": "Oracle does not derive the Common Instance Reference condition from the Source Instance Sequence.",
    "wf-audio-frequency-wrong": "Oracle does not apply the A.34 sampling frequency constraints.",
    "wf-ecg-annotation-text-and-concept": "Oracle does not apply the text/concept name exclusion of a waveform annotation.",
    "wf-ecg-annotation-unknown-channel": "Oracle does not resolve Referenced Waveform Channels in the multiplex groups.",
    "wf-ecg-bits-allocated-mismatch": "Oracle does not compare Waveform Bits Allocated with the sample interpretation.",
    "wf-ecg-bits-stored-exceeds-allocated": "Oracle does not compare Waveform Bits Stored with Waveform Bits Allocated.",
    "wf-ecg-channel-count-mismatch": "Oracle does not compare Number of Waveform Channels with the Channel Definition Sequence.",
    "wf-ecg-data-length-wrong": "Oracle does not compare the Waveform Data length with samples, channels and word size.",
    "wf-ecg-frequency-out-of-range": "Oracle does not apply the A.34 sampling frequency constraints.",
    "wf-ecg-interpretation-not-allowed": "Oracle does not apply the A.34 sample interpretation constraints.",
    "wf-ecg-modality-wrong": "Oracle accepts any General Series modality; the IOD-specific value is engine-only.",
    "wf-ecg-samples-exceeded": "Oracle does not apply the A.34 sample count constraints.",
    "wf-ecg-source-class-mismatch": "Oracle has no target metadata for the referenced source waveform.",
    "wf-ecg-too-many-groups": "Oracle does not apply the A.34 multiplex group count constraints.",
    "wf-eeg-two-groups": "Oracle does not apply the A.34 multiplex group count constraints.",
    "wf-eog-three-channels": "Oracle does not apply the A.34 channel count constraints.",
    "wf-hemodynamic-original-without-sync": "Oracle does not derive the Synchronization module condition from Waveform Originality.",
}


def witness(name, ds):
    if ds.SOPClassUID.startswith("1.2.840.10008.5.1.4.1.1.9."):
        require("WaveformSequence" in ds and len(ds.WaveformSequence) >= 1, "Changed waveform witness")
        if name != "wf-ecg-modality-wrong":
            require(ds.Modality in WAVEFORM_MODALITIES, "Changed modality witness")
    else:
        require("EncapsulatedDocument" in ds and "MIMETypeOfEncapsulatedDocument" in ds, "Changed document witness")
    if name == "wf-ecg-too-many-groups":
        require(len(ds.WaveformSequence) == 6, "Changed group count witness")
    if name == "wf-ecg-channel-count-mismatch":
        group = ds.WaveformSequence[0]
        require(int(group.NumberOfWaveformChannels) != len(group.ChannelDefinitionSequence), "Changed channel count witness")
    if name == "wf-ecg-data-length-wrong":
        group = ds.WaveformSequence[0]
        require(len(group.WaveformData) != int(group.NumberOfWaveformSamples) * int(group.NumberOfWaveformChannels) * 2, "Changed data length witness")
    if name == "doc-pdf-length-wrong":
        require(int(ds.EncapsulatedDocumentLength) != len(ds.EncapsulatedDocument), "Changed document length witness")
    if name == "doc-cda-without-identifier":
        require("HL7InstanceIdentifier" not in ds, "Changed identifier witness")


def g711_reference(code, law):
    """G.711 reconstruction tables in PCM16; DICOM A-law has no XOR 0x55."""
    if law == "MB":
        # Table 2 reconstruction: each segment doubles the quantizer step.
        level = 255 - code if code >= 128 else 127 - code
        segment, step = divmod(level, 16)
        magnitude = ((2 * step + 33) * (2 ** segment) - 33) * 4
        return magnitude if code >= 128 else -magnitude
    segment, step = divmod(code % 128, 16)
    magnitude = (2 * step + 1) * 8 if segment == 0 else (2 * step + 33) * (2 ** (segment - 1)) * 8
    return magnitude if code >= 128 else -magnitude


def decoded_witness(name, ds, expected):
    if "WaveformSequence" not in ds:
        return
    # Known malformed/profile-incompatible instances rejected by the full typed parser.
    rejected = {"wf-ecg-data-length-wrong", "wf-audio-frequency-wrong", "wf-ecg-channel-count-mismatch"}
    if expected.get("decoded") is None:
        require(name in rejected, f"Missing decoded sample witness: {name}")
        group = ds.WaveformSequence[0]
        if name == "wf-audio-frequency-wrong":
            require(float(group.SamplingFrequency) != 8000, "Changed audio rejection witness")
        else:
            expected_bytes = int(group.NumberOfWaveformSamples) * int(group.NumberOfWaveformChannels) * int(group.WaveformBitsAllocated) // 8
            require(len(group.WaveformData) != expected_bytes, "Changed malformed interleaving witness")
        return
    facts = expected["decoded"]
    require(len(facts) == len(ds.WaveformSequence), f"Decoded group count: {name}")
    for group, fact in zip(ds.WaveformSequence, facts):
        interpretation = str(group.WaveformSampleInterpretation)
        if interpretation in ("MB", "AB"):
            require([g711_reference(code, interpretation) for code in range(256)] == fact["linearPCM16Table"], f"G.711 table mismatch: {name}")
        dtype = {"SB": "i1", "UB": "u1", "SS": "<i2", "US": "<u2", "SL": "<i4", "UL": "<u4", "MB": "u1", "AB": "u1"}[interpretation]
        count, channels = int(group.NumberOfWaveformSamples), int(group.NumberOfWaveformChannels)
        raw = np.frombuffer(group.WaveformData, dtype=dtype, count=count * channels).reshape(count, channels)
        require(len(fact["channels"]) == channels, f"Decoded channel count: {name}")
        for ordinal, channel_fact in enumerate(fact["channels"]):
            definition = group.ChannelDefinitionSequence[ordinal] if ordinal < len(group.ChannelDefinitionSequence) else None
            encoded = raw[:, ordinal]
            padding = None
            if "WaveformPaddingValue" in group:
                padding = np.frombuffer(group.WaveformPaddingValue, dtype=dtype, count=1)[0]
            linear = np.array([g711_reference(int(v), interpretation) for v in encoded], dtype=float) if interpretation in ("MB", "AB") else encoded.astype(float)
            calibrated = definition is not None and "ChannelSensitivity" in definition
            if calibrated:
                physical = linear * float(definition.ChannelSensitivity) * float(definition.get("ChannelSensitivityCorrectionFactor", 1)) + float(definition.get("ChannelBaseline", 0))
                mask = np.ones(count, dtype=bool) if padding is None else encoded != padding
            else:
                physical = np.zeros(count)
                mask = np.zeros(count, dtype=bool)
            valid = physical[mask]
            require(len(valid) == channel_fact["count"], f"Physical count: {name}/{ordinal}")
            require(np.isclose(np.dot(valid, np.arange(1, len(valid) + 1)), channel_fact["checksum"], rtol=1e-12, atol=1e-9), f"Physical checksum: {name}/{ordinal}")
            require(np.allclose(valid[:8], channel_fact["first"], rtol=1e-12, atol=1e-9) and np.allclose(valid[-8:], channel_fact["last"], rtol=1e-12, atol=1e-9), f"Physical endpoints: {name}/{ordinal}")
            if channel_fact["windowRaw"] is None:
                require(name in {"wf-ecg-channel-count-mismatch", "wf-ecg-bits-allocated-mismatch"}, f"Missing bounded window: {name}")
            else:
                start, end = fact["windowStart"], fact["windowEnd"]
                require(encoded[start:end].tolist() == channel_fact["windowRaw"], f"Raw segment mismatch: {name}/{ordinal}")
                window = [float(physical[i]) if mask[i] else None for i in range(start, end)]
                require(window == channel_fact["windowPhysical"], f"Physical segment mismatch: {name}/{ordinal}")
    if "typedDiagnostics" in expected:
        diagnostics = []
        for annotation in ds.get("WaveformAnnotationSequence", []):
            references = list(annotation.ReferencedWaveformChannels)
            for group_number, channel_number in zip(references[::2], references[1::2]):
                require(1 <= group_number <= len(ds.WaveformSequence), "Unexpected unknown group in corpus")
                group = ds.WaveformSequence[group_number - 1]
                if channel_number > int(group.NumberOfWaveformChannels):
                    diagnostics.append("unknownChannel")
                positions = np.atleast_1d(annotation.get("ReferencedSamplePositions", []))
                if any(int(v) < 1 or int(v) > int(group.NumberOfWaveformSamples) for v in positions):
                    diagnostics.append("samplePositionOutOfRange")
            kind = annotation.get("TemporalRangeType")
            if kind:
                values = [np.atleast_1d(annotation.get(tag, [])) for tag in ("ReferencedSamplePositions", "ReferencedTimeOffsets", "ReferencedDateTime")]
                sizes = [len(v) for v in values if len(v)]
                n = sizes[0] if sizes else 0
                valid = n == 1 if kind in ("POINT", "BEGIN", "END") else n == 2 if kind == "SEGMENT" else n >= 2 if kind == "MULTIPOINT" else n >= 4 and n % 2 == 0
                if len(sizes) != 1 or not valid:
                    diagnostics.append("temporalMismatch")
        require(sorted(set(diagnostics)) == sorted(expected["typedDiagnostics"]), f"Typed annotation mismatch: {name}")


def document_witness(name, ds, expected):
    if expected["waveform"]:
        return
    fact = expected["document"]
    raw = bytes(ds.EncapsulatedDocument)
    declared = ds.get("EncapsulatedDocumentLength")
    # Only a single null pad following an odd declared length can be removed.
    payload = raw[:-1] if declared is not None and int(declared) % 2 == 1 and len(raw) == int(declared) + 1 and raw[-1:] == b"\0" else raw
    engine = base64.b64decode(fact["payloadBase64"], validate=True)
    require(payload == engine, f"pydicom/engine document byte mismatch: {name}")
    require(hashlib.sha256(payload).hexdigest() == fact["sha256"], f"Reopened document SHA256 mismatch: {name}")
    if expected["outcome"] == "passed":
        mime = str(ds.MIMETypeOfEncapsulatedDocument).lower()
        if mime == "application/pdf":
            require(payload.startswith(b"%PDF-"), f"PDF signature: {name}")
        elif mime == "text/xml":
            root = ET.fromstring(payload)
            require(root.tag.split("}")[-1] == "ClinicalDocument", f"CDA root: {name}")
        elif mime == "model/stl":
            require(len(payload) >= 84 and len(payload) == 84 + 50 * struct.unpack_from("<I", payload, 80)[0], f"Binary STL size: {name}")
        elif mime == "model/obj":
            require(re.search(rb"(?m)^v ", payload) is not None, f"OBJ witness: {name}")
        elif mime == "model/mtl":
            require(re.search(rb"(?m)^newmtl ", payload) is not None, f"MTL witness: {name}")
    if name == "document-mime-mismatch":
        require(ds.MIMETypeOfEncapsulatedDocument != "application/pdf" and not fact["envelopeValid"], "MIME mismatch witness")
    if name == "document-length-mismatch":
        require(int(declared) != len(raw) and payload == raw and "lengthMismatch" in fact["diagnostics"], "Length mismatch witness")
    if name == "document-cda-without-hl7-identifier":
        require("HL7InstanceIdentifier" not in ds and "missingHL7Identifier" in fact["diagnostics"], "CDA identifier witness")
    if name == "document-m3d-without-units":
        require("MeasurementUnitsCodeSequence" not in ds and "missingModelUnits" in fact["diagnostics"], "Model units witness")
    if name == "document-list-of-mime-missing":
        root = ET.fromstring(payload)
        embedded = {node.attrib["mediaType"] for node in root.iter() if "mediaType" in node.attrib}
        require("application/pdf" in embedded and "ListOfMIMETypes" not in ds and fact["diagnostics"] == ["missingMIMEList"], "Embedded MIME condition witness")
    if name == "document-obj-with-mtl-reference":
        reference = ds.ReferencedInstanceSequence[0]
        require(str(reference.ReferencedSOPClassUID).endswith(".104.5") and
                reference.RelativeURIReferenceWithinEncapsulatedDocument.encode() in payload, "OBJ/MTL URI witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Changed oracle versions")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names)), log_level=logging.CRITICAL)
    records = []
    files = sorted(args.corpus.glob("*.dcm"))
    require(files, f"No DICOM files found in corpus: {args.corpus}")
    for path in files:
        name = path.stem
        expected = json.loads(path.with_suffix(".json").read_text())
        ds = pydicom.dcmread(path)
        require(ds.SOPClassUID == expected["sopClass"] and ("WaveformSequence" in ds) == expected["waveform"], "Changed SOP Class witness")
        witness(name, ds)
        decoded_witness(name, ds, expected)
        document_witness(name, ds, expected)
        result = validator.validate(path)[str(path)]
        all_errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        false_positives = [e for e in all_errors if e in FALSE_POSITIVES]
        errors = [e for e in all_errors if e not in false_positives]
        require(errors == sorted(INDEPENDENT_ERRORS.get(name, [])), f"Changed independent errors for {name}: {errors}")
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        limitations = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "limitation" and d["layer"] != "operation"})
        if (expected["outcome"] == "passed" and expected["references"]) or name in TARGET_DEPENDENT:
            # The CLI has no target metadata, so supplied-target checks are the only incomplete source.
            require(command.returncode == 2 and layers["references"] == "incomplete" and limitations == ["referenceTargetUnavailable"]
                    and all(outcome == "passed" for layer, outcome in layers.items() if layer != "references"),
                    f"Changed CLI outcome for {name}: {layers} {limitations}")
        else:
            require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode}")
            if expected["outcome"] == "passed":
                require(all(outcome == "passed" for outcome in layers.values()) and not limitations, f"Changed CLI outcome for {name}: {layers} {limitations}")
        agreement = (expected["outcome"] == "failed") == bool(errors)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "falsePositives": len(false_positives),
            "cliLayers": layers, "cliLimitations": limitations, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} waveform and encapsulated document cases, {agreements} independent agreements after the documented "
          f"false positives, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
