#!/usr/bin/env python3
"""Writes the release notes HTML Sparkle shows in its update window: the notes
of every release up to HEAD's, newest first, from the v* tag messages that
next-release.py writes. Each release is a section tagged with its build number;
Sparkle marks the section of the installed build, and the style hides it and
everything older, so the window lists exactly what updating brings. Sections
are "## " headings and "- " items, in the system font, readable in light and
dark mode. Commit hashes are left out; they mean nothing to users.

  scripts/notes-html.py > notes.html
"""
import html
import re
import subprocess

STYLE = ("<style>:root{color-scheme:light dark}"
         "body{font:13px -apple-system,sans-serif;margin:12px 16px}"
         "h2{font-size:15px;margin:16px 0 4px}section:first-of-type h2{margin-top:0}"
         "h3{font-size:13px;margin:10px 0 4px}"
         "ul{margin:0;padding-left:20px}li{margin:2px 0}"
         ".sparkle-installed-version,.sparkle-installed-version~section{display:none}</style>")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def notes_html(notes):
    out, in_list = [], False
    for line in notes.splitlines():
        line = line.strip()
        item = line.startswith("- ")
        if in_list and not item:
            out.append("</ul>")
            in_list = False
        if not line:
            continue
        if line.startswith("## "):
            out.append(f"<h3>{html.escape(line[3:])}</h3>")
        elif item:
            if not in_list:
                out.append("<ul>")
                in_list = True
            text = re.sub(r"\s*\([0-9a-f]{7,40}\)$", "", line[2:])
            out.append(f"<li>{html.escape(text[:1].upper() + text[1:])}</li>")
        else:
            out.append(f"<p>{html.escape(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "".join(out)


def main():
    out = [STYLE]
    for tag in git("tag", "--merged", "HEAD", "--list", "v[0-9]*.[0-9]*.[0-9]*", "--sort=-v:refname").split():
        # The build number the release workflow gave this release, which Sparkle reports as the installed version.
        build = git("rev-list", "--count", tag).strip()
        notes = git("for-each-ref", "--format=%(contents)", f"refs/tags/{tag}")
        out.append(f'<section data-sparkle-version="{build}"><h2>Imla {html.escape(tag[1:])}</h2>{notes_html(notes)}</section>')
    print("".join(out))


if __name__ == "__main__":
    main()
