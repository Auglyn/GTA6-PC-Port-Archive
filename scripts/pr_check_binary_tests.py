"""Tests for the binary-file check of scripts/pr_check.py: python scripts/pr_check_binary_tests.py

The workflow marks a file binary when GitHub shows no patch and 0 changed lines, which is also true of
an empty file, a pure rename and a mode change. pr_check.py confirms with the file's content."""
import os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pr_check  # noqa: E402

BODY = "**Tested**\n- ran\n\n**Not tested**\n- nothing\n\n**AI use**\n- none\n"


def blob(data):
    """Store `data` as a blob in this repository's object database; returns its sha."""
    r = subprocess.run(["git", "hash-object", "-w", "--stdin"], input=data, capture_output=True, cwd=HERE, check=True)
    return r.stdout.decode().strip()


def run_check(rows):
    """pr_check.py --local on a files.tsv of `rows` (path, status, workflow's binary flag, data)."""
    with tempfile.TemporaryDirectory() as tmp:
        body, files = os.path.join(tmp, "body.md"), os.path.join(tmp, "files.tsv")
        with open(body, "w", encoding="utf-8") as f:
            f.write(BODY)
        with open(files, "w", encoding="utf-8") as f:
            for path, status, flag, data in rows:
                f.write(f"{path}\t{status}\t{'true' if flag else 'false'}\t{blob(data)}\n")
        r = subprocess.run([sys.executable, os.path.join(HERE, "pr_check.py"), "--body", body, "--head",
                            "0123456789ab", "--files", files, "--local"], capture_output=True, text=True, cwd=HERE)
        return r.returncode, r.stdout


class BinaryCheck(unittest.TestCase):
    def test_looks_binary(self):
        self.assertFalse(pr_check.looks_binary(b""))
        self.assertFalse(pr_check.looks_binary(b"fn main() {}\n"))
        self.assertTrue(pr_check.looks_binary(b"MZ\x90\x00\x03\x00"))
        self.assertFalse(pr_check.looks_binary(b"x" * 8000 + b"\x00"))   # git looks at 8000 bytes only

    def test_an_empty_file_and_a_pure_rename_are_not_binary(self):
        code, out = run_check([("scripts/re/.gitkeep", "added", True, b""),
                               ("scripts/re/pe_exports_moved.py", "renamed", True, b"import sys\nprint(1)\n")])
        self.assertEqual((code, out.strip()), (0, "description ok"))

    def test_a_real_binary_is_still_refused(self):
        code, out = run_check([("docs/picture.png", "added", True, b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")])
        self.assertEqual(code, 1)
        self.assertIn("`docs/picture.png` is a binary file", out)

    def test_a_renamed_binary_is_still_refused(self):
        code, out = run_check([("docs/moved.bin2", "renamed", True, b"\x00\x01\x02\x03")])
        self.assertEqual(code, 1)
        self.assertIn("`docs/moved.bin2` is a binary file", out)


if __name__ == "__main__":
    unittest.main()
