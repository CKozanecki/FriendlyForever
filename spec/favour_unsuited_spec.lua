-- Spec: #419
-- A favour none of your buffs suit isn't owed, before the #408 choice too:
-- it isn't counted, holds no place on the button, and never turns buff mode
-- on or keeps it on. A favour whose class can't be read still counts (it
-- may yet show one your buffs suit).
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local INTELLECT = 10157
local MOTW = 9885

-- The classes that use mana, written out here, not read from the addon:
-- Arcane Intellect is for them alone.
local MANA = { PALADIN = true, HUNTER = true, PRIEST = true, SHAMAN = true, MAGE = true, WARLOCK = true,
    DRUID = true }
local CLASSES = { "WARRIOR", "ROGUE", "PALADIN", "HUNTER", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

describe("A favour none of your buffs suit isn't owed, before the #408 choice too (#419)", function()
    local ns

    -- A mage who knows only Arcane Intellect, with only the "someone buffed
    -- you" trigger on. choice: "kept" or "new"; nil leaves it pending.
    local function boot(choice)
        ns = wow.boot({ autoBuffMode = true, buffDefaults = true,
            db = { buffBack = { autoOnJoin = false, autoOnDeath = false, autoOnMissing = false,
                autoOnBuffed = true } },
            before = function(state)
                state.class = "MAGE"
                state.knownSpells = { [INTELLECT] = true }
            end })
        ns.BuffButton.Frame()
        if choice then assert.is_true(ns.BuffRules.Choose(choice)) end
        assert.are.equal(choice or "pending", ns.BuffRules.Choice())
    end

    -- A stranger of class (nil: one that can't be read) buffs you.
    -- Each a new name: letters only, as the game's names are.
    local n = 0
    local function buffedBy(class)
        n = n + 1
        local name = "Str" .. string.char(97 + math.floor(n / 26) % 26, 97 + n % 26)
        local token = "nameplate" .. (n % 40 + 1)
        wow.addUnit(token, { name = name, surname = "Vale", id = name .. "-Vale", class = class })
        wow.gainBuff({ sourceUnit = token, name = "Mark of the Wild", spellId = MOTW })
        return name .. "-Vale"
    end

    for _, choice in ipairs({ false, "kept", "new" }) do
        local when = choice and ("after choosing \"" .. choice .. "\"") or "while the choice is pending"
        it(when .. ", a warrior's favour to a mage with only Intellect isn't counted and turns nothing on (white)",
            function()
            boot(choice or nil)
            buffedBy("WARRIOR")
            assert.are.equal(0, ns.Offers.Count())
            assert.is_false(ns.BuffMode.IsOn(), "nothing to give them: buff mode stays off")
            assert.is_nil(ns.BuffMode.LentKey())
            assert.are.same({ nil, "nobody is owed a buff" }, { ns.Offers.Current() })
        end)
    end

    it("while pending, a priest's favour is still owed, offered Intellect, and turns buff mode on (white)", function()
        boot(nil)
        buffedBy("PRIEST")
        assert.are.equal(1, ns.Offers.Count())
        assert.is_true(ns.BuffMode.IsOn())
        local offer = ns.Offers.Current()
        assert.are.equal("Arcane Intellect", offer.spell)
    end)

    it("while pending, a favour whose class can't be read still counts (black)", function()
        boot(nil)
        buffedBy(nil)
        assert.are.equal(1, ns.Offers.Count())
        assert.is_true(ns.BuffMode.IsOn(), "their class may yet show one Intellect suits")
    end)

    it("while pending, a mage who forgets Intellect owes nobody, and buff mode doesn't stay on for them (white)",
        function()
        boot(nil)
        buffedBy("PRIEST")
        assert.is_true(ns.BuffMode.IsOn())
        wow.state.knownSpells = {}
        wow.fire("SPELLS_CHANGED")
        assert.are.equal(0, ns.Offers.Count())
        ns.BuffButton.Refresh()
        assert.is_false(ns.BuffMode.IsOn(), "nothing to give: buff mode goes off")
    end)

    it("a storm of favours from every class, with Intellect learned and forgotten, never leaves buff mode on with "
        .. "nothing to give (red)", function()
        for _, seed in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) do
            random.seed(seed)
            boot(nil)
            -- Who has buffed you so far, and their class as the game shows it:
            -- the storm stays well under the favour limit and the time they last.
            local owed = {}
            for _ = 1, 15 do
                local roll = random.random(4)
                if roll == 1 then
                    local known = wow.state.knownSpells[INTELLECT] == true
                    wow.state.knownSpells = known and {} or { [INTELLECT] = true }
                    wow.fire("SPELLS_CHANGED")
                else
                    local pick = random.random(#CLASSES + 1)
                    local class = CLASSES[pick] -- one past the end: a class that can't be read
                    owed[buffedBy(class)] = { class = class }
                end
                wow.advance(random.random(1, 5))
                ns.BuffButton.Refresh()
                -- Worked out from the client's own state, not the addon's.
                local suits = 0
                if wow.state.knownSpells[INTELLECT] then
                    for _, f in pairs(owed) do
                        if f.class == nil or MANA[f.class] then suits = suits + 1 end
                    end
                end
                assert.are.equal(suits, ns.Offers.Count(), "seed " .. seed)
                if suits == 0 then
                    assert.is_false(ns.BuffMode.IsOn(), "seed " .. seed .. ": on with nothing to give")
                    assert.is_nil(ns.Offers.Current(), "seed " .. seed)
                end
                assert.are.same({}, wow.errors, "seed " .. seed)
            end
        end
    end)
end)
