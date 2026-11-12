"""Independent DICOMweb 0.61.2 probe; invoked only by DicomWebIndependentClientTests."""
import io
import json
import sys
from importlib.metadata import version
from pathlib import Path
import pydicom
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian, SecondaryCaptureImageStorage
from dicomweb_client.api import DICOMwebClient

assert version("dicomweb-client") == "0.61.2"
base, output = sys.argv[1:]
meta = FileMetaDataset()
meta.TransferSyntaxUID = ExplicitVRLittleEndian
meta.MediaStorageSOPClassUID = SecondaryCaptureImageStorage
meta.MediaStorageSOPInstanceUID = "2.25.2351003"
meta.ImplementationClassUID = "2.25.2351999"
ds = FileDataset(None, {}, file_meta=meta, preamble=b"\0" * 128)
ds.SOPClassUID = meta.MediaStorageSOPClassUID
ds.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
ds.StudyInstanceUID = "2.25.2351001"
ds.SeriesInstanceUID = "2.25.2351002"
ds.PatientName = "INTEROP^A2"
ds.PatientID = "SYNTHETIC-A2"
ds.StudyDate = "20260911"
ds.Modality = "OT"
ds.StudyID = "1"
ds.SeriesNumber = 1
ds.InstanceNumber = 1
ds.Rows = 2
ds.Columns = 2
ds.SamplesPerPixel = 1
ds.PhotometricInterpretation = "MONOCHROME2"
ds.BitsAllocated = 8
ds.BitsStored = 8
ds.HighBit = 7
ds.PixelRepresentation = 0
ds.PixelData = bytes([0, 64, 128, 255])
ds.is_little_endian = True
ds.is_implicit_VR = False
serialized = io.BytesIO()
pydicom.dcmwrite(serialized, ds)
Path(output).write_bytes(serialized.getvalue())
client = DICOMwebClient(url=base)
client.set_http_retry_params(retry=False)
result = client.store_instances([ds])
assert result.ReferencedSOPSequence[0].ReferencedSOPInstanceUID == ds.SOPInstanceUID
s, r, i = str(ds.StudyInstanceUID), str(ds.SeriesInstanceUID), str(ds.SOPInstanceUID)
assert len(client.search_for_studies(search_filters={"PatientName": "INTEROP*"})) == 1
assert len(client.search_for_series()) == 1
assert len(client.search_for_series(s)) == 1
assert len(client.search_for_instances()) == 1
assert len(client.search_for_instances(s)) == 1
assert len(client.search_for_instances(s, r)) == 1
for datasets in (client.retrieve_study(s), client.retrieve_series(s, r), [client.retrieve_instance(s, r, i)]):
    assert len(datasets) == 1
    served = datasets[0]
    assert served.PixelData == ds.PixelData
    assert served.PatientName == ds.PatientName
    assert served.SOPInstanceUID == ds.SOPInstanceUID
metadata = client.retrieve_instance_metadata(s, r, i)
assert client.retrieve_study_metadata(s)[0] == metadata
assert client.retrieve_series_metadata(s, r)[0] == metadata
assert metadata["00100010"]["Value"][0]["Alphabetic"] == "INTEROP^A2"
assert client.retrieve_instance_frames(s, r, i, [1])[0] == ds.PixelData
uri = metadata["7FE00010"]["BulkDataURI"]
assert client.retrieve_bulkdata(uri)[0] == ds.PixelData
print(json.dumps({"client": version("dicomweb-client"), "store": 1, "search_routes": 6,
                  "retrieve_levels": 3, "metadata_levels": 3, "frames": 1, "bulkdata": 1}))
