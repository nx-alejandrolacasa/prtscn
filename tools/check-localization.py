#!/usr/bin/env python3
"""Cross-check the UI strings the code uses against every .lproj table.

Usage: tools/check-localization.py            (exit 1 on any gap)

Collects every localizable key from Sources/PrtScn — `String(localized:)`
calls and SwiftUI literal initializers that take a LocalizedStringKey (Text,
Label, Button, Toggle, Picker, Section, LabeledContent, TextField, ColorPicker,
.help, .accessibilityLabel) — then, per Resources/<lang>.lproj/Localizable.strings,
reports keys the code uses that the table lacks, and table keys the code no
longer uses. String interpolations are compared position-insensitively
(`\\(x)` ↔ `%@` / `%lld`), so the format specifier itself isn't validated.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "PrtScn"
RESOURCES = ROOT / "Resources"

# Literals that are never looked up: units, glyphs, and the app's own name.
IGNORED = {"×", "px", "pt", "Aa", "Ff", "PrtScn", ""}

SINGLE = re.compile(
    r'(?:String\(localized: |\b(?:Text|Label|Button|Toggle|Picker|Section|LabeledContent|'
    r'TextField|ColorPicker)\(|\.help\(|\.accessibilityLabel\()"((?:\\\((?:[^()"]|"[^"]*"|\([^()]*\))*\)|[^"\\]|\\.)+)"'
)
EXPLICIT_KEY = re.compile(r'String\(localized: "([^"]+)", defaultValue:')
MULTILINE_START = re.compile(r'(?:String\(localized: |\bText\()"""\s*$')
INTERP = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')  # \( ... ) with one nesting level


def normalize(key: str) -> str:
    """Collapse interpolations / format specifiers so both sides compare equal."""
    key = INTERP.sub("%", key)
    key = re.sub(r'%(\d+\$)?(lld|ld|d|@|lf|f|s)', "%", key)
    return key.replace('\\"', '"').replace("\\n", "\n")


def swift_keys():
    keys = {}
    for path in sorted(SOURCES.glob("*.swift")):
        lines = path.read_text().split("\n")
        i = 0
        while i < len(lines):
            line = lines[i]
            if line.lstrip().startswith("//"):
                i += 1; continue
            if MULTILINE_START.search(line):
                body = []
                i += 1
                while i < len(lines) and not lines[i].strip().startswith('"""'):
                    body.append(lines[i]); i += 1
                indent = min((len(l) - len(l.lstrip()) for l in body if l.strip()), default=0)
                text = "\n".join(l[indent:] for l in body)
                text = re.sub(r'\\\n', "", text)          # `\` line continuations
                keys.setdefault(normalize(text), []).append(f"{path.name}:{i}")
                i += 1; continue
            for m in EXPLICIT_KEY.finditer(line):
                keys.setdefault(m.group(1), []).append(f"{path.name}:{i + 1}")
            for m in SINGLE.finditer(line):
                if EXPLICIT_KEY.match(line[m.start():]):
                    continue
                k = m.group(1)
                # Pure interpolation like "\(n)" is a number readout, not a phrase.
                if k in IGNORED or INTERP.fullmatch(k):
                    continue
                keys.setdefault(normalize(k), []).append(f"{path.name}:{i + 1}")
            i += 1
    return keys


def table_keys(path):
    text = re.sub(r'/\*.*?\*/', "", path.read_text(), flags=re.S)
    return {normalize(m.group(1)) for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=', text, re.M)}


def main():
    used = swift_keys()
    failed = False
    for table in sorted(RESOURCES.glob("*.lproj/Localizable.strings")):
        have = table_keys(table)
        missing = sorted(k for k in used if k not in have)
        stale = sorted(have - used.keys())
        rel = table.relative_to(ROOT)
        if missing or stale:
            failed = True
        for k in missing:
            print(f"{rel}: MISSING  {k!r}   used at {', '.join(used[k])}")
        for k in stale:
            print(f"{rel}: UNUSED   {k!r}")
        print(f"{rel}: {len(have)} keys, {len(missing)} missing, {len(stale)} unused")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
