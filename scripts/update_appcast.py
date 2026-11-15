#!/usr/bin/env python3
"""Prepend a signed release <item> to appcast.xml (newest first) for Sparkle."""
import argparse, datetime, html, re

def md_to_html(text):
    out, in_ul = [], False
    for line in text.strip().splitlines():
        s = html.escape(line.strip())
        s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
        if line.startswith("- "):
            if not in_ul: out.append("<ul>"); in_ul = True
            out.append(f"<li>{s[2:]}</li>")
            continue
        if in_ul: out.append("</ul>"); in_ul = False
        if s: out.append(f"<p>{s}</p>")
    if in_ul: out.append("</ul>")
    return "\n".join(out)

LANGUAGES = {"english": "en", "中文": "zh-Hans"}

def by_language(text):
    """Split a changelog section on its `### English` / `### 中文` headings.
    Returns [(xml:lang or None, markdown)], English first: Sparkle falls back to the first one."""
    parts, lang, lines = [], None, []
    for line in text.strip().splitlines():
        if line.startswith("### "):
            if "\n".join(lines).strip(): parts.append((lang, "\n".join(lines)))
            lang, lines = LANGUAGES.get(line[4:].strip().lower()), []
        else:
            lines.append(line)
    if "\n".join(lines).strip(): parts.append((lang, "\n".join(lines)))
    if any(l is None for l, _ in parts): return [(None, "\n".join(body for _, body in parts))]
    return sorted(parts, key=lambda part: part[0] != "en")

p = argparse.ArgumentParser()
for name in ("version", "build-number", "url", "signature", "length", "appcast"):
    p.add_argument(f"--{name}", required=True)
p.add_argument("--notes", default="")
a = p.parse_args()

content = open(a.appcast, encoding="utf-8").read()
if f"<sparkle:shortVersionString>{a.version}<" in content:
    raise SystemExit(f"appcast already has {a.version}")
date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
notes = by_language(a.notes) or [(None, f"Tiny Usage {a.version}")]
descriptions = "".join(
    f"""      <description{f' xml:lang="{lang}"' if lang else ''}><![CDATA[
{md_to_html(body)}
      ]]></description>
""" for lang, body in notes)
item = f"""    <item>
      <title>Tiny Usage {a.version}</title>
      <sparkle:version>{a.build_number}</sparkle:version>
      <sparkle:shortVersionString>{a.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>{date}</pubDate>
{descriptions}      <enclosure url="{html.escape(a.url)}" sparkle:edSignature="{a.signature}" length="{a.length}" type="application/octet-stream"/>
    </item>
"""
at = content.find("    <item>")
if at == -1: at = content.find("  </channel>")
open(a.appcast, "w", encoding="utf-8").write(content[:at] + item + content[at:])
