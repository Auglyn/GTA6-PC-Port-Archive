"""Tests for scripts/pr_check.py: python scripts/pr_check_tests.py"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pr_check  # noqa: E402

BODY = "**Tested**\n- ran\n\n**Not tested**\n- nothing\n\n**AI use**\n- none\n"


def files(*paths):
    return [(p, "modified", False, lambda: 100) for p in paths]


class RuntimePaths(unittest.TestCase):
    def test_test_files_are_not_runtime(self):
        for path in ("crates/xcl/src/gpu/recomp/tests.rs", "crates/xcl/src/gpu/adapter_tests.rs",
                     "crates/xcl/src/gpu/agility_tests.rs", "crates/xcl/src/hle/tests/vram.rs"):
            with self.subTest(path=path):
                self.assertFalse(pr_check.runtime(path))

    def test_runtime_files_are_runtime(self):
        for path in ("crates/xcl/src/gpu/rdna2.rs", "crates/xcl/src/hle/d3d12x/vram.rs",
                     # names that only contain "tests" are runtime modules, not test files
                     "crates/xcl/src/net/requests.rs", "crates/xcl/src/hle/contests.rs",
                     "crates/xcl/src/hle/testsupport/mod.rs", "crates/xcl/src/gpu/tests_layout.rs"):
            with self.subTest(path=path):
                self.assertTrue(pr_check.runtime(path))

    def test_outside_the_runtime_crate(self):
        for path in ("README.md", "scripts/pr_check.py", "tests/testtitle/src/main.rs"):
            with self.subTest(path=path):
                self.assertFalse(pr_check.runtime(path))

    def test_a_runtime_file_named_like_a_test_still_needs_a_regression_run(self):
        problems = pr_check.check(BODY, "0123456789ab", files("crates/xcl/src/net/requests.rs"), lambda sha: True)
        self.assertTrue(any("Regression run" in p for p in problems), problems)

    def test_a_test_only_pr_needs_no_regression_run(self):
        problems = pr_check.check(BODY, "0123456789ab", files("crates/xcl/src/gpu/recomp/tests.rs"), lambda sha: True)
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
