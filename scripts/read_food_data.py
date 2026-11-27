#!/usr/bin/env python3
"""Read Forever's Well Fed foods from its own data (#544).

Run by a maintainer or a session, never by players, never in CI, and never
shipped (scripts/ is in .pkgmeta's ignore list). It downloads Blizzard's data
from its CDN (us.cdn.blizzard.com only) with scripts/read_spell_levels.py's
reader, which checks every hash; nothing from upstream (Osso/wow-ui-sim) is
built or run, and only one of its data files is read, as text.

    python3 -I scripts/read_food_data.py \\
        --build-config <hex> --cdn-config <hex> \\
        --items <Osso/wow-ui-sim's crates/sim-data-profile/data/item_effects_wowforever.rs> \\
        --cache <an empty directory> --out scripts/data/forever-food.lua

The two configs are Forever's current ones (product "wowf"): the BuildConfig
and CDNConfig columns of https://us.version.battle.net/v2/products/wowf/versions.
docs/forever-facts.md ("Food buffs") records the ones used and the evidence.
The output is what spec/foodbuffs_data_spec.lua checks FoodBuffs.lua and the
simulated client against; the addon itself reads nothing from it.

What it reads, by file data ID (the wowdev community listfile; each is checked
by what it holds, below):
  SpellName (1990283): each spell's name. "Well Fed" names the auras.
  SpellEffect (1140088): which spell triggers which, and how often. A food's
    spell has an effect that triggers a Well Fed spell every EffectAuraPeriod
    milliseconds while you eat.
  ItemEffect (969941): the spell each item effect casts now.
  ItemSparse (1572924): each item's name and required level.
  --items: upstream's table of Forever's item effects (ItemXItemEffect joined
    to ItemEffect, build 1.60.1.70532): which effect is whose. Each effect's
    spell is then read from this build's ItemEffect.
A food is an item whose effect casts, in this build, a spell that triggers a
Well Fed spell. One whose name or level can't be read is left out, and said so.

The readers are checked against rows whose meaning is known before anything
is kept (CHECKS below): a layout that moved, or a field read wrong, stops it.
Everything downloaded is untrusted: IDs are whole numbers in a sane range,
names are bounded plain text, and nothing may appear twice. On any problem it
prints why, exits non-zero and writes nothing.
"""
import argparse
import hashlib
import importlib.util
import os
import re
import struct
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
_spec = importlib.util.spec_from_file_location("read_spell_levels", os.path.join(HERE, "read_spell_levels.py"))
R = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(R)

TABLES = {"SpellName": 1990283, "SpellEffect": 1140088, "ItemEffect": 969941, "ItemSparse": 1572924}
FIELDS = {"SpellName": 1, "SpellEffect": 29, "ItemEffect": 9, "ItemSparse": 68}
WELL_FED = "Well Fed"
MAX_ID = 10_000_000
MAX_NAME = 60
MAX_LEVEL = 80
NAME = re.compile(r"[A-Za-z][A-Za-z' .,&-]*[A-Za-z]")
ITEM_ROW = re.compile(r"^\s*\((\d+), (\d+), (-?\d+), (-?\d+), (-?\d+)\),\s*$")
# SpellEffect's fields, as Forever's layout holds them (CHECKS proves them).
EFFECT_AURA, EFFECT_KIND, EFFECT_PERIOD, EFFECT_TRIGGER = 0, 3, 6, 15
APPLY_AURA = 6
# ItemEffect's SpellID field.
ITEM_EFFECT_SPELL = 6
# ItemSparse: the fixed fields after the item's five strings; RequiredLevel
# is the 295th byte of them (CHECKS proves it on known items).
SPARSE_PREFIX, SPARSE_STRINGS, SPARSE_LEVEL = 4, 5, 294
# Rows whose meaning is known: Classic Era's own, unchanged in Forever.
CHECKS = {
    "names": {433: "Food", 24799: WELL_FED, 24800: "Food", 3112: "Enhance Blunt Weapon"},
    # Smoked Desert Dumplings' Classic spell: every 10 seconds of eating, Well Fed (24799).
    "trigger": (24800, 24799, 10000),
    # (item, name, required level)
    "items": [(25, "Worn Shortsword", 1), (20452, "Smoked Desert Dumplings", 45), (12218, "Monster Omelet", 35)],
    # An item effect whose spell is known: Rough Weightstone (3239) casts 3112 (#45).
    "item_spell": (3239, 3112),
}


def whole(value, what):
    if not isinstance(value, int) or not (0 < value < MAX_ID):
        raise ValueError(f"{what}: {value!r} isn't an ID")
    return value


def spell_names(data, table):
    """SpellName (WDC5, one string field): {spell ID: name}, read section by section."""
    pos = 4 + 4 + 128
    head = struct.unpack("<IIIIIIIIIHHIIIIIII", data[pos:pos + 68])
    rsize, flags, sections = head[2], head[9], head[17]
    if flags & 1:
        raise ValueError("SpellName has an offset map: its layout changed")
    pos += 68
    secs = [struct.unpack("<QIIIIIIII", data[pos + 40 * i:pos + 40 * i + 40]) for i in range(sections)]
    boff = table["storage"][0][0]
    # A string field holds an offset from itself, counted as if every
    # section's records came first and then every section's strings in turn.
    total = sum(s[2] for s in secs)
    blocks, at = [], 0
    for s in secs:
        blocks.append((at, s[3], s[1] + s[2] * rsize))
        at += s[3]

    def text(virt):
        for start, size, where in blocks:
            if start <= virt < start + size:
                a = where + (virt - start)
                end = data.find(b"\0", a, where + size)
                if end < 0:
                    raise ValueError("a spell name runs past its block")
                return data[a:end].decode("utf-8")
        raise ValueError("a spell name's offset is outside every block")

    names, first = {}, 0
    for (tact, foff, n, sts, ends, idls, rels, omc, ctc) in secs:
        records = data[foff:foff + n * rsize]
        p = foff + n * rsize + sts
        if idls != 4 * n:
            raise ValueError("a SpellName section has no ID for each row")
        ids = struct.unpack(f"<{n}I", data[p:p + idls])
        p += idls
        copies = [struct.unpack("<II", data[p + 8 * j:p + 8 * j + 8]) for j in range(ctc)]
        if not (tact and not any(records)):
            for i in range(n):
                value = R.bits(records[i * rsize:(i + 1) * rsize], boff, 32)
                sid = whole(ids[i], "SpellName ID")
                if sid in names:
                    raise ValueError(f"spell {sid} named twice")
                # 0: no name (spell 27997 at 1.60.1.71139).
                names[sid] = "" if value == 0 else text((first + i) * rsize + boff // 8 + value - total * rsize)
            for new, old in copies:
                if old in names:
                    names[whole(new, "SpellName ID")] = names[old]
        first += n
    return names


def sparse_items(data, wanted):
    """ItemSparse (an offset map, strings inline): {item: (name, level)} for wanted items."""
    pos = 4 + 4 + 128
    head = struct.unpack("<IIIIIIIIIHHIIIIIII", data[pos:pos + 68])
    if not head[9] & 1:
        raise ValueError("ItemSparse has no offset map: its layout changed")
    pos += 68
    secs = [struct.unpack("<QIIIIIIII", data[pos + 40 * i:pos + 40 * i + 40]) for i in range(head[17])]
    out = {}
    for (tact, foff, n, sts, ends, idls, rels, omc, ctc) in secs:
        p = ends + idls + 8 * ctc
        omap = [struct.unpack("<IH", data[p + 6 * j:p + 6 * j + 6]) for j in range(omc)]
        p += 6 * omc + rels
        ids = struct.unpack(f"<{omc}I", data[p:p + 4 * omc])
        for item, (off, size) in zip(ids, omap):
            if item not in wanted:
                continue
            raw = data[off:off + size]
            if not any(raw):
                continue  # encrypted, zero-filled
            if item in out:
                raise ValueError(f"item {item} has two ItemSparse rows")
            q, texts = SPARSE_PREFIX, []
            for _ in range(SPARSE_STRINGS):
                end = raw.find(b"\0", q)
                if end < 0:
                    raise ValueError(f"item {item}: a name runs past its row")
                texts.append(raw[q:end].decode("utf-8", "replace"))
                q = end + 1
            if len(raw) < q + SPARSE_LEVEL + 1:
                raise ValueError(f"item {item}: its row is too short")
            out[item] = (texts[0], raw[q + SPARSE_LEVEL])
    return out


def upstream_effects(path):
    """item -> [item effect IDs], from upstream's table, every row checked."""
    text = open(path, encoding="utf-8").read()
    start = text.find("pub static ITEM_EFFECTS")
    end = text.find("];", start)
    if start < 0 or end < 0:
        raise ValueError("--items has no ITEM_EFFECTS table")
    out, seen = {}, set()
    for line in text[start:end].splitlines()[1:]:
        if not line.strip():
            continue
        match = ITEM_ROW.match(line)
        if not match:
            raise ValueError(f"--items: unexpected row {line.strip()!r}")
        item, effect = whole(int(match.group(1)), "item"), whole(int(match.group(2)), "item effect")
        if effect in seen:
            raise ValueError(f"--items: effect {effect} twice")
        seen.add(effect)
        out.setdefault(item, []).append(effect)
    return out, hashlib.sha256(text.encode("utf-8")).hexdigest()


def download(args):
    os.makedirs(args.cache, exist_ok=True)
    build, cdn = R.config(args.cache, args.build_config), R.config(args.cache, args.cdn_config)
    build_id = R.build_name(build)
    enc_ckey, enc_ekey = build["encoding"][:2]
    enc = R.blte(R.cached(args.cache, enc_ekey + ".blte", lambda: R.fetch(R.hpath("data", enc_ekey))), enc_ekey)
    if hashlib.md5(enc).hexdigest() != enc_ckey:
        raise ValueError("encoding file doesn't match its content key")
    root_ckey = build["root"][0]
    root_ekey = R.encoding_lookup(enc, [root_ckey])[root_ckey]
    root = R.get_file(args.cache, root_ekey, R.index_lookup(args.cache, cdn["archives"], [root_ekey]).get(root_ekey))
    if hashlib.md5(root).hexdigest() != root_ckey:
        raise ValueError("root file doesn't match its content key")
    ckeys = R.root_lookup(root, list(TABLES.values()))
    files = {}
    for name, fdid in TABLES.items():
        if fdid not in ckeys:
            raise ValueError(f"{name} ({fdid}) isn't in the root file")
        ck = ckeys[fdid]
        ek = R.encoding_lookup(enc, [ck])[ck]
        loc = R.index_lookup(args.cache, cdn["archives"], [ek]).get(ek)
        R.ENCRYPTED[0] = 0
        data = R.get_file(args.cache, ek, loc)
        encrypted = R.ENCRYPTED[0]
        if hashlib.md5(data).hexdigest() != ck and not encrypted:
            raise ValueError(f"{name} doesn't match its content key")
        files[name] = (data, encrypted)
    return build_id, files


def lua_string(text):
    if not NAME.fullmatch(text) or len(text) > MAX_NAME:
        raise ValueError(f"name {text!r} isn't plain text")
    return '"' + text + '"'


def render(build_id, args, hashes, upstream_sha, well_fed, foods, left_out):
    lines = [
        "-- GENERATED by scripts/read_food_data.py (#544): do not edit by hand.",
        "-- Forever's Well Fed auras and the items that give one, read from its own",
        "-- data on Blizzard's CDN; docs/forever-facts.md (\"Food buffs\") says how.",
        "-- Read only by spec/foodbuffs_data_spec.lua; never shipped.",
        "return {",
        f'    build = "{build_id}",',
        f'    buildConfig = "{args.build_config}",',
        f'    cdnConfig = "{args.cdn_config}",',
        f'    itemEffectsSha256 = "{upstream_sha}",',
        "    -- [table] = { SHA-256 as downloaded, encrypted chunks zero-filled }",
        "    tables = {",
    ]
    for name in TABLES:
        sha, encrypted = hashes[name]
        lines.append(f'        {name} = {{ sha256 = "{sha}", encrypted = {encrypted} }},')
    lines += ["    },", "    -- Every spell named \"Well Fed\"", "    wellFed = {"]
    lines += [f"        {sid}," for sid in well_fed]
    lines += [
        "    },",
        "    -- [item ID] = { name, required level, the spell its use casts, the Well Fed",
        "    -- it gives, how often while you eat (ms), drink = its spell's name is a drink's }",
        "    foods = {",
    ]
    for item in sorted(foods):
        f = foods[item]
        drink = ", drink = true" if f["drink"] else ""
        head = f'        [{item}] = {{ name = {lua_string(f["name"])}, level = {f["level"]}, '
        rest = f'spell = {f["spell"]}, wellFed = {f["wellFed"]}, period = {f["period"]}{drink} }},'
        if len(head + rest) <= 120:
            lines.append(head + rest)
        else:
            lines += [head.rstrip(), "            " + rest]
    lines += ["    },", "    -- Items whose spell gives Well Fed, left out: [item ID] = why", "    leftOut = {"]
    for item in sorted(left_out):
        lines.append(f'        [{item}] = "{left_out[item]}",')
    lines += ["    },", "}"]
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--build-config", required=True)
    parser.add_argument("--cdn-config", required=True)
    parser.add_argument("--items", required=True, help="upstream's item_effects_wowforever.rs")
    parser.add_argument("--cache", required=True, help="a directory for the downloads")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        for value in (args.build_config, args.cdn_config):
            if not re.fullmatch(r"[0-9a-f]{32}", value):
                raise ValueError(f"not a config hash: {value!r}")
        effects_of, upstream_sha = upstream_effects(args.items)
        build_id, files = download(args)
        tables, hashes = {}, {}
        for name, (data, encrypted) in files.items():
            hashes[name] = (hashlib.sha256(data).hexdigest(), encrypted)
            if name == "ItemSparse":
                continue
            tables[name] = R.wdc5(data)
            if tables[name]["fields"] != FIELDS[name]:
                raise ValueError(f"{name} has {tables[name]['fields']} fields, not {FIELDS[name]}: its layout changed")

        names = spell_names(files["SpellName"][0], tables["SpellName"])
        for sid, name in CHECKS["names"].items():
            if names.get(sid) != name:
                raise ValueError(f"SpellName {sid} reads {names.get(sid)!r}, not {name!r}: the reader is wrong")
        well_fed = sorted(sid for sid, name in names.items() if name == WELL_FED)

        # Which spell triggers a Well Fed spell, every how many ms.
        gives = {}
        for row in tables["SpellEffect"]["rows"]:
            f = row["fields"]
            if f[EFFECT_TRIGGER] in names and names[f[EFFECT_TRIGGER]] == WELL_FED:
                spell = whole(row["parent"], "SpellEffect's spell")
                if f[EFFECT_KIND] != APPLY_AURA or not (0 < f[EFFECT_PERIOD] <= 60000):
                    raise ValueError(f"spell {spell} gives Well Fed, but not as a periodic aura")
                if spell in gives and gives[spell] != (f[EFFECT_TRIGGER], f[EFFECT_PERIOD]):
                    raise ValueError(f"spell {spell} gives two Well Fed auras")
                gives[spell] = (f[EFFECT_TRIGGER], f[EFFECT_PERIOD])
        spell, aura, period = CHECKS["trigger"]
        if gives.get(spell) != (aura, period):
            raise ValueError(f"spell {spell} reads as giving {gives.get(spell)}: the SpellEffect reader is wrong")

        effect_spell = {whole(r["id"], "ItemEffect ID"): r["fields"][ITEM_EFFECT_SPELL]
                        for r in tables["ItemEffect"]["rows"]}
        item, spell = CHECKS["item_spell"]
        if [effect_spell.get(e) for e in effects_of.get(item, [])] != [spell]:
            raise ValueError(f"item {item} doesn't read as casting {spell}: the ItemEffect reader is wrong")

        candidates = {}
        for item, effects in effects_of.items():
            spells = [effect_spell.get(e) for e in effects]
            hits = [s for s in spells if s in gives]
            if not hits:
                continue
            if len(hits) != 1 or len(spells) != 1:
                raise ValueError(f"item {item} has {len(spells)} effects, {len(hits)} of them Well Fed")
            candidates[item] = hits[0]
        known = {item for item, _, _ in CHECKS["items"]}
        items = sparse_items(files["ItemSparse"][0], set(candidates) | known)
        for item, name, level in CHECKS["items"]:
            if items.get(item) != (name, level):
                raise ValueError(f"ItemSparse {item} reads {items.get(item)!r}: the reader is wrong")

        foods, left_out = {}, {}
        for item, spell in candidates.items():
            got = items.get(item)
            if got is None:
                left_out[item] = "no readable ItemSparse row"
                continue
            name, level = got
            if not NAME.fullmatch(name) or len(name) > MAX_NAME:
                left_out[item] = "its name can't be read"
                continue
            if not (0 <= level <= MAX_LEVEL):
                raise ValueError(f"item {item} has level {level}")
            aura, period = gives[spell]
            foods[item] = {"name": name, "level": level, "spell": whole(spell, "food spell"),
                           "wellFed": whole(aura, "Well Fed"), "period": period,
                           "drink": "Drink" in (names.get(spell) or "")}
        if not foods:
            raise ValueError("no food gives Well Fed: something is wrong")
        text = render(build_id, args, hashes, upstream_sha, well_fed, foods, left_out)
    except (ValueError, KeyError, RuntimeError, OSError, UnicodeDecodeError, struct.error, zlib.error) as err:
        print(f"read_food_data: {err}", file=sys.stderr)
        print("read_food_data: nothing written", file=sys.stderr)
        return 1
    directory = os.path.dirname(os.path.abspath(args.out))
    handle, temp = tempfile.mkstemp(dir=directory, prefix=".forever-food-")
    with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as out:
        out.write(text)
    os.chmod(temp, 0o644)
    os.replace(temp, args.out)
    print(f"Forever build {build_id}: {len(well_fed)} Well Fed spells, {len(foods)} foods, "
          f"{len(left_out)} left out ({', '.join(f'{i}: {w}' for i, w in sorted(left_out.items()))})")
    for name, (sha, encrypted) in hashes.items():
        print(f"  {name}: SHA-256 {sha}, {encrypted} encrypted chunk(s) zero-filled")
    print(f"  --items SHA-256 {upstream_sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
