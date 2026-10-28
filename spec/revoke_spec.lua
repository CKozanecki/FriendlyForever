-- Spec: #68
-- Revoke (paladins, Forever): buff mode offers to take Salvation off members
-- who shouldn't have it, as your setting says: your own Salvation on
-- members your Salvation rule leaves out (the default), any tank, chosen
-- tanks, chosen players, or off.
local wow = require("spec.support.wow")

local KINGS, MIGHT_1, SALVATION = 20217, 19740, 1038
local INTELLECT = 10157
local REVOKE = wow.REVOKE_ID

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("Revoke", function()
    local ns, button

    -- A paladin who knows Kings, Might and Salvation, and Revoke unless
    -- opts.noRevoke, in buff mode.
    local function boot(opts)
        opts = opts or {}
        wow.SPELL_NAMES[SALVATION] = "Salvation"
        ns = wow.boot({ db = opts.db, before = function(state)
            state.class = opts.class or "PALADIN"
            state.knownSpells = opts.known
                or { [KINGS] = true, [MIGHT_1] = true, [SALVATION] = true, [REVOKE] = not opts.noRevoke or nil }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
    end

    local function macro() return button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText) end

    local function armed()
        local text = macro()
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    local function tokenOf(id)
        for token, u in pairs(wow.state.units) do
            if u.id == id and token ~= "target" then return token end
        end
    end

    -- Scroll once. A buff shows on whoever it reached; Revoke takes their
    -- Salvation off.
    local function scroll()
        local before = #wow.casts
        wow.pressKey("MOUSEWHEELUP")
        local cast = wow.casts[before + 1]
        if cast and not cast.failed then
            local u = wow.state.units[tokenOf(cast.target)]
            if u then
                u.auras, u.auraSources = u.auras or {}, u.auraSources or {}
                if cast.spell == "Revoke" then
                    for i = #u.auras, 1, -1 do
                        if u.auras[i] == SALVATION then
                            table.remove(u.auras, i)
                            table.remove(u.auraSources, i)
                        end
                    end
                else
                    u.auras[#u.auras + 1] = cast.id
                    u.auraSources[#u.auras] = "player"
                end
            end
        end
        return cast
    end

    -- A group of { name, class, role, mainTank, salvationFrom } members.
    local function group(kind, members)
        local names = {}
        for i, m in ipairs(members) do names[i] = m[1] end
        wow.setGroup(kind, names)
        local prefix = kind == "raid" and "raid" or "party"
        for i, m in ipairs(members) do
            local u = wow.state.units[prefix .. i]
            u.class, u.role, u.mainTank = m[2], m[3], m[4]
            if m[5] then u.auras, u.auraSources = { SALVATION }, { m[5] } end
        end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
        ns.BuffButton.Refresh()
    end

    local function mode(m) ns.BuffRules.SetRevokeMode(m) end

    before_each(function() boot() end)
    after_each(function() wow.SPELL_NAMES[SALVATION] = nil end)

    describe("whose Salvation (white)", function()
        it("takes your own Salvation off a tank first, then buffs as usual", function()
            ns.db.buffBack.buffOrder = { "might", "kings", "salvation" }
            group("party", {
                { "Ann-Vale", "WARRIOR", "TANK", false, "player" }, -- your Salvation, on the tank
                { "Bo-Lake", "ROGUE", "DAMAGER" },
            })
            assert.are.equal("Ann Vale: Revoke", armed(), "ahead of new buffs")
            assert.are.equal("Revoke their Salvation (a tank)", button.subtitle:GetText())
            local cast = scroll()
            assert.are.same({ "Revoke", "Ann-Vale" }, { cast.spell, cast.target })
            assert.are.equal("Revoked Salvation from Ann Vale.", button.result:GetText())
            assert.are.equal("Ann Vale: Blessing of Might", armed())
            local given = {}
            for _ = 1, 6 do
                local c = scroll()
                if c then given[#given + 1] = c.target .. " " .. c.spell end
            end
            assert.are.same({ "Ann-Vale Blessing of Might", "Bo-Lake Blessing of Might", "Bo-Lake Salvation" }, given,
                "Salvation never goes back on the tank")
        end)

        it("doesn't offer Revoke again while the Salvation still shows, just after", function()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "player" } })
            wow.pressKey("MOUSEWHEELUP") -- the aura isn't taken off yet
            assert.is_falsy((armed() or ""):find("Revoke", 1, true))
            wow.advance(ns.GroupBuffs.JUST_GIVEN_SECONDS + 1)
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Revoke", armed(), "still there after a while: offered again")
        end)

        it("leaves another paladin's Salvation alone by default", function()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "raid9" } })
            assert.is_falsy((armed() or ""):find("Revoke", 1, true))
            -- Even when her role can't be read: there's nothing of yours to judge.
            local u = wow.state.units.party1
            u.secrets = { role = true }
            u.auras, u.auraSources = { SALVATION, KINGS }, { "raid9", "player" }
            local offer, why, settled = ns.GroupBuffs.Next()
            assert.is_nil(offer)
            assert.are.equal("everyone in your group has your buffs", why)
            assert.is_true(settled)
        end)

        it("any tank: anyone's Salvation on a tank, by role or Main Tank, never on others", function()
            mode("anyTank")
            group("raid", {
                { "Ann-Vale", "WARRIOR", "DAMAGER", true, "raid9" }, -- the Main Tank
                { "Bo-Lake", "ROGUE", "DAMAGER", false, "raid9" },
                { "Cid-Rock", "DRUID", "TANK", false, "player" },
            })
            local revoked = {}
            for _ = 1, 10 do
                local c = scroll()
                if c and c.spell == "Revoke" then revoked[#revoked + 1] = c.target end
            end
            assert.are.same({ "Ann-Vale", "Cid-Rock" }, revoked)
        end)

        it("chosen tanks: only tanks you name", function()
            mode("chosenTanks")
            assert.is_true(ns.BuffRules.SetRevokeNames("Ann Vale, Bo Lake"))
            group("party", {
                { "Ann-Vale", "WARRIOR", "TANK", false, "raid9" },
                { "Bo-Lake", "ROGUE", "DAMAGER", false, "raid9" }, -- named, but not a tank
                { "Cid-Rock", "DRUID", "TANK", false, "raid9" }, -- a tank, but not named
            })
            assert.are.equal("Ann Vale: Revoke", armed())
            scroll()
            assert.is_falsy((armed() or ""):find("Revoke", 1, true))
        end)

        it("chosen players: anyone you name, tank or not", function()
            mode("players")
            assert.is_true(ns.BuffRules.SetRevokeNames("Bo Lake"))
            group("party", {
                { "Ann-Vale", "WARRIOR", "TANK", false, "raid9" },
                { "Bo-Lake", "ROGUE", "DAMAGER", false, "raid9" },
            })
            assert.are.equal("Bo Lake: Revoke", armed())
            assert.are.equal("Revoke their Salvation (you named them)", button.subtitle:GetText())
            scroll()
            assert.is_falsy((armed() or ""):find("Revoke", 1, true))
        end)

        it("off: never", function()
            mode("off")
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "player" } })
            assert.is_falsy((armed() or ""):find("Revoke", 1, true))
        end)

        it("is chosen on the Buff Back tab, for paladins only", function()
            local w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.are.equal("Revoke Salvation from: My Salvation only", w.who.revoke:GetText())
            assert.is_false(w.who.revokeNames:IsShown())
            wow.run(w.who.revoke, "OnClick")
            assert.are.equal("Revoke Salvation from: Any tank", w.who.revoke:GetText())
            wow.run(w.who.revoke, "OnClick")
            assert.are.equal("chosenTanks", ns.db.buffBack.revokeMode)
            assert.is_true(w.who.revokeNames:IsShown())
            w.who.revokeNames:SetFocus()
            w.who.revokeNames:SetText("Ann Vale")
            w.who.revokeNames:ClearFocus()
            assert.are.equal("Ann-Vale", ns.db.buffBack.revokeNames["ann-vale"])
            for _ = 1, 3 do wow.run(w.who.revoke, "OnClick") end
            assert.are.equal("mine", ns.db.buffBack.revokeMode, "round again")
            boot({ class = "DRUID", known = {} })
            w = ns.Options.widgets
            wow.run(w.tabs.buffBack, "OnClick")
            assert.is_false(w.who.revoke:IsShown())
        end)

        it("never offers Revoke outside your group: buff back to strangers is unchanged", function()
            mode("anyTank")
            wow.addUnit("nameplate1", { name = "Bob", surname = "Stone", class = "WARRIOR", id = "Bob-Stone",
                role = "TANK", auras = { SALVATION }, auraSources = { "raid9" } })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            assert.are.equal("Bob Stone: Blessing of Kings", armed())
        end)
    end)

    describe("what it can't see (black)", function()
        it("isn't offered without Revoke in your spellbook (or on a client that names it otherwise)", function()
            boot({ noRevoke = true })
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "player" } })
            assert.is_falsy((armed() or ""):find("Revoke", 1, true))
        end)

        it("says why when it can't tell whose Salvation it is, or who's a tank", function()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "player" } })
            wow.state.units.party1.auraSources = { nil }
            wow.state.units.party1.auras = { SALVATION, KINGS, MIGHT_1 } -- nothing else to give them
            wow.state.units.party1.auraSources = { nil, "player", "raid9" }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("Ann Vale: can't tell whose Salvation they have", button.subtitle:GetText())
            mode("anyTank")
            wow.state.units.party1.secrets = { role = true }
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("Ann Vale: can't tell if they're a tank", button.subtitle:GetText())
            local _, _, settled = ns.GroupBuffs.Next()
            assert.is_false(settled)
        end)

        it("says so when the tank is out of Revoke's range", function()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "player" } })
            wow.state.units.party1.outOfSpellRange = true
            ns.BuffButton.Refresh()
            assert.is_nil(macro())
            assert.are.equal("Ann Vale: out of range to revoke their Salvation", button.subtitle:GetText())
        end)

        it("reports a refused Revoke and moves on to others for a moment", function()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "player" } })
            wow.state.castFailures["Ann-Vale"] = "Target not in line of sight"
            scroll()
            assert.are.equal("Couldn't revoke Salvation from Ann Vale: Target not in line of sight",
                button.result:GetText())
            assert.is_falsy((armed() or ""):find("Ann Vale: Revoke", 1, true), "held back")
            wow.state.castFailures["Ann-Vale"] = nil
            wow.advance(ns.GroupBuffs.HELD_BACK_SECONDS + 1)
            ns.BuffButton.Refresh()
            assert.are.equal("Ann Vale: Revoke", armed())
        end)

        it("says Revoke, not buff, when a refused cast gives no reason", function()
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "player" } })
            wow.state.castFailures["Ann-Vale"] = "Interrupted"
            local real = wow.uiError
            wow.uiError = function() end -- the game's error text never comes
            finally(function() wow.uiError = real end)
            scroll()
            wow.advance(ns.BuffButton.SENT_ANSWER_SECONDS + 1)
            assert.are.equal("Couldn't revoke Salvation from Ann Vale (the game gave no reason).",
                button.result:GetText())
        end)

        it("only Revoke's own name answers a press: another spell's cast doesn't", function()
            assert.are.equal(ns.BuffData.REVOKE, ns.BuffData.ForCast(REVOKE))
            assert.is_nil(ns.BuffData.ForCast(123456))
            assert.is_nil(ns.BuffData.ForCast(nil))
            assert.are.equal("salvation", ns.BuffData.ForCast(SALVATION).key)
        end)

        it("repairs damaged Revoke settings", function()
            boot({ db = { buffBack = { revokeMode = "everyone", revokeNames = {
                ["ann-vale"] = "Ann-Vale", bad = "Cid-Rock", [3] = "x", ["dot-fern"] = 5 } } } })
            assert.are.equal("mine", ns.db.buffBack.revokeMode)
            assert.are.same({ ["ann-vale"] = "Ann-Vale" }, ns.db.buffBack.revokeNames)
            boot({ db = { buffBack = { revokeMode = 7, revokeNames = "Ann" } } })
            assert.are.equal("mine", ns.db.buffBack.revokeMode)
            assert.are.same({}, ns.db.buffBack.revokeNames)
            ns.db.buffBack.revokeMode, ns.db.buffBack.revokeNames = {}, 9
            group("party", { { "Ann-Vale", "WARRIOR", "TANK", false, "player" } })
            assert.are.equal("Ann Vale: Revoke", armed(), "a mode damaged mid-session reads as the default")
            assert.are.same({}, wow.errors)
            local ok, why = ns.BuffRules.SetRevokeNames("not a name!")
            assert.is_false(ok)
            assert.is_string(why)
        end)

        it("goes with settings lines", function()
            mode("players")
            ns.BuffRules.SetRevokeNames("Bo Lake")
            local text = assert(ns.Profiles.Export())
            mode("off")
            ns.db.buffBack.revokeNames = {}
            assert.is_true(ns.Profiles.Import(text))
            assert.are.equal("players", ns.db.buffBack.revokeMode)
            assert.are.same({ ["bo-lake"] = "Bo-Lake" }, ns.db.buffBack.revokeNames)
        end)
    end)

    describe("chaos (red tests)", function()
        it("only ever revokes Salvation the setting covers, and never in a fight", function()
            local revoked, buffed = 0, 0
            for _, seed in ipairs({ 7, 68, 312, 2026 }) do
                math.randomseed(seed)
                boot()
                local everyone = { "Ann-Vale", "Bo-Lake", "Cid-Rock", "Dot-Fern", "Eve-Moss" }
                local roles = { "TANK", "HEALER", "DAMAGER", "NONE" }
                local sources = { "player", "raid9", "raid8" }
                local function reshuffle()
                    local members = {}
                    for _, name in ipairs(everyone) do
                        if math.random() < 0.8 then
                            members[#members + 1] = { name, ({ "WARRIOR", "ROGUE", "MAGE" })[math.random(3)],
                                roles[math.random(#roles)], math.random() < 0.3,
                                math.random() < 0.6 and sources[math.random(#sources)] or nil }
                        end
                    end
                    if #members == 0 then members[1] = { everyone[1], "WARRIOR", "TANK", false, "player" } end
                    group(math.random() < 0.5 and "raid" or "party", members)
                end
                reshuffle()
                local actions = {
                    reshuffle,
                    function() mode(ns.BuffRules.REVOKE_MODES[math.random(#ns.BuffRules.REVOKE_MODES)]) end,
                    function()
                        local pick = {}
                        for _, name in ipairs(everyone) do if math.random() < 0.4 then pick[#pick + 1] = name end end
                        ns.BuffRules.SetRevokeNames(table.concat(pick, ", "))
                    end,
                    function() ns.BuffRules.SetRule("salvation", ns.BuffRules.RULES[math.random(4)]) end,
                    function()
                        -- Salvation lands on someone, from you or another paladin.
                        local token = (wow.state.units.raid1 and "raid" or "party") .. math.random(1, 5)
                        local u = wow.state.units[token]
                        if u then
                            u.auras, u.auraSources = u.auras or {}, u.auraSources or {}
                            u.auras[#u.auras + 1] = SALVATION
                            u.auraSources[#u.auras] = sources[math.random(#sources)]
                        end
                    end,
                    function()
                        local token = (wow.state.units.raid1 and "raid" or "party") .. math.random(1, 5)
                        local u = wow.state.units[token]
                        if u then
                            local r = math.random()
                            u.secrets = r < 0.2 and { role = true } or r < 0.35 and { mainTank = true } or nil
                        end
                    end,
                    function() if wow.state.inCombat then wow.leaveCombat() else wow.enterCombat() end end,
                    function() wow.advance(math.random() * 20) end,
                }
                for step = 1, 400 do
                    local where = ("seed %d, step %d"):format(seed, step)
                    actions[math.random(#actions)]()
                    -- What the game shows, read before the press.
                    local state = {}
                    for token, u in pairs(wow.state.units) do
                        if token:find("^party") or token:find("^raid") then
                            local from
                            for i, id in ipairs(u.auras or {}) do
                                if id == SALVATION then from = u.auraSources[i] end
                            end
                            state[u.id] = { u = u, inRaid = token:find("^raid") ~= nil, salvationFrom = from }
                        end
                    end
                    local revokeMode = ns.BuffRules.RevokeMode()
                    local names = {}
                    for key in pairs(ns.db.buffBack.revokeNames or {}) do names[key] = true end
                    local fighting = wow.state.inCombat
                    local cast = scroll()
                    if cast and cast.spell == "Revoke" then
                        assert.is_false(fighting, where .. ": in a fight")
                        local s = state[cast.target]
                        assert.is_truthy(s and s.salvationFrom, where .. ": no Salvation to revoke")
                        local u, hidden = s.u, s.u.secrets or {}
                        local tank = (not hidden.role and u.role == "TANK")
                            or (s.inRaid and not hidden.mainTank and u.mainTank == true)
                        local named = names[cast.target:lower()]
                        if revokeMode == "mine" then
                            assert.are.equal("player", s.salvationFrom, where .. ": another paladin's Salvation")
                        elseif revokeMode == "anyTank" then
                            assert.is_true(tank, where .. ": not a tank")
                        elseif revokeMode == "chosenTanks" then
                            assert.is_true(tank and named, where .. ": not a chosen tank")
                        elseif revokeMode == "players" then
                            assert.is_true(named, where .. ": not a chosen player")
                        else
                            error(where .. ": revoked with Revoke off")
                        end
                        revoked = revoked + 1
                    elseif cast then
                        buffed = buffed + 1
                    end
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
            assert.is_true(revoked > 20, "revoked: " .. revoked)
            assert.is_true(buffed > 20, "buffed: " .. buffed)
        end)
    end)
end)
