#!/usr/bin/env python3
"""Track Toastty's adopted Ghostty base without updating application source."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHA = re.compile(r"[0-9a-f]{40}")
ENGINE_FILES = {
    "upstream.json", "scripts/upstream.py", "scripts/tests/test_upstream.py",
    "scripts/build.sh", "scripts/test.sh", "scripts/test-engine.sh",
    ".github/workflows/ci.yml", ".github/workflows/nightly.yml",
}


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def manifest(root):
    data = json.loads((root / "upstream.json").read_text())
    if set(data) != {"repository", "branch", "commit", "zig_version"}:
        raise ValueError("upstream.json must contain repository, branch, commit, and zig_version")
    if data["repository"] != "ghostty-org/ghostty":
        raise ValueError("The tracked upstream must be ghostty-org/ghostty")
    if not isinstance(data["commit"], str) or not SHA.fullmatch(data["commit"]):
        raise ValueError("Pin the adopted upstream to a full commit SHA")
    branch = data["branch"]
    if not isinstance(branch, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9/_.-]*", branch):
        raise ValueError("Invalid upstream branch")
    git(root, "check-ref-format", "refs/heads/" + branch)
    version = data["zig_version"]
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.+-]+)?", version):
        raise ValueError("Pin Zig to a specific version")
    minimum = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', (root / "build.zig.zon").read_text())
    if minimum is None or minimum[1] != version:
        raise ValueError("Zig pin must match build.zig.zon's minimum_zig_version")
    return data


def check_history(root, data):
    # A claimed upstream upgrade must actually be part of this fork's history.
    subprocess.run(["git", "merge-base", "--is-ancestor", data["commit"], "HEAD"], cwd=root, check=True)


def changed_paths(root, base, head="HEAD"):
    output = git(root, "diff", "--name-only", "--no-renames", "-z", base, head)
    return set(output.rstrip("\0").split("\0")) if output else set()


def engine_changes(paths):
    return any(path in ENGINE_FILES or path.startswith(("src/", "include/", "pkg/", "vendor/", "test/", "build.zig"))
               for path in paths)


def ci_scope(root, event_name, event):
    if event_name == "workflow_dispatch":
        return True
    if event_name == "pull_request":
        base = event["pull_request"]["base"]["sha"]
    elif event_name == "push":
        base = event["before"]
        if base == "0" * 40:
            # New branches have no previous push SHA. Compare their complete
            # changes with main, not just the last commit in the branch.
            try:
                base = git(root, "merge-base", "HEAD", "refs/remotes/origin/main")
            except subprocess.CalledProcessError:
                return True
    else:
        raise ValueError("Unsupported CI event: " + event_name)
    if not SHA.fullmatch(base):
        raise ValueError("CI comparison base must be a full commit SHA")
    try:
        return engine_changes(changed_paths(root, base))
    except subprocess.CalledProcessError:
        # After a force-push, the previous SHA may no longer be fetched by
        # checkout. An unavailable range must run every suite, never skip it.
        print("Change range unavailable; running all engine tests", file=sys.stderr)
        return True


def markdown(text):
    # Commit titles and paths are data, including when rendered in a job summary.
    return re.sub(r"([\\`*_{}\[\]()<>#!|])", r"\\\1", " ".join(text.split()))


def report(root, data):
    check_history(root, data)
    remote = "https://github.com/" + data["repository"] + ".git"
    subprocess.run(["git", "fetch", "--no-tags", remote, data["branch"]], cwd=root, check=True)
    candidate = git(root, "rev-parse", "FETCH_HEAD^{commit}")
    return render_report(root, data, candidate)


def render_report(root, data, candidate):
    base = data["commit"]
    behind, ahead = map(int, git(root, "rev-list", "--left-right", "--count", base + "..." + candidate).split())
    changed = changed_paths(root, base, candidate)
    overlap = sorted(changed & changed_paths(root, base))
    url = "https://github.com/" + data["repository"]
    lines = [
        "# Ghostty upstream report", "",
        f"Adopted base: [`{base}`]({url}/commit/{base})  ",
        f"Observed {markdown(data['branch'])}: [`{candidate}`]({url}/commit/{candidate})  ",
        f"Pinned Zig: `{data['zig_version']}`", "",
        f"Upstream has **{ahead} commits** outside the adopted base; **{len(changed)} files** differ.",
    ]
    if behind:
        lines += ["", f"**Not a forward update:** {behind} adopted commits are absent from this candidate. Review the history before choosing an upgrade."]
    elif not ahead:
        lines += ["", "The tracked upstream branch is already at the adopted base."]
    lines += [
        "", f"[Full comparison]({url}/compare/{base}...{candidate}) · "
        "[Stable release notes](https://ghostty.org/docs/install/release-notes)",
        "", "This is an observation of the upstream branch, not an approved engine upgrade. "
        "Prefer a suitable newer stable release when available; review and test any selected commit.",
        "", "## Changed areas", "",
    ]
    groups = {
        "Engine and C API": ("src/", "include/"),
        "Build and dependencies": ("pkg/", "vendor/", "build.zig"),
        "macOS app": ("macos/",),
    }
    for title, prefixes in groups.items():
        lines.append(f"- {title}: {sum(path.startswith(prefixes) for path in changed)} files")
    lines += ["", "## Files changed both upstream and in Toastty", "",
              "These need attention during integration; overlapping paths do not necessarily mean merge conflicts.", ""]
    lines += ["- " + markdown(path) for path in overlap[:30]] or ["- None"]
    if len(overlap) > 30:
        lines.append(f"- Showing 30 of {len(overlap)} overlapping paths; inspect the full diff during the upgrade.")
    lines += ["", "## Recent upstream commits", ""]
    commits = git(root, "log", "--max-count=25", "--format=%H%x09%s", base + ".." + candidate)
    for line in commits.splitlines():
        sha, title = line.split("\t", 1)
        lines.append(f"- [`{sha[:9]}`]({url}/commit/{sha}) {markdown(title)}")
    if not commits:
        lines.append("- None")
    elif ahead > 25:
        lines.append(f"- Showing the latest 25 of {ahead} commits; use the full comparison for the complete range.")
    lines += ["", "No source files, branches, or upstream pins were changed. "
              "Follow `docs/upstream-maintenance.md` to prepare a reviewed upgrade PR.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check")
    check.add_argument("--verify-history", action="store_true", help="requires full Git history")
    check.add_argument("--github-output", type=Path)
    commands.add_parser("zig-version")
    scope = commands.add_parser("ci-scope")
    scope.add_argument("--github-output", type=Path, required=True)
    summary = commands.add_parser("report")
    summary.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = manifest(ROOT)
    if args.command == "zig-version":
        print(data["zig_version"])
    elif args.command == "check":
        if args.verify_history:
            check_history(ROOT, data)
        if args.github_output:
            with args.github_output.open("a") as output:
                output.write("zig-version=" + data["zig_version"] + "\n")
        print(f"Upstream manifest valid: {data['commit']}, Zig {data['zig_version']}")
    elif args.command == "ci-scope":
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        needed = ci_scope(ROOT, os.environ["GITHUB_EVENT_NAME"], event)
        with args.github_output.open("a") as output:
            output.write("engine-tests=" + str(needed).lower() + "\n")
        print("Engine tests required" if needed else "No engine or engine-test infrastructure changes")
    elif args.command == "report":
        args.output.write_text(report(ROOT, data))
        print(f"Wrote upstream report to {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
