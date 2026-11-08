-- Spec: #43
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
        for i, offer in ipairs(ns.BuffList.ShownOffers()) do
            out[i] = ns.BuffList.Rows()[i].text:GetText()
            assert.is_true(ns.BuffList.Rows()[i]:IsShown())
            assert.is_truthy(offer)
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
            slash("buffmode on")
            party({ "Ann-Vale" })
            local all = {}
            local first = ns.Offers.Current(all)
            assert.are.equal("Bob-Stone", first.name)
            assert.are.equal(first, all[1])
            local group = {}
            local member = ns.GroupBuffs.Next(group)
            assert.are.equal("Ann-Vale", member.name)
            assert.are.equal(member, group[1])
        end)

        it("leaves out an offer the button could not cast, as the button empties", function()
            local saved = { wow.SPELL_NAMES[MOTW_1], wow.SPELL_NAMES[MOTW] }
            wow.SPELL_NAMES[MOTW_1], wow.SPELL_NAMES[MOTW] = "Mark; of the Wild", "Mark; of the Wild"
            slash("buffmode on")
            party({ "Ann-Vale", "Cid-Rock" })
            wow.SPELL_NAMES[MOTW_1], wow.SPELL_NAMES[MOTW] = saved[1], saved[2]
            assert.are.same({}, rows())
            assert.is_nil(armed())
            assert.are.equal("the name or spell can't be put in a macro safely", button.subtitle:GetText())
        end)

        it("offers the next player when the first one's buff could not be cast", function()
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
            assert.are.same({ "> Ann Vale: Thorns" }, rows())
            assert.are.equal("Ann Vale: Thorns", armed())
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

        it("scrolls past six rows, and keeps no more than the most it can ever need", function()
            slash("buffmode on")
            party({ "Ann-Vale" })
            ns.BuffList.Update(button, offers(10), nil)
            assert.are.equal(6 * ns.BuffList.ROW_HEIGHT, ns.BuffList.Frame().height)
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
            for _ = 1, 150 do
                local roll = random.random(5)
                if roll ~= 2 then
                    group = {}
                    for _, n in ipairs(pool) do if random.random(2) == 1 then group[#group + 1] = n end end
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
                    assert.is_nil(macroTarget)
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
                        end
                    end
                    assert.are.equal(marked, (macroTarget:gsub("-", " ")))
                end
            end
        end)
    end)
end)
