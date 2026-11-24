-- Spec: #496
-- Guild leader controls, part 3: the Guild page. Every guildmate with the
-- addon sees who leads, the guild's limits, who has the addon and the
-- vetoed lines; a leader's copy also lists the lines said recently, each
-- with Veto. Only the guild master picks who leads, only leaders change the
-- limits and vetoes, and the Guild Login and Guild Join tabs say when the
-- guild's settings limit yours (decision 6).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local GM = { name = "Gina", surname = "Moss" }       -- rank 0
local OFFICER = { name = "Otto", surname = "Reed" }  -- rank 1, "Officer"
local MEMBER = { name = "Mia", surname = "Lund" }    -- rank 4 (wow.DEFAULT_GUILD_RANK)
local MEMBER2 = { name = "Ned", surname = "Holt" }   -- rank 4
local function Full(p) return p.name .. "-" .. p.surname end

-- A guild of these copies, the roster read, and a network carrying what
-- they send. opts.before(state) runs at each boot; opts.alsoInRoster adds
-- guildmates without the addon.
local function Guild(people, opts)
    opts = opts or {}
    local roster = {}
    for _, p in ipairs(people) do roster[#roster + 1] = Full(p) end
    for _, name in ipairs(opts.alsoInRoster or {}) do roster[#roster + 1] = name end
    local clients = {}
    for i, p in ipairs(people) do
        local c = wow.newClient({ name = p.name, surname = p.surname, guildSync = true, before = function(state)
            state.guildRoster = roster
            state.guildRanks[Full(GM)] = 0
            state.guildRanks[Full(OFFICER)] = 1
            for name, rank in pairs(opts.ranks or {}) do state.guildRanks[name] = rank end
            if opts.before then opts.before(state) end
        end })
        c.ns.GuildLead.random = function() return 0 end
        wow.fire("GUILD_ROSTER_UPDATE")
        clients[i] = c
    end
    local net = wow.network(clients)
    -- Everyone checks in (5 s after the roster), so the copies know each other.
    wow.advanceAll(net, 8, 0.5)
    return clients, net
end

local function on(c, fn)
    wow.use(c)
    return fn(c.ns)
end

-- The page's frames and controls on this copy, freshly filled.
local function Page(c)
    wow.use(c)
    c.ns.GuildPanel.Fill()
    return c.ns.GuildPanel.frames, c.ns.Options.widgets.guild
end

local function Text(region)
    return region:GetText() or ""
end

-- A section's items on a copy, sorted, as its saved file keeps them.
local function Kept(c, section)
    wow.use(c)
    local key = wow.state.realm .. ":" .. wow.state.guildName
    local g = _G.FriendlyForeverDB.guilds and _G.FriendlyForeverDB.guilds[key]
    local out = {}
    for i, item in ipairs(g and g[section] and g[section].items or {}) do out[i] = item end
    table.sort(out)
    return out
end

local function Settle(net) wow.advanceAll(net, 6, 0.5) end

-- A box clicked as the game does: its check flips, then OnClick runs
-- (unless it's disabled).
local function Toggle(cb)
    if not cb:IsEnabled() then return end
    cb:SetChecked(not cb:GetChecked())
    cb:Click()
end

-- Chat lines (not addon messages) a copy sent.
local function Spoke(c)
    wow.use(c)
    return #wow.sent
end

describe("Guild leader controls: the Guild page (#496)", function()
    before_each(function() random.seed(496) end)
    after_each(function() wow.reset() end)

    describe("who you are (white)", function()
        it("names the guild master, a leader of a picked rank and a member", function()
            local clients, net = Guild({ GM, OFFICER, MEMBER })
            assert.are.equal("master", on(clients[1], function(ns) return ns.GuildPanel.Role() end))
            assert.are.equal("member", on(clients[2], function(ns) return ns.GuildPanel.Role() end))
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetRankLeads(1, true)) end)
            Settle(net)
            assert.are.equal("leader", on(clients[2], function(ns) return ns.GuildPanel.Role() end))
            assert.are.equal("member", on(clients[3], function(ns) return ns.GuildPanel.Role() end))
            local f = Page(clients[2])
            assert.are.equal(clients[2].ns.GuildPanel.ROLE_TEXT.leader, Text(f.role))
        end)
    end)

    describe("who leads (white)", function()
        it("lists each rank below the guild master's by its name, with who the roster shows at it", function()
            local clients = Guild({ GM, OFFICER, MEMBER, MEMBER2 },
                { alsoInRoster = { "Ada-Kent", "Bea-Lowe", "Cal-Moor", "Dot-Nash" } })
            local f = Page(clients[1])
            -- The guild has 5 ranks: four below the guild master's.
            local shown = {}
            for index, cb in ipairs(f.ranks) do
                if cb:IsShown() then shown[#shown + 1] = index end
            end
            assert.are.same({ 1, 2, 3, 4 }, shown)
            assert.are.equal("Officer", Text(f.ranks[1].label))
            assert.are.equal("Rank 3", Text(f.ranks[2].label))
            assert.truthy(Text(f.ranks[1].members):find("Otto-Reed", 1, true))
            assert.truthy(Text(f.ranks[2].members):find("nobody in the roster", 1, true))
            -- Six at rank 4: three named, the rest counted.
            local four = Text(f.ranks[4].members)
            assert.truthy(four:find("Ada-Kent, Bea-Lowe, Cal-Moor and 3 more", 1, true), four)
            assert.truthy(Text(f.master):find("Gina-Moss", 1, true))
            assert.truthy(Text(f.master):find("Guild Master", 1, true))
        end)

        it("lets the guild master pick a rank with its box, and every copy then counts that rank as leading", function()
            local clients, net = Guild({ GM, OFFICER, MEMBER })
            local f = Page(clients[1])
            assert.is_true(f.ranks[1]:IsEnabled())
            Toggle(f.ranks[1])
            Settle(net)
            for _, c in ipairs(clients) do
                assert.are.same({ "1" }, Kept(c, "ranks"))
                local page = Page(c)
                assert.is_true(page.ranks[1]:GetChecked())
            end
            -- Unticked again: Otto no longer leads anywhere.
            f = Page(clients[1])
            Toggle(f.ranks[1])
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({}, Kept(c, "ranks")) end
            assert.are.equal("member", on(clients[2], function(ns) return ns.GuildPanel.Role() end))
        end)

        it("shows anyone else the ranks read-only", function()
            local clients, net = Guild({ GM, OFFICER, MEMBER })
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetRankLeads(1, true)) end)
            Settle(net)
            for i = 2, 3 do
                local f = Page(clients[i])
                assert.is_true(f.ranks[1]:GetChecked())
                for _, cb in ipairs(f.ranks) do assert.is_false(cb:IsEnabled()) end
            end
            -- An officer's own call is refused too, and nothing changes.
            local ok, why = on(clients[2], function(ns) return ns.GuildPanel.SetRankLeads(2, true) end)
            assert.is_false(ok)
            assert.truthy(why)
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({ "1" }, Kept(c, "ranks")) end
        end)

        it("asks the guild master to pick ranks until they do, or say only they lead for now", function()
            local clients, net = Guild({ GM, OFFICER })
            local f, widgets = Page(clients[1])
            assert.is_true(f.ask:IsShown())
            assert.is_true(widgets.onlyMe:IsShown())
            -- Not an officer's: they can't pick.
            local o = Page(clients[2])
            assert.is_false(o.ask:IsShown())
            -- "Only me for now": no section changes, and the question goes for good.
            Page(clients[1])
            widgets.onlyMe:Click()
            f = Page(clients[1])
            assert.is_false(f.ask:IsShown())
            assert.are.same({}, Kept(clients[1], "ranks"))
            assert.is_true(_G.FriendlyForeverDB.guilds[wow.state.realm .. ":" .. wow.state.guildName].asked)
            Settle(net)
            assert.are.same({}, Kept(clients[2], "ranks"))
        end)

        it("stops asking once the guild master picks a rank", function()
            local clients, net = Guild({ GM, OFFICER })
            local f = Page(clients[1])
            assert.is_true(f.ask:IsShown())
            Toggle(f.ranks[1])
            Settle(net)
            f = Page(clients[1])
            assert.is_false(f.ask:IsShown())
        end)
    end)

    describe("the guild's limits (white)", function()
        it("a leader steps the greeter cap from no limit down and back up, and every copy keeps it", function()
            local clients, net = Guild({ GM, MEMBER })
            local f, widgets = Page(clients[1])
            assert.are.equal("no limit", Text(f.greeters.value))
            widgets.greeters.minus:Click()
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({ "g20" }, Kept(c, "caps")) end
            for _ = 1, 19 do
                Page(clients[1])
                widgets.greeters.minus:Click()
            end
            -- Never below 1.
            Page(clients[1])
            widgets.greeters.minus:Click()
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({ "g1" }, Kept(c, "caps")) end
            f = Page(clients[2])
            assert.are.equal("1", Text(f.greeters.value))
            Page(clients[1])
            widgets.greeters.plus:Click()
            Settle(net)
            assert.are.same({ "g2" }, Kept(clients[2], "caps"))
        end)

        it("lifts a cap past the top, back to no limit", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetCap("w", 20)) end)
            Settle(net)
            local _, widgets = Page(clients[1])
            widgets.welcomes.plus:Click()
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({}, Kept(c, "caps")) end
            local f = Page(clients[2])
            assert.are.equal("no limit", Text(f.welcomes.value))
        end)

        it("turns guild hellos off and on for the whole guild, keeping the other limits", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetCap("g", 3)) end)
            Settle(net)
            local _, widgets = Page(clients[1])
            assert.is_true(widgets.hellos:GetChecked())
            Toggle(widgets.hellos)
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({ "g3", "h0" }, Kept(c, "caps")) end
            local _, member = Page(clients[2])
            assert.is_false(member.hellos:GetChecked())
            Page(clients[1])
            Toggle(widgets.hellos)
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({ "g3" }, Kept(c, "caps")) end
        end)

        it("an officer of a picked rank changes them; a member's controls are disabled", function()
            local clients, net = Guild({ GM, OFFICER, MEMBER })
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetRankLeads(1, true)) end)
            Settle(net)
            local _, widgets = Page(clients[2])
            assert.is_true(widgets.welcomes.minus:IsEnabled())
            widgets.welcomes.minus:Click()
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({ "w20" }, Kept(c, "caps")) end
            local _, member = Page(clients[3])
            for _, control in ipairs({ member.greeters.minus, member.greeters.plus, member.welcomes.minus,
                member.welcomes.plus, member.hellos }) do
                assert.is_false(control:IsEnabled())
            end
        end)
    end)

    describe("following the guild (white)", function()
        it("an open page and the guild tab's note follow a leader's change as it arrives", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[2], function(ns)
                ns.GuildPanel.Open()
                assert.is_true(ns.Options.UI.IsOpen(ns.GuildPanel.Page()))
            end)
            local f = clients[2].ns.GuildPanel.frames
            assert.are.equal("no limit", Text(f.greeters.value))
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetCap("g", 3)) end)
            Settle(net)
            wow.use(clients[2])
            assert.are.equal("3", Text(f.greeters.value))
            -- The main panel open at Guild Login: its note follows too.
            on(clients[2], function(ns)
                ns.db.guildLogin.maxGreeters = 5
                ns.Options.Open()
                ns.Options.SelectType("guildLogin")
                assert.truthy(Text(ns.Options.widgets.guildNote):find("at most 3", 1, true))
            end)
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetCap("g", 2)) end)
            Settle(net)
            wow.use(clients[2])
            local note = Text(clients[2].ns.Options.widgets.guildNote)
            assert.truthy(note:find("at most 2", 1, true), note)
        end)

        it("an open page follows an edit made through GuildLead.Set itself, not only its own buttons", function()
            local clients = Guild({ GM })
            on(clients[1], function(ns)
                ns.GuildPanel.Open()
                assert.is_true(ns.GuildLead.Set("caps", { "w7" }))
                wow.advance(0.1)
                assert.are.equal("7", Text(ns.GuildPanel.frames.welcomes.value))
            end)
        end)

        it("the guild master's open page lists a guildmate's check-in, a line and its words as they arrive", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[1], function(ns) ns.GuildPanel.Open() end)
            local f = clients[1].ns.GuildPanel.frames
            assert.is_false(f.lines[1]:IsShown())
            -- A new check-in: Mia's copy, a newer version.
            on(clients[2], function(ns)
                ns.VERSION = "9.9.9"
                ns.GuildLead.CheckIn()
            end)
            Settle(net)
            wow.use(clients[1])
            assert.truthy(Text(f.mates[1].words):find("version 9.9.9", 1, true), Text(f.mates[1].words))
            -- A line reported, then the words guild chat showed for it.
            on(clients[2], function(ns) ns.GuildLead.ReportLine("guildLogin", "All mine, {name}") end)
            Settle(net)
            wow.use(clients[1])
            assert.is_true(f.lines[1]:IsShown())
            assert.truthy(Text(f.lines[1].words):find("weren't seen here", 1, true))
            on(clients[1], function() wow.guildChat("All mine, Thrall", "Mia-Lund") end)
            Settle(net)
            wow.use(clients[1])
            assert.truthy(Text(f.lines[1].words):find("All mine, Thrall", 1, true), Text(f.lines[1].words))
        end)
    end)

    describe("following the roster (white)", function()
        it("an open page shows a member promoted to guild master as the guild master, and a demoted officer read-only",
            function()
            local clients, net = Guild({ GM, OFFICER, MEMBER })
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetRankLeads(1, true)) end)
            Settle(net)
            on(clients[3], function(ns) ns.GuildPanel.Open() end)
            on(clients[2], function(ns) ns.GuildPanel.Open() end)
            local member, officer = clients[3].ns.GuildPanel.frames, clients[2].ns.GuildPanel.frames
            wow.use(clients[2])
            assert.is_true(clients[2].ns.Options.widgets.guild.hellos:IsEnabled())
            -- Mia becomes guild master; Otto drops to rank 4.
            for _, c in ipairs({ clients[3], clients[2] }) do
                wow.use(c)
                wow.state.guildRanks[Full(MEMBER)] = 0
                wow.state.guildRanks[Full(OFFICER)] = 4
                wow.fire("GUILD_ROSTER_UPDATE")
                wow.advance(0.1)
            end
            wow.use(clients[3])
            assert.are.equal(clients[3].ns.GuildPanel.ROLE_TEXT.master, Text(member.role))
            assert.is_true(member.ranks[1]:IsEnabled())
            assert.is_true(clients[3].ns.Options.widgets.guild.hellos:IsEnabled())
            wow.use(clients[2])
            assert.are.equal(clients[2].ns.GuildPanel.ROLE_TEXT.member, Text(officer.role))
            assert.is_false(clients[2].ns.Options.widgets.guild.hellos:IsEnabled())
        end)
    end)

    describe("who has Friendly Forever (white)", function()
        it("lists the copies that checked in, newest first, with their version and when they were last seen", function()
            local clients = Guild({ GM, OFFICER, MEMBER })
            local g = on(clients[1], function(ns) return ns.GuildLead.Memory() end)
            local now = clients[1].ns.GuildLead.Now()
            g.mates["Otto-Reed"] = { version = "1.5.2", seen = now - 125 }
            g.mates["Mia-Lund"] = { version = "1.6.0", seen = now - 3 * 3600 }
            local f = Page(clients[1])
            assert.truthy(Text(f.matesCount):find("2 guildmates", 1, true))
            assert.is_true(f.mates[1]:IsShown())
            assert.is_true(f.mates[2]:IsShown())
            assert.is_false(f.mates[3]:IsShown())
            local first, second = Text(f.mates[1].words), Text(f.mates[2].words)
            assert.truthy(first:find("Otto-Reed", 1, true), first)
            assert.truthy(first:find("version 1.5.2", 1, true), first)
            assert.truthy(first:find("2 min ago", 1, true), first)
            assert.truthy(second:find("Mia-Lund", 1, true), second)
            assert.truthy(second:find("3 h ago", 1, true), second)
        end)

        it("marks who leads", function()
            local clients = Guild({ GM, OFFICER, MEMBER })
            local f = Page(clients[2])
            local gina
            for _, row in ipairs(f.mates) do
                if row:IsShown() and Text(row.words):find("Gina-Moss", 1, true) then gina = Text(row.words) end
            end
            assert.truthy(gina and gina:find("leads", 1, true), gina)
        end)

        it("pages through a long list with Newer and Older", function()
            local clients = Guild({ GM })
            local g = on(clients[1], function(ns) return ns.GuildLead.Memory() end)
            local now = clients[1].ns.GuildLead.Now()
            for i = 1, 19 do
                g.mates[string.format("Mate%s-Test", string.char(64 + i))] = { version = "1.6.0", seen = now - i * 60 }
            end
            local f, widgets = Page(clients[1])
            local rows = clients[1].ns.GuildPanel.ROWS
            assert.is_true(f.matesPager:IsShown())
            assert.is_false(widgets.matesPager.newer:IsEnabled())
            assert.are.equal("1 to 8 of 19", Text(f.matesPager.count))
            assert.truthy(Text(f.mates[1].words):find("MateA-Test", 1, true))
            widgets.matesPager.older:Click()
            f = Page(clients[1])
            assert.are.equal("9 to 16 of 19", Text(f.matesPager.count))
            assert.truthy(Text(f.mates[1].words):find("MateI-Test", 1, true))
            widgets.matesPager.older:Click()
            f = Page(clients[1])
            assert.are.equal("17 to 19 of 19", Text(f.matesPager.count))
            assert.is_false(widgets.matesPager.older:IsEnabled())
            assert.is_true(f.mates[3]:IsShown())
            assert.is_false(f.mates[4]:IsShown())
            widgets.matesPager.newer:Click()
            f = Page(clients[1])
            assert.are.equal("9 to 16 of 19", Text(f.matesPager.count))
            assert.are.equal(8, rows)
        end)
    end)

    describe("lines said recently and their vetoes (white)", function()
        it("pages through more lines and vetoes than a page holds, and Undo on page 2 undoes that veto everywhere",
            function()
            local clients, net = Guild({ GM, MEMBER })
            local tokens = {}
            on(clients[1], function(ns)
                for i = 1, 11 do tokens[i] = string.format("c%08x", i) end
                assert.is_true(ns.GuildLead.Set("vetoes", tokens))
            end)
            -- Said a few seconds apart, as lines are: one copy's burst would
            -- meet the flood limit (Comm.PEER_BURST).
            for i = 1, 10 do
                on(clients[2], function(ns) ns.GuildLead.ReportLine("guildLogin", ns.DefaultMessages.guildLogin[i]) end)
                Settle(net)
            end
            local f, widgets = Page(clients[1])
            -- Lines: newest first, 8 then 2.
            assert.are.equal("1 to 8 of 10", Text(f.linesPager.count))
            assert.truthy(Text(f.lines[1].words):find(clients[1].ns.DefaultMessages.guildLogin[10], 1, true))
            widgets.linesPager.older:Click()
            f = Page(clients[1])
            assert.are.equal("9 to 10 of 10", Text(f.linesPager.count))
            assert.truthy(Text(f.lines[1].words):find(clients[1].ns.DefaultMessages.guildLogin[2], 1, true))
            assert.is_false(f.lines[3]:IsShown())
            -- The mates' list didn't move.
            assert.is_false(f.matesPager:IsShown())
            widgets.linesPager.newer:Click()
            f = Page(clients[1])
            assert.are.equal("1 to 8 of 10", Text(f.linesPager.count))
            -- Vetoes: sorted, 8 then 3; Undo on page 2's first row is the 9th.
            assert.are.equal("1 to 8 of 11", Text(f.vetoesPager.count))
            widgets.vetoesPager.older:Click()
            f = Page(clients[1])
            assert.are.equal("9 to 11 of 11", Text(f.vetoesPager.count))
            assert.are.equal("1 to 8 of 10", Text(f.linesPager.count))
            widgets.vetoes[1]:Click()
            Settle(net)
            local want = {}
            for i, token in ipairs(tokens) do if i ~= 9 then want[#want + 1] = token end end
            for _, c in ipairs(clients) do assert.are.same(want, Kept(c, "vetoes")) end
            -- With 10 left, page 2 holds 2.
            f = Page(clients[1])
            assert.are.equal("9 to 10 of 10", Text(f.vetoesPager.count))
            widgets.vetoesPager.newer:Click()
            f = Page(clients[1])
            assert.are.equal("1 to 8 of 10", Text(f.vetoesPager.count))
        end)

        -- A member's copy says built-in guild login line i: its report reaches
        -- the leaders' copies.
        local function SayBuiltIn(c, net, i)
            on(c, function(ns) ns.GuildLead.ReportLine("guildLogin", ns.DefaultMessages.guildLogin[i]) end)
            Settle(net)
        end

        it("lists a member's line on the guild master's page, and Veto stops every copy saying it", function()
            local clients, net = Guild({ GM, MEMBER })
            SayBuiltIn(clients[2], net, 2)
            local f, widgets = Page(clients[1])
            assert.is_true(f.lines[1]:IsShown())
            local row = Text(f.lines[1].words)
            local words = clients[1].ns.DefaultMessages.guildLogin[2]
            assert.truthy(row:find("Guild Login", 1, true), row)
            assert.truthy(row:find("Mia-Lund", 1, true), row)
            assert.truthy(row:find(words, 1, true), row)
            assert.are.equal("Veto", f.lines[1].button:GetText())
            widgets.lines[1]:Click()
            Settle(net)
            for _, c in ipairs(clients) do
                assert.are.same({ "bld2" }, Kept(c, "vetoes"))
                assert.is_true(on(c, function(ns) return ns.GuildLead.IsLineVetoed("guildLogin", words) end))
            end
            f = Page(clients[1])
            assert.are.equal("Undo", f.lines[1].button:GetText())
            assert.truthy(Text(f.lines[1].words):find("vetoed", 1, true))
        end)

        it("lists the vetoed lines on every copy, with their words where known, and a leader's Undo", function()
            local clients, net = Guild({ GM, MEMBER })
            local own = "Hey {name}, my very own line"
            on(clients[2], function(ns) ns.db.guildLogin.messages[1] = own end)
            local token = on(clients[1], function(ns) return ns.GuildLead.LineToken("guildLogin", own) end)
            on(clients[1], function(ns)
                assert.is_true(ns.GuildPanel.Veto("bld3"))
                assert.is_true(ns.GuildPanel.Veto(token))
            end)
            Settle(net)
            -- The member's copy knows the custom line's words: it's one of its own.
            local f = Page(clients[2])
            assert.truthy(Text(f.vetoesCount):find("2 of at most 40", 1, true))
            local rows = { Text(f.vetoes[1].words), Text(f.vetoes[2].words) }
            local text = table.concat(rows, "\n")
            assert.truthy(text:find(clients[2].ns.DefaultMessages.guildLogin[3], 1, true), text)
            assert.truthy(text:find(own, 1, true), text)
            assert.is_false(f.vetoes[1].button:IsShown())
            -- The guild master's copy doesn't know those words.
            f = Page(clients[1])
            text = Text(f.vetoes[1].words) .. "\n" .. Text(f.vetoes[2].words)
            assert.truthy(text:find("words weren't seen here", 1, true), text)
            -- Undo the built-in one (tokens kept sorted: bld3 before the c... one).
            local _, widgets = Page(clients[1])
            assert.truthy(Text(f.vetoes[1].words):find(clients[1].ns.DefaultMessages.guildLogin[3], 1, true))
            widgets.vetoes[1]:Click()
            Settle(net)
            for _, c in ipairs(clients) do assert.are.same({ token }, Kept(c, "vetoes")) end
        end)

        it("vetoes a line once: a second veto changes nothing", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[1], function(ns)
                assert.is_true(ns.GuildPanel.Veto("bld4"))
                local version = ns.GuildLead.Version("vetoes")
                assert.is_true(ns.GuildPanel.Veto("bld4"))
                assert.are.equal(version, ns.GuildLead.Version("vetoes"))
            end)
            Settle(net)
            assert.are.same({ "bld4" }, Kept(clients[2], "vetoes"))
        end)

        it("names a vetoed line's type, and its words even on a copy whose own lines are all different", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[1], function(ns)
                for i = 1, #ns.db.guildLogin.messages do ns.db.guildLogin.messages[i] = "Mine " .. i end
                for i = 1, #ns.db.guildJoin.messages do ns.db.guildJoin.messages[i] = "Joined " .. i end
                assert.is_true(ns.GuildPanel.Veto("bjd2"))
                assert.is_true(ns.GuildPanel.Veto("bld1"))
            end)
            Settle(net)
            local f = Page(clients[1])
            local login, join = Text(f.vetoes[1].words), Text(f.vetoes[2].words)
            assert.truthy(login:find("^Guild Join: "), login)
            assert.truthy(login:find(clients[1].ns.DefaultMessages.guildJoin[2], 1, true), login)
            assert.truthy(join:find("^Guild Login: "), join)
            assert.truthy(join:find(clients[1].ns.DefaultMessages.guildLogin[1], 1, true), join)
        end)

        it("shows a custom vetoed line with the words guild chat showed, and a line of its own's escapes as text", function()
            local clients, net = Guild({ GM, MEMBER })
            local custom = "Over here, {name}!"
            on(clients[2], function(ns) ns.GuildLead.ReportLine("guildLogin", custom) end)
            on(clients[1], function() wow.guildChat("Over here, Thrall!", "Mia-Lund") end)
            Settle(net)
            local token = on(clients[1], function(ns) return ns.GuildLead.LineToken("guildLogin", custom) end)
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.Veto(token)) end)
            local mine = "Hi |cffff0000{name}|r"
            on(clients[1], function(ns)
                ns.db.guildLogin.messages[1] = mine
                assert.is_true(ns.GuildPanel.Veto(ns.GuildLead.LineToken("guildLogin", mine)))
            end)
            Settle(net)
            local f = Page(clients[1])
            local text = Text(f.vetoes[1].words) .. "\n" .. Text(f.vetoes[2].words)
            assert.truthy(text:find("Over here, Thrall!", 1, true), text)
            assert.truthy(text:find("Hi ||cffff0000{name}||r", 1, true), text)
        end)

        it("shows a custom line with the words guild chat showed from its sender", function()
            local clients, net = Guild({ GM, MEMBER })
            local custom = "Look who it is, {name}!"
            on(clients[2], function(ns) ns.GuildLead.ReportLine("guildLogin", custom) end)
            on(clients[1], function() wow.guildChat("Look who it is, |cffff0000Thrall|r!", "Mia-Lund") end)
            Settle(net)
            local f = Page(clients[1])
            local row = Text(f.lines[1].words)
            assert.truthy(row:find("Look who it is, cffff0000Thrallr!", 1, true), row)
            assert.is_nil(row:find("|c", 1, true))
        end)

        it("a member's copy lists no lines and says why", function()
            local clients, net = Guild({ GM, MEMBER, MEMBER2 })
            SayBuiltIn(clients[3], net, 1)
            local f = Page(clients[2])
            assert.are.equal(clients[2].ns.GuildPanel.LINES_MEMBER, Text(f.linesNote))
            for _, row in ipairs(f.lines) do assert.is_false(row:IsShown()) end
        end)
    end)

    describe("the note on the guild tabs (decision 6, white)", function()
        local function Note(c, tab)
            wow.use(c)
            c.ns.Options.Open()
            -- Another tab first, so this one's click fills it afresh.
            c.ns.Options.SelectType(tab == "guildJoin" and "guildLogin" or "guildJoin")
            c.ns.Options.widgets.tabs[tab]:Click()
            local note = c.ns.Options.widgets.guildNote
            return note:IsShown() and Text(note) or nil
        end

        it("says when the guild's greeter cap is lower than yours, and not when yours is lower", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[2], function(ns) ns.db.guildLogin.maxGreeters = 5 end)
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetCap("g", 2)) end)
            Settle(net)
            local note = Note(clients[2], "guildLogin")
            assert.truthy(note and note:find("at most 2 greet one login", 1, true), note)
            assert.truthy(note:find("not your 5", 1, true), note)
            on(clients[2], function(ns) ns.db.guildLogin.maxGreeters = 1 end)
            assert.is_nil(Note(clients[2], "guildLogin"))
        end)

        it("says when guild hellos are off, and the welcome cap on the Guild Join tab", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[1], function(ns)
                assert.is_true(ns.GuildPanel.SetCap("h", false))
                assert.is_true(ns.GuildPanel.SetCap("w", 3))
            end)
            Settle(net)
            local note = Note(clients[2], "guildLogin")
            assert.truthy(note and note:find("turned guild hellos off", 1, true), note)
            note = Note(clients[2], "guildJoin")
            assert.truthy(note and note:find("at most 3 welcome a new member", 1, true), note)
        end)

        it("counts your lines the guild vetoed, and a vetoed line's hover says so", function()
            local clients, net = Guild({ GM, MEMBER })
            local lines = on(clients[2], function(ns) return ns.db.guildLogin.messages end)
            on(clients[1], function(ns)
                assert.is_true(ns.GuildPanel.Veto(ns.GuildLead.LineToken("guildLogin", lines[1])))
                assert.is_true(ns.GuildPanel.Veto(ns.GuildLead.LineToken("guildLogin", lines[2])))
            end)
            Settle(net)
            local note = Note(clients[2], "guildLogin")
            assert.truthy(note and note:find("2 of these lines are vetoed", 1, true), note)
            -- The hover of the first line says it's vetoed.
            wow.use(clients[2])
            local edits = clients[2].ns.Options.widgets.edits
            wow.run(edits[1], "OnEnter")
            local said = table.concat(_G.GameTooltip.lines, "\n")
            assert.truthy(said:find(clients[2].ns.Options.VETOED_TIP, 1, true), said)
            -- A line not vetoed doesn't say so.
            wow.run(edits[3], "OnEnter")
            said = table.concat(_G.GameTooltip.lines, "\n")
            assert.is_nil(said:find(clients[2].ns.Options.VETOED_TIP, 1, true), said)
        end)

        it("shows no note on other tabs, or with nothing limiting", function()
            local clients, net = Guild({ GM, MEMBER })
            assert.is_nil(Note(clients[2], "guildLogin"))
            assert.is_nil(Note(clients[2], "guildJoin"))
            assert.is_nil(Note(clients[2], "partyJoin"))
            -- The guild's welcome cap is about Guild Join only.
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetCap("w", 2)) end)
            Settle(net)
            assert.is_nil(Note(clients[2], "partyJoin"))
            assert.is_nil(on(clients[2], function(ns) return ns.GuildPanel.LimitNote("partyJoin") end))
            assert.is_nil(Note(clients[2], "guildLogin"))
        end)

        it("says nothing about a greeter cap the same as yours, and counts one vetoed line as one", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[2], function(ns) ns.db.guildLogin.maxGreeters = 4 end)
            local first = on(clients[2], function(ns) return ns.db.guildLogin.messages[1] end)
            on(clients[1], function(ns)
                assert.is_true(ns.GuildPanel.SetCap("g", 4))
                assert.is_true(ns.GuildPanel.Veto(ns.GuildLead.LineToken("guildLogin", first)))
            end)
            Settle(net)
            local note = Note(clients[2], "guildLogin")
            assert.are.equal(nil, note and note:find("greet one login", 1, true))
            assert.truthy(note and note:find("One of these lines is vetoed", 1, true), note)
        end)
    end)

    describe("what the game won't say (black)", function()
        it("out of a guild: the page says so, shows no section, and nothing breaks", function()
            local ns = wow.boot({ before = function(state) state.inGuild = false end })
            ns.GuildPanel.Fill()
            local f = ns.GuildPanel.frames
            assert.are.equal(ns.GuildPanel.NOT_IN_GUILD, Text(f.role))
            for _, region in ipairs({ f.leadsHeader, f.limitsHeader, f.matesHeader, f.linesHeader, f.vetoesHeader,
                f.greeters, f.ask }) do
                assert.is_false(region:IsShown())
            end
            for _, cb in ipairs(f.ranks) do assert.is_false(cb:IsShown()) end
            assert.is_nil(ns.GuildPanel.Role())
            assert.is_nil(ns.GuildPanel.LimitNote("guildLogin"))
            local ok = ns.GuildPanel.Veto("bld1")
            assert.is_false(ok)
        end)

        it("names a rank it can't read, or whose name is a secret, by its number", function()
            local clients = Guild({ GM }, { before = function(state) state.guildRankNameSecret = true end })
            local f = Page(clients[1])
            assert.are.equal("Rank 2", Text(f.ranks[1].label))
        end)

        it("shows a rank's name as plain text, cut short", function()
            local clients = Guild({ GM }, { before = function(state)
                state.guildRankNames[1] = "|cffff0000Red|r |Hplayer:x|h" .. string.rep("Long", 20)
            end })
            local label = Text(Page(clients[1]).ranks[1].label)
            assert.is_nil(label:find("|c", 1, true))
            assert.is_nil(label:find("|H", 1, true))
            assert.is_true(#label <= clients[1].ns.GuildPanel.MAX_RANK_NAME * 2)
        end)

        it("lists every rank a guild can have when the game won't say how many and the roster shows none", function()
            local clients = Guild({ GM }, { before = function(state) state.guildNumRanks = nil end })
            local shown = 0
            for _, cb in ipairs(Page(clients[1]).ranks) do
                if cb:IsShown() then shown = shown + 1 end
            end
            assert.are.equal(9, shown)
        end)

        it("lists as many ranks as the roster shows when the game won't say how many", function()
            local clients = Guild({ GM, OFFICER, MEMBER }, { before = function(state)
                state.guildNumRanks = nil
            end, ranks = { ["Mia-Lund"] = 6 } })
            local shown = {}
            for index, cb in ipairs(Page(clients[1]).ranks) do
                if cb:IsShown() then shown[#shown + 1] = index end
            end
            assert.are.same({ 1, 2, 3, 4, 5, 6 }, shown)
        end)

        it("still lists a picked rank past the guild's count", function()
            local clients, net = Guild({ GM })
            on(clients[1], function(ns) assert.is_true(ns.GuildPanel.SetRankLeads(7, true)) end)
            Settle(net)
            local f = Page(clients[1])
            assert.is_true(f.ranks[7]:IsShown())
            assert.is_true(f.ranks[7]:GetChecked())
            assert.is_false(f.ranks[6]:IsShown())
        end)

        it("treats you as a member when your own name can't be read yet: the page only shows", function()
            local clients = Guild({ GM }, { before = function(state) state.units.player.nameLoading = true end })
            assert.are.equal("member", on(clients[1], function(ns) return ns.GuildPanel.Role() end))
            local f, widgets = Page(clients[1])
            assert.is_false(f.ranks[1]:IsEnabled())
            assert.is_false(widgets.hellos:IsEnabled())
        end)

        it("falls back to the roster when the game's rank count isn't a whole number from 1 to 10", function()
            for _, bad in ipairs({ 0, 11, 2.5, "5", -3 }) do
                local clients = Guild({ GM, OFFICER, MEMBER }, { before = function(state)
                    state.guildNumRanks = bad
                end, ranks = { ["Mia-Lund"] = 6 } })
                local shown = {}
                for index, cb in ipairs(Page(clients[1]).ranks) do
                    if cb:IsShown() then shown[#shown + 1] = index end
                end
                assert.are.same({ 1, 2, 3, 4, 5, 6 }, shown, tostring(bad))
                wow.reset()
            end
        end)

        it("names a rank whose name is empty, or only escapes, by its number", function()
            local clients = Guild({ GM }, { before = function(state)
                state.guildRankNames[1] = ""
                state.guildRankNames[2] = "||"
            end })
            local f = Page(clients[1])
            assert.are.equal("Rank 2", Text(f.ranks[1].label))
            assert.are.equal("Rank 3", Text(f.ranks[2].label))
        end)

        it("treats you as a member when your own rank can't be read: the page only shows", function()
            local clients = Guild({ GM }, { before = function(state) state.guildRankSecret = true end })
            assert.are.equal("member", on(clients[1], function(ns) return ns.GuildPanel.Role() end))
            local f, widgets = Page(clients[1])
            assert.is_false(f.ask:IsShown())
            assert.is_false(widgets.greeters.minus:IsEnabled())
        end)

        it("refuses a veto once the list is full, and its Veto buttons are disabled", function()
            local clients, net = Guild({ GM, MEMBER })
            local MAX = clients[1].ns.GuildLead.MAX_VETOES
            on(clients[1], function(ns)
                local items = {}
                for i = 1, MAX do items[i] = string.format("c%08x", i) end
                assert.is_true(ns.GuildLead.Set("vetoes", items))
            end)
            on(clients[2], function(ns) ns.GuildLead.ReportLine("guildLogin", ns.DefaultMessages.guildLogin[1]) end)
            Settle(net)
            local ok, why = on(clients[1], function(ns) return ns.GuildPanel.Veto("bld1") end)
            assert.is_false(ok)
            assert.truthy(why:find("full", 1, true))
            local f = Page(clients[1])
            assert.is_true(f.lines[1]:IsShown())
            assert.is_false(f.lines[1].button:IsEnabled())
            assert.are.equal(MAX, #Kept(clients[1], "vetoes"))
        end)

        it("keeps Undo on a vetoed line said recently while the list is full, and undoes it", function()
            local clients, net = Guild({ GM, MEMBER })
            local MAX = clients[1].ns.GuildLead.MAX_VETOES
            on(clients[1], function(ns)
                local items = { "bld1" }
                for i = 2, MAX do items[i] = string.format("c%08x", i) end
                assert.is_true(ns.GuildLead.Set("vetoes", items))
            end)
            on(clients[2], function(ns) ns.GuildLead.ReportLine("guildLogin", ns.DefaultMessages.guildLogin[1]) end)
            Settle(net)
            local f, widgets = Page(clients[1])
            assert.are.equal("Undo", f.lines[1].button:GetText())
            assert.is_true(f.lines[1].button:IsEnabled())
            widgets.lines[1]:Click()
            Settle(net)
            for _, c in ipairs(clients) do
                assert.are.equal(MAX - 1, #Kept(c, "vetoes"))
                assert.is_false(on(c, function(ns) return ns.GuildLead.IsVetoed("bld1") end))
            end
        end)

        it("keeps the guild master's answer through a reload's check, and drops a damaged one", function()
            local clients = Guild({ GM })
            on(clients[1], function(ns)
                ns.GuildLead.MarkRanksAsked()
                ns.GuildLead.Validate(ns.db)
                assert.is_true(ns.GuildLead.RanksAsked())
                local g = ns.GuildLead.Memory()
                g.asked = "yes"
                -- Damaged mid-session: not an answer, even before the check.
                g.ranks = { version = 0, items = {} }
                assert.is_false(ns.GuildLead.RanksAsked())
                ns.GuildLead.Validate(ns.db)
                assert.is_false(ns.GuildLead.RanksAsked())
                assert.is_nil(ns.GuildLead.Memory().asked)
            end)
        end)

        it("leaves out a guildmate's entry damaged mid-session, and still fills", function()
            local clients = Guild({ GM, MEMBER })
            local g = on(clients[1], function(ns) return ns.GuildLead.Memory() end)
            g.mates["Bad-Entry"] = 5
            g.mates["Odd-Entry"] = { version = 7, seen = "soon" }
            g.mates["Nan-Entry"] = { version = "1.6.0", seen = 0 / 0 }
            g.mates["Num-Version"] = { version = 7, seen = 100 }
            -- One fault each (#536's testing review): only the time, and only the name.
            g.mates["Seen-Only"] = { version = "1.6.0", seen = "soon" }
            g.mates[7] = { version = "1.6.0", seen = g.mates["Mia-Lund"].seen }
            local f
            assert.has_no.errors(function() f = Page(clients[1]) end)
            local names = {}
            for _, mate in ipairs(clients[1].ns.GuildPanel.MateList()) do names[#names + 1] = mate.name end
            assert.are.same({ "Mia-Lund" }, names)
            assert.truthy(Text(f.matesCount):find("1 guildmates", 1, true))
        end)

        it("after an update that adds GuildPanel.lua and a /reload (no restart): asks for a restart, nothing breaks",
            function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "GuildPanel.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_LOGIN")
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            wow.fire("GUILD_ROSTER_UPDATE")
            wow.advance(30)
            _G.SlashCmdList.FRIENDLYFOREVER("status")
            assert.are.same({}, wow.errors)
            assert.is_nil(_G.FriendlyForeverDB)
            assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game", 1, true))
        end)

        it("says how long ago for times it can't place, or in the future, as just now", function()
            local ns = wow.boot()
            local now = ns.GuildLead.Now()
            assert.are.equal("just now", ns.GuildPanel.Ago(now + 100))
            assert.are.equal("just now", ns.GuildPanel.Ago(nil))
            assert.are.equal("just now", ns.GuildPanel.Ago(now - 59))
            assert.are.equal("1 min ago", ns.GuildPanel.Ago(now - 60))
            assert.are.equal("59 min ago", ns.GuildPanel.Ago(now - 3599))
            assert.are.equal("1 h ago", ns.GuildPanel.Ago(now - 3600))
            assert.are.equal("47 h ago", ns.GuildPanel.Ago(now - 2 * 86400 + 1))
            assert.are.equal("2 days ago", ns.GuildPanel.Ago(now - 2 * 86400))
        end)
    end)

    describe("a storm of clicks and forgeries (red)", function()
        -- Who leads, worked out from the test's own model of the ranks
        -- section and each player's rank, never from the code under test.
        local RANK = { [Full(GM)] = 0, [Full(OFFICER)] = 1, [Full(MEMBER)] = 4, [Full(MEMBER2)] = 4 }
        local function Leads(model, c)
            local rank = RANK[c.full]
            return rank == 0 or model.ranks[tostring(rank)] == true
        end
        local function Sorted(set)
            local out = {}
            for item, kept in pairs(set) do if kept then out[#out + 1] = item end end
            table.sort(out)
            return out
        end
        -- The test's own stepping of a limit: 1 to 20, then no limit.
        local function Step(value, by)
            if value == nil then return by < 0 and 20 or nil end
            if value + by < 1 then return 1 end
            if value + by > 20 then return nil end
            return value + by
        end
        local function CapsList(caps)
            local out = {}
            if caps.g then out[#out + 1] = "g" .. caps.g end
            if caps.h == false then out[#out + 1] = "h0" end
            if caps.w then out[#out + 1] = "w" .. caps.w end
            table.sort(out)
            return out
        end

        for _, seed in ipairs({ 1, 2, 3 }) do
            it("keeps every copy and every page as the leaders' clicks left them (seed " .. seed .. ")", function()
                random.seed(seed)
                local clients, net = Guild({ GM, OFFICER, MEMBER, MEMBER2 })
                local sayer = clients[4]
                local model = { ranks = {}, caps = { h = true }, vetoes = {}, recent = {} }
                for _, c in ipairs(clients) do model.recent[c] = {} end
                local builtIn = clients[1].ns.DefaultMessages.guildLogin
                local stats = { rank = 0, cap = 0, refused = 0, veto = 0, undo = 0, said = 0, forged = 0, officer = 0,
                    ["forged ranks"] = 0, ["forged caps"] = 0, ["forged vetoes"] = 0 }

                for round = 1, 60 do
                    local pick = random.random(1, 8)
                    local actor = clients[random.random(1, #clients)]
                    local rank = ({ 1, 1, 4, 2 })[random.random(1, 4)]
                    -- The first rounds reach each case once, the rest at random:
                    -- lines said, the officer's rank picked, the officer's
                    -- click, a veto, an undo from the veto list, a forgery.
                    -- A forgery of each section too (#536's testing review).
                    local forced = ({ { 7 }, { 7 }, { 7 }, { 1, 1, 1 }, { 2, 2 }, { 5, 1 }, { 6, 1 },
                        { 8, nil, nil, "ranks" }, { 8, nil, nil, "caps" }, { 8, nil, nil, "vetoes" } })[round]
                    local forgedSection = ({ "ranks", "caps", "vetoes" })[random.random(1, 3)]
                    if forced then
                        pick = forced[1]
                        if forced[2] then actor = clients[forced[2]] end
                        if forced[3] then rank = forced[3] end
                        if forced[4] then forgedSection = forced[4] end
                    end
                    if pick == 1 then
                        -- The guild master ticks or unticks a rank (rank 1 is Otto's, 4 the members').
                        local r = rank
                        local f = Page(clients[1])
                        Toggle(f.ranks[r])
                        model.ranks[tostring(r)] = not model.ranks[tostring(r)] or nil
                        stats.rank = stats.rank + 1
                    elseif pick <= 4 then
                        local f, widgets = Page(actor)
                        local leads = Leads(model, actor)
                        if leads and actor == clients[2] then stats.officer = stats.officer + 1 end
                        if pick == 2 or pick == 3 then
                            local kind = pick == 2 and "g" or "w"
                            local by = random.random(1, 2) == 1 and -1 or 1
                            local control = widgets[kind == "g" and "greeters" or "welcomes"][by < 0 and "minus" or "plus"]
                            control:Click()
                            if leads then model.caps[kind] = Step(model.caps[kind], by) end
                        else
                            Toggle(widgets.hellos)
                            if leads then model.caps.h = not model.caps.h end
                        end
                        stats[leads and "cap" or "refused"] = stats[leads and "cap" or "refused"] + 1
                        assert.is_truthy(f)
                    elseif pick == 5 then
                        -- Veto or undo a line on the actor's page of recent lines.
                        local recent = model.recent[actor]
                        local f, widgets = Page(actor)
                        if Leads(model, actor) and #recent > 0 then
                            local i = random.random(1, math.min(#recent, 8))
                            local token = recent[#recent - i + 1]
                            assert.is_true(f.lines[i]:IsShown())
                            widgets.lines[i]:Click()
                            if model.vetoes[token] then
                                model.vetoes[token] = nil
                                stats.undo = stats.undo + 1
                            else
                                model.vetoes[token] = true
                                stats.veto = stats.veto + 1
                            end
                        else
                            for _, row in ipairs(f.lines) do assert.is_false(row:IsShown()) end
                            stats.refused = stats.refused + 1
                        end
                    elseif pick == 6 then
                        -- Undo a veto on the actor's list of vetoed lines.
                        local list = Sorted(model.vetoes)
                        local f, widgets = Page(actor)
                        if #list > 0 then
                            local i = random.random(1, math.min(#list, 8))
                            assert.are.equal(Leads(model, actor), f.vetoes[i].button:IsShown())
                            widgets.vetoes[i]:Click()
                            if Leads(model, actor) then
                                model.vetoes[list[i]] = nil
                                stats.undo = stats.undo + 1
                            end
                        end
                    elseif pick == 7 then
                        -- A copy says a built-in guild line; the copies that lead keep it.
                        local k = random.random(1, 12)
                        on(sayer, function(ns) ns.GuildLead.ReportLine("guildLogin", builtIn[k]) end)
                        for _, c in ipairs(clients) do
                            if Leads(model, c) then table.insert(model.recent[c], "bld" .. k) end
                        end
                        stats.said = stats.said + 1
                    else
                        -- A copy that doesn't lead forges a newer section and sends it.
                        local forger
                        for _, c in ipairs(clients) do
                            if not Leads(model, c) then forger = c end
                        end
                        if forger then
                            local section = forgedSection
                            local items = ({ ranks = { "4" }, caps = { "h0" }, vetoes = { "bld1", "bld2" } })[section]
                            on(forger, function(ns)
                                local g = ns.GuildLead.Memory()
                                local kept = g[section]
                                g[section] = { version = kept.version + 1000, items = items }
                                ns.GuildLead.SECTIONS[section].Send()
                                g[section] = kept
                            end)
                            stats.forged = stats.forged + 1
                            stats["forged " .. section] = (stats["forged " .. section] or 0) + 1
                        end
                    end
                    Settle(net)

                    -- Every copy keeps what the model says, and every page shows it.
                    local want = { ranks = Sorted(model.ranks), caps = CapsList(model.caps), vetoes = Sorted(model.vetoes) }
                    for _, c in ipairs(clients) do
                        for _, section in ipairs({ "ranks", "caps", "vetoes" }) do
                            assert.are.same(want[section], Kept(c, section),
                                string.format("round %d, %s's %s", round, c.full, section))
                        end
                        local f, widgets = Page(c)
                        local leads = Leads(model, c)
                        assert.are.equal(model.caps.g and tostring(model.caps.g) or "no limit", Text(f.greeters.value),
                            string.format("round %d, %s pick %d by %s greeters", round, c.full, pick, actor.full))
                        assert.are.equal(model.caps.w and tostring(model.caps.w) or "no limit", Text(f.welcomes.value))
                        assert.are.equal(model.caps.h, widgets.hellos:GetChecked())
                        assert.are.equal(leads, widgets.greeters.minus:IsEnabled())
                        assert.are.equal(leads, widgets.hellos:IsEnabled())
                        for r = 1, 4 do
                            assert.are.equal(model.ranks[tostring(r)] == true, f.ranks[r]:GetChecked())
                            assert.are.equal(c == clients[1], f.ranks[r]:IsEnabled())
                        end
                        local shownLines = 0
                        for _, row in ipairs(f.lines) do if row:IsShown() then shownLines = shownLines + 1 end end
                        assert.are.equal(leads and math.min(#model.recent[c], 8) or 0, shownLines,
                            string.format("round %d, %s's lines", round, c.full))
                        local shownVetoes = 0
                        for _, row in ipairs(f.vetoes) do if row:IsShown() then shownVetoes = shownVetoes + 1 end end
                        assert.are.equal(math.min(#want.vetoes, 8), shownVetoes)
                        -- The page never says a word in chat.
                        assert.are.equal(0, Spoke(c))
                    end
                end
                for case, n in pairs(stats) do
                    assert.is_true(n >= 1, string.format("seed %d never reached %s", seed, case))
                end
            end)
        end
    end)

    describe("a member can't change anything (red)", function()
        it("a member's direct calls are refused and change no copy", function()
            local clients, net = Guild({ GM, MEMBER })
            on(clients[1], function(ns)
                assert.is_true(ns.GuildPanel.SetCap("g", 4))
                assert.is_true(ns.GuildPanel.Veto("bld1"))
            end)
            Settle(net)
            on(clients[2], function(ns)
                assert.is_false((ns.GuildPanel.SetCap("g", 1)))
                assert.is_false((ns.GuildPanel.SetCap("h", false)))
                assert.is_false((ns.GuildPanel.Veto("bld2")))
                assert.is_false((ns.GuildPanel.Undo("bld1")))
                assert.is_false((ns.GuildPanel.SetRankLeads(4, true)))
            end)
            Settle(net)
            for _, c in ipairs(clients) do
                assert.are.same({ "g4" }, Kept(c, "caps"))
                assert.are.same({ "bld1" }, Kept(c, "vetoes"))
                assert.are.same({}, Kept(c, "ranks"))
            end
        end)
    end)
end)
