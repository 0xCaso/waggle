#!/usr/bin/env python3
"""Self-check a diagram file (.svg or .html), with no third-party packages.

Adapted for Waggle from self_check.py in diagram-design by Cathryn Lavery (MIT).
Waggle removed the motion checks and the Google Fonts allowance. A Waggle diagram
is static, has no script and loads nothing from the network. The fonts come from
tokens.css, which is a separate file.

Checks:
  - every non-hidden <svg> has role="img", a <title> as its first child, a <desc>,
    prefixed ids, and an aria-labelledby that names title then desc
  - no <script>, <iframe>, <object>, <embed>, <base>, no on* attribute, no srcdoc
  - no remote reference (http, https, //) in any attribute or in CSS
  - no CSS @import, no non-fragment url(), no image-set()

Usage:
    python3 scripts/self_check.py diagram.svg [more files]
"""

from __future__ import annotations

import argparse
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

REFERENCE_ATTRS = {"src", "href", "xlink:href", "poster", "srcset", "action", "formaction"}
CSS_ATTRS = {"style", "fill", "stroke", "filter", "clip-path", "mask", "marker", "marker-start", "marker-mid", "marker-end", "cursor"}
BLOCKED_TAGS = {"script", "iframe", "object", "embed", "base"}
CSS_ESCAPE_RE = re.compile(r"\\(?:([0-9a-fA-F]{1,6})[ \t\r\n\f]?|(.))", re.DOTALL)
CSS_URL_RE = re.compile(r"url\(\s*([^)]+?)\s*\)", re.IGNORECASE)


class Parser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.svgs: list[dict] = []
        self.errors: list[str] = []
        self.styles: list[str] = []
        self.css_attrs: list[str] = []
        self._depth = 0
        self._svg: dict | None = None
        self._capture: str | None = None
        self._in_style = False

    def handle_starttag(self, tag, attrs):
        tag = tag.casefold()
        data = {}
        for key, value in attrs:
            data.setdefault(key.casefold(), value or "")
        if tag in BLOCKED_TAGS:
            self.errors.append(f"<{tag}> is not allowed in a diagram")
        for key, value in data.items():
            if key.startswith("on"):
                self.errors.append(f"executable attribute {key} on <{tag}>")
            if key == "srcdoc":
                self.errors.append(f"srcdoc attribute on <{tag}>")
            if key in REFERENCE_ATTRS:
                self.check_reference(tag, value)
            if key in CSS_ATTRS:
                self.css_attrs.append(value)
        if tag == "style":
            self._in_style = True
        if tag == "svg" and self._depth == 0:
            self._depth = 1
            self._svg = {"attrs": data, "first": None, "title": None, "desc": None}
            self.svgs.append(self._svg)
            return
        if self._depth:
            self._depth += 1
            if self._depth == 2 and self._svg["first"] is None:
                self._svg["first"] = tag
            if self._depth == 2 and tag in {"title", "desc"}:
                self._svg[tag] = {"id": data.get("id", ""), "text": ""}
                self._capture = tag

    def handle_endtag(self, tag):
        tag = tag.casefold()
        if tag == "style":
            self._in_style = False
        if self._depth:
            if tag in {"title", "desc"}:
                self._capture = None
            self._depth -= 1
            if self._depth == 0:
                self._svg = None

    def handle_data(self, data):
        if self._in_style:
            self.styles.append(data)
        if self._capture and self._svg and self._svg[self._capture] is not None:
            self._svg[self._capture]["text"] += data

    def check_reference(self, tag: str, value: str) -> None:
        stripped = value.strip()
        lowered = stripped.casefold()
        if not stripped or stripped.startswith("#"):
            return
        if lowered.startswith(("javascript:", "data:text/html")):
            self.errors.append(f"executable URL on <{tag}>: {stripped[:80]}")
        elif lowered.startswith(("http://", "https://", "//")):
            self.errors.append(f"remote reference on <{tag}>: {stripped[:80]}")
        elif lowered.startswith("data:") and not lowered.startswith("data:image/"):
            self.errors.append(f"non-image data URL on <{tag}>: {stripped[:80]}")


def unescape_css(source: str) -> str:
    def replace(match: re.Match[str]) -> str:
        if match.group(1) is None:
            return match.group(2)
        code = int(match.group(1), 16)
        return "\N{REPLACEMENT CHARACTER}" if code == 0 or code > 0x10FFFF else chr(code)

    return CSS_ESCAPE_RE.sub(replace, source)


def check_css(parser: Parser) -> None:
    source = unescape_css("\n".join(parser.styles + parser.css_attrs))
    if re.search(r"@import\b", source, re.IGNORECASE):
        parser.errors.append("CSS @import is not allowed in a diagram file; put fonts in tokens.css")
    for match in CSS_URL_RE.finditer(source):
        if not match.group(1).strip().strip("'\"").strip().startswith("#"):
            parser.errors.append("non-fragment CSS url() is not allowed")
    if re.search(r"(?:-webkit-)?image-set\s*\(", source, re.IGNORECASE):
        parser.errors.append("CSS image-set() is not allowed")
    if re.search(r"(?:https?:)?//", source) and not parser.errors:
        parser.errors.append("remote reference in CSS is not allowed")


def check_svgs(parser: Parser) -> None:
    shown = [s for s in parser.svgs if s["attrs"].get("aria-hidden", "").casefold() != "true"]
    if not shown:
        parser.errors.append("the file needs one accessible (not aria-hidden) SVG")
    for n, svg in enumerate(shown, 1):
        attrs, title, desc = svg["attrs"], svg["title"] or {}, svg["desc"] or {}
        if attrs.get("role") != "img":
            parser.errors.append(f"svg {n} needs role=img")
        if svg["first"] != "title":
            parser.errors.append(f"svg {n}: <title> must be the first child")
        if not title.get("text", "").strip() or not desc.get("text", "").strip():
            parser.errors.append(f"svg {n} needs a filled <title> and <desc>")
        if title.get("id", "") in {"", "title"} or desc.get("id", "") in {"", "desc"}:
            parser.errors.append(f"svg {n}: title and desc ids must have a diagram prefix, never bare")
        if attrs.get("aria-labelledby", "").split() != [title.get("id", ""), desc.get("id", "")]:
            parser.errors.append(f"svg {n}: aria-labelledby must name the title id, then the desc id")


def verify(path: Path) -> list[str]:
    parser = Parser()
    parser.feed(path.read_text(encoding="utf-8"))
    parser.close()
    check_css(parser)
    check_svgs(parser)
    return parser.errors


def main() -> int:
    argument_parser = argparse.ArgumentParser(description=__doc__)
    argument_parser.add_argument("files", nargs="+", type=Path)
    failed = False
    for path in argument_parser.parse_args().files:
        try:
            errors = verify(path)
        except (OSError, UnicodeError) as exc:
            errors = [str(exc)]
        print(f"{'FAIL' if errors else 'OK'} {path}")
        for error in errors:
            print(f"  - {error}")
        failed = failed or bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
