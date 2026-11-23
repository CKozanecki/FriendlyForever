-- Spec: #496
-- Guild leader controls, part 1: the shared memory (each guild's leader
-- ranks, caps and vetoes, versioned in the saved settings), the guild
-- check-ins, and the rule that only a sender the roster shows as a leader
-- can change anything.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local PREFIX = "FriendlyFvr"
local KEY = "Forever Realm:Friends Forever"
local ME = "Me"
local GM, OFFICER, MEMBER, RECRUIT, STRANGER = "Gina-Moss", "Otto-Bell", "Mia-Tern", "Rex-Dunn", "Sly-Fox"
local RANKS = { [GM] = 0, [OFFICER] = 1, [MEMBER] = 4, [RECRUIT] = 4 }
local ROSTER = { ME, GM, OFFICER, MEMBER, RECRUIT }
local TYPES = { ranks = "GRANKS", caps = "GCAPS", vetoes = "GVETO" }
local SECTIONS = { "ranks", "caps", "vetoes" }

local function receive(text, sender, route)
    wow.fire("CHAT_MSG_ADDON", PREFIX, text, route or "GUILD", sender, "", 0, 0, "", 0)
end

-- One part of a section, as a copy sends it.
local function part(kind, sender, version, items, n, of)
    return table.concat({ "1", TYPES[kind], sender, tostring(version), tostring(n or 1), tostring(of or 1), items },
        ";")
end

local function count(ns, key)
    return ns.Diag.Counters()[key] or 0
end

-- The section as the saved settings hold it: read from the client's own
-- saved file, never through GuildLead.
local function saved(kind)
    local g = _G.FriendlyForeverDB.guilds and _G.FriendlyForeverDB.guilds[KEY]
    local s = g and g[kind]
    if not s then return 0, "-" end
    return s.version, #s.items == 0 and "-" or table.concat(s.items, ",")
end

local function ranksOf(state)
    for name, rank in pairs(RANKS) do state.guildRanks[name] = rank end
end

-- This copy alone, as a guild member of rank 4, with the roster read.
local function Solo(opts)
    opts = opts or {}
    local ns = wow.boot({ guildSync = true, db = opts.db, before = function(state)
        state.guildRoster = ROSTER
        ranksOf(state)
        if opts.before then opts.before(state) end
    end })
    ns.GuildLead.random = function() return 0 end
    wow.fire("GUILD_ROSTER_UPDATE")
    return ns
end

local PEOPLE = {
    [GM] = { name = "Gina", surname = "Moss" }, [OFFICER] = { name = "Otto", surname = "Bell" },
    [MEMBER] = { name = "Mia", surname = "Tern" }, [RECRUIT] = { name = "Rex", surname = "Dunn" },
}

-- A copy for this guildmate, in the guild, with its roster read.
local function Client(full, db)
    local p = PEOPLE[full]
    local c = wow.newClient({ name = p.name, surname = p.surname, guildSync = true, db = db,
        before = function(state)
            state.guildRoster = ROSTER
            ranksOf(state)
        end })
    c.ns.GuildLead.random = function() return 0 end
    wow.fire("GUILD_ROSTER_UPDATE")
    return c
end

-- A network of these clients, carrying only what is sent from now on.
local function Net(clients)
    local net = wow.network(clients)
    for _, c in ipairs(clients) do
        wow.use(c)
        net.seen[c] = #wow.addonSent
    end
    return net
end

local function on(c, fn)
    wow.use(c)
    return fn(c.ns)
end

describe("Guild leader controls: the shared memory (#496)", function()
    after_each(function() wow.reset() end)

    describe("leaders set it and every copy keeps it (white)", function()
        it("the guild master picks the ranks that lead, and every online copy takes them", function()
            local gm, officer, member = Client(GM), Client(OFFICER), Client(MEMBER)
            local net = Net({ gm, officer, member })
            assert.is_true(on(gm, function(ns) return ns.GuildLead.Set("ranks", { "1" }) end))
            wow.advanceAll(net, 10, 0.5)
            for _, c in ipairs({ gm, officer, member }) do
                wow.use(c)
                local version, items = saved("ranks")
                assert.are.equal("1", items, c.full)
                assert.is_true(version > 0)
                assert.is_true(c.ns.GuildLead.IsLeader(OFFICER), c.full)
                assert.is_false(c.ns.GuildLead.IsLeader(MEMBER), c.full)
            end
        end)

        it("an officer of a leading rank sets the caps, and every copy lowers to them", function()
            local gm, officer, member = Client(GM), Client(OFFICER), Client(MEMBER)
            local net = Net({ gm, officer, member })
            on(gm, function(ns) ns.GuildLead.Set("ranks", { "1" }) end)
            wow.advanceAll(net, 10, 0.5)
            assert.is_true(on(officer, function(ns) return ns.GuildLead.Set("caps", { "w3", "g2", "h0" }) end))
            wow.advanceAll(net, 10, 0.5)
            for _, c in ipairs({ gm, officer, member }) do
                wow.use(c)
                assert.are.equal("g2,h0,w3", select(2, saved("caps")), c.full)
                assert.are.same({ greeters = 2, welcomes = 3, hellos = false }, c.ns.GuildLead.Caps())
            end
        end)

        it("a veto list of the most entries goes out in parts and arrives whole", function()
            local gm, member = Client(GM), Client(MEMBER)
            local net = Net({ gm, member })
            local list = {}
            for i = 1, 20 do list[#list + 1] = "bld" .. i end
            for i = 1, 20 do list[#list + 1] = string.format("c%08x", i * 2654435761 % 4294967296) end
            assert.are.equal(40, #list)
            assert.is_true(on(gm, function(ns) return ns.GuildLead.Set("vetoes", list) end))
            wow.advanceAll(net, 10, 0.5)
            wow.use(gm)
            local parts = 0
            for _, m in ipairs(wow.addonSent) do
                if m.text:find(";GVETO;", 1, true) then
                    parts = parts + 1
                    assert.is_true(#m.text <= 255)
                end
            end
            assert.is_true(parts > 1, "more than one part")
            table.sort(list)
            wow.use(member)
            assert.are.equal(table.concat(list, ","), select(2, saved("vetoes")))
            assert.is_true(member.ns.GuildLead.IsVetoed("bld7"))
        end)

        it("a leader lifts a cap and undoes a veto, and every copy follows", function()
            local gm, member = Client(GM), Client(MEMBER)
            local net = Net({ gm, member })
            on(gm, function(ns)
                ns.GuildLead.Set("caps", { "g2", "w3" })
                ns.GuildLead.Set("vetoes", { "bld1", "bjc4" })
            end)
            wow.advanceAll(net, 10, 0.5)
            on(gm, function(ns)
                ns.GuildLead.Set("caps", { "w3" })
                ns.GuildLead.Set("vetoes", { "bjc4" })
            end)
            wow.advanceAll(net, 10, 0.5)
            wow.use(member)
            assert.are.equal("w3", select(2, saved("caps")))
            assert.are.equal("bjc4", select(2, saved("vetoes")))
            assert.is_false(member.ns.GuildLead.IsVetoed("bld1"))
            assert.are.same({ welcomes = 3, hellos = true }, member.ns.GuildLead.Caps())
        end)

        it("a copy that was offline catches up from an online leader's copy when it checks in", function()
            local gm, officer = Client(GM), Client(OFFICER)
            local net = Net({ gm, officer })
            on(gm, function(ns)
                ns.GuildLead.Set("ranks", { "1" })
                ns.GuildLead.Set("caps", { "g3" })
                ns.GuildLead.Set("vetoes", { "bld2" })
            end)
            wow.advanceAll(net, 10, 0.5)
            -- Mia logs in now; nothing reaches her until she checks in.
            local member = Client(MEMBER)
            net = Net({ gm, officer, member })
            wow.use(member)
            assert.are.equal(0, (saved("caps")))
            wow.advanceAll(net, 180, 0.5)
            wow.use(member)
            assert.are.equal("1", select(2, saved("ranks")))
            assert.are.equal("g3", select(2, saved("caps")))
            assert.are.equal("bld2", select(2, saved("vetoes")))
        end)

        it("with the guild master offline, a copy that missed an officer's change catches up from the officer", function()
            local gm, officer, member = Client(GM), Client(OFFICER), Client(MEMBER)
            local net = Net({ gm, officer, member })
            on(gm, function(ns) ns.GuildLead.Set("ranks", { "1" }) end)
            wow.advanceAll(net, 10, 0.5)
            -- Mia goes offline; the officer changes the caps; the guild master logs off.
            net = Net({ gm, officer })
            on(officer, function(ns) ns.GuildLead.Set("caps", { "g4" }) end)
            wow.advanceAll(net, 10, 0.5)
            -- Mia comes back with only the officer online: a fresh session's check-in.
            wow.use(member)
            local db = _G.FriendlyForeverDB
            member = Client(MEMBER, db)
            net = Net({ officer, member })
            wow.advanceAll(net, 90, 0.5)
            wow.use(member)
            assert.are.equal("g4", select(2, saved("caps")))
        end)

        it("is saved per guild, and back after a reload", function()
            Solo()
            receive(part("caps", GM, 1800000000, "g5"), GM)
            assert.are.equal("g5", select(2, saved("caps")))
            local db = _G.FriendlyForeverDB
            local ns = Solo({ db = db })
            assert.are.same({ greeters = 5, hellos = true }, ns.GuildLead.Caps())
            -- Another guild starts with nothing, and keeps the first.
            ns = Solo({ db = _G.FriendlyForeverDB, before = function(s) s.guildName = "Night Watch" end })
            assert.are.same({ hellos = true }, ns.GuildLead.Caps())
            assert.are.equal("g5", _G.FriendlyForeverDB.guilds[KEY].caps.items[1])
        end)

        it("two leaders' edits with the same version settle the same way on every copy", function()
            for _, order in ipairs({ { GM, OFFICER }, { OFFICER, GM } }) do
                local ns = Solo()
                receive(part("ranks", GM, 10, "1"), GM)
                local lists = { [GM] = "g2", [OFFICER] = "w4" }
                for _, who in ipairs(order) do
                    wow.advance(1.1)
                    receive(part("caps", who, 1800000000, lists[who]), who)
                end
                assert.are.equal("w4", select(2, saved("caps")), "the greater list wins, whichever came first")
                assert.are.equal(0, count(ns, "luaErrors"))
            end
        end)

        it("a guild master who lost their settings still moves the guild on", function()
            local gm, member = Client(GM), Client(MEMBER)
            local net = Net({ gm, member })
            on(gm, function(ns) ns.GuildLead.Set("caps", { "g2" }) end)
            wow.advanceAll(net, 10, 0.5)
            -- A fresh install a while later: no memory at all.
            wow.use(gm)
            gm = Client(GM, { enabled = true })
            net = Net({ gm, member })
            wow.advanceAll(net, 100, 1)
            assert.is_true(on(gm, function(ns) return ns.GuildLead.Set("caps", { "g6" }) end))
            wow.advanceAll(net, 10, 0.5)
            wow.use(member)
            assert.are.equal("g6", select(2, saved("caps")))
        end)

        it("each check-in records who has the addon, their version and when they were seen", function()
            local gm, member = Client(GM), Client(MEMBER)
            local net = Net({ gm, member })
            wow.advanceAll(net, 30, 0.5)
            wow.use(gm)
            local mate = _G.FriendlyForeverDB.guilds[KEY].mates[MEMBER]
            assert.are.equal(wow.parseToc().Version, mate.version)
            assert.are.equal(_G.GetServerTime() - 25, mate.seen)
            assert.are.same(gm.ns.GuildLead.Mates()[MEMBER], mate)
            -- And again every CHECKIN_EVERY seconds.
            wow.advanceAll(net, gm.ns.GuildLead.CHECKIN_EVERY, 5)
            wow.use(gm)
            assert.is_true(_G.FriendlyForeverDB.guilds[KEY].mates[MEMBER].seen > mate.seen)
        end)
    end)

    describe("who leads is read from the roster, never from the message (black)", function()
        it("a member, a stranger, or an officer of a rank that doesn't lead changes nothing", function()
            local ns = Solo()
            receive(part("caps", MEMBER, 1800000000, "g1"), MEMBER)
            wow.advance(1.1)
            receive(part("caps", STRANGER, 1800000000, "g1"), STRANGER)
            wow.advance(1.1)
            receive(part("caps", OFFICER, 1800000000, "g1"), OFFICER)
            wow.advance(1.1)
            receive(part("ranks", OFFICER, 1800000000, "1,2,3,4"), OFFICER)
            assert.are.equal(0, (saved("caps")))
            assert.are.equal(0, (saved("ranks")))
            assert.is_true(count(ns, "syncNoAuthority") >= 4)
            assert.is_false(ns.GuildLead.IsLeader(OFFICER))
        end)

        it("a message that says it is from the guild master but isn't changes nothing", function()
            local ns = Solo()
            receive(part("caps", GM, 1800000000, "g1"), MEMBER)
            assert.are.equal(0, (saved("caps")))
            assert.are.equal(1, count(ns, "commSpoofed"))
        end)

        it("a leader's rank that can't be read: nobody leads", function()
            local ns = Solo({ before = function(s) s.guildRankSecret = { [GM] = true } end })
            receive(part("caps", GM, 1800000000, "g1"), GM)
            assert.are.equal(0, (saved("caps")))
            assert.is_nil(ns.GuildLead.Rank(GM))
            assert.are.same({}, wow.errors)
        end)

        it("a roster that can't be read forgets the ranks: nobody leads until one can", function()
            local ns = Solo()
            assert.is_true(ns.GuildLead.IsGuildMaster(GM))
            local real = _G.GetNumGuildMembers
            _G.GetNumGuildMembers = function() return wow.secret(5) end
            wow.fire("GUILD_ROSTER_UPDATE")
            receive(part("caps", GM, 1800000000, "g1"), GM)
            assert.are.equal(0, (saved("caps")))
            _G.GetNumGuildMembers = real
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(1.1)
            receive(part("caps", GM, 1800000000, "g1"), GM)
            assert.are.equal("g1", select(2, saved("caps")))
        end)

        it("a demoted officer's next change is refused", function()
            local ns = Solo()
            receive(part("ranks", GM, 10, "1"), GM)
            wow.advance(1.1)
            receive(part("caps", OFFICER, 20, "g3"), OFFICER)
            assert.are.equal("g3", select(2, saved("caps")))
            wow.state.guildRanks[OFFICER] = 4
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(1.1)
            receive(part("caps", OFFICER, 30, "g1"), OFFICER)
            assert.are.equal("g3", select(2, saved("caps")))
            assert.is_false(ns.GuildLead.IsLeader(OFFICER))
        end)

        it("no guild, or one the game won't name: nothing is kept, sent or taken, and nothing breaks", function()
            for _, setup in ipairs({
                function(s) s.inGuild = false end,
                function(s) s.guildName = nil end,
                function(s) s.guildNameSecret = true end,
                function(s) s.secretRealm = true end,
            }) do
                local ns = Solo({ before = setup })
                receive(part("caps", GM, 1800000000, "g1"), GM)
                assert.is_nil(ns.GuildLead.Memory())
                assert.is_false((ns.GuildLead.Set("caps", { "g1" })))
                assert.are.same({ hellos = true }, ns.GuildLead.Caps())
                assert.is_false(ns.GuildLead.IsLeader(GM))
                assert.is_false(ns.GuildLead.IsVetoed("bld1"))
                wow.advance(60)
                for _, m in ipairs(wow.addonSent) do assert.is_nil(m.text:find(";G[CRV]", 1)) end
                assert.are.same({}, _G.FriendlyForeverDB.guilds or {})
                assert.are.same({}, wow.errors)
            end
        end)

        it("a leader can set only short tokens that limit, never a line to say", function()
            local ns = Solo({ before = function(s) s.guildRanks[ME] = 0 end })
            for _, bad in ipairs({
                { "caps", { "g21" } }, { "caps", { "g0" } }, { "caps", { "h1" } }, { "caps", { "g2", "g3" } },
                { "caps", { "Welcome to the guild!" } }, { "vetoes", { "say this" } }, { "vetoes", { "bld1", "bld1" } },
                { "vetoes", { "c1234567" } }, { "vetoes", { "cABCDEF12" } }, { "vetoes", { "bxd1" } },
                { "vetoes", { "blx1" } }, { "vetoes", { "bld0" } }, { "vetoes", { "bld100" } }, { "vetoes", { "bl1" } }, { "ranks", { "0" } }, { "ranks", { "10" } },
                { "nope", { "g1" } }, { "caps", "g1" }, { "caps", { 5 } },
            }) do
                local ok = ns.GuildLead.Set(bad[1], bad[2])
                assert.is_false(ok, tostring(bad[1]))
            end
            local many = {}
            for i = 1, 41 do many[i] = "bld" .. i end
            assert.is_false((ns.GuildLead.Set("vetoes", many)))
            assert.are.equal(0, (saved("caps")))
            assert.are.equal(0, (saved("vetoes")))
        end)

        it("a member's own copy refuses to set anything", function()
            local ns = Solo()
            assert.is_false((ns.GuildLead.Set("caps", { "g1" })))
            assert.is_false((ns.GuildLead.Set("ranks", { "4" })))
            assert.are.equal(0, (saved("caps")))
        end)

        it("damaged saved memory heals, and catches up again from version 0", function()
            local good = { version = 50, items = { "g2" } }
            local guilds = {
                [KEY] = {
                    ranks = { version = "high", items = { "1" } },
                    caps = good,
                    vetoes = { version = 9, items = { "bld1", "say this" } },
                    mates = { [MEMBER] = { version = "1.6.0", seen = 100 }, ["bad name!"] = { version = "1", seen = 1 },
                        [RECRUIT] = { version = "x", seen = 5 }, [GM] = { version = "?", seen = 0 / 0 } },
                    used = 20,
                },
                ["Forever Realm:Old"] = { used = "yesterday", caps = good },
                ["Forever Realm:Junk"] = "not a table",
                [5] = { caps = good },
            }
            for i = 1, 12 do guilds["Forever Realm:G" .. i] = { used = i } end
            local ns = Solo({ db = { enabled = true, guilds = guilds } })
            local g = _G.FriendlyForeverDB.guilds[KEY]
            assert.are.same({ version = 0, items = {} }, g.ranks)
            assert.are.same({ version = 50, items = { "g2" } }, g.caps)
            assert.are.same({ version = 0, items = {} }, g.vetoes)
            assert.are.same({ [MEMBER] = { version = "1.6.0", seen = 100 } }, g.mates)
            local n = 0
            for key in pairs(_G.FriendlyForeverDB.guilds) do
                n = n + 1
                assert.are.equal("string", type(key))
            end
            assert.are.equal(ns.GuildLead.MAX_GUILDS, n)
            -- Damaged mid-session: the next read gives a fresh section.
            g.caps.items = { "say this" }
            assert.are.same({ hellos = true }, ns.GuildLead.Caps())
            assert.are.same({}, wow.errors)
        end)
    end)

    describe("forged, oversized, malformed and replayed messages change nothing (red)", function()
        -- The test's own view of what each section should hold: only a
        -- well-formed list from a sender the roster shows leading, and newer
        -- than the last (a higher version, or the same with a greater list).
        local function Model()
            local m = { kept = {}, secret = {} }
            for _, kind in ipairs(SECTIONS) do m.kept[kind] = { v = 0, e = "-" } end
            function m.leads(sender, kind)
                local rank = wow.state.guildRanks[sender]
                local inRoster = false
                for _, name in ipairs(wow.state.guildRoster) do inRoster = inRoster or name == sender end
                if rank == nil or not inRoster or m.secret[sender] then return false end
                if kind == "ranks" then return rank == 0 end
                if rank == 0 then return true end
                for item in m.kept.ranks.e:gmatch("[^,]+") do
                    if tonumber(item) == rank then return true end
                end
                return false
            end
            function m.offer(kind, sender, v, e)
                local k = m.kept[kind]
                if v > 999999999999 then return end -- more than 12 digits
                if m.leads(sender, kind) and (v > k.v or (v == k.v and e > k.e)) then m.kept[kind] = { v = v, e = e } end
            end
            return m
        end

        local GOOD = {
            ranks = { "1", "2", "1,3", "-", "2,1" },
            caps = { "g2", "w3", "h0", "g1,w20", "g5,h0,w1", "-" },
            vetoes = { "bld1", "bjc12,c0a1b2c3d", "-", "bld3,bld4,bld5", "c00000000" },
        }
        -- Each breaks a good part's fields ({ protocol, type, subject,
        -- version, part, parts, items }) so it must be refused, and returns
        -- the message's text.
        local function join(f) return table.concat(f, ";") end
        local BREAK = {
            function(f) f[4] = "0" return join(f) end,
            function(f) f[4] = "0" .. f[4] return join(f) end,                 -- a leading zero
            function(f) f[4] = "1234567890123" return join(f) end,             -- 13 digits
            function(f) f[4] = "-5" return join(f) end,
            function(f) f[4] = "1e9" return join(f) end,
            function(f) f[5] = "2" return join(f) end,                         -- part 2 of 1
            function(f) f[6] = "7"; f[5] = "1" return join(f) end,             -- 7 parts
            function(f) f[5] = "0" return join(f) end,
            function(f) f[8] = "extra" return join(f) end,
            function(f) f[7] = nil return join(f) end,                          -- no items field
            function(f) f[7] = f[7] .. ",x9" return join(f) end,
            function(f) f[7] = f[7] .. ",Say this in guild" return join(f) end,
            function(f) f[7] = "g2,g3" return join(f) end,                     -- a cap twice (and not every type's)
            function(f) f[7] = "bld1,bld1" return join(f) end,                 -- an item twice
            function(f) f[7] = string.rep("bld1", 70, ",") return join(f) end, -- oversized
            function(f) f[1] = "2" return join(f) end,                         -- protocol 2
            function(f) f[7] = f[7] .. "|cffff0000" return join(f) end,
            function(f) f[2] = "GCAPZ" return join(f) end,
            function(f) f[7] = "" return join(f) end,
        }
        local SENDERS = { GM, OFFICER, MEMBER, RECRUIT, STRANGER }

        local function Storm(seed, steps)
            random.seed(seed)
            local ns = Solo()
            local m = Model()
            local versions = { 0, 1, 2, 5, 1800000000, 1800000001, 999999999999 }
            local stats = { taken = 0, refused = 0 }
            for step = 1, steps do
                local roll = random.random(100)
                if roll <= 4 then
                    -- The officer is promoted or demoted.
                    wow.state.guildRanks[OFFICER] = random.random(2) == 1 and 1 or random.random(2, 5)
                    wow.fire("GUILD_ROSTER_UPDATE")
                elseif roll <= 7 then
                    -- A leader's rank becomes unreadable, or readable again.
                    local who = random.random(2) == 1 and GM or OFFICER
                    m.secret[who] = not m.secret[who] or nil
                    local set = {}
                    for name in pairs(m.secret) do set[name] = true end
                    wow.state.guildRankSecret = set
                    wow.fire("GUILD_ROSTER_UPDATE")
                else
                    local kind = SECTIONS[random.random(3)]
                    local sender = SENDERS[random.random(#SENDERS)]
                    local kept = m.kept[kind].v
                    local v = random.random(3) == 1 and kept + random.random(0, 3) or versions[random.random(#versions)]
                    if v < 1 then v = 1 end
                    local e = GOOD[kind][random.random(#GOOD[kind])]
                    local text = part(kind, sender, string.format("%.0f", v), e)
                    local from = sender
                    local broken = random.random(3) == 1
                    if broken then
                        text = BREAK[random.random(#BREAK)]({ "1", TYPES[kind], sender, string.format("%.0f", v),
                            "1", "1", e })
                    elseif random.random(10) == 1 then
                        -- Forged: someone else sends the leader's very message.
                        from = SENDERS[random.random(#SENDERS)]
                        if from == sender then from = STRANGER end
                    end
                    -- Sections go only to the guild: a whisper is refused.
                    local route = random.random(20) == 1 and "WHISPER" or "GUILD"
                    local before = m.kept[kind].v .. "/" .. m.kept[kind].e
                    receive(text, from, route)
                    if not broken and from == sender and route == "GUILD" then m.offer(kind, sender, v, e) end
                    local after = m.kept[kind].v .. "/" .. m.kept[kind].e
                    if before ~= after then stats.taken = stats.taken + 1 else stats.refused = stats.refused + 1 end
                end
                for _, kind in ipairs(SECTIONS) do
                    local v, e = saved(kind)
                    assert.are.equal(m.kept[kind].v .. "/" .. m.kept[kind].e, v .. "/" .. e,
                        string.format("seed %d step %d: %s", seed, step, kind))
                end
                wow.advance(1.1) -- past each sender's flood limit
            end
            assert.are.same({}, wow.errors)
            assert.are.equal(0, count(ns, "luaErrors"))
            assert.are.equal(0, #wow.sent, "never a line in chat")
            assert.are.equal(0, #wow.casts, "never a cast")
            return stats
        end

        for _, seed in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8 }) do
            it("seed " .. seed .. ": only a newer, well-formed list from a current leader is ever kept", function()
                local stats = Storm(seed, 300)
                assert.is_true(stats.taken > 3, "some genuine changes were taken")
                assert.is_true(stats.refused > 100, "and many refused")
            end)
        end

        it("a replayed old version, or the same one again, changes nothing", function()
            local ns = Solo()
            receive(part("caps", GM, 100, "g2"), GM)
            wow.advance(1.1)
            receive(part("caps", GM, 200, "g4"), GM)
            for _, old in ipairs({ { 100, "g2" }, { 199, "h0" }, { 200, "g4" }, { 200, "g3" } }) do
                wow.advance(1.1)
                receive(part("caps", GM, old[1], old[2]), GM)
                assert.are.equal("200/g4", table.concat({ saved("caps") }, "/"))
            end
            assert.is_true(count(ns, "syncOld") >= 4)
        end)

        it("parts from a non-leader never join a leader's list, and a list's parts must all come", function()
            local ns = Solo()
            -- Two parts from the guild master, a forged part from a member between them.
            receive(part("vetoes", GM, 50, "bld1,bld2", 1, 2), GM)
            receive(part("vetoes", GM, 50, "bld9", 2, 2), MEMBER)
            assert.are.equal(0, (saved("vetoes")))
            assert.are.equal(1, ns.Versioned.Assembling(ns.GuildLead.SECTIONS.vetoes))
            wow.advance(1.1)
            receive(part("vetoes", MEMBER, 50, "bld9", 2, 2), MEMBER)
            assert.are.equal(0, (saved("vetoes")))
            assert.are.equal(1, ns.Versioned.Assembling(ns.GuildLead.SECTIONS.vetoes), "nothing kept for the member")
            wow.advance(1.1)
            receive(part("vetoes", GM, 50, "bld3", 2, 2), GM)
            assert.are.equal("bld1,bld2,bld3", select(2, saved("vetoes")))
            -- A list whose last part never comes is forgotten.
            wow.advance(1.1)
            receive(part("vetoes", GM, 60, "bld4", 1, 2), GM)
            wow.advance(ns.Versioned.ASSEMBLY_TTL + 1)
            receive(part("vetoes", GM, 60, "bld5", 2, 2), GM)
            assert.are.equal("bld1,bld2,bld3", select(2, saved("vetoes")))
            -- Parts of two versions don't mix.
            wow.advance(1.1)
            receive(part("vetoes", GM, 70, "bld6", 1, 2), GM)
            wow.advance(1.1)
            receive(part("vetoes", GM, 71, "bld7", 2, 2), GM)
            assert.are.equal("bld1,bld2,bld3", select(2, saved("vetoes")))
            -- Parts that together hold more than the most a list may.
            local many = {}
            for i = 1, 25 do many[i] = "bld" .. i end
            local first = table.concat(many, ",")
            for i = 1, 20 do many[i] = "blc" .. i end
            local second = table.concat(many, ",", 1, 20)
            wow.advance(1.1)
            receive(part("vetoes", GM, 80, first, 1, 2), GM)
            wow.advance(1.1)
            receive(part("vetoes", GM, 80, second, 2, 2), GM)
            assert.are.equal("bld1,bld2,bld3", select(2, saved("vetoes")))
            assert.are.same({}, wow.errors)
        end)

        it("a flood of stale check-ins makes a leader's copy send at most once a gap", function()
            local ns = Solo({ before = function(s) s.guildRanks[ME] = 0 end })
            assert.is_true(ns.GuildLead.Set("caps", { "g2" }))
            wow.advance(5)
            local function sends()
                local n = 0
                for _, msg in ipairs(wow.addonSent) do
                    if msg.text:find(";GCAPS;", 1, true) then n = n + 1 end
                end
                return n
            end
            local start = sends()
            local seconds = 600
            for i = 1, seconds do
                receive("1;GCHECK;" .. MEMBER .. ";1.5.2;0;0;0", MEMBER)
                if i % 2 == 0 then receive("1;GCHECK;" .. RECRUIT .. ";1.5.2;0;0;0", RECRUIT) end
                wow.advance(1)
            end
            local sent = sends() - start
            assert.is_true(sent >= 1, "it still catches them up")
            assert.is_true(sent <= seconds / ns.GuildLead.SEND_GAP + 1, sent .. " sends")
        end)

        it("with a third of the messages lost, every copy still ends up with the leaders' settings", function()
            random.seed(11)
            local gm, officer, member, recruit = Client(GM), Client(OFFICER), Client(MEMBER), Client(RECRUIT)
            local net = Net({ gm, officer, member, recruit })
            net.lose = function() return random.random(3) == 1 end
            on(gm, function(ns) ns.GuildLead.Set("ranks", { "1" }) end)
            wow.advanceAll(net, 5, 1)
            on(gm, function(ns) ns.GuildLead.Set("vetoes", { "bld1", "bld2", "bjd5" }) end)
            wow.advanceAll(net, 5, 1)
            on(gm, function(ns) ns.GuildLead.Set("caps", { "g2" }) end)
            wow.advanceAll(net, 5 * gm.ns.GuildLead.CHECKIN_EVERY, 5)
            for _, c in ipairs({ gm, officer, member, recruit }) do
                wow.use(c)
                assert.are.equal("1", select(2, saved("ranks")), c.full)
                assert.are.equal("g2", select(2, saved("caps")), c.full)
                assert.are.equal("bjd5,bld1,bld2", select(2, saved("vetoes")), c.full)
            end
        end)
    end)
    describe("the edges of each check (black)", function()
        it("a malformed section is refused by the channel itself, before it is parsed", function()
            local ns = Solo()
            for _, text in ipairs({
                part("caps", GM, 5, "g21"), part("caps", GM, 5, "x1"), part("vetoes", GM, 5, "bld1," .. string.rep("b", 30)),
                part("ranks", GM, 5, "1,2,3,4,5,6,7,8,9,1"), part("caps", GM, "05", "g1"), part("caps", GM, 5, "g1", 0, 1),
                part("caps", GM, 5, "g1", 1, 7), part("caps", GM, "1234567890123", "g1"),
            }) do
                local before = count(ns, "commMalformed")
                receive(text, GM)
                assert.are.equal(before + 1, count(ns, "commMalformed"), text)
                wow.advance(1.1)
            end
            assert.are.equal(0, (saved("caps")))
            -- "0" stands for none only in a check-in, never as a version.
            receive(part("caps", GM, 0, "g1"), GM)
            assert.are.equal(0, (saved("caps")))
            receive("1;GCHECK;" .. MEMBER .. ";1.5.2;0;x;0", MEMBER)
            assert.is_nil(_G.FriendlyForeverDB.guilds[KEY].mates[MEMBER])
        end)

        it("an empty list, sent as \"-\", is kept as empty", function()
            Solo()
            receive(part("caps", GM, 5, "g1"), GM)
            wow.advance(1.1)
            receive(part("caps", GM, 6, "-"), GM)
            assert.are.equal("6/-", table.concat({ saved("caps") }, "/"))
            assert.are.same({}, _G.FriendlyForeverDB.guilds[KEY].caps.items)
        end)

        it("a part sent twice counts once, so a list never completes without all its parts", function()
            local ns = Solo()
            receive(part("vetoes", GM, 50, "bld1", 1, 3), GM)
            wow.advance(1.1)
            receive(part("vetoes", GM, 50, "bld1", 1, 3), GM)
            wow.advance(1.1)
            receive(part("vetoes", GM, 50, "bld2", 2, 3), GM)
            assert.are.equal(0, (saved("vetoes")))
            assert.are.same({}, wow.errors)
            assert.are.equal(0, count(ns, "luaErrors"))
        end)

        it("an item twice across two parts refuses the whole list", function()
            Solo()
            receive(part("vetoes", GM, 50, "bld1,bld2", 1, 2), GM)
            wow.advance(1.1)
            receive(part("vetoes", GM, 50, "bld2", 2, 2), GM)
            assert.are.equal(0, (saved("vetoes")))
        end)

        it("an officer demoted between two parts: the list is refused", function()
            Solo()
            receive(part("ranks", GM, 10, "1"), GM)
            wow.advance(1.1)
            receive(part("vetoes", OFFICER, 50, "bld1", 1, 2), OFFICER)
            wow.state.guildRanks[OFFICER] = 4
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(1.1)
            receive(part("vetoes", OFFICER, 50, "bld2", 2, 2), OFFICER)
            assert.are.equal(0, (saved("vetoes")))
        end)

        it("at most MAX_ASSEMBLIES lists are put back together at once", function()
            local names = { "Ada-One", "Bea-Two", "Cal-Three", "Dot-Four", "Eve-Five" }
            local ns = Solo({ before = function(s)
                for _, name in ipairs(names) do
                    s.guildRoster[#s.guildRoster + 1] = name
                    s.guildRanks[name] = 1
                end
            end })
            receive(part("ranks", GM, 10, "1"), GM)
            for _, name in ipairs(names) do
                wow.advance(0.1)
                receive(part("vetoes", name, 50, "bld1", 1, 2), name)
            end
            assert.are.equal(ns.Versioned.MAX_ASSEMBLIES, ns.Versioned.Assembling(ns.GuildLead.SECTIONS.vetoes))
            -- The oldest went: its last part completes nothing; the newest's does.
            receive(part("vetoes", names[1], 50, "bld2", 2, 2), names[1])
            assert.are.equal(0, (saved("vetoes")))
            receive(part("vetoes", names[5], 50, "bld3", 2, 2), names[5])
            assert.are.equal("bld1,bld3", select(2, saved("vetoes")))
            -- Lists past their time make room before any other goes.
            for i = 2, 4 do receive(part("vetoes", names[i], 60, "bld1", 1, 2), names[i]) end
            wow.advance(ns.Versioned.ASSEMBLY_TTL + 1)
            receive(part("vetoes", names[5], 60, "bld1", 1, 2), names[5])
            assert.are.equal(1, ns.Versioned.Assembling(ns.GuildLead.SECTIONS.vetoes))
        end)

        it("parts of one version split two ways don't mix", function()
            Solo()
            receive(part("vetoes", GM, 50, "bld1", 1, 2), GM)
            wow.advance(1.1)
            receive(part("vetoes", GM, 50, "bld2", 2, 3), GM)
            wow.advance(1.1)
            receive(part("vetoes", GM, 50, "bld3", 3, 3), GM)
            assert.are.equal(0, (saved("vetoes")))
        end)

        it("a rank the roster gives as anything but a whole number from 0 to 9 doesn't lead", function()
            for _, rank in ipairs({ 0.5, -1, "0", 10 }) do
                local ns = Solo({ before = function(s) s.guildRanks[GM] = rank end })
                receive(part("caps", GM, 5, "g1"), GM)
                assert.are.equal(0, (saved("caps")), tostring(rank))
                assert.is_false(ns.GuildLead.IsGuildMaster(GM))
                assert.is_nil(ns.GuildLead.Rank(GM), tostring(rank))
            end
        end)

        it("in a guild the game won't confirm, or with a name too long for a key, nothing applies", function()
            for _, setup in ipairs({
                function(s) s.inGuild = wow.secret(true) end,
                function(s) s.guildName = string.rep("x", 120) end,
                function(s) s.guildName = "" end,
            }) do
                local ns = Solo({ before = setup })
                receive(part("caps", GM, 5, "g1"), GM)
                assert.is_nil(ns.GuildLead.Memory())
                assert.is_false(ns.GuildLead.IsLeader(GM))
                assert.are.same({}, wow.errors)
            end
            -- The game won't say whether you're in a guild, though it names one.
            local ns = Solo()
            _G.IsInGuild = function() return wow.secret(true) end
            assert.is_nil(ns.GuildLead.Memory())
            assert.is_false(ns.GuildLead.IsLeader(GM))
        end)

        it("a version is a whole number from the server's clock, or from yours when it can't be read", function()
            for _, setup in ipairs({
                function(s) s.serverSkew = 0.5 end,
                function(s) s.serverTimeSecret = true end,
                function() _G.GetServerTime = nil end,
                function() _G.GetServerTime = function() return 0 end end,
                function() _G.GetServerTime = function() return 0 / 0 end end,
                function() _G.GetServerTime = function() return 1e13 end end,
            }) do
                local ns = Solo({ before = function(s)
                    s.guildRanks[ME] = 0
                    setup(s)
                end })
                assert.is_true(ns.GuildLead.Set("caps", { "g2" }))
                local version = saved("caps")
                assert.are.equal(math.floor(version), version)
                assert.is_true(version >= _G.time() - 1 and version <= _G.time() + 1)
            end
        end)

        it("a leader's edit at the highest version is refused rather than wrapping", function()
            local ns = Solo({ before = function(s) s.guildRanks[ME] = 0 end,
                db = { enabled = true, guilds = { [KEY] = { caps = { version = 999999999999, items = { "g2" } } } } } })
            assert.is_false((ns.GuildLead.Set("caps", { "g3" })))
            assert.are.equal("999999999999/g2", string.format("%.0f/%s", saved("caps")))
        end)

        it("damaged lists, versions and guildmates are each put right", function()
            local ok = { version = 5, items = { "g2" } }
            local guilds = { [KEY] = { used = 30, ranks = { version = 0, items = { "1" } }, caps = ok,
                vetoes = { version = 7, items = { "bld1", [3] = "bld2" } },
                mates = { [MEMBER] = { version = "1.6.0", seen = 1.5 }, [RECRUIT] = { version = "1.6.0", seen = -1 },
                    ["Not A Name!"] = { version = "1.6.0", seen = 9 }, ["Ann Vale"] = { version = "1.6.0", seen = 9 },
                    [GM] = "x", [OFFICER] = { version = "1.6.0", seen = 4 } } } }
            for _, bad in ipairs({ -1, 2.5, 1e13 }) do guilds["Forever Realm:V" .. bad] = { caps = { version = bad, items = {} } } end
            guilds[""] = { used = 99 }
            guilds[string.rep("k", 121)] = { used = 99 }
            Solo({ db = { enabled = true, guilds = guilds } })
            local g = _G.FriendlyForeverDB.guilds[KEY]
            assert.are.same({ version = 0, items = {} }, g.ranks)
            assert.are.same({ version = 0, items = {} }, g.vetoes)
            assert.are.same({ [OFFICER] = { version = "1.6.0", seen = 4 } }, g.mates)
            for _, bad in ipairs({ -1, 2.5, 1e13 }) do
                assert.are.equal(0, _G.FriendlyForeverDB.guilds["Forever Realm:V" .. bad].caps.version)
            end
            assert.is_nil(_G.FriendlyForeverDB.guilds[""])
            assert.is_nil(_G.FriendlyForeverDB.guilds[string.rep("k", 121)])
        end)

        it("keeps the guildmates seen most recently, and the guilds used most recently", function()
            local mates, list = {}, {}
            for i = 1, 501 do
                local name = "Mate-" .. string.char(97 + math.floor(i / 676) % 26, 97 + math.floor(i / 26) % 26, 97 + i % 26)
                list[#list + 1] = name
                mates[name] = { version = "1.6.0", seen = 1000 + i }
            end
            local guilds = { [KEY] = { used = 50, mates = mates } }
            for i = 1, 9 do guilds["Forever Realm:G" .. i] = { used = i } end
            local ns = Solo({ db = { enabled = true, guilds = guilds } })
            local kept = _G.FriendlyForeverDB.guilds[KEY].mates
            local n = 0
            for _ in pairs(kept) do n = n + 1 end
            assert.are.equal(ns.GuildLead.MAX_MATES, n)
            assert.is_nil(kept[list[1]], "the one seen longest ago went")
            assert.is_not_nil(kept[list[501]])
            -- An eleventh guild: the one used longest ago makes room.
            wow.state.guildName = "New Guild"
            wow.fire("GUILD_ROSTER_UPDATE")
            assert.is_not_nil(ns.GuildLead.Memory())
            assert.is_nil(_G.FriendlyForeverDB.guilds["Forever Realm:G1"])
            assert.is_not_nil(_G.FriendlyForeverDB.guilds["Forever Realm:G2"])
            assert.is_not_nil(_G.FriendlyForeverDB.guilds[KEY])
            -- A new check-in past MAX_MATES makes room the same way.
            wow.state.guildName = "Friends Forever"
            receive("1;GCHECK;" .. MEMBER .. ";1.6.0;0;0;0", MEMBER)
            kept = _G.FriendlyForeverDB.guilds[KEY].mates
            n = 0
            for _ in pairs(kept) do n = n + 1 end
            assert.are.equal(ns.GuildLead.MAX_MATES, n)
            assert.is_not_nil(kept[MEMBER])
            assert.is_nil(kept[list[2]])
        end)
    end)

    describe("check-ins and sends (white)", function()
        local function sent(pattern)
            local n = 0
            for _, msg in ipairs(wow.addonSent) do
                if msg.text:find(pattern, 1, true) then n = n + 1 end
            end
            return n
        end

        it("checks in once after logging in, however many roster updates come", function()
            Solo()
            for _ = 1, 30 do
                wow.fire("GUILD_ROSTER_UPDATE")
                wow.advance(5)
            end
            assert.are.equal(1, sent(";GCHECK;"))
        end)

        it("records only guildmates in the roster", function()
            Solo()
            receive("1;GCHECK;" .. STRANGER .. ";1.6.0;0;0;0", STRANGER)
            assert.is_nil(_G.FriendlyForeverDB.guilds[KEY].mates[STRANGER])
        end)

        it("a member's copy never sends a section, however stale a check-in", function()
            Solo({ db = { enabled = true, guilds = { [KEY] = { caps = { version = 5, items = { "g2" } } } } } })
            receive("1;GCHECK;" .. RECRUIT .. ";1.6.0;0;0;0", RECRUIT)
            wow.advance(120)
            assert.are.equal(0, sent(";GCAPS;"))
        end)

        it("a leader's newer check-in prompts ours; a member's doesn't", function()
            Solo()
            wow.advance(100) -- past our own first check-in and its gap
            local start = sent(";GCHECK;")
            receive("1;GCHECK;" .. MEMBER .. ";1.6.0;0;999;0", MEMBER)
            wow.advance(30)
            assert.are.equal(start, sent(";GCHECK;"))
            receive("1;GCHECK;" .. GM .. ";1.6.0;0;999;0", GM)
            wow.advance(30)
            assert.are.equal(start + 1, sent(";GCHECK;"))
            -- Another prompt within CHECKIN_GAP waits out the gap.
            receive("1;GCHECK;" .. GM .. ";1.6.0;0;1000;0", GM)
            wow.advance(20)
            assert.are.equal(start + 1, sent(";GCHECK;"))
            wow.advance(20)
            assert.are.equal(start + 2, sent(";GCHECK;"))
        end)

        it("a check-in carries the version of each section kept", function()
            Solo({ db = { enabled = true, guilds = { [KEY] = { caps = { version = 5, items = { "g2" } },
                vetoes = { version = 1800000123, items = { "bld1" } } } } } })
            wow.advance(30)
            local text
            for _, msg in ipairs(wow.addonSent) do
                if msg.text:find(";GCHECK;", 1, true) then text = msg.text end
            end
            assert.are.equal("1;GCHECK;" .. ME .. ";" .. wow.parseToc().Version .. ";0;5;1800000123", text)
        end)

        it("setting the same list again changes nothing and sends nothing", function()
            local ns = Solo({ before = function(s) s.guildRanks[ME] = 0 end })
            wow.advance(100)
            assert.is_true(ns.GuildLead.Set("caps", { "w2", "g1" }))
            local version = saved("caps")
            wow.advance(100)
            assert.is_true(ns.GuildLead.Set("caps", { "g1", "w2" }))
            assert.are.equal(version, (saved("caps")))
            wow.advance(100)
            assert.are.equal(1, sent(";GCAPS;"))
        end)

        it("leaves a send to another leader's copy that sent it first", function()
            local gm, officer, member = Client(GM), Client(OFFICER), Client(MEMBER)
            local net = Net({ gm, officer, member })
            on(gm, function(ns) ns.GuildLead.Set("ranks", { "1" }) end)
            on(officer, function(ns) ns.GuildLead.random = function() return 0.9 end end)
            wow.advanceAll(net, 100, 0.5)
            on(gm, function(ns) ns.GuildLead.Set("caps", { "g2" }) end)
            wow.advanceAll(net, 100, 0.5)
            local before = on(officer, function() return sent(";GCAPS;") end)
            -- Mia's stale check-in reaches both leaders' copies.
            on(member, function(ns)
                _G.FriendlyForeverDB.guilds[KEY].caps = { version = 0, items = {} }
                ns.GuildLead.CheckIn()
            end)
            wow.advanceAll(net, 30, 0.5)
            assert.are.equal(before, on(officer, function() return sent(";GCAPS;") end), "the officer's copy left it")
            on(member, function() assert.are.equal("g2", select(2, saved("caps"))) end)
        end)

        it("a send waiting when the guild changes, or the leader is demoted, goes nowhere", function()
            local ns = Solo({ before = function(s) s.guildRanks[ME] = 0 end, db = { enabled = true,
                guilds = { ["Forever Realm:Night Watch"] = { caps = { version = 5, items = { "g9" } } } } } })
            wow.advance(100)
            ns.GuildLead.Set("caps", { "g2" })
            wow.advance(5)
            receive("1;GCHECK;" .. MEMBER .. ";1.6.0;0;0;0", MEMBER)
            wow.state.guildName = "Night Watch"
            wow.advance(120)
            assert.are.equal(1, sent(";GCAPS;"), "only the edit's own send")
            wow.state.guildName = "Friends Forever"
            receive("1;GCHECK;" .. RECRUIT .. ";1.6.0;0;0;0", RECRUIT)
            wow.state.guildRanks[ME] = 4
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(120)
            assert.are.equal(1, sent(";GCAPS;"))
        end)
    end)

    describe("Versioned's list check, for any section (black)", function()
        it("refuses an item past the section's longest, even one its item check would take", function()
            local ns = Solo()
            local spec = { item = function() return true end, itemBytes = 3, maxItems = 5 }
            assert.is_true(ns.Versioned.ValidList(spec, { "abc", "de" }))
            assert.is_false(ns.Versioned.ValidList(spec, { "abcd" }))
            assert.is_false(ns.Versioned.ValidList(spec, { "a", "b", "c", "d", "e", "f" }))
            assert.is_false(ns.Versioned.ValidList(spec, { "a", "a" }))
            assert.is_false(ns.Versioned.ValidList(spec, { "a", x = "b" }))
            assert.is_false(ns.Versioned.ValidList(spec, "a"))
        end)
    end)
end)
