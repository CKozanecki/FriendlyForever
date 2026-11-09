#!/usr/bin/env python3
"""Generate BuffTable.lua from Forever's extracted spell data (#209).

Run by a maintainer or a session, never by players, never in CI against
Blizzard, and never shipped (scripts/ is in .pkgmeta's ignore list).

    python3 scripts/gen_spell_table.py \
        --spells scripts/data/forever-spells.json \
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
FLAGS = ("manaOnly", "selfCast", "water")


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
    return classes, removed


def build(spells, classes, removed):
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
            for flag in FLAGS:
                if spec.get(flag) is True:
                    buff[flag] = True
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
        out_classes[cls] = buffs
    for i in removed_ids:
        if i in rank_owner:
            raise Problem(f"spell {i} is both removed and a rank of {rank_owner[i]}")
    return out_classes, absent, sorted(set(removed_ids)), report


def lua_list(ids):
    return "{ " + ", ".join(str(i) for i in ids) + " }"


def lua_string(text):
    return json.dumps(text, ensure_ascii=True)


def render(build_id, digest, source_name, classes, absent, removed_ids):
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
            for flag in FLAGS:
                if buff.get(flag):
                    parts.append(f"{flag} = true")
            lines.append("            {")
            lines.extend(f"                {part}," for part in parts)
            lines.append("            },")
        lines.append("        },")
    lines.append("    },")
    lines.append("    -- Buffs left out: their keys stay known so saved settings still load.")
    lines.append("    absent = { " + ", ".join(lua_string(k) for k in sorted(absent)) + " },")
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
        classes, removed = read_buffs(buff_json)
        out_classes, absent, removed_ids, report = build(spells, classes, removed)
        text = render(build_id, hashlib.sha256(raw).hexdigest(), os.path.basename(args.spells),
                      out_classes, absent, removed_ids)
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
