#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import re
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG_PATH = REPO_ROOT / ".circleci" / "config.yml"
GH_CI_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"


class CircleCIConfigTest(unittest.TestCase):
    def test_config_structure_and_free_tier_resource_classes(self) -> None:
        raw = CONFIG_PATH.read_text(encoding="utf-8")
        self.assertRegex(raw, r"(?m)^version:\s*2\.1\s*$")
        self.assertIn("image: cimg/base:current-24.04", raw)
        self.assertIn("FOUNDRY_VERSION: v1.10.0", raw)

        resource_classes = re.findall(r"resource_class:\s*(\S+)", raw)
        self.assertTrue(resource_classes, "Expected at least one resource_class")
        allowed_free = {"small", "medium", "medium+", "large", "xlarge", "2xlarge"}
        for rc in resource_classes:
            self.assertIn(rc, allowed_free, f"Paid or unknown resource_class: {rc}")

        self.assertNotIn("*.gen2", raw)
        for cache_path in re.findall(r"(?m)^\s*-\s+([~/.a-zA-Z0-9_*.-]+)\s*$", raw):
            self.assertNotIn("*", cache_path, f"Glob path not supported by CircleCI save_cache: {cache_path}")

    def test_parity_with_github_actions_commands(self) -> None:
        circle_raw = CONFIG_PATH.read_text(encoding="utf-8")
        gh_raw = GH_CI_PATH.read_text(encoding="utf-8")

        required_commands = [
            "./script/build-all.sh",
            "./script/test-all.sh",
            "python3 script/verify_bytecode.py --require-out",
            "python3 -B -m unittest script/test_verify_bytecode.py -v",
            "./script/build-all.sh --use solar",
            "./script/test-all.sh --use solar",
        ]
        for cmd in required_commands:
            self.assertIn(cmd, gh_raw, f"Expected command in GitHub CI: {cmd}")
            self.assertIn(cmd, circle_raw, f"Missing command in CircleCI config: {cmd}")

        self.assertRegex(circle_raw, r"(?m)^  forge-solc:\s*$")
        self.assertRegex(circle_raw, r"(?m)^  forge-solar:\s*$")
        self.assertIn("script/test_circleci_config.py", circle_raw)


if __name__ == "__main__":
    unittest.main()
