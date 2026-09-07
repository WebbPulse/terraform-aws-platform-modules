#!/usr/bin/env python3
"""Repoint registry module sources at this checkout so CI can init without a token.

Examples in this repository reference the published registry address,
app.terraform.io/WebbPulse/platform-modules/aws//modules/<name>, because that is what a
real consumer writes. Resolving that address needs an HCP Terraform API token, and CI
runs with no credentials of any kind.

This rewrites the source and version arguments in place, in the checked out working copy
only, so that terraform init resolves the module from ../../modules/<name>. That is also
strictly more useful than fetching the published version: the pull request gets validated
against the module code it actually changes, not against the last release.

A Terraform override file cannot do this job. An override can replace the value of an
argument but cannot remove one, and leaving a version argument present, even set to null,
makes Terraform insist the source is a registry address.

The edits are never committed; CI throws the working copy away at the end of the job.
"""

import pathlib
import re
import sys

REGISTRY = "app.terraform.io/WebbPulse/platform-modules/aws//modules/"

SOURCE_RE = re.compile(
    r'^(?P<indent>\s*)source(?P<pad>\s*)=\s*"'
    + re.escape(REGISTRY)
    + r'(?P<name>[^"]+)"\s*$'
)
VERSION_RE = re.compile(r'^\s*version\s*=\s*"[^"]*"\s*$')


def rewrite(path, rel_prefix):
    lines = path.read_text().splitlines(keepends=True)
    out = []
    count = 0
    i = 0
    while i < len(lines):
        m = SOURCE_RE.match(lines[i].rstrip("\n"))
        if not m:
            out.append(lines[i])
            i += 1
            continue

        count += 1
        indent, pad, name = m.group("indent"), m.group("pad"), m.group("name")
        out.append(f'{indent}source{pad}= "{rel_prefix}/{name}"\n')
        i += 1

        # Drop the version argument that belongs to this module block. It applies only to
        # registry sources and Terraform rejects it alongside a local path. It sits
        # adjacent to source in every example here, so only the immediate neighbours are
        # considered rather than parsing the whole block.
        while i < len(lines) and VERSION_RE.match(lines[i].rstrip("\n")):
            i += 1

    if count:
        path.write_text("".join(out))
    return count


def main():
    example_dir = pathlib.Path(sys.argv[1])
    depth = len(example_dir.resolve().relative_to(pathlib.Path(sys.argv[2]).resolve()).parts)
    rel_prefix = "/".join([".."] * depth) + "/modules"

    total = 0
    for tf in sorted(example_dir.glob("*.tf")):
        total += rewrite(tf, rel_prefix)

    print(f"{example_dir}: repointed {total} registry module source(s) at {rel_prefix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
