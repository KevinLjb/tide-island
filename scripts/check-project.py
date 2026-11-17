#!/usr/bin/env python3
"""Check project structure only; this does not compile or run the native app."""
from pathlib import Path
import json
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check():
    project_path = ROOT / "TideIsland.xcodeproj/project.pbxproj"
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(project_path)],
        check=True, capture_output=True, text=True,
    )
    project = json.loads(result.stdout)
    objects = project["objects"]
    root = objects[project["rootObject"]]
    require(root["isa"] == "PBXProject", "Invalid project root")

    for item in objects.values():
        if item["isa"] == "PBXFileReference" and item.get("sourceTree") == "SOURCE_ROOT":
            require((ROOT / item["path"]).is_file(), "Missing project file: " + item["path"])

    targets = {objects[key]["name"]: objects[key] for key in root["targets"]}
    require(set(targets) == {"TideIsland", "TideIslandActivity"}, "Missing native target")
    expected_sources = {
        "TideIsland": {str(p.relative_to(ROOT)) for p in (ROOT / "Native/App").glob("*.swift")},
        "TideIslandActivity": {
            str(p.relative_to(ROOT)) for p in (ROOT / "Native/ActivityExtension").glob("*.swift")
        },
    }
    shared = {str(p.relative_to(ROOT)) for p in (ROOT / "Native/Shared").glob("*.swift")}
    require(bool(shared), "Missing shared ActivityAttributes")
    for name, target in targets.items():
        actual_sources = set()
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] == "PBXSourcesBuildPhase":
                actual_sources.update(objects[objects[key]["fileRef"]]["path"] for key in phase["files"])
        require(actual_sources == expected_sources[name] | shared, "Incorrect source membership: " + name)
        dependencies = [objects[key]["productName"] for key in target["packageProductDependencies"]]
        require(dependencies == ["TideIslandCore"], "Missing shared package: " + name)
        for key in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            settings = objects[key]["buildSettings"]
            require("MARKETING_VERSION" not in settings and "CURRENT_PROJECT_VERSION" not in settings, "Target must inherit the common version: " + name)

    app = targets["TideIsland"]
    dependency_targets = [objects[objects[key]["target"]]["name"] for key in app["dependencies"]]
    require(dependency_targets == ["TideIslandActivity"], "Missing extension target dependency")
    copies = [objects[key] for key in app["buildPhases"] if objects[key]["isa"] == "PBXCopyFilesBuildPhase"]
    require(len(copies) == 1 and int(copies[0]["dstSubfolderSpec"]) == 13, "Missing extension embed phase")
    embedded = [objects[objects[key]["fileRef"]]["path"] for key in copies[0]["files"]]
    require(embedded == ["TideIslandActivity.appex"], "Incorrect embedded extension")

    bridge_phases = [objects[key] for key in app["buildPhases"] if objects[key]["isa"] == "PBXShellScriptBuildPhase"]
    require(len(bridge_phases) == 1 and bridge_phases[0]["name"] == "Embed event bridge", "Missing embedded bridge build phase")
    bridge_phase = bridge_phases[0]
    require(bridge_phase["shellPath"] == "/bin/bash" and bridge_phase["shellScript"] == '/bin/bash "$SRCROOT/scripts/build-embedded-bridge.sh"\n', "Incorrect bridge build command")
    require(int(bridge_phase["alwaysOutOfDate"]) == 1, "Bridge must rebuild when package sources change")
    require(set(bridge_phase["inputPaths"]) == {
        "$(SRCROOT)/scripts/build-embedded-bridge.sh",
        "$(SRCROOT)/scripts/embed-bridge.py",
        "$(SRCROOT)/scripts/release_metadata.py",
        "$(SRCROOT)/LICENSE",
        "$(SRCROOT)/THIRD_PARTY_NOTICES.md",
        "$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)",
    }, "Missing bridge / notice inputs")
    require(set(bridge_phase["outputPaths"]) == {
        "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/tide-island-bridge",
        "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/bridge-manifest.json",
        "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/LICENSE",
        "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/THIRD_PARTY_NOTICES.md",
    }, "Missing bridge outputs")
    for key in objects[app["buildConfigurationList"]]["buildConfigurations"]:
        require(objects[key]["buildSettings"]["ENABLE_USER_SCRIPT_SANDBOXING"] == "NO", "SwiftPM build phase requires its own DerivedFileDir scratch")

    configurations = objects[root["buildConfigurationList"]]["buildConfigurations"]
    for key in configurations:
        settings = objects[key]["buildSettings"]
        version_reference = objects[objects[key]["baseConfigurationReference"]]
        require(version_reference["path"] == "Config/Version.xcconfig", "Missing common version configuration")
        require("MARKETING_VERSION" not in settings and "CURRENT_PROJECT_VERSION" not in settings, "Version must come from VERSION.json")
        require(settings["MACOSX_DEPLOYMENT_TARGET"] == "27.3", "Native target must require macOS 27.3")
        require(settings["SWIFT_VERSION"] == "6.0", "Unexpected Swift language mode")

    app_info = plistlib.loads((ROOT / "Native/App/Info.plist").read_bytes())
    extension_info = plistlib.loads((ROOT / "Native/ActivityExtension/Info.plist").read_bytes())
    entitlements = plistlib.loads((ROOT / "Native/ActivityExtension/TideIslandActivity.entitlements").read_bytes())
    require(app_info.get("NSSupportsLiveActivities") is True, "Live Activities not enabled")
    for info in (app_info, extension_info):
        require(info.get("CFBundleShortVersionString") == "$(MARKETING_VERSION)" and info.get("CFBundleVersion") == "$(CURRENT_PROJECT_VERSION)", "Bundle must inherit generated version metadata")
        require(info.get("TideIslandSourceRevision") == "$(TIDE_ISLAND_SOURCE_REVISION)", "Missing release source revision metadata")
    require(extension_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension", "Wrong extension point")
    require(entitlements.get("com.apple.security.app-sandbox") is True, "Extension sandbox not enabled")
    scheme = ET.parse(ROOT / "TideIsland.xcodeproj/xcshareddata/xcschemes/TideIsland.xcscheme")
    references = scheme.findall(".//BuildableReference")
    require(bool(references), "Missing shared scheme buildable")
    for reference in references:
        require(objects[reference.attrib["BlueprintIdentifier"]]["name"] == "TideIsland", "Broken scheme target")

    print(json.dumps({
        "status": "passed", "scope": "project-structure-only",
        "native_targets": len(targets), "native_swift_files": len(set.union(*expected_sources.values(), shared)),
        "plist_files": 3,
    }))


if __name__ == "__main__":
    try:
        check()
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError, ET.ParseError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}), file=sys.stderr)
        sys.exit(1)
