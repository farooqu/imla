#!/usr/bin/env python3
"""Works out the next release from the commits since the last v* tag.

Prints the version, and writes Markdown release notes to the file given as the
first argument. Commits follow Conventional Commits (https://www.conventionalcommits.org):
  feat: ...                         -> minor
  fix: ..., or any other commit     -> patch
  feat!: ..., or "BREAKING CHANGE:" -> major (minor while the version is 0.x)
The first release is 0.1.0. Prints nothing when there's nothing new to release.
"""
import re
import subprocess
import sys

TYPE = re.compile(r"^(?P<type>[a-z]+)(?:\([^)]*\))?(?P<bang>!)?:\s*(?P<text>.+)$")
SECTIONS = [("breaking", "Breaking changes"), ("feat", "Features"), ("fix", "Fixes"), ("other", "Other changes")]
HIDDEN = {"chore", "ci", "build", "style", "test"}  # Kept out of the notes unless breaking.


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def last_tag():
    tags = git("tag", "--merged", "HEAD", "--list", "v[0-9]*.[0-9]*.[0-9]*", "--sort=-v:refname").split()
    return tags[0] if tags else None


def main():
    notes_path = sys.argv[1]
    tag = last_tag()
    log = git("log", "--reverse", "--format=%h%x1f%s%x1f%b%x1e", f"{tag}..HEAD" if tag else "HEAD")
    commits = [c.strip("\n").split("\x1f") for c in log.split("\x1e") if c.strip()]
    if not commits:
        return

    groups = {key: [] for key, _ in SECTIONS}
    bump = "patch"
    for sha, subject, body in commits:
        m = TYPE.match(subject)
        kind, text = (m["type"], m["text"]) if m else ("other", subject)
        breaking = bool(m and m["bang"]) or "BREAKING CHANGE:" in body
        if breaking:
            groups["breaking"].append(f"- {text} ({sha})")
            bump = "major"
        elif kind == "feat":
            groups["feat"].append(f"- {text} ({sha})")
            bump = "minor" if bump == "patch" else bump
        elif kind == "fix":
            groups["fix"].append(f"- {text} ({sha})")
        elif kind not in HIDDEN:
            groups["other"].append(f"- {text} ({sha})")

    if tag is None:
        version = "0.1.0"
    else:
        major, minor, patch = map(int, tag[1:].split("."))
        if bump == "major" and major == 0:
            bump = "minor"
        version = {"major": f"{major + 1}.0.0", "minor": f"{major}.{minor + 1}.0",
                   "patch": f"{major}.{minor}.{patch + 1}"}[bump]

    parts = [f"## {title}\n\n" + "\n".join(groups[key]) for key, title in SECTIONS if groups[key]]
    with open(notes_path, "w") as f:
        f.write("\n\n".join(parts) or "Maintenance release.")
        f.write("\n")
    print(version)


if __name__ == "__main__":
    main()
