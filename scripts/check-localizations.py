#!/usr/bin/env python3
"""Checks Vespertine's String Catalogs (App/Resources/*.xcstrings).

    python3 scripts/check-localizations.py

Every string is translated into every language the app ships, each translation carries the same format
placeholders as the English text (in any order), plural variants cover the categories each language needs, and
the catalogs hold no Russian localization. Fails with a list of what's wrong.
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


def main():
    problems = []
    for path in CATALOGS:
        if not path.exists():
            problems.append(f"{path.relative_to(ROOT)} is missing")
            continue
        check(path, problems)
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
