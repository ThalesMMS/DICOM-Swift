#!/usr/bin/env python3
"""Validate the evaluated own-toolkit target graph and minimum-product imports."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

MINIMUM = {
    "DicomData": set(),
    "DicomCodecs": set(),
    "DicomObjects": {"DicomData"},
    "DicomNetwork": {"DicomData"},
}
SYSTEM_IMPORTS = {
    "DicomData": {"Foundation", "OSLog", "zlib", "Dispatch", "Synchronization", "Darwin", "Glibc"},
    "DicomCodecs": {"Foundation"},
    "DicomObjects": {"Foundation"},
    "DicomNetwork": {"Foundation"},
}
LEGACY_PRODUCTS = {"DicomCore", "DicomAppleMedia", "DicomSwiftUI", "dicomtool", "DicomSwiftUIExample"}
IMPORT = re.compile(r"^\s*(?:(?:@[\w]+(?:\([^)]*\))?|public|package|internal|private|fileprivate)\s+)*"
                    r"import\s+(?:(?:class|enum|func|protocol|struct|typealias|var)\s+)?([\w]+)", re.MULTILINE)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def dependencies(target):
    internal, external = set(), set()
    for dependency in target.get("dependencies", []):
        if "byName" in dependency:
            internal.add(dependency["byName"][0])
        elif "target" in dependency:
            internal.add(dependency["target"][0])
        elif "product" in dependency:
            external.add(dependency["product"][0])
        else:
            raise ValueError(f"Unknown dependency shape: {target['name']}")
    return internal, external


def validate_graph(package):
    targets = {target["name"]: target for target in package["targets"]}
    require(MINIMUM.keys() <= targets.keys(), "Missing minimum implementation target")
    products = {product["name"]: product["targets"] for product in package["products"]}
    require(LEGACY_PRODUCTS <= products.keys(), "Removed compatibility product")
    for name, allowed in MINIMUM.items():
        require(products.get(name) == [name], f"Minimum product must select only its target: {name}")
        internal, external = dependencies(targets[name])
        require(internal == allowed and not external, f"Forbidden minimum-target dependency: {name}")
        for setting in targets[name].get("settings", []):
            if setting["tool"] == "linker":
                require(name == "DicomData" and setting["kind"] == {"linkedLibrary": {"_0": "z"}},
                        f"Forbidden minimum-target linkage: {name}")
    require(MINIMUM.keys() <= dependencies(targets["DicomCore"])[0], "Core lost a compatibility implementation")
    visiting, visited = set(), set()

    def visit(name):
        require(name not in visiting, f"Target dependency cycle: {name}")
        if name in visited:
            return
        visiting.add(name)
        for dependency in dependencies(targets[name])[0]:
            if dependency in targets:
                visit(dependency)
        visiting.remove(name)
        visited.add(name)

    for name in targets:
        visit(name)
    return targets


def validate_sources(package_root, targets):
    for name, allowed in MINIMUM.items():
        relative = targets[name].get("path") or "Sources/" + name
        directory = (package_root / relative).resolve()
        require(directory.is_relative_to(package_root.resolve()), f"Source path escapes package: {name}")
        files = list(directory.rglob("*.swift"))
        require(files, f"Empty implementation target: {name}")
        for path in files:
            imports = set(IMPORT.findall(path.read_text()))
            unexpected = imports - allowed - SYSTEM_IMPORTS[name]
            require(not unexpected, f"Forbidden import in {name}/{path.name}: {sorted(unexpected)}")


def validate_mtk_graph(package):
    targets = {target["name"]: target for target in package["targets"]}
    allowed = {"MTKCore": set(), "MTKUI": {"MTKCore"}, "MTKFixtures": {"MTKCore"}}
    products = {product["name"]: product["targets"] for product in package["products"]}
    for name, expected in allowed.items():
        require(name in targets and products.get(name) == [name], f"Missing MTK compatibility product: {name}")
        internal, external = dependencies(targets[name])
        require(internal == expected and not external, f"Forbidden MTK target dependency: {name}")


def validate_mtk(root):
    forbidden = {"DicomCore", "DicomData", "DicomCodecs", "DicomObjects", "DicomNetwork", "DicomAppleMedia",
                 "DICOMCore", "DICOMKit", "DICOMNetwork", "DICOMWeb", "MayamCore", "MayamWeb", "HL7Core",
                 "HL7v2Kit", "HL7v3Kit", "FHIRkit", "J2KCore", "J2KCodec", "J2K3D", "J2KMetal", "JPIP",
                 "JPEGLS", "JXLSwift", "JLISwift", "CompressionFamily", "Network", "GDCMBridge", "DicomContracts"}
    files = list((root / "Sources").rglob("*.swift"))
    require(files, "Missing MTK implementation sources")
    for path in files:
        unexpected = set(IMPORT.findall(path.read_text())) & forbidden
        require(not unexpected, f"DICOM/PACS/codec dependency in MTK: {path}: {sorted(unexpected)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--mtk-root", type=Path)
    args = parser.parse_args()
    package = json.loads(subprocess.check_output(
        ["/usr/bin/xcrun", "swift", "package", "dump-package", "--package-path", str(args.package_root)], text=True))
    targets = validate_graph(package)
    validate_sources(args.package_root, targets)
    if args.mtk_root:
        mtk_package = json.loads(subprocess.check_output(
            ["/usr/bin/xcrun", "swift", "package", "dump-package", "--package-path", str(args.mtk_root)], text=True))
        validate_mtk_graph(mtk_package)
        validate_mtk(args.mtk_root)
    print("Own toolkit target boundaries passed; build availability does not qualify codec profiles.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Toolkit architecture violation: {error}", file=sys.stderr)
        sys.exit(1)
