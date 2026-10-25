#!/usr/bin/env python3
"""Disposable signed Mac Keychain probe; no execution without a root-granted lane."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = "com.chameleonenterprise.velacanto"
ALPHA = CANONICAL + ".siri-validation"


def run(argv, log=None):
    if log:
        with log.open("wb") as output:
            subprocess.run(argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, check=True)
        return b""
    return subprocess.check_output(argv, cwd=ROOT, stderr=subprocess.PIPE)


def prepare_probe(label, artifact, identity, work, revision, inspect):
    # Inspect before copying any entitlements or compiling a probe. This rejects
    # missing/unresolved/unprovisioned identity rather than trying weaker storage.
    inspect(artifact, identity)
    entitlements = run(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(artifact)])
    prefix = work / (label + "-" + revision + "-certificate-")
    run(["/usr/bin/codesign", "--display", "--extract-certificates=" + str(prefix), str(artifact)])
    certificate = Path(str(prefix) + "0").read_bytes()
    signer = hashlib.sha1(certificate).hexdigest().upper()
    app = work / (label + "-" + revision + ".app")
    contents = app / "Contents"
    binary = contents / "MacOS/KeychainProbe"
    binary.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identity, "CFBundleExecutable": "KeychainProbe",
        "CFBundlePackageType": "APPL", "CFBundleName": "VelaCanto Disposable Keychain Probe",
        "CFBundleVersion": "2" if revision == "rebuilt" else "1", "LSUIElement": True,
        "LSMinimumSystemVersion": "27.0"}))
    shutil.copyfile(artifact / "Contents/embedded.provisionprofile", contents / "embedded.provisionprofile")
    ent_path = work / (label + "-entitlements.plist")
    ent_path.write_bytes(entitlements)
    compile_command = ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
                       "-warnings-as-errors", "-framework", "Foundation", "-framework", "Security",
                       str(ROOT / "scripts/keychain-probe/main.swift"), "-o", str(binary)]
    if revision == "rebuilt":
        compile_command.extend(["-D", "PROBE_REVISION_TWO"])
    run(compile_command, work / (label + "-" + revision + "-compile.log"))
    run(["/usr/bin/codesign", "--force", "--sign", signer, "--options", "runtime",
         "--entitlements", str(ent_path), "--generate-entitlement-der", "--timestamp=none", str(app)],
        work / (label + "-" + revision + "-sign.log"))
    inspect(app, identity)
    # The identity and full entitlement set must exactly match the reviewed artifact.
    actual = plistlib.loads(run(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(app)]))
    if actual != plistlib.loads(entitlements):
        raise RuntimeError("Probe entitlement set differs from the reviewed signed artifact")
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-source", required=True)
    parser.add_argument("--expected-base", required=True,
                        help="Reviewed ancestor commit of this candidate")
    parser.add_argument("--canonical", type=Path, required=True)
    parser.add_argument("--alpha", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    subprocess.run(["git", "merge-base", "--is-ancestor", args.expected_base, "HEAD"],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    source = run(["git", "rev-parse", "HEAD"]).decode().strip()
    if source != args.expected_source or run(["git", "status", "--porcelain"]).strip():
        raise RuntimeError("Freeze the reviewed, clean integrated source before probing")
    if not args.work.is_absolute() or not args.work.resolve().is_relative_to(Path("/private/tmp")):
        raise RuntimeError("Probe bundles/configuration must remain under /private/tmp")
    if not args.canonical.is_absolute() or not args.alpha.is_absolute():
        raise RuntimeError("Select explicit signed artifact paths")
    plan = {"source": source, "execution": args.execute,
            "identities": [CANONICAL, ALPHA], "credential_backend": "DataProtectionOnly",
            "operations": ["add", "read in new process", "read after changed signed binary",
                           "update", "read-updated in new process", "cross-identity absent",
                           "delete in finally", "verify absent"],
            "production_session_access": False, "provisioning_changes": False,
            "installed": False}
    if not args.execute:
        print(json.dumps(plan, indent=2))
        return
    if os.environ.get("VELACANTO_BUILD_LANE_OWNER") != "mac-keychain-modern":
        raise RuntimeError("Root has not granted the serialized build/sign/probe lane")
    if os.environ.get("VELACANTO_DISPOSABLE_KEYCHAIN_PROBE_AUTHORIZED") != "YES":
        raise RuntimeError("Root has not authorized synthetic disposable-item access")
    if args.work.exists():
        raise RuntimeError("Refusing to overwrite previous probe evidence")
    args.work.mkdir(mode=0o700, parents=True)
    inspect = runpy.run_path(str(ROOT / "scripts/validate-modern-keychain.py"))["inspect"]
    artifacts = [("canonical", args.canonical, CANONICAL), ("alpha", args.alpha, ALPHA)]
    binaries = {}
    results = []
    cleanup = []
    success = False

    def operation(label, binary, verb, config, allow_failure=False):
        # Synthetic UUID/nonce only. Passing JSON avoids granting a sandboxed
        # same-identity probe arbitrary filesystem access to the private config.
        result = subprocess.run([str(binary), verb, config.read_text()], cwd=ROOT,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        try:
            output = json.loads(result.stdout)
        except (ValueError, UnicodeError):
            output = {"operation": verb, "outcome": "invalid_probe_output"}
        # Only finite outcomes are retained. No raw stdout/stderr or config data.
        allowed = {"success", "item_not_found", "duplicate_item", "missing_entitlement",
                   "interaction_not_allowed", "authorization_failed", "security_failure",
                   "data_mismatch", "invalid_configuration", "invalid_probe_output"}
        outcome = output.get("outcome")
        if outcome not in allowed:
            outcome = "invalid_probe_output"
        results.append({"identity": label, "operation": verb, "outcome": outcome,
                        "passed": result.returncode == 0 and outcome != "invalid_probe_output"})
        if result.returncode or outcome == "invalid_probe_output":
            if not allow_failure:
                raise RuntimeError("Disposable probe failed; inspect finite outcome evidence")
            return False
        return True

    try:
        for label, artifact, identity in artifacts:
            for revision in ["initial", "rebuilt"]:
                binaries[(label, revision)] = prepare_probe(
                    label, artifact, identity, args.work, revision, inspect)
        for label, _, _ in artifacts:
            config = args.work / (label + "-synthetic-config.json")
            config.write_text(json.dumps({"testID": str(uuid.uuid4()),
                                         "nonce": base64.b64encode(os.urandom(32)).decode()}))
            config.chmod(0o600)
            original = binaries[(label, "initial")]
            rebuilt = binaries[(label, "rebuilt")]
            # Schedule exact-key cleanup before insertion in case process termination
            # occurs after SecItemAdd succeeds but before its result is delivered.
            cleanup.append((label, rebuilt, config))
            operation(label, original, "absent", config)
            operation(label, original, "add", config)
            operation(label, original, "read", config)
            operation(label, rebuilt, "read", config)
            operation(label, rebuilt, "update", config)
            operation(label, rebuilt, "read-updated", config)
            other = "alpha" if label == "canonical" else "canonical"
            operation(other, binaries[(other, "rebuilt")], "absent", config)
        success = True
    finally:
        cleanup_success = True
        for label, binary, config in cleanup:
            try:
                deleted = operation(label, binary, "delete", config, allow_failure=True)
                absent = operation(label, binary, "absent", config, allow_failure=True)
                cleanup_success = cleanup_success and deleted and absent
            except (subprocess.TimeoutExpired, OSError):
                cleanup_success = False
                results.append({"identity": label, "operation": "cleanup",
                                "outcome": "process_failure", "passed": False})
            # Preserve config only when cleanup could not be confirmed, so a root-
            # authorized exact-item cleanup can run without querying other items.
            if cleanup_success:
                config.unlink(missing_ok=True)
        (args.work / "probe-result.json").write_text(json.dumps({
            **plan, "passed": success and cleanup_success, "cleanup_confirmed": cleanup_success,
            "results": results}, indent=2))
        if not cleanup_success:
            raise RuntimeError("Exact disposable-item cleanup needs attention; no legacy access attempted")
    print("Disposable probe passed; production sign-in/update acceptance remains separate.")


if __name__ == "__main__":
    main()
