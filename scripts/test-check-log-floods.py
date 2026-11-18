#!/usr/bin/env python3
"""Tests for scripts/check-log-floods.py, the check that a test run didn't flood the log.

    python3 scripts/test-check-log-floods.py
"""
import importlib.util, os, sys, tempfile, unittest

sys.dont_write_bytecode = True  # importing the script must not leave a __pycache__ beside it
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check_log_floods", os.path.join(HERE, "check-log-floods.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

COLOUR = "2026-11-18 08:16:09.349676+0000 Vespertine[15581:45734] Unrecognized colorspace number -1"
MODEL = "2026-11-18 08:16:09.349716+0000 Vespertine[15581:45734] Unknown number of components for colorspace model -1"
QUIET = "✔ Test \"The picture for a key is not remembered as missing\" passed after 0.120 seconds."


class Floods(unittest.TestCase):
    def run_on(self, lines):
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as log:
            log.write("\n".join(lines) + "\n")
        try:
            return check.main(log.name)
        finally:
            os.unlink(log.name)

    def test_a_quiet_run_passes(self):
        self.assertEqual(self.run_on([QUIET] * 1000), 0)

    def test_a_few_lines_from_macos_itself_pass(self):
        self.assertEqual(self.run_on([QUIET, COLOUR, MODEL, COLOUR, QUIET]), 0)
        self.assertEqual(check.floods([COLOUR] * check.FLOODS["Unrecognized colorspace number"]), {})

    def test_the_colour_space_flood_fails(self):
        # What one 600 by 600 cover set pixel by pixel wrote: two lines a pixel.
        self.assertEqual(self.run_on([QUIET] + [COLOUR, MODEL] * 600 * 6 + [QUIET]), 1)
        self.assertEqual(check.floods([COLOUR, MODEL] * 5000),
                         {"Unrecognized colorspace number": 5000, "Unknown number of components for colorspace model": 5000})

    def test_each_warning_has_its_own_limit(self):
        limit = check.FLOODS["Unrecognized colorspace number"]
        self.assertEqual(check.floods([COLOUR] * (limit + 1)), {"Unrecognized colorspace number": limit + 1})


if __name__ == "__main__":
    unittest.main()
