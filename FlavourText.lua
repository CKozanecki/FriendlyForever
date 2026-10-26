-- The words Flavour.lua chooses from for the flavour placeholders in message
-- lines. Each slot has pools: by your race's voice, by your faction, by where
-- you are, by the hour, and general lines for anybody. A race without lines
-- of its own speaks with its faction's lines and the general ones.
--
-- Voices are the game's race file names ("Scourge" for the Forsaken), except
-- the Skyborne: both of WoW Forever's Skyborne races share the file name
-- "Skyborne", but the High Order (Alliance; descended from the Highborne
-- scholars of Eldre'Thalas, keepers of the arcane) and the Windshapers (Horde;
-- shamans holding to the wind spirits' gift of skysight) speak quite
-- differently. Flavour.Voice tells them apart: "HighOrder" and "Windshaper".
--
-- How each slot is used in a line, which every fragment must fit:
--   {greeting}  "{greeting}, {name}!" and "{greeting}!": a salutation, no
--               end punctuation.
--   {thanks}    "{thanks}, {name}!" and "{thanks} for the {buff}": a way of
--               saying thank you, no end punctuation, nothing after it that
--               "for the" can't follow.
--   {blessing}  A whole sentence with its end punctuation, said last.
--   {cheer}     A rallying cry, a whole sentence ending in "!".
-- Fragments may use {zone}, {timeofday} and {myclass}, never another slot.
-- spec/flavour_spec.lua renders every fragment in every line it fits and
-- fails on a leftover placeholder, broken punctuation or an over-long line.
local _, ns = ...

local FlavourText = {}
ns.FlavourText = FlavourText

FlavourText.greeting = {
    general = { "Well met", "Greetings", "Hail", "Good to see you", "Hail and well met" },
    faction = {
        Horde = { "Throm-ka", "Lok'tar", "Strength and honor" },
    },
    race = {
        Human = { "Well met", "Good day to you", "Light be with you", "Hail" },
        Dwarf = { "Well met", "Hail", "Good to see ye", "Ho there", "Aye, well met" },
        NightElf = { "Ishnu-alah", "Elune-adore", "Well met", "Greetings" },
        Gnome = { "Salutations", "Greetings", "Well met", "Hello there" },
        Orc = { "Throm-ka", "Lok'tar", "Well met", "Strength and honor" },
        Scourge = { "Hail", "Greetings", "Well met", "Dark Lady watch over you" },
        Tauren = { "Well met", "Peace be with you", "Greetings", "Earth Mother guide you" },
        Troll = { "Greetings", "Well met", "Hail", "Spirits be with ya" },
        HighOrder = { "Well met", "Greetings", "Knowledge and light to you", "The High Order greets you" },
        Windshaper = { "Winds guide you", "The winds greet you", "Well met", "Breath of the sky to you" },
    },
}

FlavourText.thanks = {
    general = { "Thank you", "My thanks", "Many thanks", "Much obliged", "You have my thanks", "Thank you kindly" },
    race = {
        Human = { "Thank you kindly", "My thanks", "Much obliged", "You have my gratitude" },
        Dwarf = { "Thank ye kindly", "Much obliged", "Ye have me thanks", "Me thanks" },
        NightElf = { "My thanks", "You have my gratitude", "Elune smile on you, and thank you", "Many thanks" },
        Gnome = { "Thank you ever so much", "Splendid, thank you", "Many thanks", "Much obliged" },
        Orc = { "My thanks", "You have my gratitude", "You have my respect and my thanks", "Thank you" },
        Scourge = { "My thanks", "You have my gratitude", "How very kind, thank you", "Thank you" },
        Tauren = { "My thanks", "You honor me, thank you", "You have my gratitude", "Thank you kindly" },
        Troll = { "Thank ya", "Ya have my thanks", "Many thanks", "Thank ya kindly" },
        HighOrder = {
            "My thanks", "You have the High Order's thanks", "Most gracious, thank you", "A scholar's thanks",
        },
        Windshaper = { "The winds carry my thanks", "My thanks", "The spirits and I thank you", "Many thanks" },
    },
}

FlavourText.blessing = {
    general = {
        "Safe travels.", "Good fortune to you.", "Fight well.", "May your journey be swift.",
        "May the road be kind to you.", "Glory and good fortune to you.",
    },
    faction = {
        Alliance = { "Light keep you safe.", "The Alliance stands with you." },
        Horde = { "Strength and honor.", "The Horde stands with you." },
    },
    race = {
        Human = {
            "May the Light guide your steps.", "Light be with you.", "Walk in the Light.",
            "May your blade stay sharp and your shield stay strong.",
        },
        Dwarf = {
            "May yer beard grow long and yer mug never empty.", "Stone and Light keep ye.",
            "Stay sturdy as the mountain.", "May yer forge burn hot.",
        },
        NightElf = {
            "Elune light your path.", "May Elune watch over you.", "Ishnu-dal-dieb.",
            "Walk beneath the stars.",
        },
        Gnome = {
            "May your gears never grind.", "Keep your cogs well oiled.", "Gnomeregan will rise again!",
            "Tinker on, friend.",
        },
        Orc = {
            "Lok'tar ogar!", "Strength and honor.", "May your blade drink deep.", "Fight with honor.",
        },
        Scourge = {
            "The Dark Lady watches over you.", "Victory for Sylvanas!", "Walk in shadow.",
            "Remember the Forsaken.",
        },
        Tauren = {
            "May the Earth Mother watch over you.", "Walk with the Earth Mother.", "An'she guide you.",
            "May the winds be at your back.",
        },
        Troll = {
            "Da loa be watchin' over ya.", "Walk wit' da spirits.", "Stay sharp, mon.",
            "May ya never go hungry.",
        },
        HighOrder = {
            "May the ley lines guide you.", "Knowledge is the truest shield.", "Remember Eldre'Thalas.",
            "May your mind stay as sharp as your spells.", "The arcane remembers its friends.",
        },
        Windshaper = {
            "May the winds be at your back.", "The spirits of the air watch over you.",
            "May your sight be as clear as the open sky.", "Let the winds carry you home.",
            "Walk on air, friend.",
        },
    },
    place = {
        city = { "Enjoy the comforts of {zone}.", "Rest well while you can.", "Rest easy in {zone}." },
        instance = { "Stay close and stay alive in here.", "May these halls be kind to us." },
        wilds = {
            "Safe travels through {zone}.", "Keep your eyes open out in {zone}.",
            "May {zone} treat you kindly.",
        },
    },
    time = {
        night = { "Rest well tonight.", "May the stars light your way tonight." },
        morning = { "May your day be bright.", "A fine morning for adventure." },
    },
}

FlavourText.cheer = {
    general = { "Onward!", "To adventure!", "Onward to glory!" },
    faction = {
        Alliance = { "For the Alliance!" },
        Horde = { "For the Horde!" },
    },
    race = {
        Human = { "For Stormwind!", "For the Alliance!", "For the King!" },
        Dwarf = { "For Khaz Modan!", "For Ironforge!", "For the Alliance!" },
        NightElf = { "For Darnassus!", "Elune guide us!", "For the Alliance!" },
        Gnome = { "For Gnomeregan!", "Gnomeregan forever!", "For the Alliance!" },
        Orc = { "For the Horde!", "Lok'tar ogar!", "Blood and thunder!" },
        Scourge = { "For the Dark Lady!", "Victory for Sylvanas!", "For the Forsaken!" },
        Tauren = { "For Thunder Bluff!", "For the Horde!", "Earth Mother guide us!" },
        Troll = { "For da Darkspear!", "For the Horde!" },
        HighOrder = { "For the High Order!", "For Eldre'Thalas!", "For the Alliance!" },
        Windshaper = { "For the Windshapers!", "By the four winds!", "For Zephras!", "For the Horde!" },
    },
}

-- Slots chosen by context, in Flavour.lua.
FlavourText.SLOTS = { "greeting", "thanks", "blessing", "cheer" }
