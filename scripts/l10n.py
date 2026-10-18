#!/usr/bin/env python3
"""Translations for wwwrap (Indonesian source text, English translation).

Source of truth: Localization/en.json
    { "app":       { "<Indonesian text>": "<English text>", ... },
      "extension": { ... } }

Indonesian is written directly in the code, wrapped in L("...") (Swift) or t("...") (extension).
The Indonesian text *is* the key, so the code stays readable and Indonesian needs no table.

    python3 scripts/l10n.py            # check everything, regenerate code, exit 1 on problems
    python3 scripts/l10n.py --check    # check only; also fails if generated files are stale (CI)

Checks
  - every L("...") / t("...") key has an English translation, and no translation is unused
  - no key is built at runtime (string interpolation inside L(...))
  - format specifiers (%ld, %@ ...) match between Indonesian and English, per plural variant
    ("one|other" in English picks a variant by the first integer argument)
  - user-visible text that was left unwrapped in SwiftUI views (Text("..."), Button("..."), ...)

Generated
  - Sources/wwwrap/Localization/Strings.generated.swift
  - ChromeExtension/strings.js
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localization", "en.json")
SWIFT_DIRS = ["Sources/wwwrap", "Sources/DownloadCore"]
SWIFT_OUT = os.path.join(ROOT, "Sources/wwwrap/Localization/Strings.generated.swift")
EXT_DIR = os.path.join(ROOT, "ChromeExtension")
EXT_OUT = os.path.join(EXT_DIR, "strings.js")

# Unwrapped literals right after these are user-visible text and must go through L().
UI_CONTEXT = re.compile(
    r"(?:\bText|\bButton|\bToggle|\bLabel|\.help|\bTextField|\bPicker|\bMenu|\bconfirmationDialog"
    r"|\bSectionTitle|\bSettingsGroup|\bSettingsRow|\bflash|\bUNNotificationAction)\s*\((?:[^()]*,\s*)?$"
    r"|\b(?:title|detail|subtitle|message|label|body)\s*[:=]\s*$"
)
# Literals that are never shown to users or are identical in both languages.
NEUTRAL = {"wwwrap", "Download", "GitHub", "Chromium", "Firefox"}
SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:lld|ld|d|@|f|s|%)")


def specifiers(text):
    return sorted(s for s in SPEC.findall(text) if s != "%%")


def swift_literals(path):
    """Yields (line, literal, code_before) for every plain string literal, skipping comments."""
    src = open(path, encoding="utf-8").read()
    i, n, line = 0, len(src), 1
    code_tail = ""  # recent code on this logical stretch, used to see what precedes a literal
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            code_tail += c
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            line += src[i:j].count("\n")
            i = n if j < 0 else j + 2
        elif c == "#" and re.match(r'#+"', src[i:]):
            # Raw string #"..."# (regexes): never user-visible, skip it whole.
            hashes = re.match(r'#+', src[i:]).group(0)
            multi = src.startswith('"""', i + len(hashes))
            close = ('"""' if multi else '"') + hashes
            j = src.find(close, i + len(hashes) + (3 if multi else 1))
            line += src[i:j].count("\n")
            i = n if j < 0 else j + len(close)
            code_tail += '""'
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3)
            line += src[i:j].count("\n")
            i = n if j < 0 else j + 3
            code_tail += '""'
        elif c == '"':
            start_line = line
            j, depth, buf = i + 1, 0, []
            while j < n:
                ch = src[j]
                if ch == "\\" and j + 1 < n:
                    if src[j + 1] == "(":
                        depth += 1
                        buf.append("\\(")
                        j += 2
                        continue
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                if depth > 0:
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                    buf.append(ch)
                    j += 1
                    continue
                if ch == '"':
                    break
                if ch == "\n":
                    line += 1
                buf.append(ch)
                j += 1
            yield start_line, "".join(buf), code_tail[-160:]
            code_tail += '""'
            i = j + 1
        else:
            code_tail += c
            i += 1


def unescape_swift(s):
    return s.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", "\n").replace("\\t", "\t")


def scan_swift(errors):
    keys = {}
    for d in SWIFT_DIRS:
        for dirpath, _, files in os.walk(os.path.join(ROOT, d)):
            for f in sorted(files):
                if not f.endswith(".swift") or f.endswith(".generated.swift"):
                    continue
                path = os.path.join(dirpath, f)
                rel = os.path.relpath(path, ROOT)
                lines = open(path, encoding="utf-8").read().split("\n")
                for ln, lit, before in swift_literals(path):
                    if re.search(r"\bL\(\s*$", before):
                        if "\\(" in lit:
                            errors.append(f"{rel}:{ln}: interpolation inside L(\"{lit}\"): use %ld / %@ and pass arguments")
                        keys.setdefault(unescape_swift(lit), f"{rel}:{ln}")
                        continue
                    if "l10n-ignore" in lines[ln - 1]:
                        continue
                    plain = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "", lit)  # text outside \(...)
                    if not re.search(r"[A-Za-z]", plain) or lit in NEUTRAL:
                        continue
                    visible = UI_CONTEXT.search(before.split("\n")[-1]) is not None
                    prose = " " in lit.strip() and re.search(r"[a-z]{2,}", lit) is not None
                    if visible or prose:
                        errors.append(f"{rel}:{ln}: text not translated: \"{lit}\" (wrap in L(...) or mark // l10n-ignore)")
    return keys


def scan_extension(errors):
    keys = {}
    for f in sorted(os.listdir(EXT_DIR)):
        path = os.path.join(EXT_DIR, f)
        rel = os.path.relpath(path, ROOT)
        if f.endswith(".js") and f not in ("strings.js", "i18n.js"):
            src = open(path, encoding="utf-8").read()
            for m in re.finditer(r"\bt\(\s*\"((?:[^\"\\]|\\.)*)\"", src):
                keys.setdefault(m.group(1).replace('\\"', '"'), f"{rel}:{src[:m.start()].count(chr(10)) + 1}")
        elif f.endswith(".html"):
            src = open(path, encoding="utf-8").read()
            # <span data-i18n>Indonesian text</span>: the element's own text is the key.
            for m in re.finditer(r"<\w+[^>]*\bdata-i18n\b[^>]*>([^<]*)<", src):
                keys.setdefault(m.group(1).strip(), f"{rel}:{src[:m.start()].count(chr(10)) + 1}")
    return keys


def check_table(name, keys, table, errors):
    for key, where in keys.items():
        value = table.get(key)
        if not value:
            errors.append(f"{where}: missing English for \"{key}\" (add it to Localization/en.json › {name})")
            continue
        want = specifiers(key)
        for variant in value.split("|"):
            if specifiers(variant) != want:
                errors.append(f"Localization/en.json › {name}: format mismatch for \"{key}\": "
                              f"{want} vs {specifiers(variant)} in \"{variant}\"")
        if "|" in value and not want:
            errors.append(f"Localization/en.json › {name}: plural variants need a number argument: \"{key}\"")
    for key in table:
        if key not in keys:
            errors.append(f"Localization/en.json › {name}: unused translation \"{key}\"")


def swift_string(s):
    return json.dumps(s, ensure_ascii=False)


def render_swift(table):
    out = [
        "// Generated by scripts/l10n.py from Localization/en.json. Do not edit by hand.",
        "",
        "enum Strings {",
        "    /// Indonesian source text → English.",
        "    static let en: [String: String] = [",
    ]
    for k in sorted(table):
        out.append(f"        {swift_string(k)}: {swift_string(table[k])},")
    out += ["    ]", "}", ""]
    return "\n".join(out)


def render_js(table):
    body = json.dumps(dict(sorted(table.items())), ensure_ascii=False, indent=2)
    return ("// Generated by scripts/l10n.py from Localization/en.json. Do not edit by hand.\n"
            "// Indonesian source text → English.\n"
            f"const STRINGS_EN = {body};\n")


def main():
    check_only = "--check" in sys.argv
    errors = []
    try:
        raw = open(CATALOG, encoding="utf-8").read()
        catalog = json.loads(raw, object_pairs_hook=lambda pairs: dup_check(pairs, errors))
    except FileNotFoundError:
        catalog = {"app": {}, "extension": {}}

    app_keys = scan_swift(errors)
    ext_keys = scan_extension(errors)
    check_table("app", app_keys, catalog.get("app", {}), errors)
    check_table("extension", ext_keys, catalog.get("extension", {}), errors)

    outputs = {SWIFT_OUT: render_swift(catalog.get("app", {})), EXT_OUT: render_js(catalog.get("extension", {}))}
    for path, text in outputs.items():
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if current == text:
            continue
        if check_only:
            errors.append(f"{os.path.relpath(path, ROOT)} is out of date: run python3 scripts/l10n.py")
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w", encoding="utf-8").write(text)

    for e in errors:
        print(e)
    print(f"l10n: {len(app_keys)} app texts, {len(ext_keys)} extension texts, {len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


def dup_check(pairs, errors):
    seen = {}
    for k, v in pairs:
        if k in seen:
            errors.append(f"Localization/en.json: duplicate key \"{k}\"")
        seen[k] = v
    return seen


if __name__ == "__main__":
    main()
