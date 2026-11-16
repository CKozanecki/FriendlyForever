-- Spec: #427, #274, #283
-- The options dropdowns: a click on a list row reaches the row, not the
-- full-screen click-away catcher made beside it (siblings share a frame
-- level, and the game doesn't say which takes a click), on every dropdown.
local wow = require("spec.support.wow")

-- Shown as if its tab were open: the game only hit-tests visible frames, and
-- the options hide a tab's controls when another tab is chosen.
local function reveal(frame)
    local p = frame
    while type(p) == "table" do p:Show(); p = p.parent end
end

-- Every dropdown the options built: buttons that own a list, rows and catcher.
local function dropdowns()
    local found = {}
    for _, f in ipairs(wow.frames) do
        if f.list and f.rows and f.list.catcher then
            reveal(f)
            f.list:Hide()
            found[#found + 1] = f
        end
    end
    return found
end

describe("the options dropdowns' frame levels (#427)", function()
    before_each(function()
        wow.boot({ db = {}, class = "ROGUE" })
    end)

    it("finds the two Buff Thanks dropdowns and the two weapon ones", function()
        assert.is_true(#dropdowns() >= 4)
    end)

    it("the simulated client makes siblings tie, so the winner is undefined (white)", function()
        local parent = wow.newFrame("Frame", nil, UIParent)
        local a, b = wow.newFrame("Button", nil, parent), wow.newFrame("Button", nil, parent)
        local winner, tied = wow.hitTest({ a, b })
        assert.is_nil(winner)
        assert.are.equal(2, #tied)
    end)

    it("an open list's rows take the click over the catcher, on every dropdown (white)", function()
        for _, dd in ipairs(dropdowns()) do
            reveal(dd)
            wow.run(dd, "OnClick")
            assert.is_true(dd.list:IsShown())
            for _, row in ipairs(dd.rows) do
                assert.are.equal(row, (wow.hitTest({ dd.list.catcher, row, dd })), row:GetText())
            end
            wow.run(dd, "OnClick")
        end
    end)

    it("a click on the row that wins saves its choice and closes the list, on every dropdown (white)", function()
        for _, dd in ipairs(dropdowns()) do
            for _, row in ipairs(dd.rows) do
                reveal(dd)
                wow.run(dd, "OnClick")
                local winner = wow.hitTest({ dd.list.catcher, row })
                assert.are.equal(row, winner)
                wow.run(winner, "OnClick")
                assert.is_false(dd.list:IsShown())
                -- Read back from what was saved: the button and the marked row.
                dd.Fill()
                assert.are.equal(row:GetText(), dd:GetText())
                assert.is_true(row.highlightLocked)
            end
        end
    end)

    it("the rows stay above the catcher after the panel changes the levels (white)", function()
        for _, dd in ipairs(dropdowns()) do
            for _, shift in ipairs({ 0, 5, 40 }) do
                dd.list:SetFrameLevel(10 + shift)
                dd.list.catcher:SetFrameLevel(50 + shift)
                for _, row in ipairs(dd.rows) do row:SetFrameLevel(1) end
                reveal(dd)
                wow.run(dd, "OnClick")
                assert.are.equal(dd.rows[1], (wow.hitTest({ dd.list.catcher, dd.rows[1] })))
                -- Shown another way (the game runs OnShow itself).
                wow.run(dd, "OnClick")
                reveal(dd)
                dd.list:Show()
                wow.run(dd.list, "OnShow")
                assert.are.equal(dd.rows[#dd.rows], (wow.hitTest({ dd.list.catcher, dd.rows[#dd.rows] })))
                dd.list:Hide()
            end
        end
    end)

    it("a click elsewhere closes the list and changes nothing (white)", function()
        for _, dd in ipairs(dropdowns()) do
            local before = dd:GetText()
            local other = wow.newFrame("EditBox", nil, dd.list:GetParent())
            other:EnableMouse(true)
            other:SetFrameLevel(dd.list:GetFrameLevel() - 1)
            reveal(dd)
            wow.run(dd, "OnClick")
            local winner = wow.hitTest({ dd.list.catcher, other })
            assert.are.equal(dd.list.catcher, winner)
            wow.run(winner, "OnClick")
            assert.is_false(dd.list:IsShown())
            assert.are.equal(before, dd:GetText())
        end
    end)

    it("a closed list's catcher takes no click, hidden with it (black)", function()
        for _, dd in ipairs(dropdowns()) do
            assert.is_nil((wow.hitTest({ dd.list.catcher })))
        end
    end)
end)
