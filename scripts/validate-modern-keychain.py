#!/usr/bin/env python3
"""Guarded, serialized validation; dry-run by default. Never installs or launches apps."""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = "com.chameleonenterprise.velacanto"
LOCAL = CANONICAL + ".siri-validation"


def command(argv, log=None):
    if log is None:
        return subprocess.check_output(argv, cwd=ROOT)
    with log.open("wb") as output:
        subprocess.run(argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
    return b""


def inspect(app, expected_id):
    """Only public signature/profile metadata; never query Keychain entries."""
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != expected_id:
        raise RuntimeError("Artifact bundle identity does not match the selected identity")
    ent = plistlib.loads(command([
        "/usr/bin/codesign", "--display", "--entitlements", ":-", str(app)]))
    identifier = ent.get("com.apple.application-identifier", "")
    prefix, separator, bundle = identifier.partition(".")
    if not separator or bundle != expected_id or not prefix or "$" in identifier:
        raise RuntimeError("Missing or unresolved Mac application-identifier entitlement")
    if ent.get("keychain-access-groups") != [identifier]:
        raise RuntimeError("Expected one app-specific default Keychain access group")
    if ent.get("com.apple.security.app-sandbox") is not True:
        raise RuntimeError("App Sandbox protection is missing")
    profile_path = app / "Contents/embedded.provisionprofile"
    if not profile_path.is_file():
        raise RuntimeError("Mac provisioning profile is missing; unsigned tests are insufficient")
    profile = plistlib.loads(command([
        "/usr/bin/security", "cms", "-D", "-i", str(profile_path)]))
    if "OSX" not in profile.get("Platform", []):
        raise RuntimeError("Profile does not authorize macOS")
    if profile["ExpirationDate"] <= datetime.datetime.utcnow():
        raise RuntimeError("Profile has expired")
    approved = profile.get("Entitlements", {})
    if not fnmatch.fnmatchcase(identifier, approved.get("com.apple.application-identifier", "")):
        raise RuntimeError("Profile does not authorize the application identifier")
    if not any(fnmatch.fnmatchcase(identifier, group)
               for group in approved.get("keychain-access-groups", [])):
        raise RuntimeError("Profile does not authorize the Keychain access group")
    if prefix not in profile.get("ApplicationIdentifierPrefix", []):
        raise RuntimeError("Profile does not authorize the resolved application prefix")
    # Compare only public certificate data; never inspect signing private keys.
    with tempfile.TemporaryDirectory(prefix="VelaCanto-Keychain-Cert-", dir="/private/tmp") as directory:
        certificate_prefix = Path(directory) / "certificate-"
        command(["/usr/bin/codesign", "--display", "--extract-certificates=" + str(certificate_prefix), str(app)])
        certificate = Path(str(certificate_prefix) + "0").read_bytes()
        if certificate not in profile.get("DeveloperCertificates", []):
            raise RuntimeError("Profile does not authorize the artifact signing certificate")
    return {"bundle_identity": expected_id, "profile_platform": "OSX",
            "resolved_default_group": identifier, "strict_signature": True,
            "disposable_runtime_probe": "pending", "installed": False}


def info_executable(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["tests", "signed"])
    parser.add_argument("--expected-source", required=True)
    parser.add_argument("--expected-base", required=True,
                        help="Reviewed ancestor commit of this candidate")
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--simulator", help="Existing owner-authorized simulator UUID for tests")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--allow-provisioning", action="store_true",
                        help="Requires separate root authorization for account changes")
    args = parser.parse_args()
    subprocess.run(["git", "merge-base", "--is-ancestor", args.expected_base, "HEAD"],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    source = command(["git", "rev-parse", "HEAD"]).decode().strip()
    if source != args.expected_source:
        raise RuntimeError("Source changed: review and freeze the exact integrated candidate first")
    if command(["git", "status", "--porcelain"]).strip():
        raise RuntimeError("Candidate must be clean before validation")
    if not args.derived_data.is_absolute() or not args.evidence.is_absolute():
        raise RuntimeError("Use explicit absolute build and private-evidence directories")
    if args.phase == "tests":
        if not args.simulator:
            parser.error("tests requires --simulator naming an existing authorized simulator")
        if args.execute:
            if os.environ.get("VELACANTO_AUTHORIZED_IOS_SIMULATOR") != args.simulator:
                raise RuntimeError("Explicit owner authorization is required for this simulator")
            devices = json.loads(command(["/usr/bin/xcrun", "simctl", "list", "devices", "available", "--json"]))
            existing = [device for group in devices["devices"].values() for device in group
                        if device["udid"] == args.simulator and device.get("isAvailable")]
            if len(existing) != 1:
                raise RuntimeError("Select one existing available authorized simulator; none will be created")
    common = ["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
              "-project", "NativeFoundation/VelacantoFoundation.xcodeproj", "-scheme",
              "VelacantoFoundation", "-derivedDataPath", str(args.derived_data),
              "-clonedSourcePackagesDirPath", str(args.packages),
              "-disableAutomaticPackageResolution"]
    selections = ["-only-testing:VelacantoFoundationTests/FoundationCredentialsTests",
                  "-only-testing:VelacantoFoundationTests/FoundationStartupTests",
                  "-only-testing:VelacantoFoundationTests/FoundationCredentialUpgradeTests"]
    jobs = []
    if args.phase == "tests":
        jobs = [("Mac-focused", common + ["-configuration", "Debug", "-destination",
                 "platform=macOS", "CODE_SIGNING_ALLOWED=NO", "-parallel-testing-enabled",
                 "NO", *selections, "test"]),
                ("iOS-focused", common + ["-configuration", "Debug", "-destination",
                 "platform=iOS Simulator,id=" + args.simulator, "CODE_SIGNING_ALLOWED=YES",
                 "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=",
                 "-parallel-testing-enabled", "NO", *selections, "test"])]
    else:
        for label, identity in [("canonical", CANONICAL), ("local-alpha", LOCAL)]:
            jobs.append((label, common + ["-configuration", "Release", "-destination",
                         "generic/platform=macOS", "CODE_SIGNING_ALLOWED=YES",
                         "CODE_SIGN_STYLE=Automatic", "VELACANTO_APP_BUNDLE_IDENTIFIER=" + identity,
                         *(["-allowProvisioningUpdates"] if args.allow_provisioning else []), "build"]))
    if not args.execute:
        print(json.dumps({"source": source, "phase": args.phase, "commands": jobs,
                          "execution": False, "provisioning_changes": args.allow_provisioning}, indent=2))
        return
    if os.environ.get("VELACANTO_BUILD_LANE_OWNER") != "mac-keychain-modern":
        raise RuntimeError("Root must explicitly grant the serialized build lane")
    if args.allow_provisioning and os.environ.get("VELACANTO_KEYCHAIN_PROVISIONING_AUTHORIZED") != "YES":
        raise RuntimeError("Root has not authorized external automatic provisioning changes")
    if not args.derived_data.resolve().is_relative_to(Path("/private/tmp")):
        raise RuntimeError("Stage signed bundles under /private/tmp, outside FileProvider storage")
    args.evidence.mkdir(parents=True, exist_ok=True)
    results = {"source": source, "phase": args.phase, "installation": "not performed", "jobs": []}
    for label, argv in jobs:
        command(argv, args.evidence / (label + ".log"))
        result = {"job": label, "command_passed": True}
        if args.phase == "signed":
            app = args.derived_data / "Build/Products/Release/Velacanto.app"
            identity = CANONICAL if label == "canonical" else LOCAL
            result.update(inspect(app, identity))
            # Stage each identity before the next build overwrites this products path.
            stage_root = args.derived_data.parent / (args.derived_data.name + "-keychain-" + source[:12])
            stage_root.mkdir(exist_ok=True)
            staged = stage_root / (label + ".app")
            if staged.exists():
                raise RuntimeError("Refusing to overwrite a preserved signed artifact")
            command(["/usr/bin/ditto", "--noextattr", "--norsrc", str(app), str(staged)])
            command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged)])
            archive = args.evidence / (label + ".zip")
            if archive.exists():
                raise RuntimeError("Refusing to overwrite a preserved signed archive")
            command(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(staged), str(archive)])
            executable = staged / "Contents/MacOS" / info_executable(staged)
            result["executable_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        results["jobs"].append(result)
        (args.evidence / (args.phase + "-result.json")).write_text(json.dumps(results, indent=2))
    print("Validation phase completed; installation and disposable runtime probes remain separate.")


if __name__ == "__main__":
    main()
