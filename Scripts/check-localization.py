#!/usr/bin/env python3
"""Flags user-facing strings in the interface that do not go through t().

Three of these shipped before this check existed, and none was visible to the
catalogue-parity tests, because a string that never becomes a key is a string
the catalogue never hears about:

  - Badge(text: "Degraded")     — the label sat behind an argument label, so the
                                  sweep that wrapped every other string missed it
  - Button(x ? "Add and sign in" : "Add")
                                — a ternary is not a bare literal
  - parts.append("never run")   — built by concatenation, far from any call site

All three read English in a French interface.

The rule: in the view layer, a string literal containing a capitalised word is
prose unless it sits immediately after something that says otherwise. Symbol
names, selectors and dictionary keys are lowercase or dotted and do not trip it.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Sources" / "InvoicesRetriever"

# What may legitimately precede a literal that is not prose.
EXEMPT_BEFORE = re.compile(
    r'(?:'
    r'\bt|\btn'                      # already localised
    r'|verbatim:'                    # deliberately not translated
    r'|systemImage:|systemName:'     # SF Symbol names
    r'|forKey:|withExtension:|ofType:|forResource:'
    r'|identifier:|pattern:|separator:|tag'
    r'|LabeledContent'               # a fixed technical label, e.g. SHA-256
    r'|\['                           # a dictionary key is never prose
    r')\s*\(?\s*$'
)

# Literals that are values rather than prose: keys, identifiers, header names,
# currency and country codes, a bare format specifier.
# A single capitalised word is NOT exempt: "Date", "Total" and "Issuer" are all
# column headings that need translating. Anything genuinely not prose says so
# with a `// not prose` comment on its line.
EXEMPT_VALUE = re.compile(
    r"^(?:[a-z][A-Za-z0-9_.]*|%[\d$@a-z.]*|\s*)$"
)

# An interpolation carries data, not prose. A literal that is nothing but
# interpolations and punctuation — "\(id) \(version)" — is data too.
INTERPOLATION = re.compile(r"\\\([^)]*\)")

STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
PROSE = re.compile(r'[A-Z][a-z]{2,}')

problems = []
for path in sorted(ROOT.rglob("*.swift")):
    if path.name == "Strings.swift":
        continue                      # the helpers' own documentation
    for number, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        if "// not prose" in line:
            continue
        for match in STRING.finditer(line):
            literal = match.group(1)
            skeleton = INTERPOLATION.sub("", literal)
            if not PROSE.search(skeleton) or EXEMPT_VALUE.match(skeleton.strip()):
                continue
            if EXEMPT_BEFORE.search(line[:match.start()]):
                continue
            problems.append(f"{path.relative_to(ROOT)}:{number}: {literal[:70]}")

if problems:
    print("Strings that look like prose but do not go through t():\n")
    for problem in problems:
        print("  " + problem)
    print('\nWrap them in t("…"), or Text(verbatim:) if they genuinely are not prose.')
    sys.exit(1)

print("✓ every user-facing string in the interface goes through t()")
