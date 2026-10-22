#!/usr/bin/env python3
"""Enforce the design-token rule and keep the token ledger current.

The rule: a Swift file may not invent an appearance value. Colours, fonts,
spacing, radii, strokes, opacities, sizes, shadows, materials and animation
durations come from `uniplayer/DesignTokens.swift`; anything else is a
violation.

The checker tokenises Swift rather than matching lines, so comments, string
literals, multiline calls and nested argument lists are handled structurally.
It also validates the token ledger and the Interface Builder documents.

Usage:
  scripts/check-design-tokens.py            # lint sources and XIBs
  scripts/check-design-tokens.py --ledger   # also verify DESIGN_TOKENS.md
  scripts/check-design-tokens.py --write-ledger
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOT = ROOT / "uniplayer"
TOKEN_FILE = SOURCE_ROOT / "DesignTokens.swift"
LEDGER_FILE = ROOT / "DESIGN_TOKENS.md"

# The only non-system XIB colours allowed. Each entry is keyed by the relative
# path, element key and the exact colour signature, so a new custom colour or a
# changed value fails even in the same file. These four are the default colours
# of the subtitle colour wells, which are user data rather than design values.
XIB_COLOR_EXCEPTIONS = {
    (
        "uniplayer/Base.lproj/PrefSubViewController.xib",
        "color",
        "red=0.05813049898,green=0.055541899059999997,blue=1,alpha=1,colorSpace=calibratedRGB",
    ): "default colour for a subtitle colour well (user data)",
}

XIB_SYSTEM_FONTS = {
    "system",
    "systemBold",
    "smallSystem",
    "smallSystemBold",
    "miniSystem",
    "miniSystemBold",
    "menu",
    "menuBar",
    "message",
    "label",
    "controlContent",
    "cellTitle",
    "palette",
    "title",
    "toolTips",
    "user",
    "userFixedPitch",
}

WEAK_COLOR_MEMBERS = {"primary", "secondary", "tertiary", "tint", "accentColor"}

COLOR_MEMBERS = {
    "white",
    "black",
    "clear",
    "gray",
    "grey",
    "red",
    "blue",
    "green",
    "yellow",
    "orange",
    "purple",
    "pink",
    "teal",
    "indigo",
    "mint",
    "cyan",
    "brown",
    "labelColor",
    "secondaryLabelColor",
    "tertiaryLabelColor",
    "quaternaryLabelColor",
    "disabledControlTextColor",
    "controlTextColor",
    "selectedControlTextColor",
    "controlBackgroundColor",
    "windowBackgroundColor",
    "separatorColor",
    "gridColor",
    "highlightColor",
    "controlAccentColor",
    "textColor",
    "selectedTextColor",
    "systemRed",
    "systemBlue",
    "systemGreen",
    "systemOrange",
}

STYLE_LABELS = {
    "lineWidth",
    "borderWidth",
    "cornerRadius",
    "radius",
    "shadowRadius",
    "shadowBlurRadius",
    "shadowOpacity",
    "rowHeight",
    "estimatedRowHeight",
    "xRadius",
    "yRadius",
    "width",
    "height",
    "minWidth",
    "maxWidth",
    "minHeight",
    "maxHeight",
    "spacing",
    "padding",
    "opacity",
    "alpha",
    "duration",
    "animationDuration",
    "ofSize",
    "size",
    "constant",
    "equalToConstant",
    "greaterThanOrEqualToConstant",
    "lessThanOrEqualToConstant",
    "pointSize",
    "ideal",
    "blur",
}

STYLE_PROPERTIES = {
    "lineWidth",
    "borderWidth",
    "cornerRadius",
    "shadowRadius",
    "shadowBlurRadius",
    "shadowOpacity",
    "rowHeight",
    "minimumThickness",
    "maximumThickness",
    "duration",
}

STYLE_CALLS = {
    "padding",
    "spacing",
    "frame",
    "size",
    "cornerRadius",
    "stroke",
    "strokeBorder",
    "fill",
    "background",
    "foregroundStyle",
    "foregroundColor",
    "tint",
    "shadow",
    "scaleEffect",
    "opacity",
    "offset",
    "position",
    "animation",
    "withAnimation",
    "transition",
    "clipShape",
    "overlay",
    "border",
    "inset",
    "blur",
    "withAlphaComponent",
    "systemFont",
    "boldSystemFont",
    "monospacedSystemFont",
    "monospacedDigitSystemFont",
}

GEOMETRY_CALLS = {"NSSize", "CGSize", "NSMakeSize", "NSRect", "CGRect", "NSMakeRect"}

FONT_CALLS = {
    "systemFont",
    "boldSystemFont",
    "monospacedSystemFont",
    "monospacedDigitSystemFont",
}


@dataclass
class Token:
    kind: str
    text: str
    line: int
    col: int
    start: int
    end: int


@dataclass
class Comment:
    text: str
    line: int
    start: int
    end: int


@dataclass
class Finding:
    line: int
    message: str


class Lexer:
    """A small Swift lexer that is sufficient for style inspection."""

    def __init__(self, source: str):
        self.source = source
        self.n = len(source)
        self.i = 0
        self.line = 1
        self.col = 1
        self.tokens: list[Token] = []
        self.comments: list[Comment] = []

    def advance(self, count: int = 1) -> None:
        for _ in range(count):
            if self.i < self.n:
                if self.source[self.i] == "\n":
                    self.line += 1
                    self.col = 1
                else:
                    self.col += 1
                self.i += 1

    def lex(self) -> tuple[list[Token], list[Comment]]:
        while self.i < self.n:
            c = self.source[self.i]
            if c in " \t\r\n":
                self.advance()
                continue
            if c == "/" and self.i + 1 < self.n and self.source[self.i + 1] == "/":
                self.lex_line_comment()
                continue
            if c == "/" and self.i + 1 < self.n and self.source[self.i + 1] == "*":
                self.lex_block_comment()
                continue
            if c == '"':
                self.lex_string(hashes=0)
                continue
            if c == "#" and self._raw_string_hashes() > 0:
                self.lex_string(hashes=self._raw_string_hashes())
                continue
            if c == "`":
                self.lex_backticked_identifier()
                continue
            if c.isalpha() or c == "_":
                self.lex_identifier()
                continue
            if c.isdigit():
                self.lex_number()
                continue
            self.lex_punctuation()
        return self.tokens, self.comments

    def _raw_string_hashes(self) -> int:
        j = self.i
        while j < self.n and self.source[j] == "#":
            j += 1
        return j - self.i if j < self.n and self.source[j] == '"' else 0

    def lex_line_comment(self) -> None:
        start = self.i
        line = self.line
        while self.i < self.n and self.source[self.i] != "\n":
            self.advance()
        self.comments.append(Comment(self.source[start:self.i], line, start, self.i))

    def lex_block_comment(self) -> None:
        start = self.i
        line = self.line
        depth = 0
        while self.i < self.n:
            if self.source.startswith("/*", self.i):
                depth += 1
                self.advance(2)
            elif self.source.startswith("*/", self.i):
                depth -= 1
                self.advance(2)
                if depth == 0:
                    break
            else:
                self.advance()
        self.comments.append(Comment(self.source[start:self.i], line, start, self.i))

    def lex_string(self, hashes: int) -> None:
        start = self.i
        line = self.line
        if hashes:
            self.advance(hashes)
        multiline = self.source.startswith('"""', self.i)
        quotes = 3 if multiline else 1
        self.advance(quotes)
        closing = ('"""' if multiline else '"') + ("#" * hashes)
        while self.i < self.n:
            if self.source.startswith(closing, self.i):
                self.advance(len(closing))
                break
            if self.source[self.i] == "\\" and hashes == 0:
                # Consume the escape and, for interpolation, the whole balanced
                # expression so braces and quotes inside it stay opaque.
                self.advance()
                if self.i < self.n and self.source[self.i] == "(":
                    self.consume_interpolation()
                continue
            self.advance()
        self.tokens.append(Token("string", self.source[start:self.i], line, 1, start, self.i))

    def consume_interpolation(self) -> None:
        depth = 0
        while self.i < self.n:
            c = self.source[self.i]
            if c == "(":
                depth += 1
                self.advance()
            elif c == ")":
                depth -= 1
                self.advance()
                if depth == 0:
                    return
            elif c == '"':
                self.lex_string(hashes=0)
            else:
                self.advance()

    def lex_backticked_identifier(self) -> None:
        start = self.i
        line = self.line
        self.advance()
        while self.i < self.n and self.source[self.i] != "`":
            self.advance()
        if self.i < self.n:
            self.advance()
        self.tokens.append(Token("id", self.source[start:self.i], line, 1, start, self.i))

    def lex_identifier(self) -> None:
        start = self.i
        line = self.line
        col = self.col
        while self.i < self.n and (self.source[self.i].isalnum() or self.source[self.i] in "_$"):
            self.advance()
        self.tokens.append(Token("id", self.source[start:self.i], line, col, start, self.i))

    def lex_number(self) -> None:
        start = self.i
        line = self.line
        col = self.col
        if self.source.startswith(("0x", "0X"), self.i):
            self.advance(2)
            while self.i < self.n and (self.source[self.i] in "0123456789abcdefABCDEF_"):
                self.advance()
        else:
            while self.i < self.n and (self.source[self.i].isdigit() or self.source[self.i] == "_"):
                self.advance()
            if self.i < self.n and self.source[self.i] == "." and self.i + 1 < self.n and self.source[self.i + 1].isdigit():
                self.advance()
                while self.i < self.n and (self.source[self.i].isdigit() or self.source[self.i] == "_"):
                    self.advance()
            if self.i < self.n and self.source[self.i] in "eE":
                self.advance()
                if self.i < self.n and self.source[self.i] in "+-":
                    self.advance()
                while self.i < self.n and self.source[self.i].isdigit():
                    self.advance()
        self.tokens.append(Token("num", self.source[start:self.i], line, col, start, self.i))

    def lex_punctuation(self) -> None:
        start = self.i
        line = self.line
        col = self.col
        self.advance()
        self.tokens.append(Token("punct", self.source[start:self.i], line, col, start, self.i))


def lex(source: str) -> tuple[list[Token], list[Comment]]:
    return Lexer(source).lex()


def numeric_value(token: Token) -> Decimal | None:
    if token.kind != "num":
        return None
    text = token.text.replace("_", "")
    try:
        if text.lower().startswith("0x"):
            return Decimal(int(text, 16))
        return Decimal(text)
    except (InvalidOperation, ValueError):
        return None


def matching(tokens: list[Token], open_index: int) -> int:
    """Return the index of the token closing the call opened at open_index."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    open_text = tokens[open_index].text
    close_text = pairs[open_text]
    depth = 0
    for i in range(open_index, len(tokens)):
        if tokens[i].text == open_text:
            depth += 1
        elif tokens[i].text == close_text:
            depth -= 1
            if depth == 0:
                return i
    return len(tokens) - 1


def split_arguments(tokens: list[Token], open_index: int, close_index: int) -> list[tuple[int, int]]:
    parts: list[tuple[int, int]] = []
    start = open_index + 1
    depth = 0
    for i in range(open_index + 1, close_index):
        text = tokens[i].text
        if text in "([{":
            depth += 1
        elif text in ")]}":
            depth -= 1
        elif text == "," and depth == 0:
            parts.append((start, i))
            start = i + 1
    if start < close_index:
        parts.append((start, close_index))
    return parts


def previous_significant(tokens: list[Token], index: int) -> int | None:
    for i in range(index - 1, -1, -1):
        return i
    return None


def next_significant(tokens: list[Token], index: int) -> int | None:
    for i in range(index + 1, len(tokens)):
        return i
    return None


def is_call(tokens: list[Token], index: int) -> bool:
    return (
        0 <= index < len(tokens)
        and tokens[index].kind == "id"
        and index + 1 < len(tokens)
        and tokens[index + 1].text == "("
    )


def call_name(tokens: list[Token], index: int) -> str:
    return tokens[index].text


def member_chain(tokens: list[Token], index: int) -> str:
    parts = [tokens[index].text]
    i = index - 1
    while i >= 1 and tokens[i].text == "." and tokens[i - 1].kind == "id":
        parts.insert(0, tokens[i - 1].text)
        i -= 2
    return ".".join(parts)


COLOR_APIS = {
    "foregroundStyle",
    "foregroundColor",
    "fill",
    "stroke",
    "strokeBorder",
    "background",
    "tint",
    "contentTintColor",
    "textColor",
    "backgroundColor",
    "borderColor",
    "shadowColor",
    "fillColor",
    "strokeColor",
    "color",
}


def enclosing_call(tokens: list[Token], index: int) -> str:
    depth = 0
    for i in range(index - 1, -1, -1):
        text = tokens[i].text
        if text in ")]}":
            depth += 1
        elif text in "([{":
            if depth:
                depth -= 1
                continue
            if text != "(":
                return ""
            callee = previous_significant(tokens, i)
            if callee is None or tokens[callee].kind != "id":
                return ""
            return tokens[callee].text
    return ""


def lint_source(source: str, relpath: str) -> list[Finding]:
    tokens, comments = lex(source)
    exempt_lines = {
        comment.line
        for comment in comments
        if "token-exempt:" in comment.text
    }
    findings: list[Finding] = []

    def add(token: Token, message: str) -> None:
        if token.line in exempt_lines:
            return
        findings.append(Finding(token.line, message))

    def numeric_after(index: int) -> Token | None:
        i = next_significant(tokens, index)
        if i is None:
            return None
        if tokens[i].text == "-" and i + 1 < len(tokens):
            i += 1
        return tokens[i] if tokens[i].kind == "num" else None

    def flag_numeric(token: Token, what: str) -> None:
        value = numeric_value(token)
        if value is not None and value != 0:
            add(token, f"raw {what}: {token.text}")

    # 1. Labels and assignments for style properties.
    for i, token in enumerate(tokens):
        if token.kind != "id":
            continue
        nxt = next_significant(tokens, i)
        if nxt is None:
            continue
        if tokens[nxt].text == ":" and token.text in STYLE_LABELS:
            value = numeric_after(nxt)
            if value is not None:
                flag_numeric(value, f"{token.text} value")
        if tokens[nxt].text == "=" and token.text in STYLE_PROPERTIES:
            value = numeric_after(nxt)
            if value is not None:
                flag_numeric(value, f"{token.text} value")

    # 2. Direct numeric arguments to style calls.
    for i, token in enumerate(tokens):
        if not is_call(tokens, i) or token.text not in STYLE_CALLS:
            continue
        open_index = i + 1
        close_index = matching(tokens, open_index)
        for start, end in split_arguments(tokens, open_index, close_index):
            if start >= end:
                continue
            first = start
            if tokens[first].text == "-":
                first += 1
            if first < end and tokens[first].kind == "num":
                flag_numeric(tokens[first], f"{token.text} argument")

    # 3. Raw colour constructors and members.
    for i, token in enumerate(tokens):
        if token.kind == "id" and token.text in {"NSColor", "NSFont"}:
            nxt = next_significant(tokens, i)
            if nxt is not None and tokens[nxt].text in {".", "("}:
                if token.text == "NSColor" and tokens[nxt].text == "(":
                    close = matching(tokens, nxt)
                    first = next_significant(tokens, nxt)
                    if first is not None and first < close and tokens[first].kind == "id" and tokens[first].text == "mpvColorString":
                        continue
                add(token, f"raw {token.text} constructor")
        if token.kind == "id" and token.text in {"Font", "Color"}:
            nxt = next_significant(tokens, i)
            if nxt is not None and tokens[nxt].text == ".":
                member = next_significant(tokens, nxt)
                if member is not None and tokens[member].text == "system" and token.text == "Font":
                    add(token, "raw Font.system")
                elif member is not None and tokens[member].text in COLOR_MEMBERS:
                    add(token, f"raw {token.text}.{tokens[member].text}")
            if token.text == "Color" and nxt is not None and tokens[nxt].text == "(":
                add(token, "raw Color constructor")

    for i, token in enumerate(tokens):
        if token.text != "." or i + 1 >= len(tokens):
            continue
        member = tokens[i + 1]
        if member.kind != "id":
            continue
        after_member = next_significant(tokens, i + 1)
        if after_member is not None and tokens[after_member].text in {"(", "="}:
            continue
        if member.text in COLOR_MEMBERS:
            prev = previous_significant(tokens, i)
            if prev is None or tokens[prev].kind != "id":
                add(member, f"raw colour literal: .{member.text}")
        elif member.text in WEAK_COLOR_MEMBERS and enclosing_call(tokens, i) in COLOR_APIS:
            add(member, f"raw colour literal: .{member.text}")

    # 4. Raw font calls and sizes.
    for i, token in enumerate(tokens):
        if not is_call(tokens, i):
            continue
        name = token.text
        if name in FONT_CALLS:
            if not member_chain(tokens, i).startswith("Tokens.Typography."):
                add(token, f"raw font call: {name}")
        if name == "system" and i > 0 and tokens[i - 1].text == ".":
            open_index = i + 1
            close_index = matching(tokens, open_index)
            for j in range(open_index + 1, close_index):
                if tokens[j].text == "size" and j + 1 < len(tokens) and tokens[j + 1].text == ":":
                    value = next_significant(tokens, j + 1)
                    if value is not None and tokens[value].kind == "num":
                        add(token, "raw SwiftUI font: .system")
                        break
        if name in GEOMETRY_CALLS:
            open_index = i + 1
            close_index = matching(tokens, open_index)
            depth = 0
            for j in range(open_index + 1, close_index):
                text = tokens[j].text
                if text in "([{":
                    depth += 1
                    continue
                if text in ")]}":
                    depth -= 1
                    continue
                if depth != 0 or tokens[j].kind != "num":
                    continue
                value = numeric_value(tokens[j])
                if value in (None, 0):
                    continue
                prev = tokens[j - 1].text if j > open_index else ""
                nxt = tokens[j + 1].text if j + 1 < close_index else ""
                if prev == ".":
                    continue
                # A number right after `*` or `/` is a scale factor, not a dimension.
                if prev in {"*", "/"}:
                    continue
                add(tokens[j], f"raw {name} dimension: {tokens[j].text}")

    # 5. Materials and glass configuration.
    for i, token in enumerate(tokens):
        if token.kind != "id":
            continue
        nxt = next_significant(tokens, i)
        if nxt is None:
            continue
        if token.text == "material" and tokens[nxt].text == "=":
            value = next_significant(tokens, nxt)
            if value is not None and (tokens[value].text == "." or tokens[value].kind == "id"):
                add(token, "raw material assignment")
        if token.text == "style" and tokens[nxt].text == "=":
            value = next_significant(tokens, nxt)
            if (
                value is not None
                and tokens[value].text == "."
                and value + 1 < len(tokens)
                and tokens[value + 1].text in {"clear", "regular"}
            ):
                add(token, "raw glass style assignment")
        if token.text == "NSVisualEffectView" and tokens[nxt].text == ".":
            add(token, "raw visual-effect material reference")

    for i, token in enumerate(tokens):
        if token.kind == "id" and token.text in {"CGColor"}:
            nxt = next_significant(tokens, i)
            if nxt is not None and tokens[nxt].text == "(":
                add(token, "raw CGColor constructor")
        if token.text == "init" and i > 0 and tokens[i - 1].text == ".":
            nxt = next_significant(tokens, i)
            if nxt is not None and tokens[nxt].text == "(":
                close = matching(tokens, nxt)
                for j in range(nxt + 1, close):
                    if tokens[j].kind == "id" and tokens[j].text in {"white", "red", "green", "blue"}:
                        add(tokens[j], "raw colour initializer")

    # 6. `#colorLiteral`.
    for i, token in enumerate(tokens):
        if token.text == "#" and i + 1 < len(tokens) and tokens[i + 1].text == "colorLiteral":
            add(token, "raw colour literal: #colorLiteral")

    # 7. Typed UI constants.
    for i, token in enumerate(tokens):
        if token.kind != "id" or token.text not in {"let", "var"}:
            continue
        name_index = next_significant(tokens, i)
        if name_index is None or tokens[name_index].kind != "id":
            continue
        name = tokens[name_index].text
        colon = next_significant(tokens, name_index)
        if colon is None or tokens[colon].text != ":":
            continue
        type_index = next_significant(tokens, colon)
        if type_index is None or tokens[type_index].text not in {"CGFloat", "TimeInterval", "Double"}:
            continue
        equals = next_significant(tokens, type_index)
        if equals is None or tokens[equals].text != "=":
            continue
        value = numeric_after(equals)
        if value is None:
            continue
        lowered = name.lower()
        if any(word in lowered for word in ("padding", "height", "width", "radius", "size", "spacing", "margin", "inset", "duration")):
            flag_numeric(value, f"UI constant {name}")

    # 8. Exemptions must name a reason.
    for comment in comments:
        if "token-exempt:" in comment.text:
            reason = comment.text.split("token-exempt:", 1)[1].strip()
            if not reason:
                findings.append(Finding(comment.line, "token-exempt without a reason"))

    return findings


def lint() -> list[str]:
    findings: list[str] = []
    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        if path.resolve() == TOKEN_FILE.resolve():
            continue
        rel = path.relative_to(ROOT)
        source = path.read_text(encoding="utf-8")
        for finding in lint_source(source, str(rel)):
            findings.append(f"{rel}:{finding.line}: {finding.message}")
    return findings


def check_xibs() -> list[str]:
    findings: list[str] = []
    for path in sorted(SOURCE_ROOT.rglob("*.xib")):
        try:
            rel = str(path.relative_to(ROOT))
        except ValueError:
            rel = str(path)
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as error:
            findings.append(f"{rel}: invalid XML: {error}")
            continue
        for element in root.iter():
            if element.tag == "font":
                attrs = element.attrib
                meta = attrs.get("metaFont", "")
                if attrs.get("usesAppearanceFont") == "YES" and "size" not in attrs and "name" not in attrs:
                    continue
                if "size" in attrs or "name" in attrs or meta not in XIB_SYSTEM_FONTS:
                    findings.append(
                        f"{rel}: custom font {attrs} — use a system metaFont and set product fonts in code"
                    )
            if element.tag == "color":
                if element.attrib.get("catalog") == "System":
                    continue
                signature = ",".join(
                    f"{key}={element.attrib[key]}"
                    for key in ("red", "green", "blue", "white", "alpha", "colorSpace")
                    if key in element.attrib
                )
                key = element.attrib.get("key", "")
                if (rel, key, signature) not in XIB_COLOR_EXCEPTIONS:
                    findings.append(
                        f"{rel}: custom colour {signature} — use a catalog colour or an explicit user-data exception"
                    )
    return findings


def declaration_lines(source: str) -> dict[int, str]:
    docs: dict[int, str] = {}
    current: list[str] = []
    current_start = 0
    for number, line in enumerate(source.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("///"):
            if not current:
                current_start = number
            current.append(stripped[3:].strip())
        else:
            if current:
                docs[current_start] = " ".join(current).strip()
                current = []
    if current:
        docs[current_start] = " ".join(current).strip()
    return docs


def mark_sections(source: str) -> list[tuple[int, str]]:
    marks: list[tuple[int, str]] = []
    for number, line in enumerate(source.splitlines(), 1):
        match = re.match(r"\s*// MARK: (.*)$", line)
        if match:
            marks.append((number, match.group(1).strip().replace(":", " ·")))
    return marks


def doc_for(docs: dict[int, str], line: int) -> str:
    for start in range(line, max(0, line - 30), -1):
        if start in docs:
            return docs[start]
    return ""


def section_for(marks: list[tuple[int, str]], line: int) -> str:
    section = ""
    for mark_line, heading in marks:
        if mark_line < line:
            section = heading
        else:
            break
    return section


def parse_tokens() -> list[tuple[str, str, str, str, str]]:
    """Return (section, name, declaration, documentation, full_text).

    Declarations are found from tokens and brace depth, not indentation, so a
    whitespace change cannot silently remove a token from the ledger.
    """
    source = TOKEN_FILE.read_text(encoding="utf-8")
    tokens, _ = lex(source)
    docs = declaration_lines(source)
    marks = mark_sections(source)
    tokens_out: list[tuple[str, str, str, str, str]] = []
    stack: list[str] = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token.kind == "id" and token.text in {"enum", "struct", "class", "extension"}:
            name_index = i + 1
            if name_index < len(tokens) and tokens[name_index].kind == "id":
                brace_index = name_index + 1
                if brace_index < len(tokens) and tokens[brace_index].text == "{":
                    stack.append(tokens[name_index].text)
                    i = brace_index + 1
                    continue
        if token.text == "}" and stack:
            stack.pop()
            i += 1
            continue
        if (
            token.kind == "id"
            and token.text == "static"
            and stack
            and stack[0] == "Tokens"
            and len(stack) >= 2
            and i + 2 < len(tokens)
            and tokens[i + 1].text in {"let", "var", "func"}
            and tokens[i + 2].kind == "id"
        ):
            name = tokens[i + 2].text
            start_line = token.line
            # Find the end of the declaration at the same brace depth.
            depth = 0
            j = i
            end_index = i
            while j < len(tokens):
                text = tokens[j].text
                if text in "([{":
                    depth += 1
                elif text in ")]}":
                    if depth == 0:
                        break
                    depth -= 1
                    if text == "}" and depth == 0:
                        # This brace closes a computed declaration's body; it
                        # belongs to the declaration, unlike an enclosing
                        # enum's closing brace.
                        end_index = j
                        break
                if j > i and depth == 0 and tokens[j].text in {"static", "}"}:
                    break
                if j > i and depth == 0 and tokens[j].line > tokens[j - 1].line and tokens[j].text in {"@", "}}"}:
                    break
                end_index = j
                j += 1
            end_token = tokens[end_index]
            full_text = source[token.start:end_token.end]
            first_line = full_text.splitlines()[0].strip() if full_text else ""
            declaration = re.sub(r"\s+", " ", full_text).strip()
            section = section_for(marks, start_line)
            tokens_out.append((section, name, declaration, doc_for(docs, start_line), first_line))
            i = end_index + 1
            continue
        i += 1
    return tokens_out


NUMERIC_TOKEN_RE = re.compile(r"^n(\d+(?:_\d+)?)$")


def token_value_errors() -> list[str]:
    source = TOKEN_FILE.read_text(encoding="utf-8")
    tokens, _ = lex(source)
    errors: list[str] = []
    stack: list[str] = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token.kind == "id" and token.text in {"enum", "struct", "class", "extension"}:
            name_index = next_significant(tokens, i)
            brace_index = next_significant(tokens, name_index) if name_index is not None else None
            if (
                name_index is not None
                and brace_index is not None
                and tokens[name_index].kind == "id"
                and tokens[brace_index].text == "{"
            ):
                stack.append(tokens[name_index].text)
                i = brace_index + 1
                continue
        if token.text == "}" and stack:
            stack.pop()
            i += 1
            continue
        if token.kind != "id":
            i += 1
            continue
        match = NUMERIC_TOKEN_RE.match(token.text)
        if not match:
            i += 1
            continue
        prev = previous_significant(tokens, i)
        prev2 = previous_significant(tokens, prev) if prev is not None else None
        if (
            prev is None
            or prev2 is None
            or tokens[prev].text not in {"let", "var"}
            or tokens[prev2].text != "static"
        ):
            i += 1
            continue
        family = stack[-1] if stack else ""
        if family not in {"Space", "Radius", "Stroke", "Blur", "Opacity", "Size", "Icon"}:
            i += 1
            continue
        colon = next_significant(tokens, i)
        if colon is None or tokens[colon].text != ":":
            errors.append(f"{token.text}: missing CGFloat annotation")
            i += 1
            continue
        type_index = next_significant(tokens, colon)
        if type_index is None or tokens[type_index].text != "CGFloat":
            errors.append(f"{token.text}: missing CGFloat annotation")
            i += 1
            continue
        equals = next_significant(tokens, type_index)
        if equals is None or tokens[equals].text != "=":
            i += 1
            continue
        value_index = next_significant(tokens, equals)
        if value_index is None:
            i += 1
            continue
        after = next_significant(tokens, value_index)
        if tokens[value_index].kind != "num" or (after is not None and tokens[after].line == tokens[value_index].line and tokens[after].text not in {",", "}"}):
            errors.append(f"{token.text}: initializer is not a single numeric literal")
            i += 1
            continue
        value = numeric_value(tokens[value_index])
        suffix = Decimal(match.group(1).replace("_", "."))
        family = stack[-1] if stack else ""
        encoded = suffix / Decimal(100) if family == "Opacity" else suffix
        if value is None or value != encoded:
            errors.append(f"{token.text}: value {tokens[value_index].text} does not match the name")
        i += 1
    return errors


def render_ledger() -> str:
    tokens = parse_tokens()
    layout = component_layout_tokens()
    xib_exceptions = sorted(XIB_COLOR_EXCEPTIONS.items())
    out: list[str] = [
        "# Design token ledger",
        "",
        "Generated from `uniplayer/DesignTokens.swift` by",
        "`scripts/check-design-tokens.py --write-ledger`. Do not edit by hand.",
        "",
        "## The rule",
        "",
        "Every appearance value in code is a token. A Swift file may not contain a",
        "raw colour, font, spacing, radius, stroke, opacity, size, shadow, material or",
        "animation duration. Read the token instead; if the value you need does not",
        "exist, add it to `DesignTokens.swift` with a doc comment.",
        "",
        "System text styles (`.font(.body)`, `.font(.caption)`), standard control",
        "sizes and `alphaValue` visibility state are platform semantics rather than",
        "design literals, so they are allowed.",
        "",
        "`scripts/check-design-tokens.py` enforces the rule in CI. The only escape is",
        "a line comment naming a non-appearance reason:",
        "",
        "```swift",
        "let color = NSColor(mpvColorString: value) // token-exempt: parses an mpv colour",
        "```",
        "",
        "Values follow the macOS 27 Human Interface Guidelines: system semantic",
        "colours that adapt to appearance, Increase Contrast and Reduce Transparency;",
        "the system font; Liquid Glass with an opaque visual-effect fallback; and",
        "motion that honours Reduce Motion and the app's own animation setting.",
        "",
        "## Coverage",
        "",
        "| Surface | State |",
        "|---|---|",
        "| AppKit and SwiftUI sources | Checked structurally; every remaining raw value is a finding |",
        "| Interface Builder documents | System catalog colours and `metaFont`s; non-system values require an explicit user-data exception |",
        "| Embedded plugin web documents | Self-contained CSS inside `JavascriptAPIOverlay`, `JavascriptAPIStandaloneWindow`, `PrefPluginViewController` and `SettingsPagePlugin`; a separate rendering surface, not covered by the native ledger |",
        "",
        "## Token families",
        "",
        "| Family | Purpose |",
        "|---|---|",
        "| `Palette` | Colours: system semantic, product, media, borders, HUD, legacy assets |",
        "| `Typography` | The type ramp, as roles and as a raw size fallback |",
        "| `Space` | Padding, gaps, margins and constraint offsets |",
        "| `Radius` | Corner radii |",
        "| `Stroke` | Line and border widths |",
        "| `Blur` | Shadow and soft-edge blur radii |",
        "| `Opacity` | Alpha values for scrims, borders, tints and disabled states |",
        "| `Size` | Control, component and window dimensions |",
        "| `Icon` | SF Symbol point sizes |",
        "| `Motion` | Durations and curves |",
        "| `Material` | Visual-effect and Liquid Glass configurations |",
        "| `Shadow` | Drop shadows |",
        "| `Aspect` | Media aspect ratios |",
        "| `Library`, `HUD`, `Settings`, `Window` | Component geometry |",
        "",
    ]
    current = None
    for section, name, declaration, docs, _ in tokens:
        if section != current:
            if current is not None:
                out.append("")
            current = section
            out.append(f"## {section}" if section else "## Tokens")
            out.append("")
            out.append("| Token | Declaration | Purpose |")
            out.append("|---|---|---|")
        safe = declaration.replace("|", "\\|")
        out.append(f"| `{name}` | `{safe}` | {docs or '—'} |")
    out.append("")
    out.append("## Component layout tokens")
    out.append("")
    out.append("Compact and full values for controls that follow the app's compact-interface preference.")
    out.append("")
    out.append("| Token | Declaration | File | Purpose |")
    out.append("|---|---|---|---|")
    for file, name, declaration, docs in layout:
        safe = declaration.replace("|", "\\|")
        out.append(f"| `{name}` | `{safe}` | `{file}` | {docs or '—'} |")
    out.append("")
    out.append("## Interface Builder exceptions")
    out.append("")
    out.append("Interface Builder cannot reference Swift tokens. These are the only")
    out.append("non-system values permitted; each is keyed to its exact file and value.")
    out.append("")
    if xib_exceptions:
        out.append("| File | Key | Value | Reason |")
        out.append("|---|---|---|---|")
        for (file, key, signature), reason in xib_exceptions:
            out.append(f"| `{file}` | `{key}` | `{signature}` | {reason} |")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def component_layout_tokens() -> list[tuple[str, str, str, str]]:
    tokens: list[tuple[str, str, str, str]] = []
    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        if path.resolve() == TOKEN_FILE.resolve():
            continue
        source = path.read_text(encoding="utf-8")
        docs = declaration_lines(source)
        lexed, _ = lex(source)
        for i, token in enumerate(lexed):
            if token.kind != "id" or token.text != "static":
                continue
            let_index = next_significant(lexed, i)
            if let_index is None or lexed[let_index].text != "let":
                continue
            name_index = next_significant(lexed, let_index)
            if name_index is None or lexed[name_index].kind != "id":
                continue
            equals = next_significant(lexed, name_index)
            if equals is None or lexed[equals].text != "=":
                continue
            kind_index = next_significant(lexed, equals)
            if kind_index is None:
                continue
            if lexed[kind_index].text not in {"LayoutValue", ".init"}:
                continue
            name = lexed[name_index].text
            end = name_index
            depth = 0
            j = equals
            while j < len(lexed):
                text = lexed[j].text
                if text in "([{":
                    depth += 1
                elif text in ")]}":
                    depth -= 1
                end = j
                if depth == 0 and j > equals:
                    break
                j += 1
            full = source[token.start:lexed[end].end]
            declaration = re.sub(r"\s+", " ", full).strip()
            tokens.append((str(path.relative_to(ROOT)), name, declaration, doc_for(docs, token.line)))
    return tokens


def ledger_is_current() -> bool:
    expected = render_ledger()
    actual = LEDGER_FILE.read_text(encoding="utf-8") if LEDGER_FILE.exists() else ""
    return expected == actual


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", action="store_true", help="verify DESIGN_TOKENS.md")
    parser.add_argument("--write-ledger", action="store_true", help="regenerate DESIGN_TOKENS.md")
    args = parser.parse_args()

    if args.write_ledger:
        LEDGER_FILE.write_text(render_ledger(), encoding="utf-8")
        print(f"wrote {LEDGER_FILE.relative_to(ROOT)}")

    findings = lint() + check_xibs()
    value_errors = token_value_errors()
    tokens = parse_tokens()
    undocumented = [f"{section}.{name}" for section, name, _, docs, _ in tokens if not docs]

    if value_errors:
        print("Token names disagree with their values:\n  " + "\n  ".join(value_errors), file=sys.stderr)
    if undocumented:
        print("Tokens without a doc comment:\n  " + "\n  ".join(undocumented), file=sys.stderr)
    if findings:
        print(f"{len(findings)} design-token violation(s):\n", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        print(
            "\nReplace each value with a token from uniplayer/DesignTokens.swift. "
            "If the value is genuinely not an appearance value, add "
            "`// token-exempt: <reason>` on that line.",
            file=sys.stderr,
        )

    ledger_ok = True
    if args.ledger or args.write_ledger:
        ledger_ok = ledger_is_current()
        if not ledger_ok:
            print(
                "DESIGN_TOKENS.md is stale; run scripts/check-design-tokens.py --write-ledger",
                file=sys.stderr,
            )

    return 0 if not findings and not value_errors and not undocumented and ledger_ok else 1


if __name__ == "__main__":
    sys.exit(main())
