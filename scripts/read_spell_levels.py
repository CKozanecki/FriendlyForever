#!/usr/bin/env python3
"""Read each rank's level from Forever's SpellLevels table (#459).

Run by a maintainer or a session, once per game version, never by players,
never in CI, and never shipped (scripts/ is in .pkgmeta's ignore list). It
downloads Blizzard's data from its CDN (us.cdn.blizzard.com only), so it
runs where the network allows that host, with no secrets. Standard library
only; nothing from upstream (Osso/wow-ui-sim) is built or run.

    python3 -I scripts/read_spell_levels.py \\
        --build-config <hex> --cdn-config <hex> \\
        --table BuffTable.lua --cache <an empty directory> \\
        --out scripts/data/forever-spell-levels.lua

The two configs are Forever's current ones (product "wowf"): the BuildConfig
and CDNConfig columns of https://us.version.battle.net/v2/products/wowf/versions.
docs/forever-facts.md ("Rank levels") records the ones used and the evidence.

How it reads: the build config names the encoding file (content key to
encoded key) and the root file (file data ID to content key); the CDN config
lists the archives, whose indexes say where an encoded file is. SpellLevels.db2
is file data ID 1140079 (the wowdev community listfile; its SHA-256 at build
1.60.1.70938 matched the one #379's research recorded). Its WDC5 rows are
(DifficultyID, MaxLevel, MaxPassiveAuraLevel, BaseLevel, SpellLevel), with the
spell's ID in the relationship map. The level kept is SpellLevel, the field
the server's rank rule compares (docs/forever-facts.md).

Everything downloaded is untrusted: each config must hash to its own name,
each BLTE chunk to its MD5, the encoding and root files and the table to their
content keys (a table whose encrypted chunks, keys unknown, were zero-filled
can't, and is said so; its encrypted sections are skipped). Sizes are bounded,
and any format it doesn't expect stops it. Output is written only when every
spell asked for has exactly one row, with a level from 1 to MAX_LEVEL; on any
problem it prints why, exits non-zero and writes nothing.
"""
import argparse
import hashlib
import os
import re
import struct
import sys
import tempfile
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor

SPELL_LEVELS_FDID = 1140079
MAX_LEVEL = 80
MAX_SPELL_ID = 10_000_000

HOST = "https://us.cdn.blizzard.com/tpr/wow"
MAX_FILE = 400 * 1024 * 1024
ENCRYPTED = [0]


# Blizzard's CDN for WoW's files: the only host this downloads from.
def fetch(path, rng=None, tries=4):
    url = f"{HOST}/{path}"
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url)
            if rng:
                req.add_header("Range", f"bytes={rng}")
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read(MAX_FILE + 1)
                if len(data) > MAX_FILE:
                    raise ValueError("too large")
                return data
        except Exception as e:  # noqa: BLE001
            if attempt == tries - 1:
                raise RuntimeError(f"{url} {rng}: {e}")


def hpath(kind, h):
    return f"{kind}/{h[0:2]}/{h[2:4]}/{h}"


def cached(cache, name, fn):
    p = os.path.join(cache, name)
    if os.path.exists(p):
        return open(p, "rb").read()
    data = fn()
    with open(p, "wb") as f:
        f.write(data)
    return data


def config(cache, h):
    data = cached(cache, h + ".cfg", lambda: fetch(hpath("config", h)))
    if hashlib.md5(data).hexdigest() != h:
        raise ValueError("config md5 mismatch " + h)
    out = {}
    for line in data.decode().splitlines():
        if " = " in line:
            k, v = line.split(" = ", 1)
            out[k] = v.split()
    return out


def blte(data, ekey=None):
    if data[:4] != b"BLTE":
        raise ValueError("not BLTE")
    hsize = struct.unpack(">I", data[4:8])[0]
    if ekey is not None:
        whole = data[:hsize] if hsize else data
        if hashlib.md5(whole).hexdigest() != ekey:
            raise ValueError("ekey md5 mismatch " + ekey)
    if hsize == 0:
        return chunk(data[8:], None)
    flags, n = data[8], int.from_bytes(data[9:12], "big")
    if flags != 0x0F:
        raise ValueError("BLTE flags")
    infos, pos = [], 12
    for _ in range(n):
        c, d = struct.unpack(">II", data[pos:pos + 8])
        infos.append((c, d, data[pos + 8:pos + 24].hex()))
        pos += 24
    out, pos, encrypted = [], hsize, 0
    for c, d, md5 in infos:
        raw = data[pos:pos + c]
        pos += c
        if hashlib.md5(raw).hexdigest() != md5:
            raise ValueError("chunk md5 mismatch")
        piece = chunk(raw, d)
        if piece is None:
            encrypted += 1
            piece = b"\0" * d
        if len(piece) != d:
            raise ValueError("chunk size")
        out.append(piece)
    if encrypted:
        print(f"  note: {encrypted} encrypted chunk(s) zero-filled", file=sys.stderr)
        ENCRYPTED[0] += encrypted
    return b"".join(out)


def chunk(raw, size):
    mode = raw[:1]
    if mode == b"N":
        return raw[1:]
    if mode == b"Z":
        return zlib.decompress(raw[1:])
    if mode == b"E":
        return None
    raise ValueError("BLTE mode %r" % mode)


def encoding_lookup(enc, wanted):
    """ckey hex -> ekey hex for the wanted ckeys."""
    if enc[:2] != b"EN":
        raise ValueError("encoding magic")
    ver, cks, eks = enc[2], enc[3], enc[4]
    cpage_kb, epage_kb = struct.unpack(">HH", enc[5:9])
    cpages, epages = struct.unpack(">II", enc[9:17])
    espec_size = struct.unpack(">I", enc[18:22])[0]
    if ver != 1 or cks != 16 or eks != 16:
        raise ValueError("encoding header")
    pos = 22 + espec_size
    table = []
    for _ in range(cpages):
        table.append(enc[pos:pos + 16])
        pos += 32
    pages_at = pos
    psize = cpage_kb * 1024
    found = {}
    want = {bytes.fromhex(w) for w in wanted}
    for i in range(cpages):
        page = enc[pages_at + i * psize: pages_at + (i + 1) * psize]
        p = 0
        while p + 22 <= len(page):
            count = page[p]
            if count == 0:
                break
            ck = page[p + 6:p + 22]
            if ck in want:
                found[ck.hex()] = page[p + 22:p + 38].hex()
            p += 22 + 16 * count
    return found


def index_lookup(cache, archives, wanted):
    """ekey hex -> (archive, offset, size), from each archive's .index tail."""
    want = {bytes.fromhex(w) for w in wanted}
    found = {}

    def one(arch):
        p = hpath("data", arch) + ".index"
        foot = fetch(p, "-28")
        if len(foot) != 28:
            raise ValueError("index footer")
        ver, _, _, bkb, offb, sizeb, keyb, chk = foot[8:16]
        n = struct.unpack("<I", foot[16:20])[0]
        if keyb != 16 or offb != 4 or sizeb != 4 or chk != 8 or bkb != 4:
            raise ValueError(f"index format {arch}")
        per = 4096 // 24
        blocks = (n + per - 1) // per
        toc = fetch(p, f"-{28 + blocks * 24}")[:blocks * 24]
        last = [toc[i * 16:(i + 1) * 16] for i in range(blocks)]
        hits = []
        for k in want:
            for b, lk in enumerate(last):
                if k <= lk:
                    hits.append((k, b))
                    break
        res = {}
        for k, b in hits:
            block = fetch(p, f"{b * 4096}-{b * 4096 + 4095}")
            for e in range(per):
                ent = block[e * 24:(e + 1) * 24]
                if len(ent) < 24:
                    break
                if ent[:16] == k:
                    size, off = struct.unpack(">II", ent[16:24])
                    res[k.hex()] = (arch, off, size)
        return res

    with ThreadPoolExecutor(16) as ex:
        for res in ex.map(one, archives):
            found.update(res)
    return found


def get_file(cache, ekey, loc):
    def dl():
        if loc:
            arch, off, size = loc
            return fetch(hpath("data", arch), f"{off}-{off + size - 1}")
        return fetch(hpath("data", ekey))
    return blte(cached(cache, ekey + ".blte", dl), ekey)


def root_lookup(root, fdids):
    """fdid -> ckey hex (enUS or all-locale entries)."""
    if root[:4] != b"TSFM":
        raise ValueError("root magic")
    hsize, ver = struct.unpack("<II", root[4:12])
    if hsize > 1000:
        total, named, pos, ver = hsize, ver, 12, 0
    else:
        total, named = struct.unpack("<II", root[12:20])
        pos = hsize
    out = {}
    want = set(fdids)
    while pos < len(root):
        n = struct.unpack("<I", root[pos:pos + 4])[0]
        pos += 4
        if ver == 2:
            locale, f1, f2 = struct.unpack("<III", root[pos:pos + 12])
            f3 = root[pos + 12]
            pos += 13
            content = f1 | f2 | (f3 << 17)
        else:
            content, locale = struct.unpack("<II", root[pos:pos + 8])
            pos += 8
        ids, fd = [], -1
        for i in range(n):
            fd = fd + 1 + struct.unpack("<i", root[pos + 4 * i:pos + 4 * i + 4])[0]
            ids.append(fd)
        pos += 4 * n
        ck_at = pos
        pos += 16 * n
        if not (content & 0x10000000) and named:
            pos += 8 * n
        if locale & 0x2 or locale == 0xFFFFFFFF:
            for i, fd in enumerate(ids):
                if fd in want and fd not in out:
                    out[fd] = root[ck_at + 16 * i: ck_at + 16 * i + 16].hex()
    return out


def bits(rec, off, size):
    b0 = off // 8
    v = int.from_bytes(rec[b0:b0 + (off % 8 + size + 7) // 8], "little")
    return (v >> (off % 8)) & ((1 << size) - 1)


def wdc5(data):
    if data[:4] != b"WDC5":
        raise ValueError("not WDC5")
    pos = 4 + 4 + 128
    (recs, fields, rsize, ssize, thash, lhash, minid, maxid, loc, flags, idx,
     total, bpoff, lookup, fsis, cds, pds, sections) = struct.unpack(
        "<IIIIIIIIIHHIIIIIII", data[pos:pos + 68])
    pos += 68
    secs = []
    for _ in range(sections):
        secs.append(struct.unpack("<QIIIIIIII", data[pos:pos + 40]))
        pos += 40
    pos += total * 4  # field_structure
    infos = []
    for _ in range(fsis // 24):
        infos.append(struct.unpack("<HHIIIII", data[pos:pos + 24]))
        pos += 24
    pallet = data[pos:pos + pds]
    pos += pds
    common = data[pos:pos + cds]
    pal_at, com_at, pal_off, com_maps = 0, 0, [], []
    for (_, _, add, comp, v1, v2, v3) in infos:
        pal_off.append(pal_at if comp in (3, 4) else None)
        if comp in (3, 4):
            pal_at += add
        m = {}
        if comp == 2:
            for j in range(add // 8):
                k, v = struct.unpack("<II", common[com_at + 8 * j:com_at + 8 * j + 8])
                m[k] = v
            com_at += add
        com_maps.append(m)
    if flags & 1:
        raise ValueError("sparse table not handled")
    rows = []
    for (tk, foff, n, sts, ore, idls, rels, omc, ctc) in secs:
        recdata = data[foff:foff + n * rsize]
        p = foff + n * rsize + sts
        ids = list(struct.unpack(f"<{idls // 4}I", data[p:p + idls]))
        p += idls
        copies = [struct.unpack("<II", data[p + 8 * j:p + 8 * j + 8]) for j in range(ctc)]
        p += 8 * ctc
        p += omc * 6
        rel = {}
        if rels:
            ne = struct.unpack("<I", data[p:p + 4])[0]
            for j in range(ne):
                fk, ri = struct.unpack("<II", data[p + 12 + 8 * j:p + 20 + 8 * j])
                rel[ri] = fk
        if tk and not any(recdata):
            print(f"  note: encrypted section of {n} rows skipped", file=sys.stderr)
            continue
        for i in range(n):
            rec = recdata[i * rsize:(i + 1) * rsize]
            vals = []
            for f, (boff, bsize, add, comp, v1, v2, v3) in enumerate(infos):
                if comp in (0, 1):
                    vals.append(bits(rec, boff, bsize))  # offsets count from the record's start
                elif comp == 5:
                    v = bits(rec, boff, bsize)
                    if v & (1 << (bsize - 1)):
                        v -= 1 << bsize
                    vals.append(v)
                elif comp == 2:
                    vals.append(None)  # filled below by id
                elif comp == 3:
                    k = bits(rec, boff, bsize)
                    a = pal_off[f] + 4 * k
                    vals.append(struct.unpack("<I", pallet[a:a + 4])[0])
                elif comp == 4:
                    # A pallet array (#544: SpellEffect's): v3 values per entry.
                    k = bits(rec, boff, bsize)
                    a = pal_off[f] + 4 * k * v3
                    if v3 < 1 or a + 4 * v3 > pal_off[f] + add:
                        raise ValueError("a pallet array entry outside its pallet")
                    vals.append(list(struct.unpack(f"<{v3}I", pallet[a:a + 4 * v3])))
                else:
                    raise ValueError(f"compression {comp} not handled")
            rid = ids[i] if ids else vals[idx]
            for f, (boff, bsize, add, comp, v1, v2, v3) in enumerate(infos):
                if comp == 2:
                    vals[f] = com_maps[f].get(rid, v1)
            rows.append({"id": rid, "fields": vals, "parent": rel.get(i)})
        byid = {r["id"]: r for r in rows}
        for new, old in copies:
            if old in byid:
                rows.append({"id": new, "fields": byid[old]["fields"], "parent": byid[old]["parent"]})
    return {"layout_hash": "%08X" % lhash, "fields": fields, "record_size": rsize, "rows": rows,
            "storage": [list(x) for x in infos], "bitpacked_offset": bpoff}


def table_ids(path):
    """Every rank and group spell ID in BuffTable.lua."""
    text = open(path, encoding="utf-8").read()
    ids = set()
    for listed in re.findall(r"\b(?:ranks|group) = \{([^}]*)\}", text):
        for word in listed.split(","):
            word = word.strip()
            if not re.fullmatch(r"\d{1,8}", word):
                raise ValueError(f"unexpected ID {word!r} in {path}")
            ids.add(int(word))
    if not ids:
        raise ValueError(f"no spell IDs in {path}")
    return ids


def build_name(build):
    match = re.fullmatch(r"WOW-(\d+)patch(\d+\.\d+\.\d+)_\w+", " ".join(build.get("build-name", [])))
    if not match:
        raise ValueError("build config has no build-name")
    return f"{match.group(2)}.{match.group(1)}"


def render(build_id, bcfg, ccfg, sha, layout, encrypted, levels):
    lines = [
        "-- GENERATED by scripts/read_spell_levels.py (#459): do not edit by hand.",
        "-- Each rank's level (SpellLevels.SpellLevel), read from Forever's own data on",
        "-- Blizzard's CDN; docs/forever-facts.md (\"Rank levels\") says how. Read by",
        "-- scripts/gen_spell_table.py (BuffTable.lua's levels) and spec/support/wow.lua.",
        "return {",
        f'    build = "{build_id}",',
        f'    buildConfig = "{bcfg}",',
        f'    cdnConfig = "{ccfg}",',
        f"    fileDataId = {SPELL_LEVELS_FDID},",
        f'    sha256 = "{sha}",',
        f'    layoutHash = "{layout}",',
        f"    encryptedChunks = {encrypted},",
        "    -- [spell ID] = the level the rank is learned at",
        "    levels = {",
    ]
    lines.extend(f"        [{i}] = {levels[i]}," for i in sorted(levels))
    lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--build-config", required=True)
    parser.add_argument("--cdn-config", required=True)
    parser.add_argument("--table", required=True, help="BuffTable.lua: the spells to read")
    parser.add_argument("--cache", required=True, help="a directory for the downloads")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        for value in (args.build_config, args.cdn_config):
            if not re.fullmatch(r"[0-9a-f]{32}", value):
                raise ValueError(f"not a config hash: {value!r}")
        wanted = table_ids(args.table)
        os.makedirs(args.cache, exist_ok=True)
        build, cdn = config(args.cache, args.build_config), config(args.cache, args.cdn_config)
        build_id = build_name(build)
        enc_ckey, enc_ekey = build["encoding"][:2]
        enc = blte(cached(args.cache, enc_ekey + ".blte", lambda: fetch(hpath("data", enc_ekey))), enc_ekey)
        if hashlib.md5(enc).hexdigest() != enc_ckey:
            raise ValueError("encoding file doesn't match its content key")
        root_ckey = build["root"][0]
        root_ekey = encoding_lookup(enc, [root_ckey])[root_ckey]
        locs = index_lookup(args.cache, cdn["archives"], [root_ekey])
        root = get_file(args.cache, root_ekey, locs.get(root_ekey))
        if hashlib.md5(root).hexdigest() != root_ckey:
            raise ValueError("root file doesn't match its content key")
        ckey = root_lookup(root, [SPELL_LEVELS_FDID])[SPELL_LEVELS_FDID]
        ekey = encoding_lookup(enc, [ckey])[ckey]
        locs = index_lookup(args.cache, cdn["archives"], [ekey])
        ENCRYPTED[0] = 0
        db = get_file(args.cache, ekey, locs.get(ekey))
        if hashlib.md5(db).hexdigest() != ckey and not ENCRYPTED[0]:
            raise ValueError("SpellLevels doesn't match its content key")
        table = wdc5(db)
        if table["fields"] != 5:
            raise ValueError(f"SpellLevels has {table['fields']} fields, not 5: its layout changed")
        rows = {}
        for row in table["rows"]:
            spell = row["parent"]
            if spell in wanted and row["fields"][0] == 0:
                if spell in rows:
                    raise ValueError(f"spell {spell} has two SpellLevels rows")
                level = row["fields"][4]
                if not (1 <= level <= MAX_LEVEL):
                    raise ValueError(f"spell {spell} has level {level}")
                rows[spell] = level
        missing = sorted(wanted - set(rows))
        if missing:
            raise ValueError(f"no SpellLevels row for {missing}")
        text = render(build_id, args.build_config, args.cdn_config, hashlib.sha256(db).hexdigest(),
                      table["layout_hash"], ENCRYPTED[0], rows)
    except (ValueError, KeyError, RuntimeError, OSError, struct.error, zlib.error) as err:
        print(f"read_spell_levels: {err}", file=sys.stderr)
        print("read_spell_levels: nothing written", file=sys.stderr)
        return 1
    directory = os.path.dirname(os.path.abspath(args.out))
    handle, temp = tempfile.mkstemp(dir=directory, prefix=".spell-levels-")
    with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as out:
        out.write(text)
    os.chmod(temp, 0o644)
    os.replace(temp, args.out)
    print(f"Forever build {build_id}: {len(rows)} spells' levels, SpellLevels SHA-256 "
          f"{hashlib.sha256(db).hexdigest()}, layout {table['layout_hash']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
