import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("ci", Path(__file__).parents[1] / "run_ci_tests.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class Profiles(unittest.TestCase):
    def test_v2_mac_keeps_all_three_targets_and_defers_capacity(self):
        args = ci.command("v2", "macos")
        self.assertEqual(args[:2], ["swift", "test"])
        self.assertEqual(args[args.index("--filter") + 1], "GraphEvo(Store|Runtime|Model)Tests")
        self.assertEqual(args[args.index("--skip") + 1], ci.CAPACITY_TEST)

    def test_v2_ios_keeps_all_three_targets_and_defers_capacity(self):
        args = ci.command("v2", "ios", "platform=iOS Simulator,id=fixture", "/tmp/fixture.xcresult")
        self.assertEqual([x for x in args if x.startswith("-only-testing:")],
                         ["-only-testing:GraphEvoStoreTests", "-only-testing:GraphEvoRuntimeTests", "-only-testing:GraphEvoModelTests"])
        self.assertIn("-skip-testing:GraphEvoStoreTests/GraphTypedQueryTests/" + ci.CAPACITY_TEST + "()", args)

    def test_full_has_no_test_exclusions_on_either_platform(self):
        for platform in ("macos", "ios"):
            args = ci.command("full", platform, "platform=iOS Simulator,id=fixture", "/tmp/fixture.xcresult")
            self.assertFalse(any(x.startswith(("--filter", "--skip", "-skip-testing:", "-only-testing:")) for x in args))

    def test_capacity_exclusion_names_a_real_test_and_scheme_is_the_library(self):
        root = Path(__file__).parents[2]
        fixture = root / "Tests/GraphEvoStoreTests/GraphTypedQueryTests.swift"
        self.assertIn("func " + ci.CAPACITY_TEST + "(", fixture.read_text())
        args = ci.command("full", "ios", "fixture", "/tmp/fixture.xcresult")
        self.assertEqual(args[args.index("-scheme") + 1], "GraphEvo")

    def test_empty_and_failed_result_bundles_cannot_report_success(self):
        for summary in [{}, {"passedTests": 0, "failedTests": 0}, {"passedTests": 10, "failedTests": 1}]:
            with self.assertRaises(ValueError):
                ci.validate_summary(summary)
        self.assertEqual(ci.validate_summary({"passedTests": 592, "failedTests": 0})["passedTests"], 592)

    def test_invalid_requests_fail_instead_of_selecting_less_coverage(self):
        for args in [("typo", "macos"), ("v2", "typo"), ("v2", "ios")]:
            with self.assertRaises(ValueError):
                ci.command(*args)


if __name__ == "__main__":
    unittest.main()
