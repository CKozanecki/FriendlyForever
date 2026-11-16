#!/usr/bin/env python3
"""Generate scripts/data/forever-weapon-buffs.lua from Forever's own data (#45).

Run by a maintainer or a session, never by players, never in CI against
Blizzard, and never shipped (scripts/ is in .pkgmeta's ignore list). The
output is what spec/weaponbuffs_data_spec.lua checks WeaponBuffs.lua's IDs
against; the addon itself reads nothing from it.

    python3 -I scripts/gen_weapon_data.py \\
        --spells <the file wow-cli casc sync-forever-spells wrote> \\
        --spell-ids scripts/data/forever-weapon-spell-ids.txt \\
        --items <Osso/wow-ui-sim's crates/sim-data-profile/data/item_effects_wowforever.rs> \\
        --item-ids scripts/data/forever-weapon-item-ids.txt \\
        --out scripts/data/forever-weapon-buffs.lua

Inputs (docs/forever-facts.md, "Weapon buffs", says how each was made):
  --spells     the spell extraction, with the weapon spells' IDs added to
               upstream's list: the Spell, SpellName and SpellEffect rows.
  --spell-ids  the weapon spells: each must be in it, with one enchant effect.
  --items      upstream's table of Forever's item effects (ItemXItemEffect
               joined to ItemEffect): (item, effect, spell, trigger, ...).
  --item-ids   the weapon items: each must have exactly one on-use effect.
Output: a Lua table, written only when every check passes. On any problem the
script prints why, exits non-zero and leaves the existing file untouched.

Everything read is untrusted: IDs must be whole numbers in a sane range, names
strings of bounded length, and nothing may appear twice.
"""
import argparse
import json
import re
import sys

MAX_ID = 10_000_000
MAX_NAME = 80
# SpellEffect.Effect values that put a temporary enchant on an item: 54 for
# the stones and oils, 360 for the poisons and imbues (Forever's data).
ENCHANT_EFFECTS = (54, 360)
ITEM_ROW = re.compile(r"^\s*\((\d+), (\d+), (-?\d+), (-?\d+), (-?\d+)\),\s*$")


def fail(why):
    print("gen_weapon_data: " + why, file=sys.stderr)
    sys.exit(1)


def whole(value, what, low=1, high=MAX_ID):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        fail(f"{what} is not a whole number from {low} to {high}: {value!r}")
    return value


def read_ids(path):
    ids = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            if not re.fullmatch(r"[1-9][0-9]{0,8}\n?", line):
                fail(f"{path}:{n} is not an ID")
            ids.append(whole(int(line), f"{path}:{n}"))
    if len(set(ids)) != len(ids):
        fail(f"{path} lists an ID twice")
    return ids


def read_spells(path, wanted):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    build = data.get("build")
    if not isinstance(build, str) or not re.fullmatch(r"[0-9.]{1,20}", build):
        fail("the spell data's build is not a version")
    tables = data.get("tables", {})
    names = {}
    for row in tables.get("SpellName", {}).get("rows", []):
        spell = whole(row.get("ID"), "a SpellName ID")
        name = row.get("Name_lang")
        if not isinstance(name, str) or not 0 < len(name) <= MAX_NAME or not re.fullmatch(r"[A-Za-z' :-]+", name):
            fail(f"spell {spell}'s name is not a plain name")
        if spell in names:
            fail(f"spell {spell} is named twice")
        names[spell] = name
    effects = {}
    for row in tables.get("SpellEffect", {}).get("rows", []):
        spell = whole(row.get("SpellID"), "a SpellEffect's spell")
        if spell not in wanted:
            continue
        effect = whole(row.get("Effect"), f"spell {spell}'s effect", 0, 1000)
        if effect in ENCHANT_EFFECTS:
            enchant = whole(row.get("EffectMiscValue_0"), f"spell {spell}'s enchant", 1, 100_000)
            seconds = row.get("EffectBasePointsF")
            if not isinstance(seconds, float) or not 0 < seconds <= 86400 or seconds != int(seconds):
                fail(f"spell {spell}'s enchant time is not whole seconds")
            if spell in effects:
                fail(f"spell {spell} has two enchant effects")
            effects[spell] = (effect, enchant, int(seconds))
    out = {}
    for spell in wanted:
        if spell not in names:
            fail(f"spell {spell} is not in the spell data")
        if spell not in effects:
            fail(f"spell {spell} has no enchant effect")
        out[spell] = (names[spell],) + effects[spell]
    return build, out


def read_items(path, wanted):
    uses = {}
    with open(path, encoding="utf-8") as f:
        text = f.read()
    start = text.find("pub static ITEM_EFFECTS")
    end = text.find("];", start)
    if start < 0 or end < 0:
        fail("the item effects table is not in that file")
    header = re.search(r"build (\d+\.\d+\.\d+\.\d+)", text[:start])
    if not header:
        fail("the item effects file names no build")
    for line in text[start:end].splitlines()[1:]:
        m = ITEM_ROW.match(line)
        if not m:
            fail("an item effect row is not five numbers")
        item, _, spell, trigger, _ = (int(v) for v in m.groups())
        if item in wanted and trigger == 0:
            if item in uses:
                fail(f"item {item} has two on-use effects")
            uses[item] = whole(spell, f"item {item}'s spell")
    for item in wanted:
        if item not in uses:
            fail(f"item {item} has no on-use effect")
    return header.group(1), uses


def main():
    parser = argparse.ArgumentParser()
    for name in ("--spells", "--spell-ids", "--items", "--item-ids", "--out"):
        parser.add_argument(name, required=True)
    args = parser.parse_args()
    spell_ids = read_ids(args.spell_ids)
    item_ids = read_ids(args.item_ids)
    build, spells = read_spells(args.spells, set(spell_ids))
    item_build, items = read_items(args.items, set(item_ids))
    for item in item_ids:
        if items[item] not in spells:
            fail(f"item {item}'s spell {items[item]} is not one of the weapon spells")
    lines = [
        "-- Generated by scripts/gen_weapon_data.py (#45): do not edit by hand.",
        "-- Forever's weapon buff spells (build " + build + ") and the spell each",
        "-- item casts (build " + item_build + "); docs/forever-facts.md says how.",
        "-- Read only by spec/weaponbuffs_data_spec.lua; never shipped.",
        "return {",
        '    build = "' + build + '",',
        '    itemBuild = "' + item_build + '",',
        "    -- [spell ID] = { name, effect, enchant ID, seconds }",
        "    spells = {",
    ]
    for spell in spell_ids:
        name, effect, enchant, seconds = spells[spell]
        lines.append(f'        [{spell}] = {{ name = "{name}", effect = {effect}, enchant = {enchant}, '
                     f"seconds = {seconds} }},")
    lines += ["    },", "    -- [item ID] = the spell it casts when used", "    items = {"]
    for item in item_ids:
        lines.append(f"        [{item}] = {items[item]},")
    lines += ["    },", "}", ""]
    for spell in spell_ids:
        name, effect, enchant, seconds = spells[spell]
        print(f"spell {spell}: {name}, effect {effect}, enchant {enchant}, {seconds} s")
    for item in item_ids:
        print(f"item {item}: casts {items[item]} ({spells[items[item]][0]})")
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    main()
