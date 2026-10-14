#!/usr/bin/env python3
"""Checks Vespertine's String Catalogs (App/Resources/*.xcstrings).

    python3 scripts/check-localizations.py

Every string is translated into every language the app ships, each translation carries the same format
placeholders as the English text (in any order), plural variants cover the categories each language needs, and
the catalogs hold no Russian localization. Every literal the Swift source uses as a localization key (Text("…"),
Button("…"), String(localized: "…") and the like) is in Localizable.xcstrings. Fails with a list of what's wrong.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = [ROOT / "App/Resources/Localizable.xcstrings", ROOT / "App/Resources/InfoPlist.xcstrings"]

# The languages Vespertine ships, besides English. Russian is deliberately not one of them.
LANGUAGES = [
    "am", "ar", "bn", "cs", "da", "de", "el", "es", "fa", "fi", "fil", "fr", "gu", "ha", "he", "hi", "hu", "id",
    "it", "ja", "kn", "ko", "ml", "mr", "ms", "nb", "nl", "pa", "pl", "pt-BR", "pt-PT", "ro", "sv", "sw", "ta",
    "te", "th", "tr", "uk", "ur", "vi", "zh-Hans", "zh-Hant", "zh-HK",
]
FORBIDDEN = {"ru"}

# CLDR plural categories each language needs for integers (besides "other", always required).
PLURALS = {
    "am": {"one"}, "ar": {"zero", "one", "two", "few", "many"}, "bn": {"one"}, "cs": {"one", "few"},
    "da": {"one"}, "de": {"one"}, "el": {"one"}, "en": {"one"}, "es": {"one"}, "fa": {"one"}, "fi": {"one"},
    "fil": {"one"}, "fr": {"one"}, "gu": {"one"}, "ha": {"one"}, "he": {"one", "two"}, "hi": {"one"},
    "hu": {"one"}, "id": set(), "it": {"one"}, "ja": set(), "kn": {"one"}, "ko": set(), "ml": {"one"},
    "mr": {"one"}, "ms": set(), "nb": {"one"}, "nl": {"one"}, "pa": {"one"}, "pl": {"one", "few", "many"},
    "pt-BR": {"one"}, "pt-PT": {"one"}, "ro": {"one", "few"}, "sv": {"one"}, "sw": {"one"}, "ta": {"one"},
    "te": {"one"}, "th": set(), "tr": {"one"}, "uk": {"one", "few", "many"}, "ur": {"one"}, "vi": set(),
    "zh-Hans": set(), "zh-Hant": set(), "zh-HK": set(),
}

PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?([-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGcCsSpaA]|#@[^@]+@)")


def placeholders(text):
    """The format arguments a string consumes, by position: {position: specifier}."""
    found, position = {}, 0
    for match in PLACEHOLDER.finditer(text.replace("%%", "")):
        spec = match.group(2)
        if spec.startswith("#@"):
            continue  # a substitution, checked through its own variants
        if match.group(1):
            index = int(match.group(1))
        else:
            position += 1
            index = position
        found[index] = spec
    return found


def units(localization):
    """Every (label, text) a localization can show: its string, plural variants and substitutions."""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"]
    for kind, variants in localization.get("variations", {}).items():
        for name, variant in variants.items():
            for label, unit in units(variant):
                yield f"{kind}.{name}{label}", unit
    for name, sub in localization.get("substitutions", {}).items():
        for label, unit in units(sub):
            yield f"sub.{name}{label}", unit


def all_placeholders(localization):
    """Placeholders across a localization's main string and substitutions, with substitutions at their argNum."""
    result = {}
    texts = [u["value"] for label, u in units(localization) if not label.startswith("sub.")]
    for text in texts:
        result.update(placeholders(text))
    for sub in localization.get("substitutions", {}).values():
        result[sub.get("argNum", 1)] = sub.get("formatSpecifier", "lld")
    return result


def normalize(specs):
    return {k: re.sub(r"[-+ #0]*\d*(\.\d+)?", "", v) for k, v in specs.items()}


def check(path, problems):
    catalog = json.loads(path.read_text(encoding="utf-8"))
    source = catalog.get("sourceLanguage", "en")
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        for language in FORBIDDEN & localizations.keys():
            problems.append(f"{path.name}: {key!r} has a {language} localization")
        english = localizations.get(source)
        expected = normalize(all_placeholders(english)) if english else normalize(placeholders(key))
        english_plural = bool(english and ("variations" in english or "substitutions" in english))
        for language in LANGUAGES:
            localization = localizations.get(language)
            if localization is None:
                problems.append(f"{path.name}: {key!r} is not translated into {language}")
                continue
            for label, unit in units(localization):
                if unit.get("state") not in ("translated", None):
                    problems.append(f"{path.name}: {key!r} [{language}{label}] is marked {unit.get('state')}")
                if not unit.get("value", "").strip() and key.strip():
                    problems.append(f"{path.name}: {key!r} [{language}{label}] is empty")
            got = normalize(all_placeholders(localization))
            # A plural variant may leave the count out ("one song" in place of "1 song"), so variants are checked
            # against the English arguments as a whole, not one by one.
            if got != expected and not (english_plural and set(got) <= set(expected)):
                problems.append(f"{path.name}: {key!r} [{language}] has placeholders {got}, English has {expected}")
            plural = localization.get("variations", {}).get("plural")
            # A whole-string plural follows one argument, which Xcode guesses (the first, mostly). With two counts the
            # guess can pick the wrong one ("1 of 5 song"), so the count that drives the wording needs a substitution.
            counts = [i for i, spec in normalize(placeholders(key)).items() if spec in ("lld", "ld", "d")]
            if plural and len(counts) > 1:
                problems.append(f"{path.name}: {key!r} [{language}] has a whole-string plural with {len(counts)} counts")
            subs = [s for s in localization.get("substitutions", {}).values()]
            needs = PLURALS[language]
            for variants in ([plural] if plural else []) + [s.get("variations", {}).get("plural", {}) for s in subs]:
                missing = ({"other"} | needs) - variants.keys()
                if missing:
                    problems.append(f"{path.name}: {key!r} [{language}] lacks plural forms {sorted(missing)}")


# Where a string literal in the source becomes a key of Localizable.xcstrings: the SwiftUI views and modifiers that
# take a LocalizedStringKey, String(localized:) (the packages' too: they look their text up in the app's main bundle)
# and the analysis package's localized(_:). The first argument may be a ternary between two literals.
SOURCES = ["App/Sources/**/*.swift", "Packages/*/Sources/**/*.swift"]
LOCALIZING = re.compile(
    r'(?:\b(?:Text|Button|Label|Toggle|Section|Picker|LabeledContent|Menu|TextField|SecureField|Link|GroupBox'
    r'|DisclosureGroup|ContentUnavailableView|Stepper|ProgressView)\(|\.(?:navigationTitle|help|accessibilityLabel'
    r'|accessibilityValue|accessibilityHint|alert|confirmationDialog)\(|\bString\(localized:|\blocalized\()'
    r'\s*(?:[^"(){},]*\s\?\s*)?(?=")'
)
# Literals in those places that are deliberately not localized.
NOT_LOCALIZED = {
    "\u2066\u2212",  # TransportBar: an isolate and minus sign concatenated before the remaining time
    " \u00b7 ",  # AlbumsViews: the separator joined back between a summary's parts
}
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def literal(source, start):
    """The Swift string literal opening at `start` as a catalog key with its interpolations as \\0, and where it ends."""
    end = '"""' if source.startswith('"""', start) else '"'
    i, text = start + len(end), []
    while not source.startswith(end, i):
        char = source[i]
        if char == "\\" and source[i + 1] == "(":
            depth, i = 1, i + 2
            while depth:
                if source[i] == '"':
                    i = literal(source, i)[1]
                    continue
                depth += {"(": 1, ")": -1}.get(source[i], 0)
                i += 1
            text.append("\0")
        elif char == "\\" and source[i + 1] == "u":
            close = source.index("}", i)
            text.append(chr(int(source[i + 3:close], 16)))
            i = close + 1
        elif char == "\\":
            text.append(ESCAPES.get(source[i + 1], source[i + 1]))
            i += 2
        else:
            text.append(char)
            i += 1
    text = "".join(text)
    if end == '"""':  # a multi-line literal drops its first and last line breaks and the closing line's indentation
        *lines, indent = text[1:].split("\n")
        text = "\n".join(line[len(indent):] for line in lines)
    return text, i + len(end)


def check_sources(problems):
    """Every literal the source uses as a localization key is in Localizable.xcstrings."""
    catalog = json.loads(CATALOGS[0].read_text(encoding="utf-8"))["strings"]
    # Interpolations become %@, %lld… by the value's type, which a scan can't know: compare with every argument as \0.
    keys = {PLACEHOLDER.sub("\0", key.replace("%%", "\1")).replace("\1", "%") for key in catalog}
    for pattern in SOURCES:
        for path in sorted(ROOT.glob(pattern)):
            source = path.read_text(encoding="utf-8")
            for match in LOCALIZING.finditer(source):
                found = [literal(source, match.end())]
                end = found[0][1]
                branch = re.match(r'\s*:\s*(?=")', source[end:])  # the other side of a ternary
                if branch and match.group(0).rstrip().endswith("?"):
                    found.append(literal(source, end + branch.end()))
                for key, _ in found:
                    if key and key not in keys and key not in NOT_LOCALIZED:
                        line = source.count("\n", 0, match.start()) + 1
                        shown = key.replace("\0", "%@")
                        problems.append(f"{path.relative_to(ROOT)}:{line}: {shown!r} is not in Localizable.xcstrings")


def main():
    problems = []
    for path in CATALOGS:
        if not path.exists():
            problems.append(f"{path.relative_to(ROOT)} is missing")
            continue
        check(path, problems)
    if CATALOGS[0].exists():
        check_sources(problems)
    if any((ROOT / "App").rglob("ru.lproj")):
        problems.append("App/ contains a ru.lproj")
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} localization problem(s)")
        return 1
    print(f"Localizations complete: {len(LANGUAGES)} languages besides English")
    return 0


if __name__ == "__main__":
    sys.exit(main())
