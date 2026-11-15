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

p = argparse.ArgumentParser()
for name in ("version", "build-number", "url", "signature", "length", "appcast"):
    p.add_argument(f"--{name}", required=True)
p.add_argument("--notes", default="")
a = p.parse_args()

content = open(a.appcast, encoding="utf-8").read()
if f"<sparkle:shortVersionString>{a.version}<" in content:
    raise SystemExit(f"appcast already has {a.version}")
date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
notes = md_to_html(a.notes) or f"<p>Tiny Usage {html.escape(a.version)}</p>"
item = f"""    <item>
      <title>Tiny Usage {a.version}</title>
      <sparkle:version>{a.build_number}</sparkle:version>
      <sparkle:shortVersionString>{a.version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>{date}</pubDate>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure url="{html.escape(a.url)}" sparkle:edSignature="{a.signature}" length="{a.length}" type="application/octet-stream"/>
    </item>
"""
at = content.find("    <item>")
if at == -1: at = content.find("  </channel>")
open(a.appcast, "w", encoding="utf-8").write(content[:at] + item + content[at:])
