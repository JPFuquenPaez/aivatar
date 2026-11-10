#!/bin/bash
# check_localization.sh — CI guard for the strings tables (v31).
#
# The app test host cannot reach the widget extension's bundle, so
# LocalizationTests covers only the app table. This script closes the gap:
#   1. en/fr key-set equality per bundle (app + widget)
#   2. app<->widget VALUE equality for the mirrored shared keys, en and fr
#   3. en/fr placeholder-sequence parity per bundle (a fr value that drops
#      or reorders %@/%d silently corrupts String(format:) at runtime)
#   4. every dynamic key prefix used in code, expanded, exists in the table
#      (animal.<archetype>.{name,element,temperament}, weather.<class>)
#
# Exits non-zero on any drift. Run in CI after the build job:
#   Tools/check_localization.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PYEOF'
import io, re, sys, os

root = sys.argv[1]
app_en = os.path.join(root, "Aivatar Watch App/en.lproj/Localizable.strings")
app_fr = os.path.join(root, "Aivatar Watch App/fr.lproj/Localizable.strings")
wid_en = os.path.join(root, "Aivatar Widgets/en.lproj/Localizable.strings")
wid_fr = os.path.join(root, "Aivatar Widgets/fr.lproj/Localizable.strings")

def parse(path):
    table = {}
    for line in io.open(path, encoding="utf-8"):
        m = re.match(r'^"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', line)
        if m:
            table[m.group(1)] = m.group(2)
    return table

def placeholders(s):
    return re.findall(r"%\d*\$?[@d]", s)

failures = []
def check(cond, msg):
    if not cond:
        failures.append(msg)

tables = {p: parse(p) for p in (app_en, app_fr, wid_en, wid_fr)}
for p, t in tables.items():
    check(len(t) > 0, f"{p}: parsed zero keys (format drift?)")

# 1. en/fr key-set equality per bundle
for name, en, fr in (("app", app_en, app_fr), ("widget", wid_en, wid_fr)):
    missing_fr = sorted(set(tables[en]) - set(tables[fr]))
    missing_en = sorted(set(tables[fr]) - set(tables[en]))
    check(not missing_fr, f"{name}: keys missing in fr: {missing_fr}")
    check(not missing_en, f"{name}: keys missing in en: {missing_en}")

# 2. mirrored shared keys: identical VALUES in app and widget, en and fr
shared_prefixes = ("presence.", "inline.line", "rect.line", "animal.", "identity.full")
shared_keys = sorted(k for k in tables[app_en] if k.startswith(shared_prefixes))
for k in shared_keys:
    for bundle, w in (("en", wid_en), ("fr", wid_fr)):
        a = tables[app_en if bundle == "en" else app_fr]
        check(k in tables[w], f"widget {bundle}: missing shared key {k}")
        if k in tables[w] and k in a:
            check(tables[w][k] == a[k],
                  f"widget {bundle} value drift for {k}: app={a[k]!r} widget={tables[w][k]!r}")

# 3. placeholder parity en/fr per bundle
for name, en, fr in (("app", app_en, app_fr), ("widget", wid_en, wid_fr)):
    for k in tables[en]:
        if k in tables[fr]:
            check(placeholders(tables[en][k]) == placeholders(tables[fr][k]),
                  f"{name}/{k}: placeholder sequence differs en vs fr")

# 4. dynamic key prefixes expanded over the closed sets used in code
archetypes = ["ember", "willow", "compass", "prism", "nimbus"]
weather = ["sunny", "gray", "rain", "wind", "cold", "hot", "unknown"]
dynamic = ([f"animal.{a}.{f}" for a in archetypes for f in ("name", "element", "temperament")]
           + [f"weather.{w}" for w in weather])
for k in dynamic:
    check(k in tables[app_en], f"app en: missing dynamic key {k}")
    check(k in tables[app_fr], f"app fr: missing dynamic key {k}")
    if any(k.startswith(p) for p in ("animal.",)):
        check(k in tables[wid_en], f"widget en: missing mirrored key {k}")
        check(k in tables[wid_fr], f"widget fr: missing mirrored key {k}")

if failures:
    print("LOCALIZATION CHECK FAILED:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print(f"LOCALIZATION CHECK PASSED: app {len(tables[app_en])}/{len(tables[app_fr])} keys, "
      f"widget {len(tables[wid_en])}/{len(tables[wid_fr])} keys, {len(shared_keys)} shared keys mirrored, "
      f"{len(dynamic)} dynamic keys present, placeholder parity holds.")
PYEOF
