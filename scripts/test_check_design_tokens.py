#!/usr/bin/env python3
"""Fixtures for the design-token checker.

Run with: python3 -m unittest scripts/test_check_design_tokens.py
"""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKER = ROOT / "scripts" / "check-design-tokens.py"

spec = importlib.util.spec_from_file_location("check_design_tokens", CHECKER)
checker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checker)


def messages(source: str) -> list[str]:
    return [finding.message for finding in checker.lint_source(source, "test.swift")]


class SwiftLintFixtures(unittest.TestCase):
    def test_multiline_padding_is_caught(self):
        self.assertTrue(messages("view.padding(\n  37\n)\n"))

    def test_all_swiftui_colours_are_caught(self):
        self.assertTrue(messages("view.foregroundStyle(.purple)\n"))
        self.assertTrue(messages("view.foregroundColor(.brown)\n"))
        self.assertTrue(messages("view.fill(.clear)\n"))

    def test_shadow_radius_is_caught(self):
        self.assertTrue(messages("view.shadow(radius: 9)\n"))

    def test_animation_duration_is_caught(self):
        self.assertTrue(messages("view.animation(.easeInOut(duration: 3), value: x)\n"))

    def test_block_comment_does_not_hide_code(self):
        self.assertTrue(messages("/* note */ view.padding(37)\n"))

    def test_string_mentioning_a_colour_is_clean(self):
        self.assertFalse(messages('let text = "NSColor.red"\n'))

    def test_tokenized_calls_are_clean(self):
        source = """
        view.padding(Tokens.Space.n8)
        view.foregroundStyle(Tokens.Palette.textPrimary.color)
        view.shadow(radius: Tokens.Blur.n9)
        view.animation(Tokens.Motion.hover.animation, value: x)
        """
        self.assertFalse(messages(source))

    def test_geometry_dimensions_are_caught(self):
        self.assertTrue(messages("let r = NSRect(x: 0, y: 0, width: 10, height: 20)\n"))

    def test_geometry_scale_and_centring_are_clean(self):
        source = """
        let r = NSRect(x: a - b / 2, y: c, width: d * 2, height: e)
        """
        self.assertFalse(messages(source))

    def test_ui_constant_is_caught(self):
        self.assertTrue(messages("private let padding: CGFloat = 12\n"))

    def test_exemption_requires_a_reason(self):
        found = messages("view.padding(12) // token-exempt:\n")
        self.assertTrue(any("without a reason" in message for message in found))


class TokenFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.old_token_file = checker.TOKEN_FILE
        self.old_source_root = checker.SOURCE_ROOT
        root = pathlib.Path(self.temp.name)
        checker.SOURCE_ROOT = root
        checker.TOKEN_FILE = root / "DesignTokens.swift"

    def tearDown(self):
        checker.TOKEN_FILE = self.old_token_file
        checker.SOURCE_ROOT = self.old_source_root

    def write_token_file(self, body: str) -> None:
        checker.TOKEN_FILE.write_text(f"enum Tokens {{\n{body}\n}}\n", encoding="utf-8")

    def test_expression_initializer_is_rejected(self):
        self.write_token_file("  enum Space {\n    static let n10: CGFloat = 10 * 99\n  }")
        self.assertTrue(checker.token_value_errors())

    def test_inferred_initializer_is_rejected(self):
        self.write_token_file("  enum Space {\n    static let n10 = 10\n  }")
        self.assertTrue(checker.token_value_errors())

    def test_opacity_is_compared_exactly(self):
        self.write_token_file("  enum Opacity {\n    static let n10: CGFloat = 0.1049\n  }")
        self.assertTrue(checker.token_value_errors())

    def test_matching_value_is_accepted(self):
        self.write_token_file("  enum Space {\n    static let n10: CGFloat = 10\n  }")
        self.assertFalse(checker.token_value_errors())

    def test_computed_body_appears_in_the_ledger(self):
        self.write_token_file(
            "  enum Space {\n"
            "    /// A computed token.\n"
            "    static var computed: CGFloat {\n"
            "      if flag { return 1 }\n"
            "      return 2\n"
            "    }\n"
            "  }"
        )
        ledger = checker.render_ledger()
        self.assertIn("return 2", ledger)
        self.assertIn("A computed token.", ledger)


class LedgerFixtures(unittest.TestCase):
    def test_ledger_covers_every_token_family(self):
        tokens = checker.parse_tokens()
        self.assertGreater(len(tokens), 400)
        sections = " ".join(section for section, *_ in tokens)
        for family in ("Palette", "Typography", "Spacing", "Sizes", "Opacity", "Library", "Player HUD"):
            self.assertIn(family, sections)

    def test_computed_declaration_is_complete(self):
        declarations = {name: declaration for _, name, declaration, *_ in checker.parse_tokens()}
        self.assertIn("currentContrast", declarations)
        self.assertTrue(declarations["currentContrast"].rstrip().endswith("}"))


class XIBFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.old_source_root = checker.SOURCE_ROOT
        self.root = pathlib.Path(self.temp.name)
        checker.SOURCE_ROOT = self.root
        (self.root / "Assets.xcassets").mkdir()

    def tearDown(self):
        checker.SOURCE_ROOT = self.old_source_root

    def write_xib(self, body: str) -> None:
        (self.root / "Test.xib").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<document><objects>\n' + body + "\n</objects></document>\n",
            encoding="utf-8",
        )

    def test_custom_font_is_rejected(self):
        self.write_xib('<font key="font" size="12" name="Menlo-Regular"/>')
        self.assertTrue(checker.check_xibs())

    def test_system_font_is_allowed(self):
        self.write_xib('<font key="font" metaFont="smallSystem"/>')
        self.assertFalse(checker.check_xibs())

    def test_custom_colour_is_rejected(self):
        self.write_xib('<color key="backgroundColor" red="1" green="0" blue="0" alpha="1" colorSpace="sRGB"/>')
        self.assertTrue(checker.check_xibs())

    def test_catalog_colour_is_allowed(self):
        self.write_xib('<color key="backgroundColor" name="labelColor" catalog="System" colorSpace="catalog"/>')
        self.assertFalse(checker.check_xibs())


if __name__ == "__main__":
    unittest.main()
