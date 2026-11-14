#!/usr/bin/env python3
"""Generate BuffTable.lua from Forever's extracted spell data (#209).

Run by a maintainer or a session, never by players, never in CI against
Blizzard, and never shipped (scripts/ is in .pkgmeta's ignore list).

    python3 scripts/gen_spell_table.py \
        --spells scripts/data/forever-spells-extended.json \
        --buffs scripts/spell-buffs.json \
        --out BuffTable.lua

Inputs:
  --spells  the file `wow-cli casc sync-forever-spells` wrote (Osso/wow-ui-sim).
  --buffs   our buffs by spell NAME: which spells make up each buff.
Output:
  BuffTable.lua, a plain data table the addon loads. Written only when every
  check passes; on any problem the script prints why, exits non-zero and
  leaves the existing file untouched.

Everything in the spell data is untrusted: IDs must be whole numbers in a sane
range, names strings of bounded length, and no spell may appear twice.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile

FORMAT = 1
MAX_SPELL_ID = 1_000_000
MAX_NAME = 100
BUILD_RE = re.compile(r"^\d+\.\d+\.\d+\.\d+$")
KEY_RE = re.compile(r"^[a-z][a-z0-9]{0,31}$")
CLASS_RE = re.compile(r"^[A-Z]{3,12}$")
# selfCast: a self-buff (#44), cast on yourself only; toggle: one that stays on
# until switched (an Aspect, a paladin aura); defaultNever: "Never offer" until
# you choose (Righteous Fury).
FLAGS = ("manaOnly", "selfCast", "water", "toggle", "defaultNever")
# Flags that only a self-buff may carry.
SELF_ONLY_FLAGS = ("toggle", "defaultNever")


class Problem(Exception):
    pass


def is_whole(value):
    # bool is an int in Python; floats (even 3.0) are refused, as are huge ints.
    return type(value) is int and 1 <= value <= MAX_SPELL_ID


def check_id(value, where):
    if not is_whole(value):
        raise Problem(f"{where}: spell ID {value!r} is not a whole number from 1 to {MAX_SPELL_ID}")
    return value


def load_json(path):
    def refuse(constant):
        raise Problem(f"{path}: {constant} is not valid JSON")

    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as err:
        raise Problem(f"cannot read {path}: {err}")
    try:
        return raw, json.loads(raw.decode("utf-8"), parse_constant=refuse)
    except (UnicodeDecodeError, ValueError) as err:
        raise Problem(f"{path} is not valid JSON: {err}")


def read_spells(data):
    """{id: (name, rank)} from the extracted file, or a Problem."""
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise Problem("spell data: unknown schema (expected 1)")
    build = data.get("build")
    if not isinstance(build, str) or not BUILD_RE.match(build):
        raise Problem(f"spell data: odd build {build!r}")
    tables = data.get("tables")
    if not isinstance(tables, dict):
        raise Problem("spell data: no tables")
    for name in ("Spell", "SpellName"):
        if not isinstance(tables.get(name), dict) or not isinstance(tables[name].get("rows"), list):
            raise Problem(f"spell data: no {name} rows")
    names = {}
    for row in tables["SpellName"]["rows"]:
        if not isinstance(row, dict):
            raise Problem("spell data: a SpellName row is not an object")
        spell_id = check_id(row.get("ID"), "SpellName")
        name = row.get("Name_lang")
        if not isinstance(name, str) or not name or len(name) > MAX_NAME:
            raise Problem(f"SpellName {spell_id}: name must be a string of 1 to {MAX_NAME} characters")
        if spell_id in names:
            raise Problem(f"SpellName {spell_id}: duplicated")
        names[spell_id] = name
    ranks = {}
    for row in tables["Spell"]["rows"]:
        if not isinstance(row, dict):
            raise Problem("spell data: a Spell row is not an object")
        spell_id = check_id(row.get("ID"), "Spell")
        if spell_id in ranks:
            raise Problem(f"Spell {spell_id}: duplicated")
        sub = row.get("NameSubtext_lang", "")
        if not isinstance(sub, str) or len(sub) > MAX_NAME:
            raise Problem(f"Spell {spell_id}: odd rank text")
        match = re.fullmatch(r"Rank (\d{1,3})", sub)
        ranks[spell_id] = int(match.group(1)) if match else 0
    if set(names) != set(ranks):
        raise Problem("spell data: Spell and SpellName list different spells")
    return build, {i: (names[i], ranks[i]) for i in names}


def by_name(spells):
    out = {}
    for spell_id, (name, _) in spells.items():
        out.setdefault(name, []).append(spell_id)
    return out


def ids_named(name, index, spells):
    """Every ID with this exact name, highest rank first."""
    ids = index.get(name, [])
    return sorted(ids, key=lambda i: (-spells[i][1], -i))


def read_buffs(data):
    if not isinstance(data, dict) or data.get("format") != 1:
        raise Problem("buff definitions: unknown format (expected 1)")
    classes = data.get("classes")
    if not isinstance(classes, dict) or not classes:
        raise Problem("buff definitions: no classes")
    removed = data.get("removed", [])
    if not isinstance(removed, list):
        raise Problem("buff definitions: removed must be a list")
    family_auras = data.get("familyAuras", {})
    if not isinstance(family_auras, dict):
        raise Problem("buff definitions: familyAuras must be an object")
    return classes, removed, family_auras


def group_cast(key, spec, buff, spells, index, report):
    """The group versions you can cast (GroupCasts.lua, #41), highest rank first.

    Each spell is found by name and rank number; `equals` is the buff's own
    rank of the same strength, found by its rank number. The reagent is an item
    ID, which the spell data does not cover: it is hand-listed in the buff
    definitions and only range-checked here (#209, #225).
    """
    if (not isinstance(spec, dict) or spec.get("scope") not in ("party", "class")
            or not isinstance(spec.get("spells"), list)):
        raise Problem(f"{key}: groupCast needs scope 'party' or 'class' and a list of spells")
    out = []
    for item in spec["spells"]:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            raise Problem(f"{key}: a groupCast spell needs a name")
        rank = item.get("rank", 0)
        equals_rank = item.get("equalsRank", 0)
        for number in (rank, equals_rank):
            if type(number) is not int or not 0 <= number <= 999:
                raise Problem(f"{key}: groupCast rank must be a whole number from 0 to 999")
        reagent = check_id(item.get("reagent"), f"{key} groupCast reagent")
        found = [i for i in ids_named(item["name"], index, spells) if spells[i][1] == rank]
        if len(found) != 1:
            report.append(f"NOT FOUND  {key}: group cast {item['name']!r} rank {rank}")
            continue
        if found[0] not in buff.get("group", []):
            raise Problem(f"{key}: group cast {found[0]} is not one of its group versions")
        same = [i for i in buff["ranks"] if spells[i][1] == equals_rank]
        if len(same) != 1:
            raise Problem(f"{key}: no single rank {equals_rank} to match group cast {found[0]}")
        out.append({"id": found[0], "reagent": reagent, "equals": same[0]})
        report.append(f"FOUND  {key} group cast {found[0]} ({item['name']}), reagent item {reagent} (hand-listed), equals {same[0]}")
    return {"scope": spec["scope"], "spells": out} if out else None


def family_auras_of(family_auras, spells, index, rank_owner, report):
    """{family: [IDs]}: spells that count as wearing a family of self-buffs
    but are never offered (Aspect of the Cheetah, of the Pack and of the
    Beast, #44). Only those found are kept."""
    out = {}
    for family in sorted(family_auras):
        names = family_auras[family]
        if not KEY_RE.match(family) or not isinstance(names, list):
            raise Problem(f"familyAuras {family!r}: bad family or list")
        ids = []
        for name in names:
            if not isinstance(name, str) or not name:
                raise Problem(f"familyAuras {family}: a spell needs a name")
            found = ids_named(name, index, spells)
            if not found:
                report.append(f"NOT FOUND  family {family}: {name!r}")
            for i in found:
                if i in rank_owner:
                    raise Problem(f"spell {i} is a rank of {rank_owner[i]} and in family {family}'s other spells")
            ids.extend(found)
        if ids:
            out[family] = ids
            report.append(f"FOUND  family {family}: other spells {ids}")
    return out


def build(spells, classes, removed, family_auras=None):
    index = by_name(spells)
    report = []
    out_classes = {}
    seen_keys = set()
    rank_owner = {}
    absent = []
    removed_ids = []

    for entry in removed:
        if not isinstance(entry, dict) or not isinstance(entry.get("key"), str) or not KEY_RE.match(entry["key"]):
            raise Problem("removed: each entry needs a key")
        ids = [check_id(i, f"removed {entry['key']}") for i in entry.get("ids", [])]
        if not ids or not isinstance(entry.get("reason"), str):
            raise Problem(f"removed {entry['key']}: needs ids and a reason")
        if entry["key"] in seen_keys:
            raise Problem(f"key {entry['key']} is used twice")
        seen_keys.add(entry["key"])
        # keepKey: the key stays known, so saved settings that name the buff
        # still load and keep their values. Without it (Salvation, #208: a
        # buff Blizzard confirmed removed) saved mentions are dropped as before.
        if entry.get("keepKey") is True:
            absent.append(entry["key"])
        removed_ids.extend(ids)
        for i in ids:
            shown = spells[i][0] if i in spells else "not in the data"
            report.append(f"REMOVED  {entry['key']}: {i} ({shown}) is in the removed list: {entry['reason']}")

    for cls in sorted(classes):
        if not CLASS_RE.match(cls) or not isinstance(classes[cls], list):
            raise Problem(f"class {cls!r}: bad name or list")
        buffs = []
        for spec in classes[cls]:
            key = spec.get("key") if isinstance(spec, dict) else None
            if not isinstance(key, str) or not KEY_RE.match(key):
                raise Problem(f"class {cls}: a buff needs a key like 'motw'")
            if key in seen_keys:
                raise Problem(f"key {key} is used twice")
            seen_keys.add(key)
            name = spec.get("name")
            if not isinstance(name, str) or not name:
                raise Problem(f"{key}: needs the spell's name")
            ranks = ids_named(name, index, spells)
            # One buff made of two spells (#44): Ice Armor then Frost Armor,
            # Demon Armor then Demon Skin. Their ranks follow the main name's.
            also = spec.get("alsoNames", [])
            if not isinstance(also, list) or not all(isinstance(n, str) and n for n in also):
                raise Problem(f"{key}: alsoNames must be a list of spell names")
            for also_name in also:
                found = ids_named(also_name, index, spells)
                if not found:
                    report.append(f"NOT FOUND  {key}: also-named spell {also_name!r}")
                if ranks:
                    ranks = ranks + found
            if not ranks:
                absent.append(key)
                report.append(f"NOT FOUND  {key}: no spell named {name!r} in the data; the buff is left out")
                continue
            buff = {"key": key, "name": name, "ranks": ranks}
            group = []
            for group_name in spec.get("group", []):
                found = ids_named(group_name, index, spells)
                if not found:
                    report.append(f"NOT FOUND  {key}: group spell {group_name!r}")
                group.extend(found)
            blockers = []
            for blocker_name in spec.get("blockers", []):
                found = ids_named(blocker_name, index, spells)
                if not found:
                    report.append(f"NOT FOUND  {key}: blocker {blocker_name!r}")
                blockers.extend(found)
            for blocker_id in spec.get("blockerIds", []):
                check_id(blocker_id, f"{key} blocker")
                if blocker_id in spells:
                    blockers.append(blocker_id)
                else:
                    report.append(f"NOT FOUND  {key}: blocker spell {blocker_id}")
            if group:
                buff["group"] = group
            if blockers:
                buff["blockers"] = blockers
            if "family" in spec:
                if not isinstance(spec["family"], str) or not KEY_RE.match(spec["family"]):
                    raise Problem(f"{key}: bad family")
                buff["family"] = spec["family"]
            if "defaultRule" in spec:
                if spec["defaultRule"] not in ("all", "tanks", "notTanks", "classes"):
                    raise Problem(f"{key}: unknown defaultRule {spec['defaultRule']!r}")
                buff["defaultRule"] = spec["defaultRule"]
            if "defaultClasses" in spec:
                classes_list = spec["defaultClasses"]
                if (not isinstance(classes_list, list) or not classes_list
                        or len(set(classes_list)) != len(classes_list)
                        or not all(isinstance(c, str) and CLASS_RE.match(c) for c in classes_list)):
                    raise Problem(f"{key}: defaultClasses must be a list of class names, each once")
                buff["defaultClasses"] = classes_list
            if "groupCast" in spec:
                cast = group_cast(key, spec["groupCast"], buff, spells, index, report)
                if cast:
                    buff["groupCast"] = cast
            for flag in FLAGS:
                if spec.get(flag) is True:
                    buff[flag] = True
            for flag in SELF_ONLY_FLAGS:
                if buff.get(flag) and not buff.get("selfCast"):
                    raise Problem(f"{key}: {flag} is for self-buffs (selfCast) only")
            if buff.get("selfCast") and ("group" in buff or "groupCast" in buff or "defaultRule" in buff):
                raise Problem(f"{key}: a self-buff has no group version and no rule for who gets it")
            for i in ranks:
                if i in rank_owner:
                    raise Problem(f"spell {i} is a rank of both {rank_owner[i]} and {key}")
                rank_owner[i] = key
            for field in ("group", "blockers"):
                if len(set(buff.get(field, []))) != len(buff.get(field, [])):
                    raise Problem(f"{key}: duplicate ID in {field}")
            used = ", ".join(f"{i} ({spells[i][0]}{', rank ' + str(spells[i][1]) if spells[i][1] else ''})" for i in ranks)
            report.append(f"FOUND  {cls} {key}: ranks {used}")
            if group:
                report.append(f"FOUND  {key} group versions {group}")
            if blockers:
                report.append(f"FOUND  {key} blockers {blockers}")
            buffs.append(buff)
        # A class none of whose buffs are in the data has no list (#44: the
        # hunter's Aspects before their spells are extracted).
        if buffs:
            out_classes[cls] = buffs
    for i in removed_ids:
        if i in rank_owner:
            raise Problem(f"spell {i} is both removed and a rank of {rank_owner[i]}")
    families = family_auras_of(family_auras or {}, spells, index, rank_owner, report)
    return out_classes, absent, sorted(set(removed_ids)), report, families


def lua_list(ids):
    return "{ " + ", ".join(str(i) for i in ids) + " }"


def lua_string(text):
    return json.dumps(text, ensure_ascii=True)


def render(build_id, digest, source_name, classes, absent, removed_ids, families=None):
    lines = [
        "-- GENERATED by scripts/gen_spell_table.py (#209). Do not edit by hand:",
        "-- change scripts/spell-buffs.json or re-run the extraction, then re-run the",
        "-- generator (CONTRIBUTING.md, \"Releasing\"). spec/bufftable_spec.lua checks it.",
        "local _, ns = ...",
        "",
        "ns.BuffTable = {",
        f"    format = {FORMAT},",
        f"    build = {lua_string(build_id)},",
        f"    source = {lua_string(source_name)},",
        f"    sourceSha256 = {lua_string(digest)},",
        "    classes = {",
    ]
    for cls in sorted(classes):
        lines.append(f"        {cls} = {{")
        for buff in classes[cls]:
            parts = [f"key = {lua_string(buff['key'])}", f"name = {lua_string(buff['name'])}",
                     f"ranks = {lua_list(buff['ranks'])}"]
            for field in ("group", "blockers"):
                if field in buff:
                    parts.append(f"{field} = {lua_list(buff[field])}")
            if "family" in buff:
                parts.append(f"family = {lua_string(buff['family'])}")
            if "groupCast" in buff:
                spells_text = "\n".join(
                    f"                        {{ id = {c['id']}, reagent = {c['reagent']}, equals = {c['equals']} }},"
                    for c in buff["groupCast"]["spells"])
                parts.append('groupCast = {\n                    scope = ' + lua_string(buff["groupCast"]["scope"])
                             + ',\n                    spells = {\n'
                             + spells_text + "\n                    },\n                }")
            if "defaultRule" in buff:
                parts.append(f"defaultRule = {lua_string(buff['defaultRule'])}")
            if "defaultClasses" in buff:
                parts.append("defaultClasses = {\n" + "\n".join(
                    f"                    {c} = true," for c in buff["defaultClasses"]) + "\n                }")
            for flag in FLAGS:
                if buff.get(flag):
                    parts.append(f"{flag} = true")
            lines.append("            {")
            lines.extend(f"                {part}," for part in parts)
            lines.append("            },")
        lines.append("        },")
    lines.append("    },")
    lines.append("    -- Buffs left out: their keys stay known so saved settings still load.")
    # Wrapped, so the file stays within the lint's line length (#44 added many).
    words = [lua_string(k) + "," for k in sorted(absent)]
    rows, row = [], ""
    for word in words:
        if row and len(row) + 1 + len(word) > 100:
            rows.append(row)
            row = word
        else:
            row = word if not row else row + " " + word
    if len(rows) == 0:
        lines.append("    absent = { " + row.rstrip(",") + " },")
    else:
        rows.append(row)
        lines.append("    absent = {")
        lines.extend("        " + r for r in rows)
        lines.append("    },")
    if families:
        lines.append("    -- Spells that count as wearing a family of self-buffs, never offered (#44).")
        lines.append("    familyAuras = {")
        for family in sorted(families):
            lines.append(f"        {family} = {lua_list(families[family])},")
        lines.append("    },")
    lines.append("    -- Spells of buffs Blizzard removed: an aura with one is passed over.")
    lines.append("    removedSpells = " + lua_list(removed_ids) + ",")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--spells", required=True)
    parser.add_argument("--buffs", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--report", help="also write the found / not found report here")
    args = parser.parse_args(argv)
    try:
        raw, spell_json = load_json(args.spells)
        _, buff_json = load_json(args.buffs)
        build_id, spells = read_spells(spell_json)
        classes, removed, family_auras = read_buffs(buff_json)
        out_classes, absent, removed_ids, report, families = build(spells, classes, removed, family_auras)
        text = render(build_id, hashlib.sha256(raw).hexdigest(), os.path.basename(args.spells),
                      out_classes, absent, removed_ids, families)
    except Problem as err:
        print(f"gen_spell_table: {err}", file=sys.stderr)
        print("gen_spell_table: nothing written", file=sys.stderr)
        return 1
    report_text = f"Forever build {build_id}, source SHA-256 {hashlib.sha256(raw).hexdigest()}\n" + "\n".join(report) + "\n"
    directory = os.path.dirname(os.path.abspath(args.out))
    handle, temp = tempfile.mkstemp(dir=directory, prefix=".bufftable-")
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as out:
            out.write(text)
        os.chmod(temp, 0o644)
        os.replace(temp, args.out)
    except OSError as err:
        if os.path.exists(temp):
            os.unlink(temp)
        print(f"gen_spell_table: cannot write {args.out}: {err}", file=sys.stderr)
        return 1
    if args.report:
        with open(args.report, "w", encoding="utf-8") as out:
            out.write(report_text)
    sys.stdout.write(report_text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
