#!/usr/bin/env python3
"""Checks Vespertine's String Catalogs: the Mac app's and its helper's (App/Resources, Helper/Resources) and the iPhone
and iPad app's (RemoteApp/Resources).

    python3 scripts/check-localizations.py

Every string is translated into every language the app ships, each translation carries the same format
placeholders as the English text (in any order), plural variants cover the categories each language needs, and
the catalogs hold no Russian localization. Every literal the Swift source uses as a localization key (Text("…"),
Button("…"), String(localized: "…") and the like) is in the Localizable.xcstrings of the app that shows it: the Mac app's
for App/, Helper/ and the packages, the iOS app's for RemoteApp/ and the two package targets only the phone runs. That
includes literals handed to the source's own functions and views that take a LocalizedStringKey, and the key must carry
the placeholders Swift makes of the interpolated values (%lld for an Int, %@ for a String), wherever the source shows
their type: a key under another placeholder is never found at run time, and the text stays English. Fails with a list
of what's wrong.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAC_STRINGS = ROOT / "App/Resources/Localizable.xcstrings"
IOS_STRINGS = ROOT / "RemoteApp/Resources/Localizable.xcstrings"
CATALOGS = [MAC_STRINGS, ROOT / "App/Resources/InfoPlist.xcstrings", ROOT / "Helper/Resources/InfoPlist.xcstrings",
            IOS_STRINGS, ROOT / "RemoteApp/Resources/InfoPlist.xcstrings"]

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
# The package targets only the iPhone and iPad app runs: their text is looked up in that app's bundle.
PHONE_ONLY = ["Packages/VespertineRemoteKit/Sources/VespertinePhonePlayer/", "Packages/VespertineRemoteKit/Sources/VespertineRemoteClient/"]
# (catalog, the sources whose keys it must hold, the folders among them that belong to another catalog)
SOURCE_SETS = [
    (MAC_STRINGS, ["App/Sources/**/*.swift", "Helper/Sources/**/*.swift", "Packages/*/Sources/**/*.swift"], PHONE_ONLY),
    (IOS_STRINGS, ["RemoteApp/Sources/**/*.swift"] + [folder + "**/*.swift" for folder in PHONE_ONLY], []),
]
LOCALIZING = re.compile(
    r'(?:\b(?:Text|Button|Label|Toggle|Section|Picker|LabeledContent|Menu|TextField|SecureField|Link|GroupBox'
    r'|DisclosureGroup|ContentUnavailableView|Stepper|ProgressView)\(|\.(?:navigationTitle|help|accessibilityLabel'
    r'|accessibilityValue|accessibilityHint|alert|confirmationDialog)\(|\bString\(localized:|\bLocalizedStringKey\(|\blocalized\()'
    r'\s*(?:[^"(){},]*\s\?\s*)?(?=")'
)
# Literals in those places that are deliberately not localized.
NOT_LOCALIZED = {
    "\u2066\u2212",  # TransportBar: an isolate and minus sign concatenated before the remaining time
    " \u00b7 ",  # AlbumsViews: the separator joined back between a summary's parts
}
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def literal(source, start):
    """The Swift string literal opening at `start` as a catalog key with its interpolations as \\0, where it ends, and
    the source of each interpolated expression."""
    end = '"""' if source.startswith('"""', start) else '"'
    i, text, interpolated = start + len(end), [], []
    while not source.startswith(end, i):
        char = source[i]
        if char == "\\" and source[i + 1] == "(":
            depth, i = 1, i + 2
            opened = i
            while depth:
                if source[i] == '"':
                    i = literal(source, i)[1]
                    continue
                depth += {"(": 1, ")": -1}.get(source[i], 0)
                i += 1
            text.append("\0")
            interpolated.append((source[opened:i - 1], opened))
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
    return text, i + len(end), interpolated


def code(source):
    """The source with its comments blanked out (same length, so positions and line numbers hold)."""
    out, i = list(source), 0
    try:
        while i < len(source):
            if source[i] == '"':
                i = literal(source, i)[1]
            elif source.startswith("//", i) or source.startswith("/*", i):
                close = source.find("\n", i) if source[i + 1] == "/" else source.find("*/", i) + 2
                close = len(source) if close in (-1, 1) else close
                out[i:close] = [c if c == "\n" else " " for c in source[i:close]]
                i = close
            else:
                i += 1
    except (IndexError, ValueError):
        return source  # something this scan can't read (a regex literal with a quote, say): check the file as it is
    return "".join(out)


def block(source, start, opening="(", closing=")"):
    """Where the bracket open just before `start` closes, string literals skipped; the end of the source if it never does."""
    depth, i = 1, start
    while i < len(source):
        if source[i] == '"':
            i = literal(source, i)[1]
            continue
        depth += {opening: 1, closing: -1}.get(source[i], 0)
        if not depth:
            return i
        i += 1
    return len(source)


def arguments(source, start):
    """The arguments of the call or declaration whose parenthesis opens just before `start`, as (text, position)."""
    end, depth, i, begin = block(source, start), 0, start, start
    while i < end:
        if source[i] == '"':
            i = literal(source, i)[1]
            continue
        if source.startswith("->", i):
            i += 2
            continue
        depth += {"(": 1, "[": 1, "{": 1, "<": 1, ")": -1, "]": -1, "}": -1, ">": -1}.get(source[i], 0)
        if source[i] == "," and depth <= 0:
            yield source[begin:i], begin
            begin, depth = i + 1, 0
        i += 1
    if source[begin:end].strip():
        yield source[begin:end], begin


def literals(source, start):
    """The literal at `start`, and the one on the other side of a ternary when `start` is a condition: (key, interpolations)."""
    lead = TERNARY.match(source, start)
    if not lead:
        return
    key, end, interpolated = literal(source, lead.end())
    yield key, interpolated
    branch = re.match(r'\s*:\s*(?=")', source[end:])
    if branch and lead.group(0).rstrip().endswith("?"):
        key, _, interpolated = literal(source, end + branch.end())
        yield key, interpolated


TERNARY = re.compile(r'\s*(?:[^"(){},]*\s\?\s*)?(?=")')
KEY_TYPE = r"(?:@\w+\s+)*LocalizedStringKey\??"
TYPE = re.compile(r"^[ \t]*[^\n/]*\b(?:struct|class|actor|enum|extension)\s+(\w+)[^\n]*\{[ \t]*$")


def enclosing_type(source, position):
    """The type whose body the declaration at `position` sits directly in, judged by indentation; None inside a function."""
    lines = source[:position].split("\n")
    indent = len(lines[-1]) - len(lines[-1].lstrip())
    for line in reversed(lines[:-1]):
        if line.strip() and len(line) - len(line.lstrip()) < indent and line.rstrip().endswith("{"):
            found = TYPE.match(line)
            return found.group(1) if found else None
    return None


def key_parameters(source):
    """The source's own functions and views that take a LocalizedStringKey: (name, private, positions of the unlabeled
    arguments that are keys, labels of the labeled ones). A literal passed there becomes a key like one passed to Text."""
    for match in re.finditer(r"\b(?:func\s+(\w+)|init)\s*(?:<[^>(]*>)?\(", source):
        name = match.group(1) or enclosing_type(source, match.start())
        line = source[source.rfind("\n", 0, match.start()) + 1:match.start()]
        positions, labels, unlabeled = set(), set(), 0
        for text, _ in arguments(source, match.end()):
            parameter = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(\w+)(?:\s+\w+)?\s*:\s*(.*)", text, re.S)
            if not parameter:
                continue
            is_key = re.match(KEY_TYPE + r"\s*(?:=|$)", parameter.group(2))
            if parameter.group(1) == "_":
                if is_key:
                    positions.add(unlabeled)
                unlabeled += 1
            elif is_key:
                labels.add(parameter.group(1))
        if name and (positions or labels):
            yield name, bool(match.group(1)) and bool(re.search(r"\b(?:file)?private\b", line)), positions, labels
    # A view's stored properties are the labels of its memberwise initializer.
    for match in re.finditer(r"^[ \t]*(?:@\w+\s+)*(?:\w+\s+)?(?:let|var)\s+(\w+)\s*:\s*" + KEY_TYPE + r"[ \t]*(?:=[^\n]*)?$", source, re.M):
        name = enclosing_type(source, match.start(1))
        if name:
            yield name, False, set(), {match.group(1)}


def uses(source, helpers):
    """Every place a literal in `source` becomes a localization key: (position, key, interpolations)."""
    for match in LOCALIZING.finditer(source):
        for key, interpolated in literals(source, match.end()):
            yield match.start(), key, interpolated
    # Literals handed to the source's own functions and views that take a LocalizedStringKey.
    for name, (positions, labels) in helpers.items():
        for match in re.finditer(r"(?<![\w])(?<!func )" + re.escape(name) + r"\(", source):
            unlabeled = 0
            for text, start in arguments(source, match.end()):
                label = re.match(r"\s*(\w+)\s*:(?!:)\s*", text)
                if label and "?" in text[:label.end()]:
                    label = None
                if not label:
                    unlabeled += 1
                if (label.group(1) in labels) if label else (unlabeled - 1 in positions):
                    for key, interpolated in literals(source, start + (label.end() if label else 0)):
                        yield match.start(), key, interpolated
    # Literals a property or function typed LocalizedStringKey holds or returns.
    for match in re.finditer(r"(?::|->)\s*" + KEY_TYPE + r"\s*(\{|=\s*)", source):
        if match.group(1) == "{":
            spans = [(match.end(), block(source, match.end(), "{", "}"))]
        else:
            spans, at = [], match.end()
            if source[at] == '"':
                spans = [(at, literal(source, at)[1])]
            while re.match(r"(?:switch|if|else)\b", source[at:]):  # a switch or if expression: every branch's literal
                opened = source.index("{", at) + 1
                closed = block(source, opened, "{", "}")
                spans.append((opened, closed))
                at = closed + 1 + len(re.match(r"\s*", source[closed + 1:]).group(0))
        for start, end in spans:
            i = start
            while i < end:
                if source[i] == '"':
                    key, i, interpolated = literal(source, i)
                    yield start, key, interpolated
                else:
                    i += 1


# What an interpolated value becomes in a key, by its type. Other types are left to the catalog.
SPECIFIERS = {"Int": "lld", "Int64": "lld", "Int32": "d", "UInt": "llu", "UInt64": "llu", "UInt32": "u",
              "Double": "lf", "Float": "f", "String": "@", "Substring": "@"}


def payloads(sources):
    """The types each enum case carries, by case name: {name: [type, …]}; None where two enums disagree."""
    found = {}
    for source in sources:
        for line in re.finditer(r"^[ \t]*(?:indirect\s+)?case\s+(?![.(]|let\b)([^\n]*[^:\n{])$", source, re.M):
            if re.search(r"\blet\b", line.group(1)):
                continue
            for case in re.finditer(r"\b(\w+)\(([^()]*)\)", line.group(1)):
                types = [re.sub(r"^\s*(?:\w+\s*:)?\s*", "", part).strip() for part in case.group(2).split(",")]
                found[case.group(1)] = types if found.get(case.group(1), types) == types else None
    return found


def specifier(expression, source, position, cases, depth=0):
    """The placeholder Swift makes of an interpolated expression, where the source shows its type; None where it doesn't."""
    expression = expression.strip()
    call = re.fullmatch(r"(\w+)\((.*)\)", expression, re.S)
    if call and call.group(1) in SPECIFIERS and block(call.group(2) + ")", 0) == len(call.group(2)):
        return SPECIFIERS[call.group(1)]
    if re.fullmatch(r"[\w.]+\.count", expression):
        return "lld"
    if re.fullmatch(r"[\w.]+(?:\([^()]*\))?\.formatted\((?:[^()]|\([^()]*\))*\)", expression):
        return "@"
    name = re.fullmatch(r"(\w+)(?:\s*[-+]\s*\d+)?", expression)
    if not name or depth > 2 or name.group(1)[0].isdigit():
        return None
    name, before = re.escape(name.group(1)), source[:position]
    bound = []  # (where, placeholder) for each thing before here that could have given the name its value

    def last(pattern):
        return ([None] + list(re.finditer(pattern, before)))[-1]

    declared = last(r"\b" + name + r"\s*:\s*(\w+)\b(?!\s*[.(<\[?])")
    if declared:
        bound.append((declared.start(), SPECIFIERS.get(declared.group(1))))
    assigned = last(r"(?:\b(?:let|var)\s+|,\s*)" + name + r"\s*=(?!=)\s*")
    if assigned:  # let name = value, alone or in a list of them
        value = next(arguments(source[assigned.end():source.find("\n", assigned.end())] + ")", 0), ("", 0))[0]
        bound.append((assigned.start(), specifier(value, source, assigned.start(), cases, depth + 1)))
    for other in (r"\b(?:let|var)\s+\([^)\n]*\b" + name + r"\b", r"[{,(]\s*" + name + r"\s*(?:,[^{}\n]*)?\bin\b",
                  r"\bfor\s+(?:\([^)\n]*\b)?" + name + r"\b", r"\b(?:let|var)\s+" + name + r"\b(?!\s*[:=])(?![^\n]*\)\s*[:=,)])"):
        match = last(other)
        if match:
            bound.append((match.start(), None))
    counted = last(r"\bfor\s+" + name + r"\s+in\s+[^\n{]*\.\.[.<]")
    if counted:
        bound.append((counted.start() + 1, "lld"))
    for pattern in re.finditer(r"(\blet\s+)?\.(\w+)\(([^()\n]*)\)", before):
        parts = [part.strip() for part in pattern.group(3).split(",")]
        for index, part in enumerate(parts):
            if re.fullmatch(r"(?:\w+\s*:\s*)?(?:let\s+)?" + name, part) and (pattern.group(1) or "let " in part):
                types = cases.get(pattern.group(2))
                bound.append((pattern.start(), SPECIFIERS.get(types[index]) if types and index < len(types) else None))
    return max(bound, key=lambda b: b[0])[1] if bound else None  # the nearest one before the string


def check_sources(strings, patterns, elsewhere, problems):
    """Every literal the sources matching `patterns` use as a localization key is in the catalog at `strings`."""
    catalog = json.loads(strings.read_text(encoding="utf-8"))["strings"]
    # Interpolations become %@, %lld… by the value's type, which a scan can only sometimes know: a key is first looked
    # for with every argument as \0, then its placeholders are compared wherever the source shows the type.
    keys = {}
    for key in catalog:
        shape = PLACEHOLDER.sub("\0", key.replace("%%", "\1")).replace("\1", "%")
        specs = [re.sub(r"^(?:\d+\$)?[-+ #0]*\d*(\.\d+)?", "", m.group(0)[1:]) for m in PLACEHOLDER.finditer(key.replace("%%", ""))]
        keys.setdefault(shape, []).append((key, specs))
    sources = {}
    for pattern in patterns:
        for path in sorted(ROOT.glob(pattern)):
            if not any(path.relative_to(ROOT).as_posix().startswith(folder) for folder in elsewhere):
                sources[path] = code(path.read_text(encoding="utf-8"))
    cases = payloads(sources.values())
    shared, private = {}, {}
    for path, source in sources.items():
        for name, is_private, positions, labels in key_parameters(source):
            slot = private.setdefault(path, {}) if is_private else shared
            slot.setdefault(name, (set(), set()))
            slot[name][0].update(positions)
            slot[name][1].update(labels)
    for path, source in sources.items():
        helpers = dict(shared)
        for name, (positions, labels) in private.get(path, {}).items():
            helpers[name] = (positions | helpers.get(name, (set(), set()))[0], labels | helpers.get(name, (set(), set()))[1])
        seen = set()
        for position, key, interpolated in uses(source, helpers):
            line = source.count("\n", 0, position) + 1
            if not key or key in NOT_LOCALIZED or (line, key) in seen:
                continue
            seen.add((line, key))
            where = f"{path.relative_to(ROOT)}:{line}"
            if key not in keys:
                problems.append(f"{where}: {key.replace(chr(0), '%@')!r} is not in {strings.relative_to(ROOT)}")
                continue
            known = [specifier(expression, source, at, cases) for expression, at in interpolated]
            if not any(all(k is None or k == s for k, s in zip(known, specs)) for _, specs in keys[key]):
                parts = iter(known)
                looked_up = "".join("%" + (next(parts) or "@") if c == "\0" else c for c in key)
                problems.append(f"{where}: the source looks up {looked_up!r}, {strings.relative_to(ROOT)} has it as "
                                f"{' and '.join(repr(k) for k, _ in keys[key])}")


def main():
    problems = []
    for path in CATALOGS:
        if not path.exists():
            problems.append(f"{path.relative_to(ROOT)} is missing")
            continue
        check(path, problems)
    for strings, patterns, elsewhere in SOURCE_SETS:
        if strings.exists():
            check_sources(strings, patterns, elsewhere, problems)
    if any((ROOT / "App").rglob("ru.lproj")) or any((ROOT / "RemoteApp").rglob("ru.lproj")):
        problems.append("App/ or RemoteApp/ contains a ru.lproj")
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} localization problem(s)")
        return 1
    print(f"Localizations complete: {len(LANGUAGES)} languages besides English")
    return 0


if __name__ == "__main__":
    sys.exit(main())
