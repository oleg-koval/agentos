#!/usr/bin/env python3
"""Validate the dependency-free AgentOS landing page."""

from html.parser import HTMLParser
import json
from pathlib import Path
from urllib.parse import urlparse
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.headings: list[int] = []
        self.ids: set[str] = set()
        self.fragments: set[str] = set()
        self.local_paths: set[str] = set()
        self.json_ld: list[str] = []
        self._in_json_ld = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            self.headings.append(int(tag[1]))
        if identifier := values.get("id"):
            self.ids.add(identifier)
        if tag == "a" and (href := values.get("href")):
            if href.startswith("#"):
                self.fragments.add(href[1:])
            else:
                self._record_local_path(href)
        if tag in {"img", "script"} and (src := values.get("src")):
            self._record_local_path(src)
        if tag == "link" and (href := values.get("href")):
            self._record_local_path(href)
        if tag == "script" and values.get("type") == "application/ld+json":
            self._in_json_ld = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "script":
            self._in_json_ld = False

    def handle_data(self, data: str) -> None:
        if self._in_json_ld:
            self.json_ld.append(data)

    def _record_local_path(self, value: str) -> None:
        parsed = urlparse(value)
        if not parsed.scheme and not parsed.netloc and not value.startswith(("/", "#")):
            self.local_paths.add(parsed.path)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


pages = sorted(SITE.glob("*.html"))
require({page.name for page in pages} >= {"index.html", "install.html", "support.html"}, "friend-facing site routes are incomplete")
parsers: dict[str, PageParser] = {}
for page in pages:
    page_parser = PageParser()
    page_html = page.read_text(encoding="utf-8")
    page_parser.feed(page_html)
    parsers[page.name] = page_parser
    require(page_parser.headings.count(1) == 1, f"{page.name} must contain exactly one h1")
    require(page_parser.headings[0] == 1, f"{page.name} must start with an h1")
    require(all(next_level <= level + 1 for level, next_level in zip(page_parser.headings, page_parser.headings[1:])), f"{page.name} heading levels must not skip")
    require(page_parser.fragments <= page_parser.ids, f"{page.name} has missing fragment targets: {sorted(page_parser.fragments - page_parser.ids)}")
    missing = sorted(path for path in page_parser.local_paths if not (SITE / path).is_file())
    require(not missing, f"{page.name} references missing local page asset: {missing}")

index = (SITE / "index.html").read_text(encoding="utf-8")
parser = parsers["index.html"]
require("<title>AgentOS Workstation | Arch Linux Setup &amp; Recovery</title>" in index, "title must match the validated search intent")

structured_data = json.loads("".join(parser.json_ld))
require(structured_data.get("@type") == "SoftwareApplication", "JSON-LD must describe a SoftwareApplication")
require(structured_data.get("operatingSystem") == "Arch Linux", "JSON-LD must name the verified operating system")
require(structured_data.get("url") == "https://oleg-koval.github.io/agentos/", "JSON-LD URL must match the canonical")
require(structured_data.get("license") == "https://github.com/oleg-koval/agentos/blob/main/LICENSE", "JSON-LD must link the repository license")

license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
require("MIT License" in license_text and "Copyright (c) 2026 Oleg Koval" in license_text, "root MIT license must identify the project owner")

ET.parse(SITE / "sitemap.xml")
robots = (SITE / "robots.txt").read_text(encoding="utf-8")
require("Sitemap: https://oleg-koval.github.io/agentos/sitemap.xml" in robots, "robots.txt must advertise the canonical sitemap")
all_html = "\n".join(page.read_text(encoding="utf-8") for page in pages)
require("3060184cfc884d14cb1d54f9ca25144b4e4dba8e" not in all_html.lower(), "site contains a stale signing fingerprint")
require("your-agentos-release-host.example" not in all_html, "site contains a placeholder release host")
require("agentos-repo-public.asc" not in all_html, "site contains a stale public-key asset name")
require("explicit updates" not in all_html.lower() and "no unattended" not in all_html.lower(), "site must not contradict the scheduled stable-update implementation")
require("transactional update" not in all_html.lower(), "site must not overstate the updater's snapshot failure behavior")

print("Landing page validation passed.")
