-- Spec: #43, #227, #252, #305, #313
-- The clickable list beside the buff button: everyone the button would offer
-- to, and the buff for each; a click makes that player the next offer.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local MOTW, MOTW_1, THORNS_1 = 9885, 1126, 467
local INTELLECT = 10157

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

describe("The list beside the buff button (#43)", function()
    local ns, button

    local function boot()
        ns = wow.boot({ before = function(state)
            state.class = "DRUID"
            state.knownSpells = { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
        end })
        button = ns.BuffButton.Frame()
    end

    local function party(names)
        wow.setGroup("party", names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    -- What the button casts now: "Name-Realm: Spell", or nil when empty.
    local function armed()
        local text = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    -- The rows shown, as text.
    local function rows()
        local out = {}
        local frame = ns.BuffList.Frame()
        if not frame or not frame:IsShown() then return out end
        -- The rows actually visible, as a player would see them.
        for _, row in ipairs(ns.BuffList.Rows()) do
            if row:IsShown() then out[#out + 1] = row.text:GetText() end
        end
        return out
    end

    local function click(i) ns.BuffList.Rows()[i].scripts.OnClick(ns.BuffList.Rows()[i]) end

    local function owe(name, plate)
        wow.addUnit(plate, { name = name, surname = "Stone", class = "WARRIOR", id = name .. "-Stone" })
        wow.gainBuff({ sourceUnit = plate, name = "Arcane Intellect", spellId = INTELLECT })
    end

    before_each(function() boot() end)

    describe("what it shows (white)", function()
        it("shows nothing when nobody is offered", function()
            assert.are.same({}, rows())
        end)

        it("lists favours newest first, then group members, each with its buff, matching the button", function()
            owe("Bob", "nameplate1")
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            assert.are.same({
                "> Bob Stone: Mark of the Wild",
                "Ann Vale: Mark of the Wild",
                "Cid Rock: Mark of the Wild",
            }, rows())
            assert.are.equal("Bob Stone: Mark of the Wild", armed(), "the first row is the offer")
        end)

        it("clicking a row makes that player the next offer", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            click(3)
            assert.are.equal("Dot Fern: Mark of the Wild", armed())
            assert.are.equal("> Dot Fern: Mark of the Wild", rows()[3])
            assert.are.equal("Ann Vale: Mark of the Wild", rows()[1], "the mark moved off Ann")
            assert.are.equal("Dot Fern", button.title:GetText())
        end)

        it("a clicked player who is no longer offered is forgotten, not offered again later", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            click(2)
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
            party({ "Ann-Vale" })
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            party({ "Ann-Vale", "Cid-Rock" })
            assert.are.equal("Ann Vale: Mark of the Wild", armed(), "the old choice does not come back")
        end)

        it("a click casts nothing: only a press of the button does", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            click(2)
            assert.are.equal(0, #wow.casts)
            assert.is_true(ns.BuffList.Rows()[1].protected ~= true and ns.BuffList.Rows()[1].template == nil)
        end)

        it("casts on the chosen player when the button is pressed", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            click(2)
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(1, #wow.casts)
            assert.are.equal("Cid-Rock", wow.casts[1].target, "the cast goes to the player chosen")
        end)
    end)

    describe("one row per player", function()
        it("shows a player owed a favour who is also in your group once, with the offer the button makes", function()
            owe("Bob", "nameplate1")
            slash("buffmode on")
            party({ "Bob-Stone", "Cid-Rock" })
            assert.are.same({ "> Bob Stone: Mark of the Wild", "Cid Rock: Mark of the Wild" }, rows())
            click(2)
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
        end)
    end)

    describe("a new file after an update", function()
        it("asks for a restart when only BuffList.lua is new, and the button doesn't error", function()
            wow.reset()
            local loaded = {}
            local _, files = wow.parseToc()
            for _, file in ipairs(files) do
                if file ~= "BuffList.lua" then assert(loadfile(wow.ROOT .. file))(wow.ADDON_NAME, loaded) end
            end
            wow.fire("ADDON_LOADED", wow.ADDON_NAME)
            wow.fire("PLAYER_ENTERING_WORLD", true, false)
            assert.are.same({}, wow.errors)
            assert.is_truthy(table.concat(wow.printed, "\n"):find("Restart the game", 1, true))
        end)
    end)

    describe("you in the list (buff mode buffs you too, #198)", function()
        local function bootSelf()
            ns = wow.boot({ buffSelf = true, before = function(state)
                state.class = "DRUID"
                state.knownSpells = { [MOTW_1] = true, [MOTW] = true, [THORNS_1] = true }
            end })
            button = ns.BuffButton.Frame()
            slash("buffmode on")
        end

        it("lists you as 'You' with your buff, first, and the button casts it on you", function()
            bootSelf()
            party({ "Ann-Vale" })
            assert.are.same({ "> You: Mark of the Wild", "Ann Vale: Mark of the Wild" }, rows())
            assert.is_truthy(button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
                :find("/cast [@player,nodead] Mark of the Wild", 1, true))
        end)

        it("a click on another row, and back on yours, changes the next offer", function()
            bootSelf()
            party({ "Ann-Vale" })
            click(2)
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
            assert.are.same({ "You: Mark of the Wild", "> Ann Vale: Mark of the Wild" }, rows())
            click(1)
            assert.are.equal("You", button.title:GetText())
            assert.are.same({ "> You: Mark of the Wild", "Ann Vale: Mark of the Wild" }, rows())
        end)
    end)

    describe("combat", function()
        it("is hidden in combat and shown again after", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            assert.is_true(ns.BuffList.Frame():IsShown())
            wow.enterCombat()
            assert.is_false(ns.BuffList.Frame():IsShown())
            wow.advance(10)
            assert.is_false(ns.BuffList.Frame():IsShown(), "a recheck in combat doesn't bring it back")
            click(1)
            assert.is_nil(armed(), "a click in combat changes nothing")
            wow.leaveCombat()
            assert.is_true(ns.BuffList.Frame():IsShown())
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
        end)

        it("forgets a choice when a fight starts", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            click(2)
            wow.enterCombat()
            wow.leaveCombat()
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
        end)
    end)

    describe("bad input (black)", function()
        it("hides when the list is empty", function()
            slash("buffmode on")
            party({ "Ann-Vale" })
            assert.is_true(ns.BuffList.Frame():IsShown())
            party({})
            assert.is_false(ns.BuffList.Frame():IsShown())
        end)

        it("shows a very long name on one line, cut by the game, without breaking the list", function()
            slash("buffmode on")
            local long = string.rep("A", 12) .. "-" .. string.rep("B", 12)
            party({ long, "Cid-Rock" })
            local row = ns.BuffList.Rows()[1]
            assert.is_false(row.text.wordWrap, "one line: the game cuts the rest")
            assert.are.equal(2, #rows())
        end)

        it("leaves out a member whose name can't be read, as the button does", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            wow.state.units.party1.name = wow.secret("Ann")
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.are.same({ "> Cid Rock: Mark of the Wild" }, rows())
            assert.are.equal("Cid Rock: Mark of the Wild", armed())
        end)

        it("shows names with escape codes as plain text", function()
            slash("buffmode on")
            party({ "Ann-Vale" })
            wow.state.units.party1.name = "A|cffff0000nn"
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            for _, text in ipairs(rows()) do assert.is_nil(text:find("|", 1, true)) end
        end)

        it("ignores a click on a row that is gone, and a choice of nobody", function()
            slash("buffmode on")
            party({ "Ann-Vale" })
            ns.BuffButton.Choose(nil)
            ns.BuffButton.Choose(42)
            ns.BuffButton.Choose("Nobody-Nowhere")
            ns.BuffButton.Choose(wow.secret("Ann-Vale"))
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
        end)
    end)

    describe("the list's own rules", function()
        local function offers(n, name)
            local out = {}
            for i = 1, n do
                out[i] = { name = (name or "Mem") .. i .. "-Realm", spell = "Mark of the Wild", buff = {} }
            end
            return out
        end

        it("returns the first offer it found, which is also first in the list", function()
            owe("Bob", "nameplate1")
            owe("Dan", "nameplate2")
            slash("buffmode on")
            party({ "Ann-Vale" })
            local all = {}
            local first = ns.Offers.Current(all)
            assert.are.equal("Dan-Stone", first.name, "the newest favour is first")
            assert.are.equal(first, all[1])
            assert.are.equal("Bob-Stone", all[2].name)
            local group = {}
            local member = ns.GroupBuffs.Next(group)
            assert.are.equal("Ann-Vale", member.name)
            assert.are.equal(member, group[1])
        end)

        it("leaves out an offer the button could not cast, as the button empties", function()
            -- Every buff of yours is unsafe: a later one would get its row (#313).
            local saved = {}
            for _, id in ipairs({ MOTW_1, MOTW, 9910, 9756, 8914, 1075, 782, THORNS_1 }) do
                saved[id] = wow.SPELL_NAMES[id]
                wow.SPELL_NAMES[id] = saved[id] and (saved[id] .. ";")
            end
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            for id, name in pairs(saved) do wow.SPELL_NAMES[id] = name end
            assert.are.same({}, rows())
            assert.is_nil(armed())
            assert.are.equal("the name or spell can't be put in a macro safely", button.subtitle:GetText())
        end)

        it("offers the next buff it can cast when a player's first could not be cast, theirs or the next player's (#313)", function()
            local saved = { wow.SPELL_NAMES[MOTW_1], wow.SPELL_NAMES[MOTW] }
            wow.SPELL_NAMES[MOTW_1], wow.SPELL_NAMES[MOTW] = "Mark; of the Wild", "Mark; of the Wild"
            slash("buffmode on")
            party({ "Cid-Rock", "Ann-Vale" })
            -- Ann already wears your Mark of the Wild, so she is missing only Thorns.
            local ann = wow.state.units.party2
            ann.auras, ann.auraSources = { MOTW_1 }, { "player" }
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            wow.SPELL_NAMES[MOTW_1], wow.SPELL_NAMES[MOTW] = saved[1], saved[2]
            -- Cid's Mark can't be cast, so his Thorns is his row; Ann's is hers.
            assert.are.same({ "> Cid Rock: Thorns", "Ann Vale: Thorns" }, rows())
            assert.are.equal("Cid Rock: Thorns", armed())
        end)

        it("hides rows no longer needed when the list shrinks", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock", "Dot-Fern" })
            party({ "Ann-Vale" })
            assert.is_true(ns.BuffList.Rows()[1]:IsShown())
            assert.is_false(ns.BuffList.Rows()[2]:IsShown())
            assert.is_false(ns.BuffList.Rows()[3]:IsShown())
        end)

        it("never shows it in combat, and ignores a choice made then", function()
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            wow.enterCombat()
            ns.BuffList.Update(button, offers(3), "Mem1-Realm")
            assert.is_false(ns.BuffList.Frame():IsShown())
            ns.BuffButton.Choose("Cid-Rock")
            wow.leaveCombat()
            assert.are.equal("Ann Vale: Mark of the Wild", armed())
        end)

        it("hides when given nothing", function()
            slash("buffmode on")
            party({ "Ann-Vale" })
            ns.BuffList.Update(button, {}, nil)
            assert.is_false(ns.BuffList.Frame():IsShown())
            ns.BuffList.Update(button, nil, nil)
            assert.is_false(ns.BuffList.Frame():IsShown())
        end)

        it("shows names as plain text, whatever escape codes they carry", function()
            slash("buffmode on")
            party({ "Ann-Vale" })
            local bad = { { name = "A|cffff0000nn|r-Vale", spell = "Mark|Hx|h of the Wild", buff = {} } }
            ns.BuffList.Update(button, bad, nil)
            assert.is_nil(ns.BuffList.Rows()[1].text:GetText():find("|", 1, true))
        end)

        it("sits on the button's right, or on its left when the screen has no room there", function()
            slash("buffmode on")
            party({ "Ann-Vale" })
            local function anchor() return ns.BuffList.Frame().points[1] end
            local function expectRight()
                assert.are.same({ "TOPLEFT", button, "TOPRIGHT", 6, 0 }, anchor())
            end
            local function expectLeft()
                assert.are.same({ "TOPRIGHT", button, "TOPLEFT", -6, 0 }, anchor())
            end
            expectRight() -- room on the right, or unknown
            local savedWidth = _G.UIParent.width
            _G.UIParent.width = 1024
            button.right = 1014
            ns.BuffList.Update(button, offers(2), nil)
            expectLeft()
            button.right = 100
            ns.BuffList.Update(button, offers(2), nil)
            expectRight()
            -- Exactly fitting still goes on the right; one pixel more does not.
            button.right = 1024 - 6 - ns.BuffList.WIDTH
            ns.BuffList.Update(button, offers(2), nil)
            expectRight()
            button.right = 1024 - 6 - ns.BuffList.WIDTH + 1
            ns.BuffList.Update(button, offers(2), nil)
            expectLeft()
            -- Measured in screen pixels: the button's scale and the screen's both count.
            button.right = 1014
            button.scale = 0.5
            ns.BuffList.Update(button, offers(2), nil)
            expectRight()
            button.scale = nil
            _G.UIParent.scale = 2
            ns.BuffList.Update(button, offers(2), nil)
            expectRight()
            _G.UIParent.scale = nil
            -- Unreadable readings fall back to the right.
            button.right = "wide"
            ns.BuffList.Update(button, offers(2), nil)
            expectRight()
            _G.UIParent.width = 0
            button.right = 1014
            ns.BuffList.Update(button, offers(2), nil)
            expectRight()
            _G.UIParent.width = savedWidth
        end)

        it("scrolls past six rows, and keeps no more than the most it can ever need", function()
            slash("buffmode on")
            party({ "Ann-Vale" })
            ns.BuffList.Update(button, offers(10), nil)
            assert.are.equal(6 * 18, ns.BuffList.Frame().height, "six rows are shown")
            local content = ns.BuffList.Rows()[1].parent
            assert.are.equal(10 * 18, content.height, "the rows beyond them are reached by scrolling")
            assert.are.equal(content, ns.BuffList.Frame().scroll.scrollChild)
            ns.BuffList.Update(button, offers(2), nil)
            assert.are.equal(2 * 18, ns.BuffList.Frame().height, "a short list is no taller than its rows")
            assert.are.equal(2 * 18, content.height)
            ns.BuffList.Update(button, offers(10), nil)
            ns.BuffList.Update(button, offers(70), nil)
            assert.are.equal(ns.BuffList.MAX_ROWS, #ns.BuffList.ShownOffers())
            assert.is_nil(ns.BuffList.Rows()[ns.BuffList.MAX_ROWS + 1])
        end)
    end)

    describe("a storm of roster changes (red)", function()
        it("keeps the list and the button consistent", function()
            random.seed(43)
            slash("buffmode on")
            local pool = { "Ann-Vale", "Cid-Rock", "Dot-Fern", "Eve-Glen", "Fay-Hill", "Gus-Moor" }
            local group = {}
            local sawEmpty, sawLaterMark = 0, 0
            for _ = 1, 150 do
                local roll = random.random(6)
                if roll ~= 2 then
                    group = {}
                    if roll ~= 6 then -- a 6 empties the party
                        for _, n in ipairs(pool) do if random.random(2) == 1 then group[#group + 1] = n end end
                    end
                end
                if roll == 1 and #group > 0 then
                    party(group)
                    local shown = rows()
                    if #shown > 0 then click(random.random(#shown)) end
                elseif roll == 2 then
                    wow.enterCombat(); click(1); wow.leaveCombat()
                else
                    party(group)
                end
                -- Worked out from the simulated client: the button holds a
                -- member of the group exactly when the list shows one, and
                -- the member it holds is on the list.
                local shown = rows()
                local macroTarget = armed() and armed():match("^(.-):")
                if #shown == 0 then
                    sawEmpty = sawEmpty + 1
                    assert.is_nil(macroTarget)
                    assert.is_false(ns.BuffList.Frame() ~= nil and ns.BuffList.Frame():IsShown(), "no empty box left up")
                else
                    local wanted = {}
                    for _, n in ipairs(group) do wanted[(n:gsub("-", " "))] = true end
                    local marked
                    for _, text in ipairs(shown) do
                        local name = text:gsub("^> ", ""):match("^(.-):")
                        assert.is_true(wanted[name], name .. " is in the group")
                        if text:sub(1, 2) == "> " then
                            assert.is_nil(marked, "one mark only")
                            marked = name
                            if text ~= shown[1] then sawLaterMark = sawLaterMark + 1 end
                        end
                    end
                    assert.are.equal(marked, (macroTarget:gsub("-", " ")))
                end
            end
            assert.is_true(sawEmpty > 0, "the storm reached an empty list")
            assert.is_true(sawLaterMark > 0, "the storm reached a mark on a row other than the first")
        end)
    end)
end)

describe("A group cast in the list (#227)", function()
    local ns, button
    local BRILLIANCE = 23028

    local function boot()
        ns = wow.boot({ before = function(state)
            state.class = "MAGE"
            state.knownSpells = { [INTELLECT] = true, [BRILLIANCE] = true }
            state.items = { [wow.ITEM.arcanePowder] = 5 }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
    end

    local function group(kind, names)
        wow.setGroup(kind, names)
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function rows()
        local out = {}
        local frame = ns.BuffList.Frame()
        if not frame or not frame:IsShown() then return out end
        for _, row in ipairs(ns.BuffList.Rows()) do
            if row:IsShown() then out[#out + 1] = row.text:GetText() end
        end
        return out
    end

    local function armed()
        local text = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    local function click(i) ns.BuffList.Rows()[i].scripts.OnClick(ns.BuffList.Rows()[i]) end

    describe("white", function()
        it("shows a party's group cast as one row, not the members it covers", function()
            boot()
            group("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            assert.are.same({ "> Party (4): Arcane Brilliance" }, rows())
            assert.are.equal("Ann Vale: Arcane Brilliance", armed())
            assert.are.equal(0, #wow.casts, "listing casts nothing")
        end)

        it("shows a raid subgroup's cast as 'Group 3 (4)', and the rest singly", function()
            boot()
            group("raid", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane" })
            for i, g in ipairs({ 1, 3, 3, 3, 3, 1, 1 }) do wow.state.units["raid" .. i].subgroup = g end
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            assert.are.same({
                "> Group 3 (4): Arcane Brilliance",
                "Ann Vale: Arcane Intellect",
                "Fay Reed: Arcane Intellect",
                "Gus Lane: Arcane Intellect",
            }, rows())
        end)

        it("clicking the group row arms the group cast; another member's row arms their single buff", function()
            boot()
            group("raid", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane" })
            for i, g in ipairs({ 1, 3, 3, 3, 3, 1, 1 }) do wow.state.units["raid" .. i].subgroup = g end
            wow.fire("GROUP_ROSTER_UPDATE")
            wow.advance(0)
            click(3)
            assert.are.equal("Fay Reed: Arcane Intellect", armed())
            assert.are.equal("Fay Reed", button.title:GetText())
            assert.are.equal("Group 3 (4): Arcane Brilliance", rows()[1])
            click(1)
            assert.are.equal("Bo Fern: Arcane Brilliance", armed())
            assert.are.equal("Group 3 (4 missing)", button.title:GetText())
            assert.are.equal("> Group 3 (4): Arcane Brilliance", rows()[1])
            assert.are.equal(0, #wow.casts, "a click casts nothing")
        end)

        it("the group row goes once its cast lands", function()
            boot()
            group("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            wow.pressKey("MOUSEWHEELUP")
            assert.are.equal(1, #wow.casts)
            ns.BuffButton.Refresh()
            assert.are.same({}, rows())
        end)


        it("keeps the covered members' rows when the group cast isn't in the list (its aim is owed a favour)", function()
            boot()
            slash("buffmode off")
            wow.addUnit("nameplate1", { name = "Ann", surname = "Vale", class = "MAGE", id = "Ann-Vale" })
            wow.gainBuff({ sourceUnit = "nameplate1", name = "Arcane Intellect", spellId = INTELLECT })
            slash("buffmode on")
            assert.are.equal(1, ns.Offers.Count(), "a favour is owed to Ann")
            group("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            local text = table.concat(rows(), "|")
            assert.is_truthy(text:find("> Ann Vale: Arcane Intellect", 1, true), text)
            for _, who in ipairs({ "Bo Fern", "Cid Rock", "Dot Moss" }) do
                assert.is_truthy(text:find(who .. ": Arcane Intellect", 1, true), who .. " keeps a row")
            end
        end)

        it("keeps the covered members' rows, and the button armed, when the group cast can't go in a macro", function()
            boot()
            local saved = wow.SPELL_NAMES[BRILLIANCE]
            wow.SPELL_NAMES[BRILLIANCE] = "Arcane; Brilliance"
            group("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            local text = table.concat(rows(), "|")
            wow.SPELL_NAMES[BRILLIANCE] = saved
            -- The group cast's aim is covered too: it keeps its own row (#252).
            for _, who in ipairs({ "Ann Vale", "Bo Fern", "Cid Rock", "Dot Moss" }) do
                assert.is_truthy(text:find(who .. ": Arcane Intellect", 1, true), who .. " keeps a row: " .. text)
            end
            assert.is_nil(text:find("Party (", 1, true), "no group row: its macro can't be built")
            assert.is_truthy(armed():find("Arcane Intellect", 1, true), "the button holds a single buff, not nothing")
        end)

        it("shows the longest group rows whole: no code cuts the text, and the list is wide enough for the budget", function()
            boot()
            group("party", { "Ann-Vale" })
            -- The width of each, as the UI simulator measured it (run 42749343166).
            local worst = {
                { "your party", 4, "Prayer of Shadow Protection", 208 },
                { "Group 3", 5, "Prayer of Shadow Protection", 223 },
                { "Warlocks", 12, "Greater Blessing of Wisdom", 230 },
                { "Warriors", 40, "Greater Blessing of Wisdom", 228 },
            }
            for _, w in ipairs(worst) do
                ns.BuffList.Update(button, { { name = "Ann-Vale", spell = w[3], buff = {},
                    cast = { label = w[1], count = w[2] } } }, "Ann-Vale")
                local text = ns.BuffList.Rows()[1].text:GetText()
                assert.are.equal(string.format("> %s (%d): %s", w[1] == "your party" and "Party" or w[1], w[2], w[3]), text)
                -- The measured text, plus the scrollbar (22) and the row's insets (8),
                -- fits the list (the +1 is the UI scenario's own rule): a narrower
                -- list cuts this row. The game's own font is checked in game (#214).
                assert.is_true(w[4] + 30 <= ns.BuffList.WIDTH + 1, text .. " fits the list's width")
            end
        end)

        it("is hidden in combat", function()
            boot()
            group("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            wow.enterCombat()
            assert.is_false(ns.BuffList.Frame():IsShown())
        end)
    end)

    describe("black", function()
        it("a group cast whose macro can't be built leaves its aim, and every member it covered, with their own single rows", function()
            boot()
            local saved = wow.SPELL_NAMES[BRILLIANCE]
            wow.SPELL_NAMES[BRILLIANCE] = "Arcane; Brilliance"
            group("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
            local text = table.concat(rows(), "|")
            -- Click another member's row, then the aim's: each arms their own single buff.
            local function clickRow(who)
                for k, row in ipairs(rows()) do
                    if row:find(who, 1, true) then click(k) return true end
                end
                return false
            end
            local clickedDot = clickRow("Dot Moss")
            local armedDot = armed()
            local clickedAnn = clickRow("Ann Vale")
            local armedAnn = armed()
            local casts = #wow.casts
            -- Put the name back before any assertion, so a failure can't leak into other tests.
            wow.SPELL_NAMES[BRILLIANCE] = saved
            for _, who in ipairs({ "Ann Vale", "Bo Fern", "Cid Rock", "Dot Moss" }) do
                assert.is_truthy(text:find(who .. ": Arcane Intellect", 1, true), who .. " has a single row: " .. text)
            end
            assert.is_true(clickedDot and clickedAnn, "both rows were there to click")
            assert.are.equal("Dot Moss: Arcane Intellect", armedDot)
            assert.are.equal("Ann Vale: Arcane Intellect", armedAnn)
            assert.are.equal(0, casts, "a click casts nothing")
        end)

        local function show(cast)
            boot()
            group("party", { "Ann-Vale" })
            ns.BuffList.Update(button, { { name = "Ann-Vale", spell = "Arcane Brilliance", buff = {}, cast = cast } },
                "Ann-Vale")
            return ns.BuffList.Rows()[1].text:GetText()
        end

        it("never errors on a damaged, secret or odd label or count, and falls back to a single row", function()
            assert.are.equal("> Ann Vale: Arcane Brilliance", show(wow.secret and { label = wow.secret("Group 3"), count = 4 }))
            assert.are.equal("> Ann Vale: Arcane Brilliance", show({ label = 5, count = 4 }))
            assert.are.equal("> Ann Vale: Arcane Brilliance", show({ label = "Group 3", count = "4" }))
            assert.are.equal("> Ann Vale: Arcane Brilliance", show({ label = "Group 3", count = 0 / 0 }))
            assert.are.equal("> Ann Vale: Arcane Brilliance", show({ label = "|| ", count = 4 }))
            assert.are.equal("> Ann Vale: Arcane Brilliance", show("damaged"))
            assert.are.same({}, wow.errors)
        end)

        it("shows escape codes in a label as plain text, on one line", function()
            local text = show({ label = "Gr|cffff0000oup\n3", count = 4 })
            assert.are.equal("> Grcffff0000oup 3 (4): Arcane Brilliance", text)
            assert.is_false(ns.BuffList.Rows()[1].text.wordWrap)
        end)
    end)

    describe("red", function()
        it("a storm of raid groups and clicks lists no covered member singly, one row per player, one mark", function()
            boot()
            random.seed(227)
            for _ = 1, 5 do random.random() end -- past the generator's near-zero first draws (#38)
            local names = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss", "Eve-Hill", "Fay-Reed", "Gus-Lane" }
            local groupRows = 0
            for step = 1, 60 do
                group("raid", names)
                for i = 1, #names do wow.state.units["raid" .. i].subgroup = random.random(1, 3) end
                wow.fire("GROUP_ROSTER_UPDATE")
                wow.advance(0)
                if random.random(1, 3) == 1 then click(random.random(1, math.max(1, #rows()))) end
                -- Worked out from the simulated client's own units: nobody wears Intellect,
                -- so every member of a group row's subgroup is covered by it.
                local subgroupOf = {}
                for i, n in ipairs(names) do subgroupOf[(n:gsub("-", " "))] = wow.state.units["raid" .. i].subgroup end
                local singles, groups, marks, marked = {}, {}, 0, nil
                for _, text in ipairs(rows()) do
                    local plain = text:gsub("^> ", "")
                    local n = plain:match("^Group (%d) %(%d+%): ")
                    if n then groups[#groups + 1] = tonumber(n) else
                        local who = plain:match("^(.-):")
                        assert.is_nil(singles[who], who .. " is listed twice (step " .. step .. ")")
                        singles[who] = true
                    end
                    if text:sub(1, 2) == "> " then marks = marks + 1 marked = plain end
                end
                groupRows = groupRows + #groups
                for _, g in ipairs(groups) do
                    for who in pairs(singles) do
                        assert.are_not.equal(g, subgroupOf[who], who .. " is covered by Group " .. g .. " (step " .. step .. ")")
                    end
                end
                if #rows() > 0 then
                    assert.are.equal(1, marks, "exactly one row is marked")
                    -- The marked row is what the button holds.
                    local target = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
                        :match("/targetexact ([^\n]+)")
                    local groupNo = marked:match("^Group (%d)")
                    if groupNo then
                        assert.are.equal(tonumber(groupNo), subgroupOf[(target:gsub("-", " "))], "a group row's aim is in it")
                    else
                        assert.are.equal(marked:match("^(.-):"), (target:gsub("-", " ")))
                    end
                end
            end
            assert.is_true(groupRows > 0, "the storm reached group rows")
            assert.are.same({}, wow.errors)
        end)
    end)
end)

describe("Two group casts aimed at the same player (#305)", function()
    local ns, button
    local FORT, PRAYER_FORT = 10938, 21564
    local SPIRIT, PRAYER_SPIRIT = 27841, 27681

    local function boot()
        ns = wow.boot({ before = function(state)
            state.class = "PRIEST"
            state.knownSpells = { [FORT] = true, [PRAYER_FORT] = true, [SPIRIT] = true, [PRAYER_SPIRIT] = true }
            state.items = { [wow.ITEM.sacredCandle] = 5 }
        end })
        button = ns.BuffButton.Frame()
        slash("buffmode on")
    end

    -- A party of mages: each is missing both Fortitude and Divine Spirit.
    local function party()
        wow.setGroup("party", { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" })
        for i = 1, 4 do wow.state.units["party" .. i].class = "MAGE" end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function rows()
        local out = {}
        local frame = ns.BuffList.Frame()
        if not frame or not frame:IsShown() then return out end
        for _, row in ipairs(ns.BuffList.Rows()) do
            if row:IsShown() then out[#out + 1] = row.text:GetText() end
        end
        return out
    end

    local function armed()
        local text = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    -- Both Fortitude spells (the group version and the single buff) can't go
    -- in a macro, so the button drops every Fortitude offer, Ann's included.
    local function unsafeFortitude()
        local saved = { [PRAYER_FORT] = wow.SPELL_NAMES[PRAYER_FORT], [FORT] = wow.SPELL_NAMES[FORT] }
        wow.SPELL_NAMES[PRAYER_FORT] = "Prayer; of Fortitude"
        wow.SPELL_NAMES[FORT] = "Power; Word: Fortitude"
        return function() for id, name in pairs(saved) do wow.SPELL_NAMES[id] = name end end
    end

    local function click(i) ns.BuffList.Rows()[i].scripts.OnClick(ns.BuffList.Rows()[i]) end

    describe("white", function()
        it("lists each group cast aimed at a player as an entry of its own, from the button's own rules", function()
            boot()
            party()
            local list = {}
            ns.GroupBuffs.Next(list)
            local groups = {}
            for _, offer in ipairs(list) do
                if offer.cast then groups[#groups + 1] = offer.name .. ": " .. offer.spell end
            end
            assert.are.same({ "Ann-Vale: Prayer of Fortitude", "Ann-Vale: Prayer of Spirit" }, groups)
        end)

        -- Buff mode's "missing your buff" trigger reads the same rules (#272):
        -- there each member and buff is one entry, a group offer and its aim's
        -- single offer alike, so a second buff gone missing still counts.
        it("leaves Missing one entry for each member and buff, the group offers' aims included", function()
            boot()
            party()
            local list = ns.GroupBuffs.Missing()
            local seen, count = {}, 0
            for _, offer in ipairs(list) do
                local key = offer.name .. ": " .. offer.buff.key
                assert.is_nil(seen[key], key .. " is listed twice")
                seen[key] = true
                count = count + 1
            end
            for _, who in ipairs({ "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" }) do
                for _, key in ipairs({ "fortitude", "spirit" }) do
                    assert.is_true(seen[who .. ": " .. key], who .. " is missing " .. key)
                end
            end
            assert.are.equal(8, count)
        end)

        it("still keeps one row per player, the first group cast, which hides the singles it covers", function()
            boot()
            party()
            assert.are.same({ "> Party (4): Prayer of Fortitude" }, rows())
            assert.are.equal("Ann Vale: Prayer of Fortitude", armed())
            assert.are.equal(0, #wow.casts, "listing casts nothing")
        end)
    end)

    describe("black", function()
        it("when the first of two group casts aimed at the same player can't go in a macro, the second still gets its row", function()
            boot()
            local restore = unsafeFortitude()
            party()
            local listed = rows()
            local armedFirst = armed()
            local clicked = #listed > 0
            if clicked then click(1) end
            local armedClicked = armed()
            local castsBefore = #wow.casts
            wow.pressKey("MOUSEWHEELUP")
            local cast = wow.casts[1]
            -- Put the names back before any assertion, so a failure can't leak into other tests.
            restore()
            assert.are.same({ "> Party (4): Prayer of Spirit" }, listed, "Ann's second group cast has its row, covering everyone")
            assert.are.equal("Ann Vale: Prayer of Spirit", armedFirst)
            assert.is_true(clicked, "the row was there to click")
            assert.are.equal("Ann Vale: Prayer of Spirit", armedClicked)
            assert.are.equal(0, castsBefore, "listing and clicking cast nothing")
            assert.are.equal(PRAYER_SPIRIT, cast and cast.id, "the button's press casts it")
            assert.are.same({}, wow.errors)
        end)
    end)
end)

describe("A member's later single buff (#313)", function()
    local ns, button
    local FORT, PRAYER_FORT = 10938, 21564
    local SPIRIT, PRAYER_SPIRIT = 27841, 27681
    local NAMES = { "Ann-Vale", "Bo-Fern", "Cid-Rock", "Dot-Moss" }

    -- A priest giving single buffs only: "Use group versions" is off.
    local function boot()
        ns = wow.boot({ before = function(state)
            state.class = "PRIEST"
            state.knownSpells = { [FORT] = true, [PRAYER_FORT] = true, [SPIRIT] = true, [PRAYER_SPIRIT] = true }
            state.items = { [wow.ITEM.sacredCandle] = 5 }
        end })
        button = ns.BuffButton.Frame()
        ns.db.buffBack.groupVersions = false
        slash("buffmode on")
    end

    -- A party of mages: each is missing both Fortitude and Divine Spirit.
    local function party()
        wow.setGroup("party", NAMES)
        for i = 1, 4 do wow.state.units["party" .. i].class = "MAGE" end
        wow.fire("GROUP_ROSTER_UPDATE")
        wow.advance(0)
    end

    local function rows()
        local out = {}
        local frame = ns.BuffList.Frame()
        if not frame or not frame:IsShown() then return out end
        for _, row in ipairs(ns.BuffList.Rows()) do
            if row:IsShown() then out[#out + 1] = row.text:GetText() end
        end
        return out
    end

    local function armed()
        local text = button:GetAttribute(ns.BuffButton.SECURE_ATTRIBUTE.leftButtonMacroText)
        if not text then return nil end
        return text:match("/targetexact ([^\n]+)") .. ": " .. text:match("/cast %[help,nodead%] ([^\n]+)")
    end

    local function click(i) ns.BuffList.Rows()[i].scripts.OnClick(ns.BuffList.Rows()[i]) end

    describe("white", function()
        it("lists each single buff a member lacks as an entry of its own, from the button's own rules", function()
            boot()
            party()
            local list = {}
            ns.GroupBuffs.Next(list)
            local singles = {}
            for _, offer in ipairs(list) do
                assert.is_nil(offer.cast, "group versions are off")
                singles[#singles + 1] = offer.name .. ": " .. offer.spell
            end
            -- Your buff order: Fortitude to everyone before Divine Spirit to anyone.
            assert.are.same({
                "Ann-Vale: Power Word: Fortitude", "Bo-Fern: Power Word: Fortitude",
                "Cid-Rock: Power Word: Fortitude", "Dot-Moss: Power Word: Fortitude",
                "Ann-Vale: Divine Spirit", "Bo-Fern: Divine Spirit",
                "Cid-Rock: Divine Spirit", "Dot-Moss: Divine Spirit",
            }, singles)
        end)

        it("with every spell buildable, keeps one row per player, their first buff", function()
            boot()
            party()
            assert.are.same({
                "> Ann Vale: Power Word: Fortitude", "Bo Fern: Power Word: Fortitude",
                "Cid Rock: Power Word: Fortitude", "Dot Moss: Power Word: Fortitude",
            }, rows())
            assert.are.equal("Ann Vale: Power Word: Fortitude", armed())
            assert.are.equal(0, #wow.casts, "listing casts nothing")
        end)
    end)

    describe("black", function()
        it("when a member's first single buff can't go in a macro, their next buff still gets its row", function()
            boot()
            local saved = wow.SPELL_NAMES[FORT]
            wow.SPELL_NAMES[FORT] = "Power; Word: Fortitude"
            party()
            local listed = rows()
            local armedFirst = armed()
            local clicked = #listed >= 3
            if clicked then click(3) end
            local armedClicked = armed()
            local castsBefore = #wow.casts
            wow.pressKey("MOUSEWHEELUP")
            local cast = wow.casts[1]
            -- Put the name back before any assertion, so a failure can't leak into other tests.
            wow.SPELL_NAMES[FORT] = saved
            assert.are.same({
                "> Ann Vale: Divine Spirit", "Bo Fern: Divine Spirit",
                "Cid Rock: Divine Spirit", "Dot Moss: Divine Spirit",
            }, listed, "each member's Divine Spirit has its row")
            assert.are.equal("Ann Vale: Divine Spirit", armedFirst)
            assert.is_true(clicked, "Cid's row was there to click")
            assert.are.equal("Cid Rock: Divine Spirit", armedClicked)
            assert.are.equal(0, castsBefore, "listing and clicking cast nothing")
            assert.are.equal(SPIRIT, cast and cast.id, "the button's press casts it")
            assert.are.equal("Cid-Rock", cast and cast.target)
            assert.are.same({}, wow.errors)
        end)
    end)
end)
