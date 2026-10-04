"""Prints the GitHub "list pull request files" response for a local diff.

Usage: files.py REPO BASE HEAD. NOPATCH (comma-separated file names) drops
the patch of those files, as GitHub does for large diffs.
"""
import json
import os
import subprocess
import sys

repo, base, head = sys.argv[1:4]
nopatch = set(filter(None, os.environ.get("NOPATCH", "").split(",")))


def git(*args):
    return subprocess.run(
        ["git", "-C", repo, "-c", "core.quotePath=false", *args],
        capture_output=True, check=True,
    ).stdout.decode("utf-8", "surrogateescape")


statuses = {"A": "added", "D": "removed", "M": "modified", "T": "changed"}
fields = git("diff", "-z", "--name-status", "-M", base, head).split("\0")
out = []
i = 0
while i < len(fields) - 1:
    status = fields[i]
    if status.startswith("R"):
        entry = {"status": "renamed", "previous_filename": fields[i + 1], "filename": fields[i + 2]}
        paths = [fields[i + 1], fields[i + 2]]
        i += 3
    else:
        entry = {"status": statuses[status[0]], "filename": fields[i + 1]}
        paths = [fields[i + 1]]
        i += 2
    diff = git("diff", "-M", base, head, "--", *paths)
    if "\n@@" in diff and "Binary files" not in diff and entry["filename"] not in nopatch:
        entry["patch"] = diff[diff.index("\n@@") + 1:].rstrip("\n")
    out.append(entry)
json.dump(out, sys.stdout)
