-- Spec: #497
-- The raid leader's buff assignments (experimental): the raid leader and
-- raid assistants, checked against the raid roster on every message, say
-- who gives which buff to which groups. That overrides the automatic raid
-- split for those buffs only; an assignment that can't be met falls back to
-- the split for that buff; leaving the raid or a new leader clears them.
-- Every incoming message is untrusted, and nothing here ever casts.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local PREFIX = "FriendlyFvr"
local FORT, SPIRIT, SHADOW = 10938, 27841, 10958
local KINGS, WISDOM_1, MIGHT_1 = 20217, 19742, 19740
local PRIEST_SPELLS = { [FORT] = true, [SPIRIT] = true, [SHADOW] = true }
local PALADIN_SPELLS = { [KINGS] = true, [WISDOM_1] = true, [MIGHT_1] = true }
local KEY_OF = { [FORT] = "fortitude", [SPIRIT] = "spirit", [SHADOW] = "shadow" }

local LEADER, ANN, BOB, CID = "Lea-Dorn", "Ann-Vale", "Bob-Lake", "Cid-Rock"
-- Raid members without the addon: { full name, class, group }.
local EXTRAS = { { "Tor-Axe", "WARRIOR", 3 }, { "Mia-Fire", "MAGE", 6 }, { "Pip-Holt", "PRIEST", 7 } }

local function count(ns, key)
    return ns.Diag.Counters()[key] or 0
end

-- The groups as a set: groups(1, 4) is { [1] = true, ..., [4] = true }.
local function groups(from, to)
    local out = {}
    for g = from, to or from do out[g] = true end
    return out
end

-- An item as the wire carries it, worked out here, not by RaidLead: the
-- key, the groups' bits as two hex digits, and the name's djb2 hash.
local function hash(name)
    local h = 5381
    for i = 1, #name do h = (h * 33 + name:byte(i)) % 4294967296 end
    return string.format("%04x%04x", math.floor(h / 65536), h % 65536)
end
local function item(key, set, name)
    local bits = 0
    for g = 1, 8 do
        if set[g] then bits = bits + 2 ^ (g - 1) end
    end
    return key .. string.format("%02x", bits) .. hash(name)
end

-- One RASSIGN part, as a copy sends it.
local function part(sender, version, items, n, of)
    return table.concat({ "1", "RASSIGN", sender, tostring(version), tostring(n or 1), tostring(of or 1),
        items and #items > 0 and table.concat(items, ",") or "-" }, ";")
end

local function receive(text, sender)
    wow.fire("CHAT_MSG_ADDON", PREFIX, text, "RAID", sender, "", 0, 0, "", 0)
end

local function on(c, fn)
    wow.use(c)
    return fn(c.ns)
end

-- The groups (sorted text) of a share's value: "all", "1,2,3,4" or "none".
local function groupText(value)
    if value == true then return "all" end
    if type(value) ~= "table" then return "none" end
    local out = {}
    for g = 1, 8 do
        if value[g] then out[#out + 1] = tostring(g) end
    end
    return table.concat(out, ",")
end

local function shareOf(c, key)
    return on(c, function(ns)
        local mine = ns.RaidSplit.Current()
        return groupText(mine and mine[key])
    end)
end

-- Every offer buff mode would make now.
local function offers(c)
    return on(c, function(ns)
        local list = {}
        ns.GroupBuffs.Next(list)
        return list
    end)
end

-- The names offered key, sorted.
local function offeredTo(c, key)
    local names = {}
    for _, offer in ipairs(offers(c)) do
        if offer.buff.key == key then names[#names + 1] = offer.name end
    end
    table.sort(names)
    return names
end

-- The live client's raid unit for a full name.
local function unitOf(full)
    for token, u in pairs(wow.state.units) do
        if u.id == full and token:find("^raid") then return u end
    end
end

-- How many messages of this type the live client has sent.
local function sentOf(msgType)
    local n = 0
    for _, m in ipairs(wow.addonSent) do
        if m.text:find(";" .. msgType .. ";", 1, true) then n = n + 1 end
    end
    return n
end

local INTELLECT = 10157

describe("The raid leader's buff assignments (#497)", function()
    local clients, net, byName

    after_each(function() wow.reset() end)

    it("asks for a restart when only RaidLead.lua is new, and nothing errors in a raid (black)", function()
        wow.reset()
        local loaded = {}
        local _, files = wow.parseToc()
        for _, file in ipairs(files) do
            if file ~= "RaidLead.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
        end
        wow.fire("ADDON_LOADED", wow.ADDON_NAME)
        wow.fire("PLAYER_ENTERING_WORLD", true, false)
        wow.advance(60)
        wow.setGroup("raid", { LEADER, BOB })
        wow.fire("GROUP_ROSTER_UPDATE")
        _G.SlashCmdList.FRIENDLYFOREVER("status")
        _G.SlashCmdList.FRIENDLYFOREVER("raid")
        wow.advance(10)
        assert.are.same({}, wow.errors)
        assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game (not /reload)", 1, true))
    end)

    -- Copies of the addon: { name, surname, class, known, group, db, buffModeOff }.
    local function copies(list)
        clients, byName = {}, {}
        for _, p in ipairs(list) do
            local c = wow.newClient({ name = p.name, surname = p.surname, db = p.db,
                before = function(state)
                    state.class = p.class
                    state.knownSpells = {}
                    for id in pairs(p.known or {}) do state.knownSpells[id] = true end
                end })
            c.class, c.group = p.class, p.group
            c.ns.RaidLead.random = function() return 0 end
            if not p.buffModeOff then c.ns.BuffMode.Set(true) end
            clients[#clients + 1] = c
            byName[c.full] = c
        end
        net = wow.network(clients)
    end

    -- The usual raid: a warrior leading, three priests, and the extras.
    local function usual(opts)
        opts = opts or {}
        copies({
            { name = "Lea", surname = "Dorn", class = "WARRIOR", group = 1 },
            { name = "Ann", surname = "Vale", class = "PRIEST", known = opts.annKnows or PRIEST_SPELLS, group = 1 },
            { name = "Bob", surname = "Lake", class = "PRIEST", known = PRIEST_SPELLS, group = 5 },
            { name = "Cid", surname = "Rock", class = "PRIEST", known = PRIEST_SPELLS, group = 2 },
        })
    end

    -- Put members (clients; default all) in one raid with the extras, led by
    -- leader, with these assistants and these members offline (as every
    -- copy's game shows them), and let it settle.
    local function form(o)
        o = o or {}
        local members = o.members or clients
        local leader = o.leader or LEADER
        for _, c in ipairs(clients) do
            wow.use(c)
            local inIt = false
            for _, m in ipairs(members) do
                if m == c then inIt = true end
            end
            if inIt then
                local names, classes, gs = {}, {}, {}
                for _, m in ipairs(members) do
                    if m ~= c then
                        names[#names + 1] = m.full
                        classes[#names], gs[#names] = m.class, m.group
                    end
                end
                for _, e in ipairs(EXTRAS) do
                    names[#names + 1] = e[1]
                    classes[#names], gs[#names] = e[2], e[3]
                end
                wow.setGroup("raid", names)
                for i, class in ipairs(classes) do
                    wow.state.units["raid" .. i].class = class
                    wow.state.units["raid" .. i].subgroup = gs[i]
                end
                wow.addUnit("raid" .. (#names + 1), { name = c.name, surname = c.surname, id = c.full,
                    class = c.class, subgroup = c.group })
                wow.state.leader = leader
                wow.state.isLeader = c.full == leader
                for token, u in pairs(wow.state.units) do
                    if token:find("^raid") then
                        u.assistant = (o.assistants or {})[u.id] == true
                        u.offline = (o.offline or {})[u.id] == true
                    end
                end
            else
                wow.setGroup(nil)
            end
            wow.fire("GROUP_ROSTER_UPDATE")
        end
        wow.advanceAll(net, 30, 0.5)
    end

    -- Fortitude: Ann for groups 1-4, Bob for 5-8.
    local FORT_SPLIT = { item("fortitude", groups(1, 4), ANN), item("fortitude", groups(5, 8), BOB) }

    local function assign(c, items)
        local ok, why = on(c, function(ns) return ns.RaidLead.Set(items) end)
        assert.is_true(ok, why)
        wow.advanceAll(net, 15, 0.5)
    end

    describe("assigning (white)", function()
        it("a leader's assignment makes only the assigned players offer that buff, each to their groups; "
            .. "the others don't offer it there", function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            assert.equal("1,2,3,4", shareOf(byName[ANN], "fortitude"))
            assert.equal("5,6,7,8", shareOf(byName[BOB], "fortitude"))
            assert.equal("none", shareOf(byName[CID], "fortitude"))
            -- Groups 1-4 hold Lea, Ann (1), Cid (2) and Tor (3); 5-8 Bob (5), Mia (6), Pip (7).
            -- Neither buffs themselves (their buff-self setting is off).
            assert.same({ CID, LEADER, "Tor-Axe" }, offeredTo(byName[ANN], "fortitude"))
            assert.same({ "Mia-Fire", "Pip-Holt" }, offeredTo(byName[BOB], "fortitude"))
            assert.same({}, offeredTo(byName[CID], "fortitude"))
        end)

        it("each priest's presses cast Fortitude only on their assigned groups, and the raid gets it once each",
            function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            local by = {} -- [target] = who gave Fortitude
            for _, c in ipairs({ byName[ANN], byName[BOB], byName[CID] }) do
                wow.use(c)
                for _ = 1, 12 do
                    local before = #wow.casts
                    wow.pressKey("MOUSEWHEELUP")
                    local cast = wow.casts[before + 1]
                    if not cast then break end
                    if KEY_OF[cast.id] == "fortitude" then
                        assert.is_nil(by[cast.target], cast.target .. " got Fortitude twice")
                        by[cast.target] = c.full
                    end
                    local u = unitOf(cast.target)
                    if u then
                        u.auras, u.auraSources = u.auras or {}, u.auraSources or {}
                        u.auras[#u.auras + 1] = cast.id
                        u.auraSources[#u.auras] = "player"
                    end
                    wow.advance(2)
                end
            end
            -- Ann and Bob don't buff themselves (their buff-self setting is off).
            assert.same({ [LEADER] = ANN, [CID] = ANN, ["Tor-Axe"] = ANN,
                ["Mia-Fire"] = BOB, ["Pip-Holt"] = BOB }, by)
        end)

        it("unassigned buffs keep the automatic split, shared out among the copies", function()
            usual()
            form()
            local before = {}
            for _, c in ipairs({ byName[ANN], byName[BOB], byName[CID] }) do
                before[c.full] = shareOf(c, "spirit") .. "/" .. shareOf(c, "shadow")
            end
            -- Without assignments: Ann Fortitude, Bob Spirit, Cid Shadow Protection.
            assert.same({ [ANN] = "none/none", [BOB] = "all/none", [CID] = "none/all" }, before)
            assign(byName[LEADER], FORT_SPLIT)
            -- Fortitude is assigned for every group, so the others draft
            -- Spirit and Shadow Protection among the three of them: Ann
            -- Spirit, Bob Shadow, and Cid, with nothing left, half of Spirit.
            assert.equal("1,2,3,4", shareOf(byName[ANN], "spirit"))
            assert.equal("all", shareOf(byName[BOB], "shadow"))
            assert.equal("5,6,7,8", shareOf(byName[CID], "spirit"))
            -- Every copy works out the same whole split.
            local seen
            for _, c in ipairs({ byName[ANN], byName[BOB], byName[CID] }) do
                local text = on(c, function(ns)
                    local _, all = ns.RaidSplit.Current()
                    local out = {}
                    for name, share in pairs(all) do
                        for key, value in pairs(share) do out[#out + 1] = name .. ":" .. key .. "=" .. groupText(value) end
                    end
                    table.sort(out)
                    return table.concat(out, ";")
                end)
                seen = seen or text
                assert.equal(seen, text)
            end
        end)

        it("a buff assigned for some groups only: the split's holder keeps the groups nobody was given", function()
            usual()
            form()
            -- Without assignments Ann holds Fortitude for the whole raid.
            assign(byName[LEADER], { item("fortitude", groups(5, 8), BOB) })
            assert.equal("1,2,3,4", shareOf(byName[ANN], "fortitude"))
            assert.equal("5,6,7,8", shareOf(byName[BOB], "fortitude"))
            assert.equal("none", shareOf(byName[CID], "fortitude"))
        end)

        it("an assistant can assign, and every copy, the leader's included, takes it", function()
            usual()
            form({ assistants = { [CID] = true } })
            assign(byName[CID], FORT_SPLIT)
            for _, c in ipairs(clients) do
                assert.equal(2, #on(c, function(ns) return ns.RaidLead.Assignments() end), c.full)
            end
        end)

        it("a copy that joins later, or reloads, catches up from a leader's copy", function()
            usual()
            form({ members = { byName[LEADER], byName[ANN], byName[BOB] } })
            assign(byName[LEADER], FORT_SPLIT)
            assert.equal(0, on(byName[CID], function(ns) return ns.RaidLead.Version() end))
            form()
            -- The leader's copy waits out SEND_GAP since its last send (the edit).
            wow.advanceAll(net, 60, 0.5)
            assert.equal(on(byName[LEADER], function(ns) return ns.RaidLead.Version() end),
                on(byName[CID], function(ns) return ns.RaidLead.Version() end))
            assert.equal("none", shareOf(byName[CID], "fortitude"))
        end)

        it("the window shows the assignments by name and saves what the leader types", function()
            usual()
            form()
            local ns = byName[LEADER].ns
            wow.use(byName[LEADER])
            ns.RaidLead.Open()
            local frame = ns.RaidLead.Frame()
            assert.is_true(frame:IsShown())
            local rows = {}
            for _, row in ipairs(frame.rows) do rows[row.key] = row end
            rows.fortitude.box:SetText("ann 1-4, Bob Lake 5 6 7 8")
            rows.kings.box:SetText("")
            frame.save:Click()
            wow.advanceAll(net, 15, 0.5)
            assert.equal("1,2,3,4", shareOf(byName[ANN], "fortitude"))
            assert.equal("5,6,7,8", shareOf(byName[BOB], "fortitude"))
            wow.use(byName[LEADER])
            ns.RaidLead.Open()
            assert.equal("Ann Vale 1-4, Bob Lake 5-8", rows.fortitude.box:GetText())
            -- Clear all: the split again everywhere.
            frame.clear:Click()
            wow.advanceAll(net, 15, 0.5)
            assert.equal("all", shareOf(byName[ANN], "fortitude"))
            assert.equal(0, #on(byName[CID], function(n) return n.RaidLead.Assignments() end))
        end)
    end)

    describe("assigning, the finer points (white)", function()
        it("two players given the same groups of a buff: the groups nobody was given still go to the split",
            function()
            usual()
            form()
            assign(byName[LEADER], { item("fortitude", groups(1, 4), ANN), item("fortitude", groups(1, 4), BOB) })
            -- Groups 5-8 are nobody's: Ann, who drafts Fortitude, keeps them.
            assert.equal("all", shareOf(byName[ANN], "fortitude"))
            assert.equal("1,2,3,4", shareOf(byName[BOB], "fortitude"))
            -- Ann offers it to groups 5-8 too (Mia in 6, Pip in 7).
            local names = offeredTo(byName[ANN], "fortitude")
            assert.truthy(table.concat(names, ","):find("Mia-Fire,Pip-Holt", 1, true))
        end)

        it("a split that shares out groups keeps its groups less the assigned ones", function()
            copies({
                { name = "Lea", surname = "Dorn", class = "WARRIOR", group = 1 },
                { name = "Ann", surname = "Vale", class = "MAGE", known = { [INTELLECT] = true }, group = 1 },
                { name = "Bob", surname = "Lake", class = "MAGE", known = { [INTELLECT] = true }, group = 5 },
            })
            form()
            -- Two mages: Ann groups 1-4, Bob 5-8.
            assert.equal("1,2,3,4", shareOf(byName[ANN], "intellect"))
            assign(byName[LEADER], { item("intellect", groups(8), BOB) })
            assert.equal("1,2,3,4", shareOf(byName[ANN], "intellect"))
            assert.equal("5,6,7,8", shareOf(byName[BOB], "intellect"))
        end)

        it("with the split switched off, the assignments still narrow your copy's offers (#497 question 1)", function()
            copies({
                { name = "Lea", surname = "Dorn", class = "WARRIOR", group = 1 },
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS, group = 1,
                    db = { buffBack = { raidSplit = false } } },
                { name = "Bob", surname = "Lake", class = "PRIEST", known = PRIEST_SPELLS, group = 5 },
            })
            form()
            assign(byName[LEADER], { item("fortitude", groups(1, 8), BOB) })
            -- No split for Ann: every buff she gives, less Fortitude.
            assert.equal("none", shareOf(byName[ANN], "fortitude"))
            assert.equal("all", shareOf(byName[ANN], "spirit"))
            assert.same({}, offeredTo(byName[ANN], "fortitude"))
            assert.is_true(#offeredTo(byName[ANN], "spirit") > 0)
            wow.use(byName[ANN])
            local ns = byName[ANN].ns
            assert.truthy(ns.RaidSplit.ShareText(true):find("Bob Lake has Power Word: Fortitude", 1, true))
            -- A buff no assignment covers is still offered as without the split.
            assert.is_true(ns.RaidSplit.Covers(ns.BuffData.ByKey("innerfire")))
        end)

        it("a member's offer is refused with the reason the leader's assignment gives", function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            local fort = byName[CID].ns.BuffData.ByKey("fortitude")
            local ok, why = on(byName[CID], function(ns)
                return ns.RaidSplit.CoversMember(fort, { unit = wow.tokenFor(unitOf("Tor-Axe")) })
            end)
            assert.is_false(ok)
            assert.equal("the raid leader gave it to someone else", why)
            ok, why = on(byName[ANN], function(ns)
                return ns.RaidSplit.CoversMember(fort, { unit = wow.tokenFor(unitOf("Mia-Fire")) })
            end)
            assert.is_false(ok)
            assert.equal("the raid leader gave their group to someone else", why)
        end)

        it("the leader's edits: the same list again changes nothing, and a new version is always above the kept one",
            function()
            usual()
            form()
            wow.use(byName[LEADER])
            local ns = byName[LEADER].ns
            assert.is_true(ns.RaidLead.Set(FORT_SPLIT))
            local version = ns.RaidLead.Version()
            wow.advance(30)
            local sent = sentOf("RASSIGN")
            assert.is_true(ns.RaidLead.Set({ FORT_SPLIT[2], FORT_SPLIT[1] }))
            wow.advance(30)
            assert.equal(version, ns.RaidLead.Version())
            assert.equal(sent, sentOf("RASSIGN"))
            -- Kept from an assistant whose clock ran far ahead: ours goes above it.
            receive(part(CID, 5000000000, { FORT_SPLIT[1] }), CID)
            assert.equal(0, ns.RaidLead.Version() - version, "Cid isn't an assistant yet")
            unitOf(CID).assistant = true
            receive(part(CID, 5000000000, { FORT_SPLIT[1] }), CID)
            assert.equal(5000000000, ns.RaidLead.Version())
            assert.is_true(ns.RaidLead.Set(FORT_SPLIT))
            assert.equal(5000000001, ns.RaidLead.Version())
            -- Lists the addon can't share are refused.
            assert.is_false((ns.RaidLead.Set({ "junk" })))
            local many = {}
            for i = 1, 31 do many[i] = item("fortitude", groups(1), "Aaa-B" .. string.rep("b", i)) end
            assert.is_false((ns.RaidLead.Set(many)))
            assert.equal(5000000001, ns.RaidLead.Version())
        end)
    end)

    describe("a Blessing assigned (white)", function()
        it("the leader's assignment of Kings comes before a paladin's own choice of it", function()
            copies({
                { name = "Lea", surname = "Dorn", class = "WARRIOR", group = 1 },
                { name = "Ann", surname = "Vale", class = "PALADIN", known = PALADIN_SPELLS, group = 1 },
                { name = "Bob", surname = "Lake", class = "PALADIN", known = PALADIN_SPELLS, group = 5 },
            })
            form()
            assert.is_true(on(byName[BOB], function(ns) return ns.BuffRules.SetRaidBlessings({ "kings" }) end))
            wow.advanceAll(net, 15, 0.5)
            local kings = byName[BOB].ns.BuffData.ByKey("kings")
            assert.is_true(on(byName[BOB], function(ns) return ns.BuffRules.CoversInRaid(kings) end))
            assign(byName[LEADER], { item("kings", groups(1, 8), ANN) })
            assert.is_false(on(byName[BOB], function(ns) return ns.BuffRules.CoversInRaid(kings) end))
            assert.is_true(on(byName[ANN], function(ns) return ns.BuffRules.CoversInRaid(kings) end))
            assert.same({}, offeredTo(byName[BOB], "kings"))
            -- Bob chose only Kings, which is now Ann's: he gives none (the
            -- leader only narrows his choice), and Ann drafts the rest.
            for _, key in ipairs({ "kings", "wisdom", "might" }) do
                assert.same({}, offeredTo(byName[BOB], key), key)
                assert.equal("all", shareOf(byName[ANN], key), key)
                assert.is_true(#offeredTo(byName[ANN], key) > 0, key)
            end
        end)
    end)

    describe("a Blessing a paladin left out (black)", function()
        it("assigned to a paladin who chose other Blessings by hand, it can't be met: he doesn't offer it, "
            .. "and it stays with the split", function()
            copies({
                { name = "Lea", surname = "Dorn", class = "WARRIOR", group = 1 },
                { name = "Ann", surname = "Vale", class = "PALADIN", known = PALADIN_SPELLS, group = 1 },
                { name = "Bob", surname = "Lake", class = "PALADIN", known = PALADIN_SPELLS, group = 5 },
            })
            form()
            assert.is_true(on(byName[BOB], function(ns) return ns.BuffRules.SetRaidBlessings({ "kings" }) end))
            wow.advanceAll(net, 15, 0.5)
            local before = offeredTo(byName[ANN], "might")
            assert.is_true(#before > 0)
            assign(byName[LEADER], { item("might", groups(1, 8), BOB) })
            assert.same({}, offeredTo(byName[BOB], "might"))
            assert.same(before, offeredTo(byName[ANN], "might"))
            assert.is_false(on(byName[ANN], function(ns) return ns.RaidSplit.Assigned(ns.BuffData.ByKey("might")) end))
            assert.is_false(on(byName[BOB], function(ns) return ns.RaidSplit.Assigned(ns.BuffData.ByKey("might")) end))
        end)
    end)

    describe("clearing (white)", function()
        it("leaving the raid forgets the assignments", function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            form({ members = { byName[LEADER], byName[ANN], byName[BOB] } })
            assert.equal(0, #on(byName[CID], function(ns) return ns.RaidLead.Items() end))
            assert.equal(0, on(byName[CID], function(ns) return ns.RaidLead.Version() end))
            assert.equal(2, #on(byName[ANN], function(ns) return ns.RaidLead.Items() end))
        end)

        it("a new raid leader clears them on every copy, and the old list sent again is refused", function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            local version = on(byName[ANN], function(ns) return ns.RaidLead.Version() end)
            form({ leader = BOB, assistants = { [LEADER] = true } })
            for _, c in ipairs(clients) do
                assert.equal(0, #on(c, function(ns) return ns.RaidLead.Items() end), c.full)
            end
            assert.equal("all", shareOf(byName[ANN], "fortitude"))
            -- The old leader, now an assistant, sends the old list again.
            on(byName[ANN], function()
                receive(part(LEADER, version, FORT_SPLIT), LEADER)
            end)
            assert.equal(0, #on(byName[ANN], function(ns) return ns.RaidLead.Items() end))
        end)
    end)

    describe("battlegrounds, leaves the game can't read, and groups with gaps (black)", function()
        it("a battleground keeps your raid's assignments without using them, and they apply again back in the raid",
            function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            wow.use(byName[CID])
            local ns = byName[CID].ns
            local version = ns.RaidLead.Version()
            wow.state.inInstance, wow.state.instanceType = true, "pvp"
            wow.setGroup("raid", { "Wes-Gulch", "Tor-Axe" })
            wow.state.leader, wow.state.isLeader = "Wes-Gulch", false
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(30)
            assert.equal(0, #ns.RaidLead.Assignments())
            assert.equal(2, #ns.RaidLead.Items())
            assert.is_false(ns.RaidLead.MayAssign("Wes-Gulch"))
            -- An arena too, and while the game won't say where you are.
            wow.state.instanceType = "arena"
            assert.equal(0, #ns.RaidLead.Assignments())
            local isIn = _G.IsInInstance
            _G.IsInInstance = function() error("unreadable") end
            wow.state.inInstance = false
            assert.equal(0, #ns.RaidLead.Assignments())
            _G.IsInInstance = isIn
            wow.state.inInstance, wow.state.instanceType = false, nil
            form()
            assert.equal(version, ns.RaidLead.Version())
            assert.equal(2, #on(byName[CID], function(n) return n.RaidLead.Assignments() end))
            assert.equal("none", shareOf(byName[CID], "fortitude"))
        end)

        it("while the game won't say whether this is a battleground, nobody may assign: parts and edits are refused",
            function()
            usual()
            form()
            local isIn = _G.IsInInstance
            local ok, err = pcall(function()
                wow.use(byName[ANN])
                _G.IsInInstance = function() error("unreadable") end
                receive(part(LEADER, 5, FORT_SPLIT), LEADER)
                assert.equal(0, #byName[ANN].ns.RaidLead.Items())
                wow.use(byName[LEADER])
                _G.IsInInstance = function() error("unreadable") end
                assert.is_false((byName[LEADER].ns.RaidLead.Set(FORT_SPLIT)))
            end)
            _G.IsInInstance = isIn
            assert(ok, err)
        end)

        it("an assignee whose own raid slot reads as offline still gives its groups the buff", function()
            usual()
            form()
            wow.use(byName[CID])
            unitOf(CID).offline = true -- his own raid slot, in his own game only
            assign(byName[LEADER], { item("fortitude", groups(1, 4), CID), item("fortitude", groups(5, 8), BOB) })
            assert.equal("1,2,3,4", shareOf(byName[CID], "fortitude"))
            assert.same({ ANN, LEADER, "Tor-Axe" }, offeredTo(byName[CID], "fortitude"))
            assert.same({}, offeredTo(byName[ANN], "fortitude"))
            -- And when that slot's name can't be read at all.
            wow.use(byName[CID])
            local own = unitOf(CID)
            own.offline, own.secrets = false, { name = true }
            wow.advance(1)
            assert.equal("1,2,3,4", shareOf(byName[CID], "fortitude"))
        end)

        it("a leave whose one roster update can't be read checks in to the next raid, with buff mode off and "
            .. "nothing else looking", function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            wow.use(byName[CID])
            byName[CID].ns.BuffMode.Set(false)
            local checks = sentOf("RCHECK")
            wow.setGroup(nil)
            wow.state.inRaidUnreadable = true
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(1)
            wow.state.inRaidUnreadable = false
            wow.advance(300)
            form()
            wow.advanceAll(net, 60, 0.5)
            wow.use(byName[CID])
            assert.equal(checks + 1, sentOf("RCHECK"))
        end)

        it("roster updates that can't be read look again once every few seconds, however many come, "
            .. "and every time they happen", function()
            usual()
            form()
            wow.use(byName[CID])
            byName[CID].ns.BuffMode.Set(false)
            wow.state.inRaidUnreadable = true
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0.1)
            local timers = #wow.timers
            for _ = 1, 10 do wow.fire("GROUP_ROSTER_UPDATE") end
            assert.equal(timers, #wow.timers, "one look again, not ten")
            wow.state.inRaidUnreadable = false
            -- Twice in one session: an unreadable leave, then the next raid.
            for round = 1, 2 do
                wow.use(byName[CID])
                local checks = sentOf("RCHECK")
                wow.setGroup(nil)
                wow.state.inRaidUnreadable = true
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(1)
                wow.state.inRaidUnreadable = false
                wow.advance(300)
                form()
                wow.advanceAll(net, 60, 0.5)
                wow.use(byName[CID])
                assert.equal(checks + 1, sentOf("RCHECK"), "round " .. round)
            end
        end)

        it("a leave whose one roster update can't be read still checks in to the next raid", function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            wow.use(byName[CID])
            local ns = byName[CID].ns
            local checks = sentOf("RCHECK")
            -- The leave's update can't be read; a later look reads it.
            wow.setGroup(nil)
            wow.state.inRaidUnreadable = true
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.state.inRaidUnreadable = false
            assert.equal(0, #ns.RaidLead.Assignments())
            assert.equal(0, ns.RaidLead.Version())
            form()
            wow.advanceAll(net, 60, 0.5)
            wow.use(byName[CID])
            assert.equal(checks + 1, sentOf("RCHECK"))
            assert.equal(2, #ns.RaidLead.Items())
        end)

        it("the button's share text names groups with a gap as runs", function()
            usual()
            form()
            assign(byName[LEADER], { item("fortitude", groups(2), BOB) })
            assert.equal("Your share: Power Word: Fortitude (groups 1, 3-8)",
                on(byName[ANN], function(ns) return ns.RaidSplit.ShareText(false) end))
            assert.equal("Your share: Power Word: Fortitude (group 2), Divine Spirit",
                on(byName[BOB], function(ns) return ns.RaidSplit.ShareText(false) end))
        end)
    end)

    describe("assignments that can't be met fall back to the split (black)", function()
        it("an offline player's groups go back to the split for that buff; the rest of it stays assigned",
            function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            form({ offline = { [ANN] = true } })
            -- Ann can't be counted: Bob gives Fortitude to the whole raid.
            assert.equal("all", shareOf(byName[BOB], "fortitude"))
            assert.equal("none", shareOf(byName[CID], "fortitude"))
        end)

        it("someone without the addon, someone without the spell, or someone not in the raid: the split as before",
            function()
            usual({ annKnows = { [SPIRIT] = true, [SHADOW] = true } })
            form()
            local function all()
                local out = {}
                for _, c in ipairs({ byName[ANN], byName[BOB], byName[CID] }) do
                    for _, key in ipairs({ "fortitude", "spirit", "shadow" }) do
                        out[#out + 1] = c.full .. ":" .. key .. "=" .. shareOf(c, key)
                    end
                end
                return table.concat(out, ";")
            end
            local before = all()
            for _, who in ipairs({ "Pip-Holt", ANN, "Zed-Gone" }) do
                assign(byName[LEADER], { item("fortitude", groups(1, 8), who) })
                assert.equal(before, all(), who)
            end
        end)

        it("the window refuses a player who can't give the buff, a name not in the raid, and bad groups", function()
            usual()
            form()
            wow.use(byName[LEADER])
            local ns = byName[LEADER].ns
            local roster = ns.RaidLead.Roster()
            local items, why = ns.RaidLead.ParseLine("fortitude", "Mia Fire", roster)
            assert.is_nil(items)
            assert.equal("Mia Fire can't give Power Word: Fortitude", why)
            assert.is_nil(ns.RaidLead.ParseLine("fortitude", "Zed 1-4", roster))
            assert.is_nil(ns.RaidLead.ParseLine("fortitude", "Ann 0-9", roster))
            assert.is_nil(ns.RaidLead.ParseLine("fortitude", "Ann 4-2", roster))
            assert.is_nil(ns.RaidLead.ParseLine("fortitude", "1-4", roster))
            assert.same({}, ns.RaidLead.ParseLine("fortitude", "  ", roster))
        end)

        it("members see the window read-only, and can't set anything", function()
            usual()
            form()
            wow.use(byName[CID])
            local ns = byName[CID].ns
            ns.RaidLead.Open()
            local frame = ns.RaidLead.Frame()
            assert.is_false(frame.save:IsEnabled())
            assert.is_false(frame.rows[1].box:IsEnabled())
            local ok, why = ns.RaidLead.Set(FORT_SPLIT)
            assert.is_false(ok)
            assert.equal("only the raid leader or an assistant can", why)
        end)

        it("an unreadable rank lets nobody assign: the leader's own copy refuses, and others refuse the leader",
            function()
            usual()
            form()
            -- The leader's rank unreadable in Ann's game: Ann takes nothing.
            wow.use(byName[ANN])
            unitOf(LEADER).secrets = { rank = true }
            assign(byName[LEADER], FORT_SPLIT)
            assert.equal(0, #on(byName[ANN], function(ns) return ns.RaidLead.Items() end))
            assert.equal(2, #on(byName[BOB], function(ns) return ns.RaidLead.Items() end))
            -- Unreadable in the leader's own game: it can't set them.
            wow.use(byName[LEADER])
            unitOf(LEADER).secrets = { rank = true }
            assert.is_false((byName[LEADER].ns.RaidLead.Set({})))
        end)

        it("out of a raid, or when the raid answer can't be read, nothing is kept or taken", function()
            local ns = wow.boot({})
            assert.is_false((ns.RaidLead.Set(FORT_SPLIT)))
            receive(part(LEADER, 5, FORT_SPLIT), LEADER)
            assert.equal(0, #ns.RaidLead.Items())
            wow.setGroup("raid", { LEADER, ANN })
            wow.state.leader = LEADER
            wow.state.inRaidUnreadable = true
            receive(part(LEADER, 5, FORT_SPLIT), LEADER)
            assert.equal(0, #ns.RaidLead.Assignments())
        end)
    end)

    describe("assignments that can't be met, and readings that can't be trusted (black)", function()
        it("a player who hasn't been heard from lately can't be counted: their groups go back to the split",
            function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            net.lose = function(_, sender) return sender == byName[BOB] end
            wow.advanceAll(net, 200, 1)
            -- Bob silent for longer than the split waits: Ann gives Fortitude to everyone.
            assert.equal("all", shareOf(byName[ANN], "fortitude"))
        end)

        it("two raid members whose names share a hash: an assignment to either can't be met", function()
            copies({
                { name = "Lea", surname = "Dorn", class = "WARRIOR", group = 1 },
                { name = "Ann", surname = "Vale", class = "PRIEST", known = PRIEST_SPELLS, group = 1 },
                { name = "Lia", surname = "Ezmo", class = "PRIEST", known = PRIEST_SPELLS, group = 5 },
            })
            assert.equal(hash("Lia-Ezmo"), hash("Lia-FYmo"))
            EXTRAS[#EXTRAS + 1] = { "Lia-FYmo", "PRIEST", 6 }
            local ok, err = pcall(function()
                form()
                local before = shareOf(byName[ANN], "fortitude")
                assert.equal("all", before)
                assign(byName[LEADER], { item("fortitude", groups(1, 8), "Lia-Ezmo") })
                assert.equal(before, shareOf(byName[ANN], "fortitude"))
            end)
            EXTRAS[#EXTRAS] = nil
            assert(ok, err)
        end)

        it("the window's names and groups: a first name two members share, and groups outside 1 to 8", function()
            local ns = wow.boot({})
            local roster = { ["Ann-Vale"] = { class = "PRIEST" }, ["Ann-Moss"] = { class = "PRIEST" } }
            local items, why = ns.RaidLead.ParseLine("fortitude", "Ann 1-4", roster)
            assert.is_nil(items)
            assert.equal("more than one member is called Ann", why)
            assert.equal(1, #ns.RaidLead.ParseLine("fortitude", "Ann Moss 1-4", roster))
            assert.is_nil(ns.RaidLead.ParseLine("fortitude", "Ann Moss 0-3", roster))
            assert.is_nil(ns.RaidLead.ParseLine("fortitude", "Ann Moss 5-9", roster))
            assert.is_nil(ns.RaidLead.ParseLine("fortitude", "Ann Moss 9", roster))
        end)

        it("while the raid answer can't be read, nothing kept is used, nothing new is taken, and the leader can't edit",
            function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            wow.use(byName[ANN])
            local ns = byName[ANN].ns
            local version = ns.RaidLead.Version()
            wow.state.inRaidUnreadable = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.equal(0, #ns.RaidLead.Assignments())
            assert.equal(2, #ns.RaidLead.Items(), "kept, not forgotten")
            receive(part(LEADER, version + 1, { FORT_SPLIT[1] }), LEADER)
            assert.equal(version, ns.RaidLead.Version())
            wow.state.inRaidUnreadable = false
            assert.equal(2, #ns.RaidLead.Assignments())
            wow.use(byName[LEADER])
            wow.state.inRaidUnreadable = true
            assert.is_false((byName[LEADER].ns.RaidLead.Set({})))
        end)

        it("a leader who can't be read after setting them doesn't clear them; two leaders let nobody assign",
            function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            wow.use(byName[ANN])
            local ns = byName[ANN].ns
            unitOf(LEADER).secrets = { rank = true }
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.equal(2, #ns.RaidLead.Items())
            unitOf(LEADER).secrets = nil
            -- Bob reads as a second leader: nobody may assign, the leader included.
            unitOf(BOB).raidRank = 2
            receive(part(LEADER, ns.RaidLead.Version() + 1, { FORT_SPLIT[1] }), LEADER)
            assert.equal(2, #ns.RaidLead.Items())
            assert.is_false(ns.RaidLead.MayAssign(LEADER))
        end)
    end)

    describe("untrusted messages (red)", function()
        -- Ann's copy alone, in the usual raid as her game shows it.
        local function solo(opts)
            opts = opts or {}
            local ns = wow.boot({ name = "Ann", surname = "Vale", before = function(state)
                state.class = "PRIEST"
                state.knownSpells = {}
                for id in pairs(PRIEST_SPELLS) do state.knownSpells[id] = true end
            end })
            ns.RaidLead.random = function() return 0 end
            wow.setGroup("raid", { LEADER, BOB, CID, "Tor-Axe" })
            for token, u in pairs(wow.state.units) do
                if token:find("^raid") then u.assistant = (opts.assistants or {})[u.id] == true end
            end
            wow.state.leader = LEADER
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(30)
            return ns
        end

        it("a member who is neither leader nor assistant changes nothing", function()
            local ns = solo()
            receive(part(CID, 5, FORT_SPLIT), CID)
            assert.equal(0, #ns.RaidLead.Items())
            assert.equal(1, count(ns, "syncNoAuthority"))
        end)

        it("a message naming the leader but sent by someone else is dropped as forged", function()
            local ns = solo()
            receive(part(LEADER, 5, FORT_SPLIT), CID)
            assert.equal(0, #ns.RaidLead.Items())
            assert.equal(1, count(ns, "commSpoofed"))
        end)

        it("someone not in the raid, even one the game calls a leader elsewhere, changes nothing", function()
            local ns = solo()
            receive(part("Sly-Fox", 5, FORT_SPLIT), "Sly-Fox")
            assert.equal(0, #ns.RaidLead.Items())
        end)

        it("an oversized or malformed message changes nothing", function()
            local ns = solo()
            local long = {}
            for i = 1, 12 do long[i] = item("fortitude", groups(1), "Aaa-Bbb" .. string.rep("c", i)) end
            receive(part(LEADER, 5, long), LEADER)
            assert.equal(1, count(ns, "commOversized"))
            for _, bad in ipairs({
                part(LEADER, 5, { "fortitude00" .. hash(ANN) }),     -- no group
                part(LEADER, 5, { "battleshout0f" .. hash(ANN) }),   -- not a shared buff
                part(LEADER, 5, { "fortitude0f" .. "XYZ" }),          -- not a hash
                part(LEADER, 0, FORT_SPLIT),                          -- version 0
                part(LEADER, 5, FORT_SPLIT, 3, 2),                    -- part 3 of 2
                part(LEADER, 5, { FORT_SPLIT[1], FORT_SPLIT[1] }),    -- the same player twice
                part(LEADER, 5, FORT_SPLIT) .. ";x",                  -- a field too many
            }) do
                receive(bad, LEADER)
                assert.equal(0, #ns.RaidLead.Items(), bad)
            end
        end)

        it("a replayed or older version changes nothing; a newer one is taken", function()
            local ns = solo()
            receive(part(LEADER, 10, FORT_SPLIT), LEADER)
            assert.equal(10, ns.RaidLead.Version())
            receive(part(LEADER, 9, { FORT_SPLIT[1] }), LEADER)
            receive(part(LEADER, 10, FORT_SPLIT), LEADER)
            assert.equal(10, ns.RaidLead.Version())
            assert.equal(2, #ns.RaidLead.Items())
            receive(part(LEADER, 11, { FORT_SPLIT[2] }), LEADER)
            assert.same({ FORT_SPLIT[2] }, ns.RaidLead.Items())
        end)

        it("a sender demoted while its parts arrive is refused at the next part", function()
            local ns = solo({ assistants = { [CID] = true } })
            local six = {}
            for i = 1, 6 do six[i] = item("fortitude", groups(i), "Aaa-B" .. string.rep("b", i)) end
            receive(part(CID, 5, { six[1], six[2], six[3] }, 1, 2), CID)
            unitOf(CID).assistant = false
            receive(part(CID, 5, { six[4], six[5], six[6] }, 2, 2), CID)
            assert.equal(0, #ns.RaidLead.Items())
            assert.is_true(count(ns, "syncNoAuthority") >= 1)
        end)

        it("an item of a buff the split doesn't share, a hash or groups that aren't hex, or one player twice "
            .. "for one buff, changes nothing", function()
            local ns = solo()
            for _, list in ipairs({
                { "innerfire0f" .. hash(ANN) },                                     -- a self-buff
                { "zz0f" .. hash(ANN) },                                            -- no such buff
                { "fortitude0fzzzzzzzz" },                                          -- the hash isn't hex
                { "fortitudezz" .. hash(ANN) },                                     -- the groups aren't hex
                { item("fortitude", groups(1, 4), ANN), item("fortitude", groups(5, 8), ANN) },
            }) do
                receive(part(LEADER, 5, list), LEADER)
                assert.equal(0, #ns.RaidLead.Items(), list[1])
            end
            -- One player for two buffs is fine.
            receive(part(LEADER, 5, { item("fortitude", groups(1, 4), ANN), item("spirit", groups(1, 4), ANN) }),
                LEADER)
            assert.equal(2, #ns.RaidLead.Items())
        end)

        it("check-ins: once per raid joined, and again after leaving and coming back", function()
            local ns = solo()
            assert.equal(1, sentOf("RCHECK"))
            for _ = 1, 4 do
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(70)
            end
            assert.equal(1, sentOf("RCHECK"))
            wow.setGroup(nil)
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.setGroup("raid", { LEADER, BOB, CID, "Tor-Axe" })
            wow.state.leader = LEADER
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(30)
            assert.equal(2, sentOf("RCHECK"))
            assert.is_not_nil(ns)
        end)

        it("check-ins a leader's copy hears: only a raid member's older version makes it send; a malformed one "
            .. "is dropped", function()
            local ns = wow.boot({ name = "Lea", surname = "Dorn", before = function(state) state.class = "WARRIOR" end })
            ns.RaidLead.random = function() return 0 end
            wow.setGroup("raid", { ANN, BOB, CID, "Tor-Axe" })
            wow.state.leader, wow.state.isLeader = LEADER, true
            unitOf(CID).assistant = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.RaidLead.Set(FORT_SPLIT))
            wow.advance(120)
            local version = string.format("%.0f", ns.RaidLead.Version())
            local sent, checks = sentOf("RASSIGN"), sentOf("RCHECK")
            local function check(sender, stamp)
                receive(table.concat({ "1", "RCHECK", sender, stamp }, ";"), sender)
                wow.advance(70)
            end
            check("Sly-Fox", "0")        -- not in the raid
            check(ANN, version)          -- already up to date
            check(ANN, "abc")            -- malformed
            check(ANN, "0123")           -- malformed
            assert.equal(sent, sentOf("RASSIGN"))
            assert.equal(1, count(ns, "raidLeadNotMember"))
            assert.is_true(count(ns, "commMalformed") >= 2)
            -- A plain member with a newer version doesn't make us ask; an assistant does.
            check(ANN, "99999999999")
            assert.equal(checks, sentOf("RCHECK"))
            check(CID, "99999999999")
            assert.equal(checks + 1, sentOf("RCHECK"))
            -- And a flood of those asks at most once a minute.
            for _ = 1, 12 do
                receive(table.concat({ "1", "RCHECK", CID, "99999999999" }, ";"), CID)
                wow.advance(10)
            end
            assert.is_true(sentOf("RCHECK") - checks - 1 <= 2, "at most once a minute")
            -- Out of date: it catches Ann up.
            check(ANN, "0")
            assert.equal(sent + 1, sentOf("RASSIGN"))
        end)

        it("a send another copy made first, or one its own copy may no longer make, isn't sent", function()
            local ns = wow.boot({ name = "Lea", surname = "Dorn", before = function(state) state.class = "WARRIOR" end })
            ns.RaidLead.random = function() return 0 end
            wow.setGroup("raid", { ANN, BOB, CID, "Tor-Axe" })
            wow.state.leader, wow.state.isLeader = LEADER, true
            unitOf(CID).assistant = true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.RaidLead.Set(FORT_SPLIT))
            wow.advance(5)
            local sent = sentOf("RASSIGN")
            local version = string.format("%.0f", ns.RaidLead.Version())
            -- Ann is behind; Cid's copy catches her up before ours does.
            receive(table.concat({ "1", "RCHECK", ANN, "0" }, ";"), ANN)
            wow.advance(1)
            receive(part(CID, version, ns.RaidLead.Items()), CID)
            wow.advance(120)
            assert.equal(sent, sentOf("RASSIGN"))
        end)

        it("a check-in arriving while an edit waits doesn't hold the edit back", function()
            local ns = wow.boot({ name = "Lea", surname = "Dorn", before = function(state) state.class = "WARRIOR" end })
            ns.RaidLead.random = function() return 0 end
            wow.setGroup("raid", { ANN, BOB, CID, "Tor-Axe" })
            wow.state.leader, wow.state.isLeader = LEADER, true
            wow.fire("GROUP_ROSTER_UPDATE")
            assert.is_true(ns.RaidLead.Set(FORT_SPLIT))
            wow.advance(30)
            local sent = sentOf("RASSIGN")
            assert.is_true(ns.RaidLead.Set({ FORT_SPLIT[1] }))
            wow.advance(1)
            receive(table.concat({ "1", "RCHECK", ANN, "0" }, ";"), ANN)
            wow.advance(4)
            assert.equal(sent + 1, sentOf("RASSIGN"), "the edit went out at once")
        end)

        it("an assistant's edit doesn't go out once they're demoted before it does", function()
            local ns = wow.boot({ name = "Cid", surname = "Rock", before = function(state) state.class = "PRIEST" end })
            ns.RaidLead.random = function() return 0 end
            wow.setGroup("raid", { LEADER, ANN, BOB, "Tor-Axe" })
            wow.state.leader = LEADER
            wow.state.units.player.assistant = true
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(30)
            assert.is_true(ns.RaidLead.Set(FORT_SPLIT))
            wow.state.units.player.assistant = false
            wow.advance(30)
            assert.equal(0, sentOf("RASSIGN"))
        end)

        it("chaos: storms of forged, oversized, replayed and genuine messages, with promotions and unreadable "
            .. "ranks, keep only what the model says, and nothing is cast", function()
            for _, seed in ipairs({ 1, 2, 3, 4, 5, 6 }) do
                wow.reset()
                -- Bob starts as an assistant; promotions and demotions flip him and the others.
                local ns = solo({ assistants = { [BOB] = true } })
                random.seed(seed)
                local SENDERS = { LEADER, BOB, CID, "Tor-Axe", "Sly-Fox" }
                local POOL = { FORT_SPLIT[1], FORT_SPLIT[2], item("spirit", groups(1, 8), CID),
                    item("kings", groups(2, 3), BOB), item("motw", groups(8), "Tor-Axe") }
                local model = { version = 0, encoded = "-" }
                local casts = #wow.casts
                local cases = { taken = 0, refused = 0, old = 0, junk = 0, assistant = 0, leaderUnread = 0 }
                for _ = 1, 250 do
                    local roll = random.random(1, 10)
                    if roll == 1 then
                        -- Promote or demote someone, or make a rank unreadable, in Ann's game.
                        local u = unitOf(SENDERS[random.random(1, 3)])
                        if random.random(1, 2) == 1 then u.assistant = not u.assistant
                        else u.secrets = (u.secrets and u.secrets.rank) and {} or { rank = true } end
                    else
                        local sender = SENDERS[random.random(1, #SENDERS)]
                        local list, seen = {}, {}
                        for _ = 1, random.random(0, 4) do
                            local it = POOL[random.random(1, #POOL)]
                            if not seen[it] then
                                seen[it] = true
                                list[#list + 1] = it
                            end
                        end
                        -- Near the version kept, so newer and older both keep coming.
                        local version = math.max(1, model.version + random.random(-3, 3))
                        local junk = roll == 2
                        local text = part(sender, version, list)
                        if junk then text = text:sub(1, random.random(1, #text - 1)) .. string.rep("z", random.random(0, 300)) end
                        -- The model, from the client's own state, never from RaidLead.
                        local u = unitOf(sender)
                        local rank = u and not (u.secrets and u.secrets.rank)
                            and (u.id == LEADER and 2 or u.assistant and 1 or 0)
                        local leaderReadable = not (unitOf(LEADER).secrets and unitOf(LEADER).secrets.rank)
                        -- Compared as sent, in the order sent.
                        local encoded = #list > 0 and table.concat(list, ",") or "-"
                        receive(text, sender)
                        if junk then
                            cases.junk = cases.junk + 1
                        elseif not (rank == 1 or rank == 2) or not leaderReadable then
                            cases.refused = cases.refused + 1
                            if (rank == 1 or rank == 2) then cases.leaderUnread = cases.leaderUnread + 1 end
                        elseif version > model.version or (version == model.version and encoded > model.encoded) then
                            model = { version = version, encoded = encoded }
                            cases.taken = cases.taken + 1
                            if rank == 1 then cases.assistant = cases.assistant + 1 end
                        else
                            cases.old = cases.old + 1
                        end
                        local items = ns.RaidLead.Items()
                        if not junk then
                            local got = #items > 0 and table.concat(items, ",") or "-"
                            assert.equal(model.version, ns.RaidLead.Version(), "seed " .. seed)
                            assert.equal(model.encoded, got, "seed " .. seed)
                        end
                    end
                    wow.advance(random.random(0, 3))
                end
                assert.equal(casts, #wow.casts, "nothing is cast without a press")
                assert.is_true(cases.taken >= 3 and cases.refused >= 10 and cases.old >= 10 and cases.junk >= 5
                    and cases.assistant >= 1 and cases.leaderUnread >= 1,
                    "seed " .. seed .. " reached every case: " .. cases.taken .. " taken, " .. cases.assistant
                    .. " from an assistant, " .. cases.refused .. " refused, " .. cases.leaderUnread
                    .. " with the leader unreadable, " .. cases.old .. " old, " .. cases.junk .. " junk")
            end
        end)

        it("a flood of check-ins makes a leader's copy send at most once a minute", function()
            usual()
            form()
            assign(byName[LEADER], FORT_SPLIT)
            wow.use(byName[LEADER])
            local sent = #wow.addonSent
            for _ = 1, 30 do
                receive(table.concat({ "1", "RCHECK", ANN, "0" }, ";"), ANN)
                wow.advance(4)
            end
            local n = 0
            for i = sent + 1, #wow.addonSent do
                if wow.addonSent[i].text:find(";RASSIGN;", 1, true) then n = n + 1 end
            end
            -- 120 seconds, the first send already 15 seconds back: at 60 and 120.
            assert.is_true(n >= 1 and n <= 2, n .. " sends in 120 seconds")
        end)
    end)
end)
