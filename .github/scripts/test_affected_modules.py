"""The attribution rules, exercised against a real git history in tmp_path.

The fixture repository is a miniature of this one: three modules with tests, a
handful of examples whose names are prefixed with their module, a root `versions.tf`
and a workflow file. One test rewires two modules into a relative source chain to
cover the dependent map, which the real repository does not currently exercise.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import affected_modules  # noqa: E402


def write(root, relative, text):
    """Create a file under root, parents included."""
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def git(root, *args):
    """Run a git command in the fixture repository."""
    return subprocess.run(
        ["git", *args], cwd=root, capture_output=True, text=True, check=True
    ).stdout.strip()


@pytest.fixture
def repo(tmp_path):
    """A git repository holding the modules and examples layout, committed once."""
    root = tmp_path / "repo"
    root.mkdir()
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.email", "ci@example.invalid")
    git(root, "config", "user.name", "CI")

    write(root, "versions.tf", 'terraform {\n  required_version = ">= 1.10"\n}\n')
    write(root, "README.md", "# fixture\n")
    write(root, ".github/workflows/terraform-ci.yml", "name: Terraform CI\n")
    write(root, ".github/scripts/local_module_override.py", "# override\n")

    for module in ("http-api", "lambda-function", "staging-access-gate"):
        write(root, f"modules/{module}/main.tf", 'resource "null_resource" "a" {}\n')
        write(root, f"modules/{module}/README.md", f"# {module}\n")
        write(
            root,
            f"modules/{module}/tests/basic.tftest.hcl",
            'run "ok" {\n  command = plan\n}\n',
        )

    for example, source in (
        ("http-api-basic", "../../modules/http-api"),
        ("http-api-strangler", "../../modules/http-api"),
        ("lambda-function-basic", "../../modules/lambda-function"),
        ("lambda-function-image", "../../modules/lambda-function"),
        ("staging-access-gate-complete", "../../modules/staging-access-gate"),
    ):
        write(
            root,
            f"examples/{example}/main.tf",
            f'module "under_test" {{\n  source = "{source}"\n}}\n',
        )

    git(root, "add", "-A")
    git(root, "commit", "-qm", "base")
    return root


def commit(root, changes, message="change"):
    """Apply a mapping of relative path to text, commit, and return base and head."""
    base = git(root, "rev-parse", "HEAD")
    for relative, text in changes.items():
        write(root, relative, text)
    git(root, "add", "-A")
    git(root, "commit", "-qm", message)
    return base, git(root, "rev-parse", "HEAD")


def run(root, base, head):
    """Invoke the resolver and return its outputs as a mapping."""
    output = root / "outputs.txt"
    output.write_text("", encoding="utf-8")
    summary = root / "summary.md"
    summary.write_text("", encoding="utf-8")

    env = {"GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)}
    previous = {key: os.environ.get(key) for key in env}
    os.environ.update(env)
    try:
        code = affected_modules.main(
            ["--repo-root", str(root), "--base", base, "--head", head]
        )
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    values = {"_code": code}
    for line in output.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        values[key] = value
    values["_summary"] = summary.read_text(encoding="utf-8")
    return values


def test_a_module_change_affects_only_that_module(repo):
    """The narrowest case, and the whole point of the resolver."""
    base, head = commit(repo, {"modules/http-api/main.tf": "# changed\n"})
    result = run(repo, base, head)
    assert json.loads(result["modules"]) == ["http-api"]
    assert result["all"] == "false"
    assert result["any"] == "true"


def test_a_module_change_pulls_in_its_own_examples(repo):
    """Validating the module without its examples would miss a broken interface."""
    base, head = commit(repo, {"modules/http-api/main.tf": "# changed\n"})
    result = run(repo, base, head)
    assert json.loads(result["validate"]) == [
        "modules/http-api",
        "examples/http-api-basic",
        "examples/http-api-strangler",
    ]
    assert json.loads(result["test"]) == ["modules/http-api"]


def test_an_example_change_maps_to_its_module(repo):
    """An example edit reruns its module's suite, not every module's."""
    base, head = commit(repo, {"examples/lambda-function-image/main.tf": "# changed\n"})
    result = run(repo, base, head)
    assert json.loads(result["modules"]) == ["lambda-function"]
    assert json.loads(result["test"]) == ["modules/lambda-function"]


def test_the_longest_module_prefix_owns_an_example(repo):
    """`lambda-function-image` is lambda-function's, never a shorter accidental prefix."""
    assert (
        affected_modules.example_owner(
            "lambda-function-image", ["lambda", "lambda-function"]
        )
        == "lambda-function"
    )


def test_the_workflow_file_forces_every_module(repo):
    """A workflow edit changes how everything is built, so nothing narrower is honest."""
    base, head = commit(repo, {".github/workflows/terraform-ci.yml": "name: CI\n"})
    result = run(repo, base, head)
    assert result["all"] == "true"
    assert json.loads(result["modules"]) == [
        "http-api",
        "lambda-function",
        "staging-access-gate",
    ]


def test_the_shared_test_helper_forces_every_module(repo):
    """The override script rewrites every example's sources, so it reaches all of them."""
    base, head = commit(repo, {".github/scripts/local_module_override.py": "# v2\n"})
    assert run(repo, base, head)["all"] == "true"


def test_a_root_tf_change_forces_every_module(repo):
    """Root `versions.tf` sets the floor every module inherits."""
    base, head = commit(repo, {"versions.tf": 'terraform {\n  required_version = ">= 1.11"\n}\n'})
    assert run(repo, base, head)["all"] == "true"


def test_a_path_outside_modules_and_examples_forces_every_module(repo):
    """Anything unrecognised is assumed to move everything, which is the safe reading."""
    base, head = commit(repo, {"README.md": "# fixture two\n"})
    assert run(repo, base, head)["all"] == "true"


def test_a_file_directly_under_modules_forces_every_module(repo):
    """A loose file at the top of `modules/` belongs to no single module."""
    base, head = commit(repo, {"modules/NOTES.md": "# notes\n"})
    assert run(repo, base, head)["all"] == "true"


def test_a_relative_source_dependent_is_pulled_in(repo):
    """A module embedding another reruns whenever the embedded one changes."""
    write(
        repo,
        "modules/http-api/gate.tf",
        'module "gate" {\n  source = "../staging-access-gate"\n}\n',
    )
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "wire")

    base, head = commit(repo, {"modules/staging-access-gate/main.tf": "# changed\n"})
    result = run(repo, base, head)
    assert json.loads(result["modules"]) == ["http-api", "staging-access-gate"]
    assert json.loads(result["test"]) == ["modules/http-api", "modules/staging-access-gate"]


def test_the_dependent_map_is_transitive(repo):
    """A chain of relative sources reaches every module above the one that changed."""
    write(
        repo,
        "modules/http-api/gate.tf",
        'module "gate" {\n  source = "../staging-access-gate"\n}\n',
    )
    write(
        repo,
        "modules/lambda-function/api.tf",
        'module "api" {\n  source = "../http-api"\n}\n',
    )
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "chain")

    base, head = commit(repo, {"modules/staging-access-gate/main.tf": "# changed\n"})
    assert json.loads(run(repo, base, head)["modules"]) == [
        "http-api",
        "lambda-function",
        "staging-access-gate",
    ]


def test_the_dependent_map_is_empty_without_relative_sources(repo):
    """This repository wires nothing together, so the map adds nothing."""
    modules = affected_modules.discover_modules(repo)
    dependents = affected_modules.build_dependents(repo, modules)
    assert all(not value for value in dependents.values())


def test_the_node_flag_follows_its_module(repo):
    """The node suite belongs to staging-access-gate and runs only when it is affected."""
    base, head = commit(repo, {"modules/http-api/main.tf": "# changed\n"})
    assert run(repo, base, head)["node"] == "false"

    base, head = commit(repo, {"modules/staging-access-gate/main.tf": "# changed\n"})
    assert run(repo, base, head)["node"] == "true"


def test_an_empty_diff_affects_nothing(repo):
    """Base equal to head is a known diff of zero files, not an unknown one."""
    head = git(repo, "rev-parse", "HEAD")
    result = run(repo, head, head)
    assert json.loads(result["modules"]) == []
    assert json.loads(result["validate"]) == []
    assert json.loads(result["test"]) == []
    assert result["all"] == "false"
    assert result["any"] == "false"
    assert result["node"] == "false"


def test_an_empty_base_yields_every_module(repo):
    """An empty base means the diff cannot be trusted, so nothing is skipped."""
    head = git(repo, "rev-parse", "HEAD")
    result = run(repo, "", head)
    assert result["all"] == "true"
    assert len(json.loads(result["modules"])) == 3


def test_the_zero_sha_yields_every_module(repo):
    """A first push carries the zero sha as `github.event.before`."""
    head = git(repo, "rev-parse", "HEAD")
    result = run(repo, "0" * 40, head)
    assert result["all"] == "true"
    assert result["node"] == "true"


def test_a_base_that_is_not_an_ancestor_yields_every_module(repo):
    """A force push leaves a base off the branch, and a plain diff would under-report."""
    git(repo, "checkout", "-q", "-b", "side")
    write(repo, "modules/http-api/main.tf", "# side\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "side")
    side = git(repo, "rev-parse", "HEAD")
    git(repo, "checkout", "-q", "main")
    write(repo, "modules/lambda-function/main.tf", "# main\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "main")
    head = git(repo, "rev-parse", "HEAD")

    result = run(repo, side, head)
    assert result["all"] == "true"
    assert "ancestor" in result["reason"]


def test_the_skip_list_is_dropped_from_validate(repo):
    """A module needing a caller supplied provider alias cannot validate standalone."""
    write(repo, "modules/staging-dns/main.tf", 'resource "null_resource" "a" {}\n')
    write(repo, "modules/staging-dns/tests/basic.tftest.hcl", 'run "ok" {\n  command = plan\n}\n')
    write(
        repo,
        "examples/staging-dns-basic/main.tf",
        'module "under_test" {\n  source = "../../modules/staging-dns"\n}\n',
    )
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "dns")

    base, head = commit(repo, {"modules/staging-dns/main.tf": "# changed\n"})
    result = run(repo, base, head)
    assert json.loads(result["modules"]) == ["staging-dns"]
    assert "modules/staging-dns" not in json.loads(result["validate"])
    assert json.loads(result["test"]) == ["modules/staging-dns"]


def test_a_module_without_tests_is_an_error(repo):
    """Every module must ship a suite, which the old discover job also enforced."""
    write(repo, "modules/orphan/main.tf", 'resource "null_resource" "a" {}\n')
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "orphan")

    base, head = commit(repo, {"modules/http-api/main.tf": "# changed\n"})
    assert run(repo, base, head)["_code"] == 1


def test_the_step_summary_holds_a_path_to_modules_table(repo):
    """The summary is the record of why a module was or was not selected."""
    base, head = commit(
        repo,
        {
            "modules/http-api/main.tf": "# changed\n",
            "examples/lambda-function-image/main.tf": "# changed\n",
        },
    )
    summary = run(repo, base, head)["_summary"]
    assert "## Affected modules" in summary
    assert "| Changed path | Modules |" in summary
    assert "modules/http-api/main.tf" in summary
    assert "examples/lambda-function-image/main.tf" in summary


def test_the_real_repository_maps_every_example_to_a_module():
    """A guard on this repository's own layout, not the fixture's."""
    repo_root = Path(__file__).resolve().parents[2]
    modules = affected_modules.discover_modules(repo_root)
    examples = affected_modules.discover_examples(repo_root)
    assert modules and examples
    unowned = [
        example for example in examples if affected_modules.example_owner(example, modules) is None
    ]
    assert unowned == []
