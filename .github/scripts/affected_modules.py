"""Decide which modules a diff affects, and which directories CI therefore runs.

A module is an immediate subdirectory of `modules/`. Every changed path is
attributed to the modules it can reach: a file under `modules/<name>/` belongs to
that module, a file under `examples/<name>-<variant>/` belongs to the module its
directory name is prefixed with, and anything that can move every module at once
belongs to all of them. A module another module pulls in through a relative
`source = "../x"` path also drags in its dependents, so a change to a shared
module still runs whoever embeds it.

The resulting module set drives three matrices: the directories to validate
(each affected module plus its examples, minus the ones needing a caller supplied
provider alias), the modules to test, and whether the node suite has to run. A
base that cannot be resolved is reported as unknown, which yields every module.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

VALIDATE_SKIP = ("modules/acm-certificate", "modules/staging-dns")
"""Directories that cannot validate standalone; they need a caller supplied alias."""

FULL_PATHS = (
    ".github/workflows/terraform-ci.yml",
    ".github/scripts/affected_modules.py",
    ".github/scripts/test_affected_modules.py",
    ".github/scripts/local_module_override.py",
)
"""Files whose change can alter how every module is built, tested or validated."""

NODE_MODULE = "staging-access-gate"
"""The one module carrying a node suite alongside its terraform tests."""

RELATIVE_SOURCE_RE = re.compile(r'^\s*source\s*=\s*"(\.\.[^"]*)"\s*$')
"""A module block pointing at a sibling directory rather than the registry."""


class Unknown(Exception):
    """The diff could not be computed, so every module has to be assumed affected."""


def _run(args, cwd):
    """Run a git command, returning stdout, or raise `Unknown` if it fails."""
    try:
        done = subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=False)
    except OSError as error:
        raise Unknown(f"could not run {' '.join(args)}: {error}") from error
    if done.returncode != 0:
        raise Unknown(f"{' '.join(args)} failed: {done.stderr.strip() or done.stdout.strip()}")
    return done.stdout


def _have(ref, repo_root):
    """Whether the ref resolves to an object already present locally."""
    try:
        _run(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], repo_root)
    except Unknown:
        return False
    return True


def changed_paths(base, head, repo_root):
    """Repo-relative paths changed between base and head, with a fetch if needed.

    Raises `Unknown` when base is empty, is the all-zero sha a first push carries,
    cannot be resolved even after fetching, or is not an ancestor of head, since a
    diff against an unrelated commit would silently under-report.
    """
    if not base:
        raise Unknown("base is empty, so the diff is unknown")
    if set(base) == {"0"}:
        raise Unknown("base is the zero sha, so the diff is unknown")

    if not _have(base, repo_root):
        try:
            _run(["git", "fetch", "--no-tags", "--depth=1", "origin", base], repo_root)
        except Unknown:
            pass
    if not _have(base, repo_root):
        raise Unknown(f"base {base} could not be resolved, even after a fetch")
    if not _have(head, repo_root):
        raise Unknown(f"head {head} could not be resolved")

    try:
        _run(["git", "merge-base", "--is-ancestor", base, head], repo_root)
    except Unknown as error:
        raise Unknown(f"base {base} is not an ancestor of {head}") from error

    output = _run(["git", "diff", "--name-only", base, head], repo_root)
    return [line for line in output.splitlines() if line.strip()]


def discover_modules(repo_root):
    """Module names: immediate subdirectories of `modules/`."""
    modules_dir = repo_root / "modules"
    if not modules_dir.is_dir():
        return []
    return sorted(
        path.name
        for path in modules_dir.iterdir()
        if path.is_dir() and not path.name.startswith(".")
    )


def discover_examples(repo_root):
    """Example names: immediate subdirectories of `examples/`."""
    examples_dir = repo_root / "examples"
    if not examples_dir.is_dir():
        return []
    return sorted(
        path.name
        for path in examples_dir.iterdir()
        if path.is_dir() and not path.name.startswith(".")
    )


def example_owner(example, modules):
    """The module an example belongs to: the longest module name it is prefixed with.

    `lambda-function-image` belongs to `lambda-function`, never to a shorter name
    that happens to also be a prefix, so the longest match is the only safe read.
    """
    best = None
    for module in modules:
        if example == module or example.startswith(module + "-"):
            if best is None or len(module) > len(best):
                best = module
    return best


def build_dependents(repo_root, modules):
    """Map each module to the modules that embed it through a relative source.

    The map is transitive, so changing a module deep in a chain still reaches
    everyone above it. Empty when no module references another, which is the
    current shape of this repository.
    """
    modules_dir = repo_root / "modules"
    direct = {module: set() for module in modules}
    for module in modules:
        root = modules_dir / module
        for path in sorted(root.rglob("*.tf")):
            try:
                text = path.read_text(encoding="utf-8")
            except OSError:
                continue
            for line in text.splitlines():
                match = RELATIVE_SOURCE_RE.match(line)
                if not match:
                    continue
                target = (path.parent / match.group(1)).resolve()
                try:
                    relative = target.relative_to(modules_dir.resolve())
                except ValueError:
                    continue
                parts = relative.parts
                if len(parts) == 1 and parts[0] in direct and parts[0] != module:
                    direct[parts[0]].add(module)

    dependents = {}
    for module in modules:
        seen, stack = set(), list(direct[module])
        while stack:
            current = stack.pop()
            if current in seen:
                continue
            seen.add(current)
            stack.extend(direct.get(current, ()))
        seen.discard(module)
        dependents[module] = seen
    return dependents


def attribute(paths, modules, examples):
    """Map each changed path to the modules it directly affects, before dependents.

    Returns the per-path attribution and whether every module is forced.
    """
    all_modules = set(modules)
    attribution = {}
    forced = False

    for path in paths:
        if path in FULL_PATHS:
            attribution[path] = ("workflow", set(all_modules))
            forced = True
            continue

        parts = path.split("/")

        if parts[0] == "modules":
            if len(parts) >= 3 and parts[1] in all_modules:
                attribution[path] = ("module", {parts[1]})
            else:
                attribution[path] = ("modules-root", set(all_modules))
                forced = True
            continue

        if parts[0] == "examples":
            if len(parts) >= 3 and parts[1] in examples:
                owner = example_owner(parts[1], modules)
                if owner is None:
                    attribution[path] = ("example-unowned", set(all_modules))
                    forced = True
                else:
                    attribution[path] = ("example", {owner})
            else:
                attribution[path] = ("examples-root", set(all_modules))
                forced = True
            continue

        attribution[path] = ("outside", set(all_modules))
        forced = True

    return attribution, forced


def select_directories(affected, modules, examples, repo_root):
    """The validate directories, test modules and node flag for an affected set.

    A module is validated and tested when it is affected; an example is validated
    when its owning module is. The skip list drops the directories that cannot
    stand alone, and only a module holding a `tests` directory can be tested.
    """
    validate = []
    for module in modules:
        if module not in affected:
            continue
        directory = f"modules/{module}"
        if directory not in VALIDATE_SKIP:
            validate.append(directory)
    for example in examples:
        owner = example_owner(example, modules)
        if owner is None or owner in affected:
            directory = f"examples/{example}"
            if directory not in VALIDATE_SKIP:
                validate.append(directory)

    tests = [
        f"modules/{module}"
        for module in modules
        if module in affected and (repo_root / "modules" / module / "tests").is_dir()
    ]

    node = NODE_MODULE in affected
    return validate, tests, node


def untested_modules(repo_root, modules):
    """Modules shipping no `tests` directory, which the workflow treats as an error."""
    return [
        module
        for module in modules
        if not (repo_root / "modules" / module / "tests").is_dir()
    ]


def render_summary(attribution, reason, affected, all_flag, validate, tests, node):
    """The `$GITHUB_STEP_SUMMARY` markdown: the verdict, then path to modules."""
    lines = ["## Affected modules", "", reason, ""]
    lines.append("| Field | Value |")
    lines.append("| --- | --- |")
    lines.append(f"| modules | `{json.dumps(affected)}` |")
    lines.append(f"| all | `{str(all_flag).lower()}` |")
    lines.append(f"| validate | {len(validate)} directories |")
    lines.append(f"| test | {len(tests)} modules |")
    lines.append(f"| node | `{str(node).lower()}` |")
    lines.append("")

    if attribution:
        lines.append("| Changed path | Modules |")
        lines.append("| --- | --- |")
        for path in sorted(attribution):
            label, owners = attribution[path]
            if owners:
                rendered = ", ".join(f"`{name}`" for name in sorted(owners))
            else:
                rendered = "_none_"
            lines.append(f"| `{path}` | {rendered} <sub>{label}</sub> |")
    else:
        lines.append("No changed paths were attributed.")
    lines.append("")
    return "\n".join(lines)


def write_outputs(values, summary):
    """Write the job outputs and append the step summary, when running under Actions."""
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(summary + "\n")


def main(argv=None):
    """Resolve the affected modules and emit the resolve job's outputs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--repo-root", default=".")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()
    modules = discover_modules(repo_root)
    examples = discover_examples(repo_root)

    missing = untested_modules(repo_root, modules)
    for module in missing:
        print(
            f"::error::modules/{module} has no tests directory; "
            "every module must ship a .tftest.hcl suite"
        )
    if missing:
        return 1

    unknown_reason = ""
    try:
        paths = changed_paths(args.base, args.head, repo_root)
    except Unknown as error:
        unknown_reason = str(error)
        paths = []

    if unknown_reason:
        affected_set = set(modules)
        all_flag = True
        attribution = {}
        reason = f"All {len(modules)} modules: {unknown_reason}."
    elif not modules:
        affected_set = set()
        all_flag = False
        attribution = {}
        reason = "No modules found under modules/."
    else:
        attribution, forced = attribute(paths, modules, examples)
        direct = set()
        for _label, owners in attribution.values():
            direct |= owners

        dependents = build_dependents(repo_root, modules)
        affected_set = set(direct)
        for module in direct:
            affected_set |= dependents.get(module, set())

        all_flag = forced or (bool(modules) and affected_set == set(modules))

        if not paths:
            reason = "No files changed, so no module is affected."
        elif all_flag:
            reason = f"All {len(modules)} modules are affected by {len(paths)} changed file(s)."
        elif affected_set:
            reason = (
                f"{len(affected_set)} of {len(modules)} modules affected by "
                f"{len(paths)} changed file(s): {', '.join(sorted(affected_set))}."
            )
        else:
            reason = f"No module is affected by the {len(paths)} changed file(s)."

    affected = [module for module in modules if module in affected_set]
    validate, tests, node = select_directories(affected_set, modules, examples, repo_root)

    values = {
        "modules": json.dumps(affected),
        "all": str(bool(all_flag)).lower(),
        "any": str(bool(affected)).lower(),
        "validate": json.dumps(validate),
        "test": json.dumps(tests),
        "node": str(bool(node)).lower(),
        "reason": reason,
    }

    summary = render_summary(attribution, reason, affected, all_flag, validate, tests, node)
    write_outputs(values, summary)

    print(reason)
    print(f"modules={values['modules']}")
    print(f"all={values['all']} any={values['any']} node={values['node']}")
    print(f"validate: {len(validate)} directories")
    print(f"test: {len(tests)} modules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
