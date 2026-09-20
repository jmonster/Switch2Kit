"""Execution-policy regressions; these do not replace the native platform tests."""
import copy
import itertools
import json
import os
import sys
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

import policy

ROOT = Path(__file__).resolve().parents[2]


class StrictLoader(yaml.BaseLoader):
    """Keep YAML's `on` as text and reject duplicate keys instead of masking them."""


def mapping(loader, node, deep=False):
    result = {}
    for key, value in node.value:
        name = loader.construct_object(key, deep=deep)
        if name in result:
            raise ValueError(f"Duplicate YAML key: {name}")
        result[name] = loader.construct_object(value, deep=deep)
    return result


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)


def workflows():
    paths = sorted((ROOT / ".github/workflows").glob("*.y*ml"))
    return {p.name: yaml.load(p.read_text(), Loader=StrictLoader) for p in paths}


class WorkflowPolicyTests(unittest.TestCase):
    def setUp(self):
        self.flows = workflows()
        self.ci = self.flows["ci.yml"]

    def test_only_one_automatic_workflow_and_no_feature_branch_pushes_or_schedules(self):
        self.assertEqual(set(self.ci["on"]), {"pull_request", "push", "merge_group", "workflow_dispatch"})
        self.assertEqual(self.ci["on"]["push"], {"branches": ["main"]})
        self.assertEqual(len(self.flows), 9)
        for name, flow in self.flows.items():
            if name != "ci.yml":
                self.assertEqual(set(flow["on"]), {"workflow_dispatch"}, name)

    def test_total_timeout_budget_and_no_hidden_matrix_or_reusable_job_fanout(self):
        budgets = {"preflight": 2, "macos": 8, "linux": 8, "windows": 8, "gate": 1}
        self.assertEqual(set(self.ci["jobs"]), set(budgets))
        total = 0
        for name, job in self.ci["jobs"].items():
            timeout = int(job["timeout-minutes"])
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, budgets[name])
            self.assertNotIn("strategy", job)
            self.assertNotIn("uses", job)
            self.assertNotIn("continue-on-error", job)
            for step in job["steps"]:
                self.assertNotIn("continue-on-error", step)
            total += timeout
        self.assertLessEqual(total, 27)

    def test_native_jobs_wait_for_preflight(self):
        for name in policy.NATIVE_JOBS:
            job = self.ci["jobs"][name]
            self.assertEqual(job["needs"], "preflight")
            self.assertEqual(job["if"], "needs.preflight.outputs.native == 'true'")
        checkout = self.ci["jobs"]["preflight"]["steps"][0]
        self.assertEqual(checkout["with"]["fetch-depth"], "0")

    def test_gate_always_reports_and_requires_every_native_lane(self):
        gate = self.ci["jobs"]["gate"]
        self.assertEqual(gate["if"], "always()")
        self.assertEqual(gate["name"], "CI gate")
        self.assertEqual(set(gate["needs"]), {"preflight", *policy.NATIVE_JOBS})
        self.assertIn("policy.py gate", gate["steps"][-1]["run"])
        self.assertEqual(gate["steps"][-1]["env"]["NEEDS_JSON"], "${{ toJSON(needs) }}")
        # Filtering the whole workflow could leave a required check pending forever.
        self.assertEqual(self.ci["on"]["pull_request"], "")

    def test_all_workflows_cancel_superseded_runs_and_have_finite_jobs(self):
        for flow in self.flows.values():
            self.assertEqual(flow["concurrency"]["cancel-in-progress"], "true")
            self.assertIn("github.ref", flow["concurrency"]["group"])
            for job in flow["jobs"].values():
                self.assertTrue(0 < int(job["timeout-minutes"]) <= 90)

    def test_pinned_actions_read_only_permissions_and_no_persisted_checkout_token(self):
        for flow in self.flows.values():
            self.assertEqual(flow["permissions"], {"contents": "read"})
            for job in flow["jobs"].values():
                self.assertNotIn("permissions", job)
                for step in job["steps"]:
                    if "uses" in step:
                        self.assertRegex(step["uses"], r"^[\w/-]+@[a-f0-9]{40}$")
                    if step.get("uses", "").startswith("actions/checkout@"):
                        self.assertEqual(step["with"]["persist-credentials"], "false")

    def test_no_successful_routine_artifact_uploads_or_new_build_cache(self):
        for job in self.ci["jobs"].values():
            for step in job["steps"]:
                self.assertFalse(step.get("uses", "").startswith("actions/cache"))
                if step.get("uses", "").startswith("actions/upload-artifact@"):
                    self.assertEqual(step["if"], "failure()")
                    self.assertEqual(step["with"]["retention-days"], "1")
        for flow in self.flows.values():
            for job in flow["jobs"].values():
                for step in job["steps"]:
                    if step.get("uses", "").startswith("actions/upload-artifact@"):
                        self.assertTrue(1 <= int(step["with"]["retention-days"]) <= 7)

    def test_material_coverage_and_single_routine_sdl_build(self):
        runs = {name: "\n".join(s.get("run", "") for s in job["steps"])
                for name, job in self.ci["jobs"].items()}
        for command in ["tests/repository/run.sh", "tests/distribution-notices/run.sh", "tests/app-identity/run.sh", "scripts/switch2kit/check-boundaries.py"]:
            self.assertIn(command, runs["preflight"])
        for command in ["bash tests/run.sh", "scripts/verify-switch2kit-consumer.sh", "scripts/build-switch2kit-demo.sh", "scripts/build-app.sh", "codesign --verify --strict", "scripts/check-runtime.sh"]:
            self.assertIn(command, runs["macos"])
        for command in ["swift test -Xswiftc -warnings-as-errors", "tests/linux-bluez/run.sh", "tests/emulator-host/verify.sh"]:
            self.assertIn(command, runs["linux"])
        self.assertIn("swift test -Xswiftc -warnings-as-errors", runs["windows"])
        self.assertIn("swift build -c release --product Switch2KitC", runs["windows"])
        repositories = [s["with"]["repository"] for j in self.ci["jobs"].values()
                        for s in j["steps"] if "repository" in s.get("with", {})]
        self.assertEqual(repositories, ["libsdl-org/SDL"])
        self.assertEqual(sum(text.count("bash tests/run.sh") for text in runs.values()), 1)

    def test_manual_qualification_keeps_secondary_platforms_and_explicit_emulators(self):
        windows = self.flows["windows-native.yml"]["jobs"]["windows"]["strategy"]["matrix"]["include"]
        self.assertEqual({cell["swift"] for cell in windows}, {"6.2.1", "6.3.3"})
        self.assertEqual(len(self.flows["runtime-qualification.yml"]["jobs"]["runtime"]["strategy"]["matrix"]["include"]), 4)
        for filename in ["emulator-integration.yml", "linux-bluez.yml"]:
            flow = self.flows[filename]
            self.assertEqual(flow["on"]["workflow_dispatch"]["inputs"]["full_emulators"]["default"], "false")
            for key in (["native", "launch"] if filename == "emulator-integration.yml" else ["dolphin", "cemu"]):
                self.assertIn("inputs.full_emulators", flow["jobs"][key]["if"])
                self.assertIn("needs", flow["jobs"][key])

    def test_embedded_bash_syntax(self):
        for name, flow in self.flows.items():
            for job in flow["jobs"].values():
                for step in job["steps"]:
                    if "run" not in step or step.get("shell") == "pwsh":
                        continue
                    text = re.sub(r"\$\{\{.*?\}\}", "ci-placeholder", step["run"])
                    result = subprocess.run(["bash", "-n"], input=text, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, (name, step.get("name"), result.stderr))

    def test_yaml_duplicate_keys_are_rejected(self):
        with self.assertRaises(ValueError):
            yaml.load("jobs: {}\njobs: {}\n", Loader=StrictLoader)


class SelectionTests(unittest.TestCase):
    def test_known_documentation_skips_compilers(self):
        self.assertFalse(policy.requires_native(["README.md", "docs/protocol.md", "docs/nested/setup.md", "Examples/README.md", ".github/CI.md"]))

    def test_unknown_and_material_inputs_never_skip(self):
        for path in ["Sources/Transport.swift", "Tests/Test.swift", "tests/fixture.md", "LICENSES/SDL.txt", "CREDITS.md", "Package.swift", "Package.resolved", "scripts/build.sh", "Integrations/SDL3/CMakeLists.txt", ".github/workflows/ci.yml", "docs/input.json", "new-build-input", "/README.md", "docs/../Sources/input.md"]:
            self.assertTrue(policy.requires_native(["README.md", path]), path)
        self.assertTrue(policy.requires_native([]))

    def test_large_change_list_does_not_hide_late_source_change(self):
        self.assertTrue(policy.requires_native([f"docs/{i}.md" for i in range(501)] + ["Sources/late.swift"]))

    def test_missing_diff_or_non_pr_event_runs_all_native_checks(self):
        with patch.object(policy, "changed_paths", side_effect=subprocess.CalledProcessError(1, "git")):
            self.assertTrue(policy.plan("pull_request", "a" * 40, "b" * 40))
        self.assertTrue(policy.plan("pull_request", "--bad-ref", ""))
        for event in ["workflow_dispatch", "merge_group", "unknown"]:
            self.assertTrue(policy.plan(event, "", ""))

    def test_whole_pr_diff_and_renamed_or_deleted_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
            def commit():
                git("add", "-A")
                git("commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-q")
            git("config", "user.name", "CI fixture")
            git("config", "user.email", "ci@example.invalid")
            (root / "Sources").mkdir()
            (root / "docs").mkdir()
            (root / "Sources/engine.swift").write_text("initial")
            base = commit()
            (root / "Sources/engine.swift").write_text("changed")
            commit()
            (root / "docs/latest.md").write_text("docs-only last commit")
            head = commit()
            self.assertIn("Sources/engine.swift", policy.changed_paths(base, head, root))
            self.assertTrue(policy.plan("pull_request", base, head, root))
            (root / "Sources/engine.swift").rename(root / "docs/moved.md")
            renamed = commit()
            self.assertIn("Sources/engine.swift", policy.changed_paths(head, renamed, root))
            self.assertTrue(policy.plan("pull_request", head, renamed, root))
            # An advancing target branch must not contaminate the PR's own diff.
            git("checkout", "-q", "-b", "target", base)
            (root / "target-only.txt").write_text("unrelated")
            target = commit()
            self.assertNotIn("target-only.txt", policy.changed_paths(target, head, root))
            self.assertIn("target-only.txt", policy.changed_paths(target, head, root, pr_diff=False))
            self.assertFalse(policy.plan("push", git("rev-parse", f"{head}^"), head, root))
            self.assertTrue(policy.plan("push", "0" * 40, head, root))


class GateTests(unittest.TestCase):
    def test_cli_output_and_failure_exit_codes(self):
        script = ROOT / ".github/ci/policy.py"
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            env = dict(os.environ, EVENT_NAME="workflow_dispatch", GITHUB_OUTPUT=str(output))
            result = subprocess.run([sys.executable, str(script), "plan"], env=env, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(output.read_text(), "native=true\n")
        good = {"preflight": {"result": "success", "outputs": {"native": "false"}}, **{n: {"result": "skipped"} for n in policy.NATIVE_JOBS}}
        for payload, expected in [(json.dumps(good), 0), ("{}", 1), ("not JSON", 1)]:
            result = subprocess.run([sys.executable, str(script), "gate"], env=dict(os.environ, NEEDS_JSON=payload), capture_output=True)
            self.assertEqual(result.returncode, expected)

    def test_exhaustive_success_failure_cancel_and_skip_combinations(self):
        states = ["success", "failure", "cancelled", "skipped"]
        for native in ["true", "false"]:
            for preflight in states:
                for results in itertools.product(states, repeat=3):
                    needs = {"preflight": {"result": preflight, "outputs": {"native": native}}}
                    needs.update({name: {"result": result} for name, result in zip(policy.NATIVE_JOBS, results)})
                    expected = "success" if native == "true" else "skipped"
                    self.assertEqual(policy.gate_ok(needs), preflight == "success" and all(r == expected for r in results))

    def test_missing_results_and_malformed_plans_fail_closed(self):
        for needs in [None, [], {}, {"preflight": None}, {"preflight": {"result": "success", "outputs": None}}, {"preflight": {"result": "success", "outputs": {"native": ""}}}]:
            self.assertFalse(policy.gate_ok(needs))
        good = {"preflight": {"result": "success", "outputs": {"native": "true"}}, **{n: {"result": "success"} for n in policy.NATIVE_JOBS}}
        for name in policy.NATIVE_JOBS:
            missing = copy.deepcopy(good)
            del missing[name]
            self.assertFalse(policy.gate_ok(missing))


if __name__ == "__main__":
    unittest.main()
