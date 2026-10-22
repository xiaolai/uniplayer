#!/usr/bin/env python3
"""Enforce the design-token rule and keep the token ledger current.

The rule: a Swift file may not invent an appearance value. Colours, fonts,
spacing, radii, strokes, opacities, sizes, shadows, materials and animation
durations come from `uniplayer/DesignTokens.swift`; anything else is a
violation.

Usage:
  scripts/check-design-tokens.py            # lint the Swift sources
  scripts/check-design-tokens.py --ledger   # also verify DESIGN_TOKENS.md
  scripts/check-design-tokens.py --write-ledger
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOT = ROOT / "uniplayer"
TOKEN_FILE = SOURCE_ROOT / "DesignTokens.swift"
LEDGER_FILE = ROOT / "DESIGN_TOKENS.md"

# A line may opt out of one rule with this marker, but the reason must follow
# the colon. Blanket exemptions are rejected.
EXEMPTION_RE = re.compile(r"//\s*token-exempt:\s*(\S.*)$")

# Appearance values only. Numeric values are matched only when they are the
# argument of a known appearance API, so layout arithmetic and model data stay
# out of scope.
RULES: list[tuple[str, re.Pattern[str]]] = [
    ("raw AppKit colour", re.compile(r"\bNSColor\s*[.(]")),
    ("raw SwiftUI colour", re.compile(r"\bColor\s*\.\s*(?:white|black|clear|gray|red|blue|green|yellow|orange)\b|\bColor\s*\(")),
    ("raw font", re.compile(r"\bNSFont\s*\.|(?<!Typography)\.(?:systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont)\s*\(")),
    ("raw SwiftUI font", re.compile(r"\.font\s*\(\s*\.system\s*\(\s*size:\s*[-+]?\d")),
    ("raw shadow", re.compile(r"\.shadow\s*\(\s*(?:color\s*:\s*)?(?:\.(?:white|black|gray)|Color\b|NSColor\b)")),
    ("raw material", re.compile(r"\.material\s*=\s*(?:\.|NSVisualEffectView\b)")),
    ("raw glass style", re.compile(r"\.style\s*=\s*\.(?:clear|regular)\b")),
    ("raw border width", re.compile(r"\b(?:lineWidth|borderWidth)\s*[:=]\s*[-+]?\d")),
    ("raw corner radius", re.compile(r"\bcornerRadius\s*[:=]\s*[-+]?\d")),
    ("raw opacity", re.compile(r"(?:\.opacity|withAlphaComponent)\s*\(\s*[-+]?\d")),
    ("raw spacing", re.compile(r"\bspacing\s*:\s*[-+]?\d")),
    ("raw padding", re.compile(r"\.padding\s*\(\s*(?:\.[a-z]+\s*,\s*)?[-+]?\d")),
    ("raw constraint constant", re.compile(r"\bconstant\s*:\s*[-+]?\d")),
    ("raw fixed dimension", re.compile(r"\bequalToConstant\s*:\s*[-+]?\d")),
    ("raw frame", re.compile(r"\.frame\s*\([^)]*\b(?:width|height|minWidth|maxWidth|minHeight|maxHeight)\s*:\s*[-+]?\d")),
    ("raw size", re.compile(r"\.size\s*\(\s*(?:width|height)\s*:\s*[-+]?\d")),
    ("raw font size", re.compile(r"\b(?:ofSize|size)\s*:\s*[-+]?\d")),
    ("raw duration", re.compile(r"\.duration\s*=\s*[-+]?\d|\bduration\s*:\s*[-+]?\d(?=[^\n]*(?:Animation|withAnimation|easeIn|easeOut|linear|spring|timingFunction))")),
    ("raw scale", re.compile(r"\.scaleEffect\s*\(\s*[-+]?\d")),
    ("raw shadow opacity", re.compile(r"\bshadowOpacity\s*=\s*[-+]?\d")),
    ("raw colour shorthand", re.compile(r"\.(?:foregroundStyle|foregroundColor|fill|stroke|strokeBorder|background|tint)\(\s*\.(?:white|black|gray|red|blue|green|orange|yellow|clear)\b")),
    ("raw colour assignment", re.compile(r"\.(?:contentTintColor|textColor|borderColor|backgroundColor|shadowColor|fillColor|strokeColor)\s*=\s*[^\n]*(?<![\w.])\.(?:white|black|gray|red|blue|green|orange|yellow|clear)\b")),
    ("raw SwiftUI semantic colour", re.compile(r"\.(?:foregroundColor|foregroundStyle|tint|background|fill|stroke)\(\.(?:primary|secondary|tertiary|accentColor|tint)\)")),
    ("raw colour literal", re.compile(r"(?:foregroundStyle|foregroundColor|fill|stroke|strokeBorder|background|tint|contentTintColor|textColor|borderColor|backgroundColor|shadowColor|fillColor|strokeColor)\s*[:=(][^\n]*(?<![\w.])\.(?:white|black|gray|red|blue|green|orange|yellow|clear)\b")),
    ("raw style default", re.compile(r"\b(?:spacing|padding|cornerRadius|radius|width|height|size|fontSize|duration)\s*:\s*(?:CGFloat|TimeInterval|Double|Int)\s*=\s*[-+]?[1-9]\d*(?:\.\d+)?")),
    ("raw layout value", re.compile(r"\bLayoutValue\(\s*[-+]?\d")),
    ("raw padding modifier", re.compile(r"\.padding\(\.[a-zA-Z]+\(\s*[-+]?\d")),
    ("raw spacing modifier", re.compile(r"\.spacing\(\.[a-zA-Z]+\(\s*[-+]?\d")),
    ("raw UI constant", re.compile(r"\b(?:let|var)\s+\w*(?:[Pp]adding|[Hh]eight|[Ww]idth|[Rr]adius|[Ss]ize|[Ss]pacing|[Mm]argin|[Ii]nset)\w*\s*:\s*CGFloat\s*=\s*[-+]?\d")),
    ("raw semantic colour", re.compile(r"\.(?:textColor|contentTintColor|borderColor|backgroundColor|shadowColor|fillColor|strokeColor|foregroundStyle|foregroundColor|fill|stroke|background|tint)\s*[:=][^\n]*(?<![\w.])\.(?:labelColor|secondaryLabelColor|tertiaryLabelColor|quaternaryLabelColor|disabledControlTextColor|controlTextColor|selectedControlTextColor|controlBackgroundColor|windowBackgroundColor|separatorColor|gridColor|highlightColor|controlAccentColor|textColor|selectedTextColor|systemRed|systemBlue|systemGreen|systemOrange|clear|white|black|gray)\b")),
    ("raw row height", re.compile(r"\b(?:rowHeight|estimatedRowHeight)\s*[:=]\s*[-+]?\d")),
    ("raw bezier radius", re.compile(r"\b(?:xRadius|yRadius|cornerWidth|cornerHeight)\s*:\s*[-+]?\d")),
    ("raw shadow blur", re.compile(r"\bshadowBlurRadius\s*=\s*[-+]?\d")),
    ("raw inset", re.compile(r"\bNSInsetRect\([^)]*,\s*[-+]?[1-9]\d*(?:\.\d+)?")),
    ("raw size literal", re.compile(r"\b(?:NSSize|CGSize)\([^)]*\b(?:width|height):\s*[-+]?[1-9]\d*(?:\.\d+)?|\bNSMakeSize\(\s*[-+]?[1-9]")),
    ("raw rect literal", re.compile(r"\b(?:NSRect|CGRect)\([^)]*\b(?:width|height):\s*[-+]?[1-9]\d*(?:\.\d+)?")),

    ("raw shadow radius", re.compile(r"\bshadowRadius\s*=\s*[-+]?\d")),
]

# Lines that match a rule but are not appearance values. Keep this list short
# and structural, never a list of files.
ALLOWED = [
    re.compile(r"^\s*//"),
    re.compile(r"^\s*///"),
    re.compile(r'^\s*"[^"]*"'),          # a string literal, including HTML in JS
    re.compile(r"#colorLiteral\b"),
]

# Files whose entire purpose is to define or consume a non-visual `Color` type.
# Vetting is per line: the exemption must name the reason.
FILE_EXEMPTIONS: dict[str, str] = {}


def triple_quotes(line: str) -> int:
    return line.count('"""')


def swift_files() -> list[Path]:
    return sorted(SOURCE_ROOT.rglob("*.swift"))


def lint() -> list[str]:
    findings: list[str] = []
    for path in swift_files():
        if path.resolve() == TOKEN_FILE.resolve():
            continue
        rel = path.relative_to(ROOT)
        in_block_comment = False
        in_multiline_string = False
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if in_multiline_string:
                if triple_quotes(stripped) % 2 == 1:
                    in_multiline_string = False
                continue
            if in_block_comment:
                if "*/" in stripped:
                    in_block_comment = False
                continue
            quotes = triple_quotes(stripped)
            if quotes:
                if quotes % 2 == 1:
                    in_multiline_string = True
                continue
            if stripped.startswith("/*"):
                if "*/" not in stripped:
                    in_block_comment = True
                continue
            if any(pattern.search(line) for pattern in ALLOWED):
                continue
            if EXEMPTION_RE.search(line):
                continue
            if "Tokens." in line:
                # A tokenised call may still carry a raw literal in a sibling
                # argument; the individual rules catch that below.
                pass
            for name, pattern in RULES:
                if pattern.search(line):
                    findings.append(f"{rel}:{number}: {name}: {stripped}")
                    break
    return findings


def token_value_errors() -> list[str]:
    """Check that numeric token names encode their declared value."""
    errors: list[str] = []
    text = TOKEN_FILE.read_text(encoding="utf-8")
    for family in ["Space", "Radius", "Stroke", "Blur", "Opacity", "Size", "Icon"]:
        start = text.index(f"enum {family} {{")
        depth = 0
        end = start
        while end < len(text):
            if text[end] == "{":
                depth += 1
            elif text[end] == "}":
                depth -= 1
                if depth == 0:
                    break
            end += 1
        for name, literal in re.findall(r"static let (n[\d_]+): CGFloat = ([\d.]+)", text[start:end]):
            suffix = name[1:]
            if family == "Opacity":
                expected = int(suffix)
                actual = round(float(literal) * 100)
            else:
                expected = float(suffix.replace("_", "."))
                actual = float(literal)
            if abs(expected - actual) > 0.0001:
                errors.append(f"{family}.{name} declares {literal}, name says {suffix}")
    return errors


def parse_tokens() -> list[tuple[str, str, str, str]]:
    """Return (section, name, declaration, documentation) for every token.

    Token declarations sit at four spaces of indentation inside the nested
    enums; anything deeper belongs to an implementation and is not a token.
    """
    tokens: list[tuple[str, str, str, str]] = []
    section = ""
    docs: list[str] = []
    in_tokens = False
    for raw in TOKEN_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        if line.startswith("enum Tokens {"):
            in_tokens = True
            continue
        if not in_tokens:
            continue
        if line == "}":
            break
        if re.match(r"^  enum \w+ \{$", line):
            section = line.strip()[len("enum "):-2].strip()
            docs = []
            continue
        match = re.match(r"^    // MARK: (.*)$", line)
        if match:
            section = match.group(1).strip().replace(":", " ·")
            docs = []
            continue
        if line.startswith("    ///"):
            docs.append(line.strip()[3:].strip())
            continue
        match = re.match(r"^    static (?:let|var|func) ([A-Za-z_][A-Za-z0-9_]*)", line)
        if match:
            tokens.append((section, match.group(1), line.strip(), " ".join(docs).strip()))
            docs = []
            continue
        if line.strip():
            docs = []
    return tokens


def component_layout_tokens() -> list[tuple[str, str, str, str]]:
    """Return (file, name, declaration, documentation) for LayoutValue tokens."""
    tokens: list[tuple[str, str, str, str]] = []
    for path in sorted(SOURCE_ROOT.rglob("*.swift")):
        if path.resolve() == TOKEN_FILE.resolve():
            continue
        docs: list[str] = []
        in_comment = False
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("///"):
                docs.append(stripped[3:].strip())
                continue
            if stripped.startswith("//"):
                continue
            match = re.match(r"static let (\w+) = (?:LayoutValue\(|\.init\()", stripped)
            if match:
                tokens.append((str(path.relative_to(ROOT)), match.group(1), stripped, " ".join(docs).strip()))
                docs = []
                continue
            if stripped:
                docs = []
    return tokens


def xib_exceptions() -> tuple[list[tuple[str, int, str]], list[tuple[str, int, str]]]:
    """Return (font, colour) exceptions in Interface Builder documents."""
    import collections
    font_files: dict[str, set[str]] = collections.defaultdict(set)
    font_counts: dict[str, int] = collections.defaultdict(int)
    color_files: dict[str, set[str]] = collections.defaultdict(set)
    color_counts: dict[str, int] = collections.defaultdict(int)
    for path in sorted(SOURCE_ROOT.rglob("*.xib")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in re.finditer(r'<font key="font"([^/]*)/>', text):
            attrs = match.group(1).strip()
            if "size=" in attrs or "name=" in attrs:
                font_files[attrs].add(str(path.relative_to(ROOT)))
                font_counts[attrs] += 1
        for match in re.finditer(r'<color key="[^"]+"([^/]*)/>', text):
            attrs = match.group(1).strip()
            if 'catalog="System"' not in attrs:
                color_files[attrs].add(str(path.relative_to(ROOT)))
                color_counts[attrs] += 1
    fonts = [(attrs, font_counts[attrs], ", ".join(sorted(files))) for attrs, files in sorted(font_files.items())]
    colors = [(attrs, color_counts[attrs], ", ".join(sorted(files))) for attrs, files in sorted(color_files.items())]
    return fonts, colors


def render_ledger() -> str:
    tokens = parse_tokens()
    layout = component_layout_tokens()
    xib_fonts, xib_colors = xib_exceptions()
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
        "| AppKit and SwiftUI sources | 100 % tokenised; lint-enforced |",
        "| Interface Builder documents | System catalog colours and `metaFont`s; the custom values below are the remaining exceptions |",
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
    for section, name, declaration, docs in tokens:
        if section != current:
            if current is not None:
                out.append("")
            current = section
            out.append(f"## {section}" if section else "## Tokens")
            out.append("")
            out.append("| Token | Declaration | Purpose |")
            out.append("|---|---|---|")
        rhs = declaration
        value = rhs.split("=", 1)[1].strip() if "=" in rhs else rhs
        value = re.sub(r"\s+", " ", value)
        if len(value) > 110:
            value = value[:107] + "..."
        out.append(f"| `{name}` | `{value}` | {docs or '—'} |")
        out.append("") if False else None
    out.append("## Component layout tokens")
    out.append("")
    out.append("Compact and full values for controls that follow the app's compact-interface preference.")
    out.append("")
    out.append("| Token | Declaration | File | Purpose |")
    out.append("|---|---|---|---|")
    for file, name, declaration, docs in layout:
        safe_declaration = declaration.replace("|", "\\|")
        out.append(f"| `{name}` | `{safe_declaration}` | `{file}` | {docs or '—'} |")
    out.append("")
    out.append("## Interface Builder exceptions")
    out.append("")
    out.append("Interface Builder cannot reference Swift tokens, so these values are the")
    out.append("remaining exceptions. Colour-well defaults are user data, not design values;")
    out.append("the others are candidates to move into code when their view is next touched.")
    out.append("")
    if xib_fonts:
        out.append("### Custom fonts")
        out.append("")
        out.append("| Font | Count | Locations |")
        out.append("|---|---|---|")
        for attrs, count, files in xib_fonts:
            out.append(f"| `{attrs}` | {count} | {files} |")
        out.append("")
    if xib_colors:
        out.append("### Custom colours")
        out.append("")
        out.append("| Colour | Count | Locations |")
        out.append("|---|---|---|")
        for attrs, count, files in xib_colors:
            out.append(f"| `{attrs}` | {count} | {files} |")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", action="store_true", help="also verify DESIGN_TOKENS.md")
    parser.add_argument("--write-ledger", action="store_true", help="regenerate DESIGN_TOKENS.md")
    args = parser.parse_args()

    if args.write_ledger:
        LEDGER_FILE.write_text(render_ledger(), encoding="utf-8")
        print(f"wrote {LEDGER_FILE.relative_to(ROOT)}")

    tokens = parse_tokens()
    value_errors = token_value_errors()
    if value_errors:
        print("Token names disagree with their values:\n  " + "\n  ".join(value_errors), file=sys.stderr)
    undocumented = [f"{section}.{name}" for section, name, _, docs in tokens if not docs]
    if undocumented:
        print("Tokens without a doc comment:\n  " + "\n  ".join(undocumented), file=sys.stderr)

    findings = lint()
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
        expected = render_ledger()
        actual = LEDGER_FILE.read_text(encoding="utf-8") if LEDGER_FILE.exists() else ""
        if expected != actual:
            ledger_ok = False
            print(
                "DESIGN_TOKENS.md is stale; run scripts/check-design-tokens.py --write-ledger",
                file=sys.stderr,
            )

    return 0 if not findings and not value_errors and not undocumented and ledger_ok else 1


if __name__ == "__main__":
    sys.exit(main())
