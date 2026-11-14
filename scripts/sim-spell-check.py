#!/usr/bin/env python3
"""Checks the UI simulator's Forever spell data against our committed copy (#160).

The UI simulator workflow downloads Forever's spell data with the simulator's
own tool and pins the result's SHA-256 itself. The simulator's project records
a hash only for an older, shorter selection of spells, and that is the file
committed here as scripts/data/forever-spells.json (#209). This script ties the
two together: every spell in the committed file must have exactly the same rows
in the downloaded one, from tables of the same layout and the same game build.
Spells only the download has are listed, since nothing vouches for them but the
pinned hash.

Usage: sim-spell-check.py <downloaded spells.json> <committed forever-spells.json>

Exits 0 when they agree, and 1 with a message when they don't or a file can't
be read. It prints numbers and table names only, never text from either file.
The workflow runs it only after the download's hash matched the pinned one.
"""

import json
import sys

# Each table, and the column that names the spell a row belongs to.
TABLES = {
    "Spell": "ID",
    "SpellEffect": "SpellID",
    "SpellMisc": "SpellID",
    "SpellName": "ID",
    "SpellPower": "SpellID",
}


class Mismatch(Exception):
    """The two files disagree, or one isn't the shape expected."""


def load(path, what):
    try:
        with open(path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError) as error:
        raise Mismatch("can't read the %s spell data: %s" % (what, type(error).__name__))
    if not isinstance(data, dict) or not isinstance(data.get("tables"), dict):
        raise Mismatch("the %s spell data has no tables" % what)
    if sorted(data["tables"]) != sorted(TABLES):
        raise Mismatch("the %s spell data doesn't hold exactly the five spell tables" % what)
    for name, table in data["tables"].items():
        if not isinstance(table, dict) or not isinstance(table.get("rows"), list):
            raise Mismatch("the %s spell data's %s table has no rows" % (what, name))
    return data


def spell_of(row, column, what, name):
    spell = row.get(column) if isinstance(row, dict) else None
    # bool is an int in Python; a spell is a plain whole number.
    if not isinstance(spell, int) or isinstance(spell, bool) or spell <= 0:
        raise Mismatch("a row of the %s %s table names no spell" % (what, name))
    return spell


def spells_in(data, what):
    """The spells a file holds: the ones its SpellName table names."""
    return {spell_of(row, TABLES["SpellName"], what, "SpellName") for row in data["tables"]["SpellName"]["rows"]}


def check(downloaded, committed):
    """Returns (shared, extra): the spells both hold, and those only the download has."""
    for key in ("schema", "build"):
        if downloaded.get(key) != committed.get(key):
            raise Mismatch("the two files differ in their %s" % key)
    ours = spells_in(committed, "committed")
    theirs = spells_in(downloaded, "downloaded")
    if not ours:
        raise Mismatch("the committed spell data holds no spells")
    missing = sorted(ours - theirs)
    if missing:
        raise Mismatch("the download lacks committed spells: %s" % ", ".join(str(spell) for spell in missing))
    for name, column in sorted(TABLES.items()):
        mine, other = committed["tables"][name], downloaded["tables"][name]
        for key in ("layout_hash", "unreadable_records"):
            if mine.get(key) != other.get(key):
                raise Mismatch("the %s tables differ in their %s" % (name, key))
        # Both files list a table's rows in the same order (by spell, then by
        # record), so the committed rows must be the download's, less the
        # rows of spells only the download has.
        kept = []
        for row in other["rows"]:
            spell = spell_of(row, column, "downloaded", name)
            if spell in ours:
                kept.append(row)
            elif spell not in theirs:
                raise Mismatch("the download's %s table has a row for spell %d, which its SpellName table lacks" % (name, spell))
        for row in mine["rows"]:
            if spell_of(row, column, "committed", name) not in ours:
                raise Mismatch("the committed %s table has a row for a spell its SpellName table lacks" % name)
        # Compared as text, so 1 and 1.0, or 1 and true, count as different.
        if json.dumps(kept, sort_keys=True) != json.dumps(mine["rows"], sort_keys=True):
            raise Mismatch("the %s rows of the committed spells differ" % name)
    return sorted(ours), sorted(theirs - ours)


def main(argv):
    if len(argv) != 3:
        print("usage: sim-spell-check.py <downloaded spells.json> <committed forever-spells.json>")
        return 1
    try:
        shared, extra = check(load(argv[1], "downloaded"), load(argv[2], "committed"))
    except Mismatch as error:
        print("spell data check failed: %s" % error)
        return 1
    print("spell data check passed: all %d committed spells have the same rows in the download" % len(shared))
    if extra:
        print("spells only the download has (%d), covered by the pinned hash alone: %s"
              % (len(extra), ", ".join(str(spell) for spell in extra)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
