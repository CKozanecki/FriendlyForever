-- Spec: #508, #519, #544
-- Each character's own buff settings (#508, the owner's decisions of 19 Nov
-- 2026): weapon buffs, buff mode's key, self-buffs, the buff order and who
-- gets each buff are each character's. A character on a shared profile uses
-- that profile's. Profiles switch with the character. Weapon buffs are reset
-- once, for every character. A character with no record (keyed by realm and
-- name) is new, whatever its level: it copies the account's other settings
-- once, and sees the walkthrough's step about them once.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

local ns

-- The game's characters for these specs. Their levels don't matter: a
-- character the addon hasn't seen is new, whatever its level.
local CHARS = {
    Ann = { name = "Ann", surname = "Vale", level = 60 },
    Bo = { name = "Bo", surname = "Reed", level = 42 },
    Cy = { name = "Cy", surname = "Dunn", level = 1 },
    Di = { name = "Di", surname = "Moss", level = 1 },
}

-- The unset settings, written out here rather than read from the addon.
local UNSET = { weaponBuffs = false, weaponMain = "none", weaponOff = "none", selfBuffs = true,
    buffModeKey = "MOUSEWHEELUP", buffOrder = {}, neverOffer = {} }
local CHECKED = { "weaponBuffs", "weaponMain", "weaponOff", "selfBuffs", "buffModeKey", "buffOrder", "neverOffer" }

local function slash(text) _G.SlashCmdList.FRIENDLYFOREVER(text) end

-- Log in as one of CHARS, with the saved settings db (the same table the
-- last session saved), as the game does after a logout.
local function login(who, db, opts)
    local c = CHARS[who]
    ns = wow.boot({ db = db, walkthrough = opts and opts.walkthrough, welcome = opts and opts.walkthrough,
        before = function(state)
            state.units.player = { name = c.name, surname = c.surname, id = c.name .. "-" .. c.surname,
                isPlayer = true, level = c.level }
            if opts and opts.nameUnread then state.units.player.nameLoading = true end
            if opts and opts.secretRealm then state.secretRealm = true end
        end })
    return ns
end

local function logout()
    wow.fire("PLAYER_LOGOUT")
    return _G.FriendlyForeverDB
end

local function live()
    local out = {}
    for _, field in ipairs(CHECKED) do out[field] = ns.Util.DeepCopy(ns.db.buffBack[field]) end
    return out
end

-- Settings saved by 1.5.0 (schema 8): one account-wide set.
local function v150(buffBack, extra)
    local db = { schemaVersion = 8, enabled = true, walkthrough = { seen = 4, firstRun = false },
        buffBack = buffBack or { weaponBuffs = true, weaponMain = "wizardOil", weaponOff = "sharpening",
            selfBuffs = false, buffModeKey = "F", buffOrder = { "intellect" }, neverOffer = { motw = true },
            whoChoice = "new", whoParty = { intellect = { tanks = true } } } }
    for k, v in pairs(extra or {}) do db[k] = v end
    return db
end
-- A character's copy of them: weapon buffs reset, the rest the account's.
local V150C = { weaponBuffs = false, weaponMain = "none", weaponOff = "none", selfBuffs = false,
    buffModeKey = "F", buffOrder = { "intellect" }, neverOffer = { motw = true } }
-- A character's key and record, written out here.
local function key(who) return "Forever Realm:" .. CHARS[who].name .. "-" .. CHARS[who].surname end
local function rec(who) return ns.db.characters[key(who)] end
local function weapons() return { ns.db.buffBack.weaponBuffs, ns.db.buffBack.weaponMain, ns.db.buffBack.weaponOff } end

describe("Each character's own buff settings (#508)", function()
    after_each(function() _G.FriendlyForeverDB = nil end)

    describe("white", function()
        it("weapon settings changed on one character don't change another's", function()
            login("Ann", v150())
            assert.are.same({ false, "none", "none" }, weapons(), "reset once, for every character")
            ns.db.buffBack.weaponBuffs = true
            ns.db.buffBack.weaponMain = "manaOil"
            login("Bo", logout())
            assert.are.same({ false, "none", "none" }, weapons(), "Bo's start unset, not Ann's")
            ns.db.buffBack.weaponBuffs = true
            ns.db.buffBack.weaponMain = "windfury"
            ns.db.buffBack.weaponOff = "sharpening"
            login("Ann", logout())
            assert.are.same({ true, "manaOil", "none" }, weapons())
            login("Bo", logout())
            assert.are.same({ true, "windfury", "sharpening" }, weapons())
            assert.are.same({}, wow.errors)
        end)

        it("food buffs are each character's own too, as weapon buffs (#544)", function()
            local function food() return { ns.db.buffBack.foodBuffs, ns.db.buffBack.foodItem } end
            login("Ann", v150())
            assert.are.same({ false, 0 }, food(), "off, with no food, from settings saved before food buffs")
            ns.db.buffBack.foodBuffs = true
            ns.db.buffBack.foodItem = 2680
            login("Bo", logout())
            assert.are.same({ false, 0 }, food(), "Bo's start unset, not Ann's")
            ns.db.buffBack.foodBuffs = true
            ns.db.buffBack.foodItem = 12218
            login("Ann", logout())
            assert.are.same({ true, 2680 }, food())
            login("Bo", logout())
            assert.are.same({ true, 12218 }, food())
            -- A character's saved food that isn't one of the list loads as none.
            rec("Ann").settings.foodItem = 117
            login("Ann", logout())
            assert.are.same({ true, 0 }, food())
            assert.are.same({}, wow.errors)
        end)

        it("the buff mode key, self-buffs, buff order and who gets each buff move with the character too",
            function()
            login("Ann", v150())
            assert.are.equal("tanks", next(ns.db.buffBack.whoParty.intellect))
            slash("buffmode key G")
            ns.db.buffBack.selfBuffs = true
            ns.db.buffBack.buffOrder = { "motw" }
            ns.db.buffBack.neverOffer = {}
            ns.db.buffBack.whoParty = { intellect = { healers = true } }
            login("Bo", logout())
            assert.are.same(V150C, live(), "Bo has the account's, weapon buffs reset")
            assert.are.same({ tanks = true }, ns.db.buffBack.whoParty.intellect)
            login("Ann", logout())
            assert.are.same({ weaponBuffs = false, weaponMain = "none", weaponOff = "none",
                selfBuffs = true, buffModeKey = "G", buffOrder = { "motw" }, neverOffer = {} }, live())
            assert.are.same({ healers = true }, ns.db.buffBack.whoParty.intellect)
            assert.are.equal("G", ns.BuffMode.Key(), "buff mode lends Ann's key")
        end)

        it("the first login of an existing character copies the account's values once, and a second doesn't",
            function()
            login("Ann", v150())
            ns.db.buffBack.buffModeKey = "G"
            login("Di", logout())
            assert.are.same(V150C, live(), "the account's 1.5.0 values, not Ann's since")
            assert.are.equal("F", rec("Di").settings.buffModeKey, "the copy is recorded at once")
            ns.db.buffBack.weaponMain = "rockbiter"
            ns.db.buffBack.buffModeKey = "H"
            login("Di", logout())
            assert.are.equal("rockbiter", ns.db.buffBack.weaponMain, "not copied again")
            assert.are.equal("H", ns.db.buffBack.buffModeKey)
            -- Even with Ann's settings live and the seed still kept.
            login("Ann", logout())
            login("Di", logout())
            assert.are.equal("H", ns.db.buffBack.buffModeKey)
            local seedNow = {}
            for _, f in ipairs(CHECKED) do seedNow[f] = ns.db.characterSeed.settings[f] end
            assert.are.same(V150C, seedNow, "the migration ran once: the seed is the 1.5.0 values, weapons reset")
            assert.are.equal(ns.Config.SCHEMA_VERSION, ns.db.schemaVersion)
        end)

        it("a character on a shared profile reads and writes it; others switch back to their own", function()
            login("Ann", v150())
            ns.db.buffBack.weaponMain = "wizardOil"
            slash("profile new Party")
            ns.db.buffBack.weaponMain = "manaOil"
            ns.db.guildLogin.delay = 9
            login("Bo", logout())
            assert.are.equal("Bo", ns.Profiles.Active(), "a new character gets a profile of its own (#519)")
            assert.are.equal("manaOil", ns.db.buffBack.weaponMain, "a copy of the live settings, Party's")
            ns.db.buffBack.weaponMain = "windfury"
            slash("profile use Default")
            assert.are.equal("none", ns.db.buffBack.weaponMain, "Bo's own")
            slash("profile use Party")
            assert.are.equal("manaOil", ns.db.buffBack.weaponMain, "Bo reads Party's")
            assert.are.equal(9, ns.db.guildLogin.delay)
            ns.db.buffBack.weaponOff = "weightstone"
            login("Cy", logout())
            assert.are.equal("Cy", ns.Profiles.Active(), "a new character gets a profile of its own (#519)")
            assert.are.equal("weightstone", ns.db.buffBack.weaponOff, "a copy of Party's, as Bo left it")
            slash("profile use Default")
            assert.are.same(V150C, live(), "Cy's own")
            login("Ann", logout())
            assert.are.equal("Party", ns.Profiles.Active())
            assert.are.equal("weightstone", ns.db.buffBack.weaponOff, "Ann sees what Bo wrote to Party")
            login("Cy", logout())
            assert.are.equal("Default", ns.Profiles.Active(), "Cy chose its own: it switches back")
            assert.are.same(V150C, live())
            login("Ann", logout())
            slash("profile use Default")
            assert.are.equal("wizardOil", ns.db.buffBack.weaponMain, "Ann's own are back")
            assert.are.equal("none", ns.db.buffBack.weaponOff)
            login("Bo", logout())
            assert.are.equal("Party", ns.Profiles.Active(), "Bo still chose Party")
            assert.are.equal("weightstone", ns.db.buffBack.weaponOff)
            assert.are.equal("windfury", ns.db.profiles.Bo.buffBack.weaponMain, "Bo's own profile kept its edit")
            assert.are.equal("manaOil", ns.db.buffBack.weaponMain, "never reaching Party")
            assert.are.same({}, wow.errors)
        end)

        it("a new shared profile's edits, made in place, never reach the character's own", function()
            login("Ann", v150())
            slash("profile new Party")
            -- The options change these lists in place.
            ns.db.buffBack.neverOffer.intellect = true
            table.insert(ns.db.buffBack.buffOrder, "motw")
            ns.db.buffBack.whoParty.intellect.healers = true
            slash("profile use Default")
            assert.are.same(V150C, live(), "Ann's own are as she left them")
            assert.are.same({ tanks = true }, ns.db.buffBack.whoParty.intellect)
            slash("profile use Party")
            assert.are.same({ motw = true, intellect = true }, ns.db.buffBack.neverOffer, "Party kept its edits")
        end)

        it("each new character sees the step about its own settings once; a seen one never does", function()
            login("Ann", v150(), { walkthrough = true })
            local tour = ns.Walkthrough.Frame()
            assert.is_true(tour:IsShown())
            assert.are.equal("What's new: Each character's own buffs", tour.title:GetText(), "the 1.5.2 What's new")
            assert.are.equal(1, ns.Walkthrough.Count(), "one step, not two")
            wow.run(tour.next, "OnClick")
            assert.is_false(tour:IsShown())
            login("Bo", logout(), { walkthrough = true })
            tour = ns.Walkthrough.Frame()
            assert.is_true(tour:IsShown(), "a second character sees it")
            assert.are.equal("Each character's own buffs", tour.title:GetText())
            assert.are.equal(1, ns.Walkthrough.Count())
            assert.is_truthy(tour.stepText:GetText():find("This character's weapon buffs", 1, true))
            local weaponPage = select(3, ns.Options.Pages())
            assert.are.equal(weaponPage.category:GetID(), wow.settings.opened, "Weapon buffs first")
            wow.run(tour.next, "OnClick")
            for _, who in ipairs({ "Bo", "Ann", "Bo" }) do
                login(who, logout(), { walkthrough = true })
                assert.is_false(ns.Walkthrough.Frame():IsShown(), who .. " has seen it")
            end
        end)

        it("tells a character on a shared profile that these settings are the profile's", function()
            login("Ann", v150(nil, { charProfiles = { ["Ann-Vale"] = "Healer", ["Bo-Reed"] = "Healer" },
                activeProfile = "Healer",
                profiles = { Healer = { schemaVersion = 8 }, Default = { schemaVersion = 8 } } }),
                { walkthrough = true })
            local text = ns.Walkthrough.Frame().stepText:GetText()
            assert.is_truthy(text:find("uses the shared profile Healer", 1, true))
            assert.is_truthy(text:find("were reset for every character, this profile's included", 1, true),
                "What's new still says weapon buffs were reset")
            assert.is_falsy(text:find("This character's weapon buffs are its own", 1, true))
        end)

        it("skipping it changes nothing, and it isn't shown again", function()
            login("Ann", v150(), { walkthrough = true })
            wow.run(ns.Walkthrough.Frame().next, "OnClick")
            login("Bo", logout(), { walkthrough = true })
            local before, walkthrough = live(), ns.Util.DeepCopy(ns.db.walkthrough)
            assert.is_true(ns.Walkthrough.Frame():IsShown())
            wow.run(ns.Walkthrough.Frame().CloseButton, "OnClick")
            assert.are.same(before, live())
            assert.are.same(walkthrough, ns.db.walkthrough)
            login("Bo", logout(), { walkthrough = true })
            assert.is_false(ns.Walkthrough.Frame():IsShown())
        end)

        it("on a new install, the first character sees it in the walkthrough and the second on its own", function()
            login("Ann", nil, { walkthrough = true })
            local tour = ns.Walkthrough.Frame()
            assert.are.equal(#ns.Walkthrough.STEPS, ns.Walkthrough.Count())
            wow.run(tour.skip, "OnClick")
            login("Ann", logout(), { walkthrough = true })
            assert.is_false(ns.Walkthrough.Frame():IsShown())
            login("Cy", logout(), { walkthrough = true })
            assert.is_true(ns.Walkthrough.Frame():IsShown())
            assert.are.equal(1, ns.Walkthrough.Count())
            assert.are.same(UNSET, live(), "a new install's copy is the defaults: unset")
        end)

        it("the walkthrough names each page whose settings are each character's", function()
            login("Ann", v150())
            local step
            for _, info in ipairs(ns.Walkthrough.STEPS) do
                if info.title == "Each character's own buffs" then step = info end
            end
            assert.is_truthy(step)
            assert.are.equal(ns.Config.WALKTHROUGH_VERSION, step.since)
            local text = step.text()
            for _, page in ipairs({ "The Buffs tab", "buff order", "\"Never offer\"", "who gets each buff",
                "buff mode's key", "\"Offer my self-buffs\"", "Weapon and food buffs page", "Weapon buffs are",
                "shared profile" }) do
                assert.is_truthy(text:find(page, 1, true), page)
            end
            step.open()
            local weaponPage = select(3, ns.Options.Pages())
            assert.are.equal(weaponPage.category:GetID(), wow.settings.opened, "it opens the Weapon buffs page")
        end)
    end)

    describe("black", function()
        it("an unseen character, whatever its level, starts with weapon buffs off and both kinds none", function()
            login("Ann", v150()) -- level 60, weapon buffs on in 1.5.0
            assert.are.same({ false, "none", "none" }, weapons())
            assert.is_table(rec("Ann"), "it has a record from now on")
            login("Cy", logout()) -- level 1
            assert.are.same(V150C, live())
            ns.db.buffBack.weaponBuffs = true
            login("Cy", logout())
            assert.is_true(ns.db.buffBack.weaponBuffs, "a seen character keeps its choice")
        end)

        it("the reset runs once: later logins and profiles saved since keep weapon buffs", function()
            local db = v150(nil, { profiles = { Old = { schemaVersion = 8,
                buffBack = { weaponBuffs = true, weaponMain = "manaOil" } }, Default = { schemaVersion = 8 } } })
            login("Ann", db)
            ns.db.buffBack.weaponBuffs = true
            ns.db.buffBack.weaponMain = "manaOil"
            login("Bo", logout())
            login("Ann", logout())
            assert.are.same({ true, "manaOil", "none" }, weapons(), "not reset again")
            assert.are.equal(9, ns.db.schemaVersion)
            slash("profile use Old")
            assert.are.same({ false, "none", "none" }, weapons(), "a profile stored by 1.5.0 is reset as it is used")
            ns.db.buffBack.weaponMain = "rockbiter"
            slash("profile use Default")
            slash("profile use Old")
            assert.are.equal("rockbiter", ns.db.buffBack.weaponMain, "one saved since keeps its choice")
        end)

        -- The architecture review of #514: a 1.5.x account whose last
        -- character was on a shared profile. #519 (the owner's "B1", 24 Nov
        -- 2026): a character with no 1.5.x choice never joins the shared
        -- profile, and never has Default's stored copy put over the live
        -- settings: it gets a profile of its own, a copy of them. Its own
        -- settings (on Default) are still a copy of Default's.
        it("a character with no 1.5.x choice gets a profile of its own, with a copy of Default's on Default",
            function()
            local healer = { weaponBuffs = true, weaponMain = "manaOil", buffModeKey = "H", buffOrder = { "fortitude" } }
            local db = v150({ weaponBuffs = true, weaponMain = "manaOil", buffModeKey = "H",
                buffOrder = { "fortitude" } }, { activeProfile = "Healer", charProfiles = { ["Bo-Reed"] = "Healer" },
                profiles = { Healer = { schemaVersion = 8, buffBack = healer },
                    Default = { schemaVersion = 8, buffBack = { buffModeKey = "M", buffOrder = { "intellect" },
                        weaponBuffs = true, weaponMain = "wizardOil" } } } })
            login("Ann", db) -- played on Default in 1.5.0, last to log in was Bo on Healer
            assert.are.equal("Ann", ns.Profiles.Active(), "its own (#519), never Healer")
            assert.are.equal("Ann", rec("Ann").profile, "and recorded as Ann's")
            assert.are.same({ "H", { "fortitude" } }, { ns.db.buffBack.buffModeKey, ns.db.buffBack.buffOrder },
                "a copy of the live settings, never Default's stored copy")
            slash("profile use Default")
            assert.are.same({ "M", { "intellect" }, false, "none" }, { ns.db.buffBack.buffModeKey,
                ns.db.buffBack.buffOrder, ns.db.buffBack.weaponBuffs, ns.db.buffBack.weaponMain },
                "Ann's own: Default's, weapon buffs reset; never Healer's")
            login("Bo", logout())
            assert.are.equal("Healer", ns.Profiles.Active(), "Bo chose Healer in 1.5.x")
            assert.are.same({ "H", false }, { ns.db.buffBack.buffModeKey, ns.db.buffBack.weaponBuffs })
            ns.db.buffBack.weaponBuffs = true
            login("Ann", logout())
            assert.are.equal("Default", ns.Profiles.Active(), "Ann chose her own")
            login("Cy", logout()) -- made after the update, with Default left active
            assert.are.equal("Default", ns.Profiles.Active(), "with Default active, a new character starts on it")
            assert.are.same({ "M", false }, { ns.db.buffBack.buffModeKey, ns.db.buffBack.weaponBuffs })
            ns.db.buffBack.weaponMain = "rockbiter"
            login("Ann", logout())
            assert.are.same({ "M", "none" }, { ns.db.buffBack.buffModeKey, ns.db.buffBack.weaponMain })
            login("Bo", logout())
            assert.are.same({ true, "none" }, { ns.db.buffBack.weaponBuffs, ns.db.buffBack.weaponMain },
                "Healer's, not Cy's")
            assert.are.equal("M", ns.db.profiles.Default.buffBack.buffModeKey, "Default's stored copy is kept")
        end)

        it("an account on Default copies its live settings, not Default's older stored copy", function()
            for _, active in ipairs({ "Default", false }) do
                local db = v150(nil, { activeProfile = active or nil, profiles = {
                    Default = { schemaVersion = 8, buffBack = { buffModeKey = "M" } }, Other = { schemaVersion = 8 } } })
                login("Ann", db)
                login("Bo", logout())
                assert.are.equal("F", ns.db.buffBack.buffModeKey, tostring(active))
                assert.are.equal("F", ns.db.characterSeed.settings.buffModeKey, tostring(active))
            end
        end)

        it("damaged character data falls back safely", function()
            login("Ann", v150())
            login("Bo", logout())
            local db = logout()
            db.characters[key("Ann")] = { settings = { weaponBuffs = "yes", weaponMain = "laser",
                weaponOff = "windfury", buffModeKey = "ESCAPE", buffOrder = { "nope", "motw", "motw" }, selfBuffs = 3,
                whoChoice = "kept", whoGets = { motw = { rule = "all" } } }, profile = 42, welcomed = "yes" }
            db.characters["R:Ghost-X"] = "junk"
            db.characters[7] = {}
            db.characters["no realm"] = {}
            db.characters[string.rep("a", 200) .. ":B-C"] = {}
            db.characterLive = { "not a key" }
            login("Ann", db)
            assert.is_nil(ns.db.characters["no realm"], "a key no character can have is dropped")
            assert.is_nil(ns.db.characters[string.rep("a", 200) .. ":B-C"])
            assert.is_nil(rec("Ann").profile, "a damaged profile choice is Default")
            assert.is_nil(rec("Ann").welcomed)
            assert.are.same({ weaponBuffs = false, weaponMain = "none", weaponOff = "windfury", selfBuffs = true,
                buffModeKey = "MOUSEWHEELUP", buffOrder = { "motw" }, neverOffer = {} }, live())
            assert.are.same({}, ns.db.buffBack.whoGets, "checked across fields: kept rules leave 1.3.3's behind")
            assert.is_nil(ns.db.characters["R:Ghost-X"])
            assert.is_nil(ns.db.characters[7])
            assert.are.equal(key("Ann"), ns.db.characterLive)
            assert.are.same({}, wow.errors)
        end)

        it("checks every character's settings on load, not only the one logging in", function()
            login("Ann", v150())
            login("Bo", logout())
            local db = logout()
            db.characters[key("Ann")].settings.weaponMain = "laser"
            db.characters[key("Ann")].settings.junk = string.rep("x", 100)
            db.characters[key("Ann")].junk = string.rep("x", 100)
            login("Bo", db)
            assert.are.equal("none", rec("Ann").settings.weaponMain)
            assert.is_nil(rec("Ann").settings.junk, "nothing else can grow the saved file")
            assert.is_nil(rec("Ann").junk)
        end)

        it("a damaged record of whose settings are live never hands them to another character", function()
            -- false stands for the field removed from the file.
            for _, marker in ipairs({ "Not A Key", { "x" }, 12, false }) do
                login("Ann", v150())
                ns.db.buffBack.weaponBuffs = true
                ns.db.buffBack.weaponMain = "manaOil"
                ns.db.buffBack.buffModeKey = "G"
                local db = logout()
                db.characterLive = marker or nil
                login("Di", db)
                assert.are.same(V150C, live(), "Di gets the copy, not Ann's live settings")
                assert.is_nil(ns.db.characters["Not A Key"])
            end
        end)

        it("keeps the character whose settings are live when over the cap", function()
            login("Bo", v150())
            ns.db.characters["Aaa:Aaa-Aaa"] = { settings = { weaponMain = "manaOil" } }
            ns.Config.MAX_CHARACTERS = 1
            ns.Config.Repair()
            local function keys()
                local out = {}
                for who in pairs(ns.db.characters) do out[#out + 1] = who end
                table.sort(out)
                return out
            end
            assert.are.same({ key("Bo") }, keys())
            -- The live one first, once, then the rest in sorted order.
            ns.db.characters["Zzy:Y-Y"] = { settings = {} }
            ns.db.characters["Zzz:Z-Z"] = { settings = {} }
            ns.Config.MAX_CHARACTERS = 2
            wow.advance(ns.Config.REPAIR_INTERVAL_SECONDS)
            ns.Config.Repair()
            assert.are.same({ key("Bo"), "Zzy:Y-Y" }, keys())
            ns.Config.MAX_CHARACTERS = 200
        end)

        it("an unreadable name on a shared profile never changes that profile for the others", function()
            login("Ann", v150())
            ns.db.guildLogin.delay = 20
            slash("profile new Party")
            ns.db.buffBack.weaponBuffs = true
            ns.db.buffBack.weaponMain = "manaOil"
            ns.db.guildLogin.delay = 9
            login("Bo", logout(), { nameUnread = true })
            assert.are.equal("Default", ns.Profiles.Active(), "Default for the session, where nothing is anyone's")
            assert.are.equal(20, ns.db.guildLogin.delay, "Default's settings for the session, not Party's")
            assert.are.same({ false, "none", "none" }, weapons())
            login("Cy", logout())
            assert.are.equal("Default", ns.Profiles.Active())
            assert.are.equal(20, ns.db.guildLogin.delay, "Default's stored copy unchanged for the others")
            login("Ann", logout())
            assert.are.equal("Party", ns.Profiles.Active())
            assert.are.same({ true, "manaOil", "none" }, weapons(), "Party's are as Ann left them")
            assert.are.equal(9, ns.db.guildLogin.delay)
        end)

        it("deleting one shared profile leaves the characters on another on it", function()
            login("Ann", v150())
            slash("profile new Party")
            login("Bo", logout())
            slash("profile new Old")
            slash("profile use Default")
            slash("profile delete Old")
            login("Ann", logout())
            assert.are.equal("Party", ns.Profiles.Active())
        end)

        it("on a shared profile, the #408 step says the choice is the profile's", function()
            local db = v150({ whoGets = { motw = { rule = "tanks" } } }, { schemaVersion = 7,
                walkthrough = { seen = 2, firstRun = false }, activeProfile = "Party",
                charProfiles = { ["Ann-Vale"] = "Party", ["Bo-Reed"] = "Party" },
                profiles = { Party = { schemaVersion = 7 }, Default = { schemaVersion = 7 } } })
            db.buffBack.whoChoice = nil
            login("Ann", db, { walkthrough = true })
            local text = ns.Walkthrough.Frame().stepText:GetText()
            assert.is_truthy(text:find("The choice is for the shared profile Party, and every character on it.", 1,
                true))
            assert.is_falsy(text:find("The choice is for this character", 1, true))
        end)

        it("on a profile only this character uses, the #408 step says the choice is that profile's alone (#519)",
            function()
            local db = v150({ whoGets = { motw = { rule = "tanks" } } }, { schemaVersion = 7,
                walkthrough = { seen = 2, firstRun = false }, activeProfile = "Party",
                profiles = { Party = { schemaVersion = 7 }, Default = { schemaVersion = 7 } } })
            db.buffBack.whoChoice = nil
            login("Ann", db, { walkthrough = true }) -- new, with Party active: a profile of its own
            local text = ns.Walkthrough.Frame().stepText:GetText()
            assert.are.equal("Ann", ns.Profiles.Active())
            assert.is_truthy(text:find("The choice is for the profile Ann, which only this character uses.", 1, true),
                text)
            assert.is_falsy(text:find("shared profile", 1, true))
        end)

        it("each character makes the keep-or-reset choice of #408 for its own rules", function()
            local db = v150({ whoGets = { motw = { rule = "tanks" } } }, { schemaVersion = 7 })
            db.buffBack.whoChoice = nil
            login("Ann", db)
            assert.are.equal("pending", ns.BuffRules.Choice())
            ns.BuffRules.Choose("new")
            assert.are.equal("new", ns.BuffRules.Choice())
            login("Bo", logout())
            assert.are.equal("pending", ns.BuffRules.Choice(), "Bo's own rules wait for Bo's choice")
            assert.are.same({ rule = "tanks" }, ns.db.buffBack.whoGets.motw)
            login("Ann", logout())
            assert.are.equal("new", ns.BuffRules.Choice())
        end)

        it("a character whose remembered profile is gone uses its own", function()
            login("Ann", v150())
            login("Bo", logout())
            ns.db.buffBack.weaponMain = "windfury"
            local db = logout()
            db.characters[key("Ann")].profile = "Gone"
            login("Ann", db)
            assert.are.equal("Default", ns.Profiles.Active())
            assert.are.same(V150C, live())
        end)

        it("a character on its own isn't moved to the account's old profile when its choice is lost", function()
            local db = v150(nil, { activeProfile = "Raiding", charProfiles = { ["Ann-Vale"] = "Raiding" },
                profiles = { Raiding = { schemaVersion = 8 }, Default = { schemaVersion = 8 } } })
            login("Ann", db)
            assert.are.equal("Raiding", ns.Profiles.Active())
            slash("profile use Default")
            db = logout()
            db.charProfiles = {}
            login("Ann", db)
            assert.are.equal("Default", ns.Profiles.Active(), "its record is the source, not 1.5.x's list")
        end)

        it("Default is there to go back to even after it was deleted", function()
            login("Ann", v150())
            ns.db.buffBack.weaponMain = "rockbiter"
            slash("profile new Party")
            ns.db.buffBack.weaponMain = "manaOil"
            assert.are.equal("Default", ns.Profiles.Delete("Default"))
            assert.are.equal("Default", ns.Profiles.Use("Default"))
            assert.are.equal("rockbiter", ns.db.buffBack.weaponMain, "Ann's own")
        end)

        it("going back to Default lends the character's own buff mode key", function()
            login("Ann", v150())
            slash("profile new Party")
            login("Bo", logout())
            slash("profile use Default") -- Bo, new, kept Party (#519): to Bo's own
            slash("buffmode key H")
            slash("profile new Other") -- Default's stored copy now holds Bo's key
            login("Ann", logout())
            assert.are.equal("Party", ns.Profiles.Active())
            ns.BuffMode.Set(true, { yours = true })
            assert.are.equal("F", ns.BuffMode.LentKey())
            slash("profile use Default")
            assert.are.equal("F", ns.BuffMode.LentKey(), "Ann's own key, not the one Default's copy held")
        end)

        it("a damaged file naming another character on a shared profile never keeps its settings as theirs",
            function()
            login("Ann", v150())
            login("Bo", logout())
            ns.db.buffBack.weaponMain = "windfury"
            login("Ann", logout())
            slash("profile new Party")
            ns.db.buffBack.weaponMain = "manaOil"
            local db = logout()
            db.characterLive = key("Bo")
            login("Ann", db)
            assert.are.equal("Party", ns.Profiles.Active())
            login("Bo", logout())
            assert.are.equal("windfury", ns.db.buffBack.weaponMain, "Bo's own, not Party's")
        end)

        it("even if the logout save didn't run, the next login keeps the last character's settings as theirs",
            function()
            login("Ann", v150())
            ns.db.buffBack.weaponMain = "manaOil"
            login("Bo", _G.FriendlyForeverDB) -- no PLAYER_LOGOUT
            login("Ann", logout())
            assert.are.equal("manaOil", ns.db.buffBack.weaponMain)
        end)

        it("a damaged seed or character list heals, and characters then start unset", function()
            login("Ann", v150())
            local db = logout()
            db.characterSeed = "junk"
            db.characters = 5
            login("Bo", db)
            assert.are.same(UNSET, live())
            assert.is_nil(ns.db.characterSeed)
            assert.are.equal("table", type(ns.db.characters))
            db = logout()
            db.characterSeed = { settings = { weaponMain = "laser", buffModeKey = "G", junk = string.rep("x", 100) } }
            login("Cy", db)
            assert.are.same({ "none", "G" }, { ns.db.characterSeed.settings.weaponMain,
                ns.db.characterSeed.settings.buffModeKey }, "a damaged seed is checked on load")
            assert.is_nil(ns.db.characterSeed.settings.junk, "nothing else can grow the saved file")
        end)

        it("damage to the character data mid-session is repaired before it is used", function()
            login("Ann", v150())
            slash("profile new Party")
            ns.db.characters[key("Ann")] = "junk"
            slash("profile use Default")
            assert.are.same(V150C, live(), "a lost record is new again: the copy")
            slash("profile use Party")
            rec("Ann").settings.weaponMain = "laser"
            assert.are.equal("Default", ns.Profiles.Use("Default"))
            assert.are.equal("none", rec("Ann").settings.weaponMain, "a damaged field gets its default")
            assert.are.equal("none", ns.db.buffBack.weaponMain)
            slash("profile use Party")
            ns.db.characters[key("Ann")] = nil
            ns.db.characterSeed = { settings = "x", profile = "Default" }
            slash("profile use Default")
            assert.are.same(UNSET, live(), "a damaged seed is dropped: unset")
            assert.are.equal("new", ns.db.buffBack.whoChoice)
            ns.db.characterLive = true
            assert.are.equal("Third", ns.Profiles.New("Third")) -- straight after, no other check heals it
            assert.is_nil(ns.db.characters[true])
            assert.are.same({}, wow.errors)
        end)

        it("data damaged mid-session is repaired before it is used", function()
            login("Ann", v150())
            ns.db.characters = "junk"
            ns.db.characterLive = 12
            slash("profile new Party")
            assert.are.equal("Party", ns.Profiles.Active())
            assert.are.equal("table", type(ns.db.characters))
            slash("profile use Default")
            assert.are.same({}, wow.errors)
        end)

        it("while the player's name can't be read, records nothing and offers no weapon buffs", function()
            login("Ann", v150())
            ns.db.buffBack.weaponBuffs = true
            ns.db.buffBack.weaponMain = "manaOil"
            login("Bo", _G.FriendlyForeverDB, { nameUnread = true, walkthrough = true }) -- even with no logout save
            assert.are.same({ false, "none", "none" }, weapons(), "never Ann's")
            assert.is_false(ns.Profiles.NeedsWelcome())
            ns.Profiles.Welcomed() -- nothing to mark, and no error
            assert.is_nil(rec("Bo"))
            assert.is_false(ns.db.characterLive)
            assert.are.same({ true, "manaOil", "none" }, { rec("Ann").settings.weaponBuffs,
                rec("Ann").settings.weaponMain, rec("Ann").settings.weaponOff }, "Ann's are kept as hers")
            assert.are.same({}, wow.errors)
        end)

        it("while the name or realm can't be read, another character's food is off too, and not offered (#544)",
            function()
            for _, opts in ipairs({ { nameUnread = true }, { secretRealm = true } }) do
                login("Ann", v150())
                ns.db.buffBack.foodBuffs = true
                ns.db.buffBack.foodItem = 2680
                login("Bo", _G.FriendlyForeverDB, opts) -- Ann's live settings, never saved by a logout
                assert.are.same({ false, 0 }, { ns.db.buffBack.foodBuffs, ns.db.buffBack.foodItem }, "never Ann's")
                assert.is_nil(ns.FoodBuffs.Next())
                assert.are.same({ true, 2680 }, { rec("Ann").settings.foodBuffs, rec("Ann").settings.foodItem },
                    "Ann's are kept as hers")
                assert.are.same({}, wow.errors)
            end
        end)

        it("records nothing while the realm can't be read: a secret, none, empty, too long or no API", function()
            for _, how in ipairs({ "secret", "none", "empty", "long", "missing" }) do
                ns = wow.boot({ db = v150(), before = function(state)
                    state.units.player = { name = "Ann", surname = "Vale", id = "Ann-Vale", isPlayer = true }
                    if how == "secret" then state.secretRealm = true end
                    if how == "none" then state.realm = nil end
                    if how == "empty" then state.realm = "" end
                    if how == "long" then state.realm = string.rep("R", 120) end
                end, afterLoad = function()
                    if how == "missing" then _G.GetRealmName = nil end
                end })
                assert.are.same(V150C, live(), how)
                assert.are.same({}, ns.db.characters, how)
                assert.is_false(ns.db.characterLive, how)
                assert.are.same({}, wow.errors, how)
            end
        end)

        it("keeps a record current when the character logs out", function()
            login("Ann", v150())
            ns.db.buffBack.weaponMain = "rockbiter"
            assert.are.equal("rockbiter", logout().characters[key("Ann")].settings.weaponMain)
        end)

        it("a character 1.5.x remembered on a profile keeps it", function()
            login("Ann", v150(nil, { charProfiles = { ["Ann-Vale"] = "Raiding" },
                profiles = { Raiding = { schemaVersion = 8 }, Default = { schemaVersion = 8 } } }))
            assert.are.equal("Raiding", ns.Profiles.Active())
            assert.are.equal("Raiding", rec("Ann").profile)
        end)

        it("a new character on a shared profile gets its own copy, not the seed itself", function()
            login("Ann", v150())
            slash("profile new Party")
            local db = logout()
            db.charProfiles = { ["Bo-Reed"] = "Party" }
            login("Bo", db)
            assert.are.equal("Party", ns.Profiles.Active())
            assert.are.same(V150C, (function()
                local out = {}
                for _, f in ipairs(CHECKED) do out[f] = rec("Bo").settings[f] end
                return out
            end)())
            assert.is_false(rawequal(rec("Bo").settings, ns.db.characterSeed.settings), "never the same table")
        end)

        it("going back to Default while the name can't be read offers no weapon buffs", function()
            login("Ann", v150())
            ns.db.buffBack.weaponBuffs = true
            ns.db.buffBack.weaponMain = "manaOil"
            slash("profile new Party") -- Default's stored copy holds Ann's weapon buffs
            wow.state.units.player.nameLoading = true
            slash("profile use Default")
            assert.are.same({ false, "none", "none" }, weapons())
            assert.is_false(ns.db.characterLive)
        end)

        it("a deleted profile's characters go back to their own, even if one is made again by that name",
            function()
            login("Ann", v150())
            login("Bo", logout())
            slash("profile new Party")
            login("Ann", logout())
            assert.are.equal("Default", ns.Profiles.Active())
            slash("profile delete Party")
            slash("profile new Party")
            slash("profile use Default")
            login("Bo", logout())
            assert.are.equal("Default", ns.Profiles.Active(), "Bo chose the old Party, not this one")
        end)

        it("a record list damaged mid-session is repaired before it is used", function()
            login("Ann", v150())
            ns.db.characters = { [key("Ann")] = { settings = "x" } }
            assert.are.equal("Party", ns.Profiles.New("Party"))
            assert.are.equal("table", type(rec("Ann").settings))
            ns.db.characters[key("Ann")].profile = 42
            assert.are.equal("Default", ns.Profiles.Use("Default"))
            assert.are.same({}, wow.errors)
        end)

        it("an import's undo stays with the character it was made on", function()
            login("Ann", v150())
            assert.is_true(ns.Profiles.Import(assert(ns.Profiles.Export())))
            assert.is_true(ns.Profiles.CanUndoImport())
            login("Bo", logout())
            assert.is_false(ns.Profiles.CanUndoImport(), "Bo's undo would hand him Ann's own settings")
            login("Ann", logout())
            assert.is_true(ns.Profiles.CanUndoImport(), "Ann's still")
            local db = logout()
            db.importUndo.who = 42
            login("Ann", db)
            assert.is_false(ns.Profiles.CanUndoImport(), "a damaged one is dropped")
            assert.is_nil(ns.db.importUndo)
            assert.is_true(ns.Profiles.Import(assert(ns.Profiles.Export())))
            ns.db.importUndo.who = {} -- mid-session
            assert.is_false(ns.Profiles.CanUndoImport())
            assert.is_nil(ns.db.importUndo)
            assert.is_true(ns.Profiles.Import(assert(ns.Profiles.Export())))
            ns.db.importUndo.who = nil -- as 1.5.x saved it
            login("Bo", logout())
            assert.is_true(ns.Profiles.CanUndoImport(), "one saved before 1.5.2 names nobody: as before")
        end)
    end)

    describe("red: chaos over damaged and partial 1.5.0 settings", function()
        local KINDS = { "none", "sharpening", "wizardOil", "manaOil", "windfury", "rockbiter" }
        local KEYS = { "MOUSEWHEELUP", "F", "G", "SHIFT-T", "BUTTON4" }
        local ORDERS = { {}, { "motw" }, { "intellect", "motw" }, { "fortitude" } }
        local JUNK = { "x", 42, true, {}, { 1, 2 }, -1 }
        local VALID = {
            weaponBuffs = function() return random.random(2) == 1 end,
            weaponMain = function() return KINDS[random.random(#KINDS)] end,
            weaponOff = function() return KINDS[random.random(#KINDS)] end,
            selfBuffs = function() return random.random(2) == 1 end,
            buffModeKey = function() return KEYS[random.random(#KEYS)] end,
            buffOrder = function() return { unpack(ORDERS[random.random(#ORDERS)]) } end,
            neverOffer = function() return random.random(2) == 1 and { motw = true } or {} end,
        }
        local function copy(t)
            if type(t) ~= "table" then return t end
            local out = {}
            for k, v in pairs(t) do out[k] = copy(v) end
            return out
        end
        -- One 1.5.0 buffBack: each field valid, damaged or missing. Returns
        -- it and what a character's copy of it is (weapon buffs reset).
        local function draw()
            local saved, expected = {}, {}
            for _, field in ipairs(CHECKED) do
                local roll = random.random(4)
                if roll <= 2 then
                    saved[field] = VALID[field]()
                    expected[field] = copy(saved[field])
                    -- Weapon buffs are reset once, for every character.
                    if field:find("^weapon") then expected[field] = copy(UNSET[field]) end
                else
                    saved[field] = roll == 3 and JUNK[random.random(#JUNK)] or nil
                    expected[field] = copy(UNSET[field])
                end
            end
            return saved, expected
        end

        -- A 1.5.0 account: on Default; with its buff settings lost; or on the
        -- shared profile Party, with Default's own settings stored and some
        -- characters remembered on Party.
        local function seeded(seed)
            random.seed(seed)
            local current, currentExpected = draw()
            local kind = ({ "default", "default", "default", "lost", "shared", "shared" })[random.random(6)]
            if kind == "lost" then return { db = v150("junk"), seedValues = copy(UNSET), legacy = {}, kind = kind } end
            if kind == "default" then return { db = v150(current), seedValues = currentExpected, legacy = {}, kind = kind } end
            local default, defaultExpected = draw()
            local legacy, remembered = {}, {}
            for _, who in ipairs({ "Ann", "Bo", "Cy", "Di" }) do
                if random.random(2) == 1 then
                    legacy[who] = true
                    remembered[CHARS[who].name .. "-" .. CHARS[who].surname] = "Party"
                end
            end
            return { db = v150(current, { activeProfile = "Party", charProfiles = remembered, profiles = {
                    Party = { schemaVersion = 8, buffBack = copy(current) },
                    Default = { schemaVersion = 8, buffBack = default } } }),
                seedValues = defaultExpected, party = currentExpected, legacy = legacy, kind = kind }
        end

        -- How often each path ran, over every seed: each must run.
        local reach = { newLogin = 0, ownProfile = 0, partyLogin = 0, toParty = 0, backToDefault = 0, recordDamage = 0,
            liveDamage = 0, seedDamage = 0, lost = 0, shared = 0 }

        for _, seed in ipairs({ 1, 7, 9, 52, 508, 2026, 31337 }) do
            it("seed " .. seed .. ": each character keeps its own, the copy is made once, weapons reset, nothing errors",
                function()
                local start = seeded(seed)
                local seedValues = start.seedValues
                if start.kind ~= "default" then reach[start.kind] = reach[start.kind] + 1 end
                local names = { "Ann", "Bo", "Cy", "Di" }
                local recorded = {}       -- characters with a record
                local own = {}            -- each character's own settings, as the model has them
                local onParty = {}        -- characters on the shared profile
                local named = {}          -- characters on a profile of their own (#519): its settings
                local party = start.party -- the shared profile's settings, once there is one
                local seedLost = false
                local current             -- who is logged in
                -- The settings of the profile active at logout, when it isn't Default.
                local activeShared = start.kind == "shared" and party or nil
                local namedMade = 0       -- profiles of their own made: far from the cap of 20
                local function settingsOf(who)
                    if onParty[who] then return party end
                    return named[who] or own[who]
                end
                local function expect(why)
                    assert.are.same(settingsOf(current), live(), why)
                end
                for step = 1, 40 do
                    local roll = random.random(11)
                    local why = "seed " .. seed .. " step " .. step
                    if roll <= 4 or not current then
                        if current then activeShared = (onParty[current] or named[current]) and settingsOf(current) or nil end
                        local saved = current and logout() or start.db
                        -- Damage to the saved file between sessions.
                        local damage = random.random(8)
                        if current and damage == 1 then
                            saved.characterLive = ({ false, "junk", 42, {} })[random.random(4)] or nil
                            reach.liveDamage = reach.liveDamage + 1
                        elseif current and damage == 2 then
                            saved.characterSeed = ({ false, "junk", { settings = 5 } })[random.random(3)] or nil
                            seedLost = true
                            reach.seedDamage = reach.seedDamage + 1
                        end
                        current = names[random.random(#names)]
                        if not recorded[current] then
                            -- New: a copy of Default's settings (or unset) as its
                            -- own; on Party by a 1.5.x choice; with none, while a
                            -- shared profile is active, a profile of its own, a
                            -- copy of the live settings (#519).
                            recorded[current] = true
                            own[current] = copy(seedLost and UNSET or seedValues)
                            onParty[current] = start.legacy[current] and party ~= nil or nil
                            if not onParty[current] and activeShared then
                                named[current] = copy(activeShared)
                                namedMade = namedMade + 1
                                assert.is_true(namedMade < 17, "the model doesn't reach the cap of profiles")
                                reach.ownProfile = reach.ownProfile + 1
                            end
                            reach.newLogin = reach.newLogin + 1
                        end
                        if onParty[current] then reach.partyLogin = reach.partyLogin + 1 end
                        login(current, saved)
                        expect(why .. ": login as " .. current)
                    elseif roll <= 7 then
                        local field = CHECKED[random.random(#CHECKED)]
                        local value = VALID[field]()
                        ns.db.buffBack[field] = copy(value)
                        settingsOf(current)[field] = copy(value)
                        expect(why .. ": edit " .. field)
                    elseif roll <= 9 then
                        if party == nil then
                            slash("profile new Party")
                            party = copy(live())
                            onParty[current] = true
                            reach.toParty = reach.toParty + 1
                        elseif not onParty[current] then
                            slash("profile use Party")
                            onParty[current] = true
                            reach.toParty = reach.toParty + 1
                        end
                        named[current] = nil -- its own profile stays stored, unused
                        expect(why .. ": to Party")
                    elseif roll == 10 then
                        if onParty[current] or named[current] then
                            slash("profile use Default")
                            onParty[current], named[current] = nil, nil
                            reach.backToDefault = reach.backToDefault + 1
                        end
                        expect(why .. ": to Default")
                    else
                        -- Damage another character's record: it is new again at
                        -- its next login.
                        local other = names[random.random(#names)]
                        if other ~= current and type(ns.db.characters) == "table" then
                            ns.db.characters[key(other)] = JUNK[random.random(2)]
                            recorded[other], own[other], onParty[other], named[other] = nil, nil, nil, nil
                            reach.recordDamage = reach.recordDamage + 1
                        end
                    end
                end
                local db = logout()
                assert.are.same({}, wow.errors)
                assert.are.equal(9, db.schemaVersion)
                if start.kind == "lost" or seedLost then
                    assert.is_nil(db.characterSeed, "no 1.5.0 buff settings to copy")
                else
                    local seedNow = {}
                    for _, f in ipairs(CHECKED) do seedNow[f] = db.characterSeed.settings[f] end
                    assert.are.same(seedValues, seedNow, "the seed is Default's 1.5.0 values, checked, weapons reset")
                end
            end)
        end

        it("the seeds reach every path", function()
            for path, count in pairs(reach) do assert.is_true(count > 0, path .. " never ran") end
        end)
    end)
end)
