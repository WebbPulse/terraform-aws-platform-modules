#!/usr/bin/env python3
"""Repoint registry module sources at this checkout so CI can init without a token.

Rewrites source and drops version in the working copy only, so an example validates
against the module code the pull request changes rather than the last release.
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
    """Repoint every registry module source in one file and return how many were changed."""
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

        while i < len(lines) and VERSION_RE.match(lines[i].rstrip("\n")):
            i += 1

    if count:
        path.write_text("".join(out))
    return count


def main():
    """Repoint every .tf file in the example directory named on the command line."""
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
