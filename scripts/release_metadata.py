"""Bounded release metadata inspection; never runs an application or helper."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct


MAXIMUM_CODE_BYTES = 64 * 1024 * 1024
CPU_NAMES = {0x01000007: "x86_64", 0x0100000C: "arm64"}
NOTICE_FILENAMES = ("LICENSE", "THIRD_PARTY_NOTICES.md")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate metadata key")
        result[key] = value
    return result


def read_regular(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= maximum:
            raise ValueError("Expected a bounded regular metadata / code file")
        data = source.read(maximum + 1)
        after = os.fstat(source.fileno())
        if len(data) != before.st_size or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError("Artifact changed during inspection")
    return data


def version_record(root):
    value = json.loads(read_regular(Path(root) / "VERSION.json", 4096), object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != {"schema_version", "version", "build"} or type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError("Unsupported version metadata")
    if not isinstance(value["version"], str) or not re.fullmatch(r"(?:0|[1-9][0-9]{0,4})\.(?:0|[1-9][0-9]{0,4})\.(?:0|[1-9][0-9]{0,4})", value["version"]):
        raise ValueError("Use a three-component numeric release version without leading zeros")
    if type(value["build"]) is not int or not 1 <= value["build"] <= 2147483647:
        raise ValueError("Use a positive bounded integer build number")
    return value


def mach_architectures(data):
    """Inspect bounded 64-bit Mach-O / universal headers, not loader validity."""
    def thin(blob):
        if len(blob) < 32 or blob[:4] != b"\xcf\xfa\xed\xfe":
            raise ValueError("Expected a 64-bit little-endian Mach-O header")
        cpu = struct.unpack_from("<I", blob, 4)[0]
        if cpu not in CPU_NAMES:
            raise ValueError("Unsupported Mach-O CPU type")
        return CPU_NAMES[cpu]

    if data[:4] == b"\xcf\xfa\xed\xfe":
        return [thin(data)]
    formats = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
               b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if len(data) < 8 or data[:4] not in formats:
        raise ValueError("Expected Mach-O or universal code")
    endian, wide = formats[data[:4]]
    count = struct.unpack_from(endian + "I", data, 4)[0]
    stride = 32 if wide else 20
    if not 1 <= count <= 8 or 8 + count * stride > len(data):
        raise ValueError("Invalid universal architecture table")
    names, ranges = [], []
    for index in range(count):
        fields = struct.unpack_from(endian + ("IIQQII" if wide else "IIIII"), data, 8 + index * stride)
        cpu, _, offset, size, alignment = fields[:5]
        if wide and fields[5] != 0:
            raise ValueError("Unknown universal reserved bits")
        if cpu not in CPU_NAMES or alignment > 30 or size < 32 or offset < 8 + count * stride or offset + size > len(data) or offset % (1 << alignment):
            raise ValueError("Invalid universal code range")
        if any(offset < end and offset + size > start for start, end in ranges):
            raise ValueError("Overlapping universal code ranges")
        name = thin(data[offset:offset + size])
        if name != CPU_NAMES[cpu] or name in names:
            raise ValueError("Duplicate or mismatched universal CPU")
        names.append(name); ranges.append((offset, offset + size))
    return sorted(names)


def require_directory(path):
    if not stat.S_ISDIR(Path(path).lstat().st_mode):
        raise ValueError("Artifact directories must not be symlinks")


def inspect_application(application, record, expected_architectures=None, expected_revision=None):
    app = Path(application)
    if app.suffix != ".app":
        raise ValueError("Expected an application bundle")
    extension = app / "Contents/PlugIns/TideIslandActivity.appex"
    for directory in (app, app / "Contents", app / "Contents/MacOS", app / "Contents/Helpers", app / "Contents/Resources", app / "Contents/PlugIns",
                      extension, extension / "Contents", extension / "Contents/MacOS"):
        require_directory(directory)
    app_info = plistlib.loads(read_regular(app / "Contents/Info.plist", 65536))
    extension_info = plistlib.loads(read_regular(extension / "Contents/Info.plist", 65536))
    if not isinstance(app_info, dict) or not isinstance(extension_info, dict):
        raise ValueError("Expected bundle metadata dictionaries")
    identities = [(app_info, "dev.kevinljb.tide-island", "APPL", "TideIsland"),
                  (extension_info, "dev.kevinljb.tide-island.activity", "XPC!", "TideIslandActivity")]
    revisions = set()
    for info, identifier, kind, executable in identities:
        if (info.get("CFBundleIdentifier"), info.get("CFBundlePackageType"), info.get("CFBundleExecutable")) != (identifier, kind, executable):
            raise ValueError("Incorrect release bundle identity")
        if info.get("CFBundleShortVersionString") != record["version"] or info.get("CFBundleVersion") != str(record["build"]):
            raise ValueError("Release bundle version drift")
        revision = info.get("TideIslandSourceRevision")
        if not isinstance(revision, str) or not (revision == "development" or re.fullmatch("[0-9a-f]{40}", revision)):
            raise ValueError("Missing source revision metadata")
        revisions.add(revision)
        if expected_revision is not None and revision != expected_revision:
            raise ValueError("Archive source revision differs from the reviewed commit")
    point = extension_info.get("NSExtension")
    minimum = app_info.get("LSMinimumSystemVersion")
    if not isinstance(minimum, str) or not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", minimum) or tuple(map(int, minimum.split(".")[:2])) < (27, 3) or extension_info.get("LSMinimumSystemVersion") != minimum:
        raise ValueError("Invalid native deployment version metadata")
    if len(revisions) != 1 or app_info.get("NSSupportsLiveActivities") is not True or not isinstance(point, dict) or point.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
        raise ValueError("Inconsistent release capability metadata")
    manifest = json.loads(read_regular(app / "Contents/Resources/bridge-manifest.json", 16384), object_pairs_hook=unique_object)
    if not isinstance(manifest, dict) or set(manifest) != {"version", "kind", "executable", "sha256"} or type(manifest["version"]) is not int or manifest["version"] != 1 or manifest["kind"] != "tide-island-embedded-bridge" or manifest["executable"] != "tide-island-bridge":
        raise ValueError("Invalid embedded bridge delivery metadata")
    files = {}
    for relative in ("Contents/MacOS/TideIsland", "Contents/PlugIns/TideIslandActivity.appex/Contents/MacOS/TideIslandActivity", "Contents/Helpers/tide-island-bridge"):
        path = app / relative
        data = read_regular(path, MAXIMUM_CODE_BYTES)
        if not path.stat().st_mode & 0o111:
            raise ValueError("Release code is not executable")
        architectures = mach_architectures(data)
        if expected_architectures is not None and set(architectures) != set(expected_architectures):
            raise ValueError("Release architecture set differs from requested architectures")
        files[relative] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "architectures": architectures}
    bridge = files["Contents/Helpers/tide-island-bridge"]
    if bridge["sha256"] != manifest["sha256"] or len({tuple(value["architectures"]) for value in files.values()}) != 1:
        raise ValueError("Embedded helper integrity or bundle architectures differ")
    notices = {}
    for name in NOTICE_FILENAMES:
        data = read_regular(app / "Contents/Resources" / name, 65536)
        if not data.decode("utf-8").strip():
            raise ValueError("Missing distribution notice text")
        notices[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    return {"scope": "archive-metadata-and-headers-only", "version": record["version"], "build": str(record["build"]),
            "source_revision": next(iter(revisions)), "minimum_native_system": minimum,
            "files": files, "notices": notices, "native_runtime_verified": False, "signature_verified": False}


def verify_manifest(manifest_path, directory):
    manifest = json.loads(read_regular(manifest_path, 65536), object_pairs_hook=unique_object)
    if not isinstance(manifest, dict) or manifest.get("kind") != "tide-island-release" or type(manifest.get("schema_version")) is not int or manifest["schema_version"] != 1:
        raise ValueError("Unsupported release manifest")
    version, build, architectures = manifest.get("version"), manifest.get("build"), manifest.get("architectures")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Invalid release version metadata")
    if not isinstance(architectures, list) or not architectures or len(architectures) > 2 or any(item not in ("arm64", "x86_64") for item in architectures) or len(set(architectures)) != len(architectures):
        raise ValueError("Invalid release architecture metadata")
    variant = "universal" if len(architectures) == 2 else architectures[0]
    suffix = version + "-" + build + "-macos-" + variant + ".zip"
    expected = {"TideIsland-" + suffix, "TideIsland-bridge-" + suffix}
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != expected:
        raise ValueError("Manifest may name only its two release archive files")
    for name, entry in artifacts.items():
        if not isinstance(entry, dict) or set(entry) != {"bytes", "sha256"} or type(entry["bytes"]) is not int or not 0 < entry["bytes"] <= 512 * 1024 * 1024 or not isinstance(entry["sha256"], str) or not re.fullmatch("[0-9a-f]{64}", entry["sha256"]):
            raise ValueError("Invalid artifact digest metadata")
        data = read_regular(Path(directory) / name, 512 * 1024 * 1024)
        if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("Artifact checksum differs from the release manifest")
    return {"status": "passed", "scope": "archive-checksums-only", "artifacts_checked": len(artifacts), "signature_verified": False, "native_runtime_verified": False}
