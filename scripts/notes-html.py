#!/usr/bin/env python3
"""Turns release notes from next-release.py into the HTML Sparkle shows in its
update window: "## " headings and "- " items, in the system font, readable in
light and dark mode. Commit hashes are left out; they mean nothing to users.

  scripts/notes-html.py notes.md > notes.html
"""
import html
import re
import sys

STYLE = ("<style>:root{color-scheme:light dark}"
         "body{font:13px -apple-system,sans-serif;margin:12px 16px}"
         "h2{font-size:13px;margin:12px 0 4px}h2:first-of-type{margin-top:0}"
         "ul{margin:0;padding-left:20px}li{margin:2px 0}</style>")


def main():
    out, in_list = [STYLE], False
    for line in open(sys.argv[1]).read().splitlines():
        line = line.strip()
        item = line.startswith("- ")
        if in_list and not item:
            out.append("</ul>")
            in_list = False
        if not line:
            continue
        if line.startswith("## "):
            out.append(f"<h2>{html.escape(line[3:])}</h2>")
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
    print("".join(out))


if __name__ == "__main__":
    main()
