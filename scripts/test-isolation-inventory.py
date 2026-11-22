#!/usr/bin/env python3
"""Exercise the real build.sh result verifier against synthetic xcresult trees."""
import json
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
build = (root / "scripts" / "build.sh").read_text(encoding="utf-8")
marker = "<<'PYTHON'\n"
program = build.split(marker, 1)[1].split("\nPYTHON\n", 1)[0]
prefix = program.split("seen = {}", 1)[0]

with tempfile.TemporaryDirectory(prefix="velacanto-inventory-") as directory:
    result = pathlib.Path(directory) / "synthetic.json"
    result.write_text('{"testNodes": []}', encoding="utf-8")
    for platform in ("macos", "ios"):
        namespace = {"__name__": "__main__"}
        previous = sys.argv
        try:
            sys.argv = ["verifier", str(result), platform]
            exec(compile(prefix, "build.sh verifier", "exec"), namespace)
        finally:
            sys.argv = previous
        expected = sorted(namespace["expected"])
        critical_search_tests = {
            "FoundationCatalogSourceTests/testEmptySearchSeedCanContinueFallbackToFirstMatch",
            "FoundationCatalogSourceTests/testFallbackFailureKeepsCursorForExplicitRetry",
            "FoundationCatalogSourceTests/testRetiredFallbackCannotPublishLatePage",
            "FoundationCatalogSourceTests/testSearchFallbackContinuationOwnsItsCursorAndRetainsProviderRows",
            "FoundationComposedCatalogModelTests/testCappedSearchSourceRoundTripCannotExposeAnotherRead",
            "FoundationComposedCatalogModelTests/testSearchFilterRoundTripPreservesSeedCoverage",
            "FoundationComposedCatalogModelTests/testSearchFilterSuspensionDrainsAndRejectsLateFallbackThenRetriesSameCursor",
            "FoundationComposedCatalogModelTests/testSearchSourceRoundTripRetainsContinuedRowsAndCursorWithoutReads",
            "FoundationSearchResolverTests/testEmptyCategoryContinuationEntryVisibility",
            "FoundationSearchResolverTests/testEmptyOriginalSeedWithoutFallbackContinuesExplicitly",
            "FoundationSearchResolverTests/testNativeEmptyFallbackSeedMakesOneExplicitReadAndClearsNotice",
            "FoundationSearchResolverTests/testNativeFilteredPageRetainsContinuationWithoutWalking",
            "FoundationSearchResolverTests/testNativeOriginalAndFallbackCursorsRetryIndependently",
            "FoundationSearchResolverTests/testNativeRetirementRejectsLateFallbackResult",
        }
        assert critical_search_tests == namespace["search_required"], "critical search inventory drifted"
        negative_cases = critical_search_tests
        assert negative_cases.issubset(expected)
        def run(nodes):
            result.write_text(json.dumps({"testNodes": nodes}), encoding="utf-8")
            return subprocess.run(
                [sys.executable, "-c", program, str(result), platform],
                capture_output=True, text=True, check=False)
        passing = [
            {"nodeType": "Test Case", "nodeIdentifier": name, "result": "Passed"}
            for name in expected
        ]
        assert run(passing).returncode == 0, "complete inventory should pass"
        for name in sorted(negative_cases):
            index = expected.index(name)
            missing = [node.copy() for node in passing]
            missing.pop(index)
            assert run(missing).returncode != 0, f"missing {name} accepted"
            skipped = [node.copy() for node in passing]
            skipped[index]["result"] = "Skipped"
            assert run(skipped).returncode != 0, f"skipped {name} accepted"
            wrong = [node.copy() for node in passing]
            wrong[index]["nodeIdentifier"] = "OtherTestClass/" + name.split("/", 1)[1]
            assert run(wrong).returncode != 0, f"wrong class for {name} accepted"
    print("Isolation inventory positive and missing/skipped/wrong-class controls passed for macOS and iOS")

# The retired in-process RootView UI traversal is replaced by mandatory external Mac UI coverage.
external_script = (root / "scripts" / "test-root-lyrics-retirement.sh").read_text(encoding="utf-8")
external_program = external_script.split(
    "python3 - \"$result_root/tests.json\" \"$result_root/export-summary.log\" <<'PY'\n", 1
)[1].split("\nPY\n", 1)[0]
external_required = "FoundationRootLyricsRetirementUITests/testActualRootSignOutRetiresHeldLyricsWithoutChangingSelectedOccurrence"
mac_gate = build.split("isolation_macos() {", 1)[1].split("\n}", 1)[0]
assert mac_gate.index("./scripts/test-root-lyrics-retirement.sh") < mac_gate.index("isolation_macos_verified=YES")
with tempfile.TemporaryDirectory(prefix="velacanto-root-ui-inventory-") as directory:
    result = pathlib.Path(directory) / "tests.json"
    summary_path = pathlib.Path(directory) / "summary.json"
    def run_external(nodes, **overrides):
        result.write_text(json.dumps({"testNodes": nodes}), encoding="utf-8")
        summary = dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0,
                       expectedFailures=0, runtimeWarnings=[])
        summary.update(overrides)
        summary_path.write_text(json.dumps(summary), encoding="utf-8")
        return subprocess.run(
            [sys.executable, "-c", external_program, str(result), str(summary_path)],
            capture_output=True, text=True, check=False)
    passing = [{"nodeType": "Test Case", "nodeIdentifier": external_required, "result": "Passed"}]
    assert run_external(passing).returncode == 0, "complete external UI inventory should pass"
    assert run_external([]).returncode != 0, "empty external UI execution accepted"
    for state in ("Skipped", "Failed"):
        bad = [dict(passing[0], result=state)]
        assert run_external(bad).returncode != 0, f"external UI {state} accepted"
    wrong = [dict(passing[0], nodeIdentifier="WrongClass/" + external_required.split("/", 1)[1])]
    assert run_external(wrong).returncode != 0, "wrong external UI class accepted"
    assert run_external(passing * 2).returncode != 0, "duplicate external UI execution accepted"
    assert run_external(passing, skippedTests=1).returncode != 0, "external UI summary skip accepted"
    assert run_external(passing, runtimeWarnings=[{"message": "synthetic warning"}]).returncode != 0, "external UI runtime warning accepted"
print("External root UI gate wiring and positive/missing/skipped/failed/wrong-class/duplicate/warning controls passed")
