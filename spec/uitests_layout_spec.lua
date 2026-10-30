-- Spec: #35, #52, #90, #112, #148
-- The UI simulator's layout check (uitests/scenarios.lua), run here against
-- stand-in regions whose edges, anchors and text sizes each test sets
-- itself, so the expected answer comes from those numbers and not from the
-- check. The scenarios themselves run only in the simulator.

-- Loads the scenario file the way the simulator does, with test() and
-- A_Print stubbed, and returns its layout checks and what they printed.
local function loadChecks(extra)
    local printed = {}
    local env = setmetatable({
        test = function() end,
        A_Print = function(text) printed[#printed + 1] = text end,
    }, { __index = _G })
    for name, value in pairs(extra or {}) do env[name] = value end
    local chunk = assert(loadfile("uitests/scenarios.lua"))
    setfenv(chunk, env)
    return chunk(), printed
end

-- The buff-back button as the simulator lays it out: 220 by 44, its lines
-- right of the 36-pixel icon, 6 pixels in from its edges.
local BUTTON = { left = 0, right = 220, top = 44, bottom = 0 }

-- A stand-in region. Its methods return the fields given; methods names a
-- method to replace with a function, or to take away with false.
local function region(fields, methods)
    local r = {}
    function r.GetLeft() return fields.left end
    function r.GetRight() return fields.right end
    function r.GetTop() return fields.top end
    function r.GetBottom() return fields.bottom end
    function r.GetNumPoints() return #(fields.points or {}) end
    function r.GetPoint(_, i) return (fields.points or {})[i] end
    if fields.width then function r.GetStringWidth() return fields.width end end
    if fields.height then function r.GetStringHeight() return fields.height end end
    if fields.lines then function r.GetNumLines() return fields.lines end end
    for name, fn in pairs(methods or {}) do r[name] = fn or nil end
    return r
end

-- The hint: pinned by its bottom corners, as tall as its text. One line of
-- it is 12 high; wrapped onto two, 24.
local function hint(lines, methods)
    local height = 12 * lines
    return region({
        left = 46, right = 214, bottom = 6, top = 6 + height,
        points = { "BOTTOMLEFT", "BOTTOMRIGHT" }, width = 150, height = height, lines = lines,
    }, methods)
end

local function fails(fn)
    local ok, err = pcall(fn)
    assert.is_false(ok, "the check passed")
    return tostring(err)
end

describe("UI simulator layout check (TextInside)", function()
    local checks, printed

    before_each(function() checks, printed = loadChecks() end)

    describe("white: the drawn text's top and bottom are checked against its frame", function()
        it("passes a one-line hint inside the button and reports its top and bottom and its line count", function()
            local line = checks.TextInside(region(BUTTON), hint(1), "hint", 1)
            assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; up and down: text 6..18, frame 0..44, 1 line", line)
            assert.are.same({ line }, printed)
        end)

        it("fails a hint that wraps onto two lines, though they still fit inside the button", function()
            local err = fails(function() checks.TextInside(region(BUTTON), hint(2), "long favour", 1) end)
            assert.truthy(err:find("up and down: text 6..30, frame 0..44, 2 lines: wraps onto more lines than 1", 1, true), err)
        end)

        it("passes a hint that wraps when no line limit is asked for", function()
            local line = checks.TextInside(region(BUTTON), hint(2), "hint")
            assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; up and down: text 6..30, frame 0..44", line)
        end)

        it("fails a line pinned on its top whose wrapped text hangs below the frame", function()
            -- The region is one line high, but its text is three: from its top
            -- at 24 down to -12, below the frame's bottom at 0.
            local frame = region({ left = 0, right = 220, top = 30, bottom = 0 })
            local title = region({
                left = 46, right = 214, top = 24, bottom = 12,
                points = { "TOPLEFT", "TOPRIGHT" }, width = 150, height = 36,
            })
            local err = fails(function() checks.TextInside(frame, title, "title") end)
            assert.truthy(err:find("up and down: text -12..24, frame 0..30: spills out of its frame", 1, true), err)
        end)

        it("fails a line pinned on its bottom whose text grows above the frame's top", function()
            -- The region is one line high, but its text is four: up to 54.
            local err = fails(function()
                checks.TextInside(region(BUTTON), hint(1, { GetStringHeight = function() return 48 end }), "hint")
            end)
            assert.truthy(err:find("up and down: text 6..54, frame 0..44: spills out of its frame", 1, true), err)
        end)

        it("fails a line pinned by its middle whose text grows past the frame both ways", function()
            local centred = region({
                left = 46, right = 214, top = 28, bottom = 16,
                points = { "LEFT" }, width = 150, height = 60,
            })
            local err = fails(function() checks.TextInside(region(BUTTON), centred, "centred") end)
            assert.truthy(err:find("up and down: text -8..52, frame 0..44: spills out", 1, true), err)
        end)

        it("allows text a pixel of slack past the frame's top and bottom", function()
            -- Pinned by its bottom at 6, 39 high: its top at 45, one past the frame's 44.
            local line = checks.TextInside(region(BUTTON), hint(1, { GetStringHeight = function() return 39 end }), "hint")
            assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; up and down: text 6..45, frame 0..44", line)
            local low = region({
                left = 46, right = 214, top = 11, bottom = -1,
                points = { "TOPLEFT", "TOPRIGHT" }, width = 150, height = 12,
            })
            line = checks.TextInside(region(BUTTON), low, "title")
            assert.are.equal("LAYOUT title: text 46..214, frame 0..220; up and down: text -1..11, frame 0..44", line)
        end)

        it("passes a line pinned on its top and bottom, which keeps between them however tall its text", function()
            local boxed = region({
                left = 46, right = 214, top = 38, bottom = 6,
                points = { "TOPLEFT", "BOTTOMRIGHT" }, width = 150, height = 200,
            })
            local line = checks.TextInside(region(BUTTON), boxed, "boxed")
            assert.are.equal("LAYOUT boxed: text 46..214, frame 0..220; up and down: text 6..38, frame 0..44", line)
        end)

        it("notes a line pinned on its right whose text is cut short there", function()
            local cut = hint(1, { GetStringWidth = function() return 200 end })
            local line = checks.TextInside(region(BUTTON), cut, "hint")
            assert.are.equal(
                "LAYOUT hint: text 46..214, frame 0..220, cut short (its text is 200 wide); up and down: text 6..18, frame 0..44", line)
        end)

        -- The simulator sizes the hint to its whole text (it is pinned to the
        -- icon on one side and the button on the other), so it never wraps it
        -- and GetNumLines says 1. The game wraps it.
        local function wide(wraps, methods)
            methods = methods or {}
            methods.GetStringWidth = methods.GetStringWidth or function() return 184 end
            methods.CanWordWrap = function() return wraps end
            return hint(1, methods)
        end

        it("fails a hint the game would wrap at its width, though the client counts one line", function()
            local err = fails(function() checks.TextInside(region(BUTTON), wide(true), "long favour", 1) end)
            assert.truthy(err:find(
                "up and down: text 6..30, frame 0..44, 2 lines once wrapped at its width: wraps onto more lines than 1", 1, true), err)
        end)

        it("doesn't call a line the game would wrap cut short", function()
            local err = fails(function() checks.TextInside(region(BUTTON), wide(true), "long favour", 1) end)
            assert.truthy(err:find("LAYOUT long favour: text 46..214, frame 0..220; up and down", 1, true), err)
        end)

        it("doesn't call a line the client wraps itself cut short", function()
            local line = checks.TextInside(region(BUTTON), hint(2, { GetStringWidth = function() return 300 end }), "hint")
            assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; up and down: text 6..30, frame 0..44", line)
        end)

        it("counts the client's own lines when it already wraps as the game would", function()
            local line = checks.TextInside(region(BUTTON), hint(2, { GetStringWidth = function() return 300 end,
                CanWordWrap = function() return true end }), "hint", 2)
            assert.truthy(line:find("up and down: text 6..30, frame 0..44, 2 lines$"), line)
        end)

        it("grows a line the client counts no lines for by all the lines the game wraps onto", function()
            -- 400 wide in a 168 line wraps onto 3: 36 high, from 6 up to 42.
            local line = checks.TextInside(region(BUTTON), hint(1, { GetStringWidth = function() return 400 end,
                GetNumLines = function() return 0 end, CanWordWrap = function() return true end }), "hint", 3)
            assert.truthy(line:find("up and down: text 6..42, frame 0..44, 3 lines once wrapped at its width$"), line)
        end)

        it("reports an empty hint with word wrap on as no lines, not as wrapped", function()
            local empty = hint(1, { GetStringWidth = function() return 0 end, GetNumLines = function() return 0 end,
                CanWordWrap = function() return true end })
            local line = checks.TextInside(region(BUTTON), empty, "empty", 1)
            assert.truthy(line:find(", 0 lines$"), line)
        end)

        it("works out the wrap at the line's own width", function()
            local err = fails(function()
                checks.TextInside(region(BUTTON), wide(true, { GetStringWidth = function() return 337 end }), "hint", 2)
            end)
            assert.truthy(err:find(", 3 lines once wrapped at its width", 1, true), err)
        end)

        it("passes a wide hint with word wrap off, which the game cuts short instead", function()
            local line = checks.TextInside(region(BUTTON), wide(false), "long favour", 1)
            assert.are.equal("LAYOUT long favour: text 46..214, frame 0..220, cut short (its text is 184 wide)"
                .. "; up and down: text 6..18, frame 0..44, 1 line", line)
        end)

        it("passes a wide hint held to one line by its max lines", function()
            local line = checks.TextInside(region(BUTTON), wide(true, { GetMaxLines = function() return 1 end }),
                "long favour", 1)
            assert.truthy(line:find(", 1 line$"), line)
        end)

        it("fails a line pinned on its top that the game would wrap below the frame, though the client doesn't", function()
            local frame = region({ left = 0, right = 220, top = 30, bottom = 0 })
            local title = region({
                left = 46, right = 214, top = 24, bottom = 12,
                points = { "TOPLEFT", "TOPRIGHT" }, width = 400, height = 12, lines = 1,
            }, { CanWordWrap = function() return true end })
            local err = fails(function() checks.TextInside(frame, title, "title") end)
            assert.truthy(err:find("up and down: text -12..24, frame 0..30: spills out of its frame", 1, true), err)
        end)

        it("grows the line's own height when its text height can't be read", function()
            local err = fails(function()
                checks.TextInside(region(BUTTON), wide(true, { GetStringHeight = false,
                    GetStringWidth = function() return 600 end }), "hint")
            end)
            assert.truthy(err:find("up and down: text 6..54, frame 0..44: spills out", 1, true), err)
        end)

        it("allows the line a pixel of slack before it counts as wrapping", function()
            local line = checks.TextInside(region(BUTTON), wide(true, { GetStringWidth = function() return 169 end }),
                "hint", 1)
            assert.truthy(line:find(", 1 line$"), line)
        end)

        it("grows a line the client already wraps by the lines it misses", function()
            -- The client draws 2 lines, 24 high; the game wraps onto 4: 48 high.
            local err = fails(function()
                checks.TextInside(region(BUTTON), hint(2, { CanWordWrap = function() return true end,
                    GetStringWidth = function() return 600 end }), "hint")
            end)
            assert.truthy(err:find("up and down: text 6..54, frame 0..44: spills out", 1, true), err)
        end)

        it("doesn't work out a wrap for a line with no room at all", function()
            local squashed = region({
                left = 46, right = 46, bottom = 6, top = 18,
                points = { "BOTTOMLEFT", "BOTTOMRIGHT" }, width = 100, height = 12, lines = 1,
            }, { CanWordWrap = function() return true end })
            local line = checks.TextInside(region(BUTTON), squashed, "hint", 1)
            assert.truthy(line:find(", 1 line$"), line)
        end)

        it("passes a hint that wraps onto no more lines than its limit", function()
            local line = checks.TextInside(region(BUTTON), wide(true, { GetMaxLines = function() return 0 end }),
                "hint", 2)
            assert.truthy(line:find(", 2 lines once wrapped at its width$"), line)
        end)

        it("passes a hint that fits its line with word wrap on", function()
            local line = checks.TextInside(region(BUTTON), wide(true, { GetStringWidth = function() return 150 end }),
                "hint", 1)
            assert.truthy(line:find(", 1 line$"), line)
        end)

        it("counts lines from the client when it can't say whether the line wraps", function()
            local methods = { GetStringWidth = function() return 184 end }
            local line = checks.TextInside(region(BUTTON),
                hint(1, { GetStringWidth = methods.GetStringWidth, CanWordWrap = function() error("no") end }), "hint", 1)
            assert.truthy(line:find(", 1 line$"), line)
            line = checks.TextInside(region(BUTTON), hint(1, { GetStringWidth = methods.GetStringWidth,
                CanWordWrap = function() return 1 end }), "hint", 1)
            assert.truthy(line:find(", 1 line$"), line)
        end)

        it("counts the wrapped lines when the client can't count them itself", function()
            local err = fails(function()
                checks.TextInside(region(BUTTON), wide(true, { GetNumLines = false }), "hint", 1)
            end)
            assert.truthy(err:find(", 2 lines once wrapped at its width", 1, true), err)
        end)

        it("still fails text that runs past the frame's right edge", function()
            local long = region({
                left = 46, right = 196, top = 38, bottom = 26,
                points = { "TOPLEFT" }, width = 200, height = 12,
            })
            local err = fails(function() checks.TextInside(region(BUTTON), long, "long") end)
            assert.truthy(err:find("text 46..246, frame 0..220", 1, true), err)
        end)
    end)

    describe("black: a frame whose vertical edges can't be read is reported, not passed silently", function()
        local function unreadable()
            return {
                ["missing"] = false,
                ["an error"] = function() error("not here") end,
                ["nothing"] = function() return nil end,
                ["not a number"] = function() return "44" end,
            }
        end

        for what, fn in pairs(unreadable()) do
            it("reports the frame's top giving " .. what .. " in its LAYOUT line", function()
                local frame = region(BUTTON, { GetTop = fn })
                local line = checks.TextInside(frame, hint(1), "hint")
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; top and bottom can't be read here", line)
                assert.are.same({ line }, printed)
            end)

            it("reports the text line's bottom giving " .. what .. " in its LAYOUT line", function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetBottom = fn }), "hint")
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; top and bottom can't be read here", line)
            end)

            it("reports a line count giving " .. what .. " in its LAYOUT line", function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetNumLines = fn }), "hint", 1)
                assert.are.equal(
                    "LAYOUT hint: text 46..214, frame 0..220; up and down: text 6..18, frame 0..44, lines can't be counted here", line)
            end)
        end

        for what, fn in pairs(unreadable()) do
            it("falls back to the line's own top and bottom when its text height gives " .. what, function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetStringHeight = fn }), "hint")
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; up and down: text 6..18, frame 0..44", line)
            end)

            it("counts lines from the client, with word wrap on, when the text width gives " .. what, function()
                local line = checks.TextInside(region(BUTTON),
                    hint(1, { GetStringWidth = fn, CanWordWrap = function() return true end }), "hint", 1)
                assert.truthy(line:find(", 1 line$"), line)
            end)

            it("falls back to the line's own left and right when its text width gives " .. what, function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetStringWidth = fn }), "hint")
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; up and down: text 6..18, frame 0..44", line)
            end)
        end

        it("says lines can't be counted, not that they wrapped, for a fitting line the client can't count", function()
            local line = checks.TextInside(region(BUTTON),
                hint(1, { GetNumLines = false, CanWordWrap = function() return true end }), "hint", 1)
            assert.truthy(line:find(", lines can't be counted here$"), line)
        end)

        for what, fn in pairs(unreadable()) do
            it("treats anchors giving " .. what .. " as none, still reporting the line", function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetNumPoints = fn, GetPoint = fn }), "hint")
                -- No anchors: the text grows both ways from its middle, 12 high.
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; up and down: text 6..18, frame 0..44", line)
            end)
        end

        it("treats an anchor point that errors as none, whatever its error says", function()
            -- Text 24 high: pinned by its bottom it would reach 6..30; with no
            -- anchors it grows both ways from the middle, 12: 0..24.
            local line = checks.TextInside(region(BUTTON), hint(1, {
                GetPoint = function() error("BOTTOMLEFT") end, GetStringHeight = function() return 24 end,
            }), "hint")
            assert.are.equal("LAYOUT hint: text 46..214, frame 0..220; up and down: text 0..24, frame 0..44", line)
        end)

        it("reports a frame whose left and right can't be read, as before", function()
            local line = checks.TextInside(region(BUTTON, { GetLeft = false }), hint(1), "hint", 1)
            assert.are.equal("LAYOUT hint: edges can't be read here", line)
            assert.are.same({ line }, printed)
        end)
    end)
end)

describe("UI simulator layout check (PushedDownInside)", function()
    local checks, printed

    before_each(function() checks, printed = loadChecks() end)

    -- A page 300 high, 120 wide, its regions and buttons given.
    local function page(regions, children)
        local p = region({ left = 0, right = 120, top = 300, bottom = 0 })
        function p.GetRegions() return unpack(regions) end
        function p.GetChildren() return unpack(children or {}) end
        return p
    end

    -- A shown text line, pinned on its left and right 10 to 110 (100 wide),
    -- one line high from top; its text is width wide, so it wraps at 100.
    local function text(label, top, width)
        return region({ left = 10, right = 110, top = top, bottom = top - 12, points = { "TOPLEFT", "RIGHT" } }, {
            GetObjectType = function() return "FontString" end,
            IsShown = function() return true end,
            GetText = function() return label end,
            CanWordWrap = function() return true end,
            GetStringWidth = function() return width end,
            GetNumLines = function() return 1 end,
            GetMaxLines = function() return 0 end,
        })
    end

    local function button(label, top)
        return region({ left = 10, right = 90, top = top, bottom = top - 22 }, {
            GetObjectType = function() return "Button" end,
            IsShown = function() return true end,
            GetText = function() return label end,
        })
    end

    it("passes a page with no wrapped text, and names its lowest region (white)", function()
        local line = checks.PushedDownInside(page({ text("Heading", 280, 50) }, { button("Clear", 40) }), "page")
        assert.are.equal('LAYOUT page pushed down by wrapped text: lowest "Clear" ends at 18, frame bottom 0', line)
        assert.are.same({ line }, printed)
    end)

    it("fails a button pushed off the page by text that wraps above it (black)", function()
        -- 1000 wide in 100: ten lines, nine extra, 153 px. The button's bottom
        -- at 98 ends at -55.
        local err = fails(function()
            checks.PushedDownInside(page({ text("Long note", 280, 1000) }, { button("Clear", 120) }), "page")
        end)
        assert.truthy(err:find('lowest "Clear" ends at -55, frame bottom 0: would leave its frame in the game', 1, true), err)
    end)

    it("doesn't push a region that is above the wrapping text (white)", function()
        -- The note at 60 wraps to three lines (34 px extra) and ends at 14.
        -- The button above it, at 280, stays where it is.
        local line = checks.PushedDownInside(page({ text("Note", 60, 250) }, { button("Clear", 280) }), "page")
        assert.are.equal('LAYOUT page pushed down by wrapped text: lowest "Note" ends at 14, frame bottom 0', line)
    end)

    it("counts the lowest region's own wrapped lines too (black)", function()
        -- Alone, one line high from 40 to 28, but three lines in the game: it
        -- ends at -6, below the page.
        local err = fails(function() checks.PushedDownInside(page({ text("Note", 40, 250) }), "page") end)
        assert.truthy(err:find('lowest "Note" ends at -6, frame bottom 0', 1, true), err)
    end)

    it("adds the wrapping of every line above, and the region's own (black)", function()
        -- Two notes above wrap one extra line each (34 px); the bottom note at
        -- 80 wraps two extra (34 px) itself: its bottom at 68 ends at 0.
        local line = checks.PushedDownInside(page({ text("A", 280, 150), text("B", 200, 150), text("C", 80, 250) }),
            "page")
        assert.are.equal('LAYOUT page pushed down by wrapped text: lowest "C" ends at 0, frame bottom 0', line)
        -- A pixel of slack, like TextInside's.
        line = checks.PushedDownInside(page({ text("A", 280, 150), text("B", 200, 150), text("C", 79, 250) }), "page")
        assert.are.equal('LAYOUT page pushed down by wrapped text: lowest "C" ends at -1, frame bottom 0', line)
        local err = fails(function()
            checks.PushedDownInside(page({ text("A", 280, 150), text("B", 200, 150), text("C", 77, 250) }), "page")
        end)
        assert.truthy(err:find('lowest "C" ends at -3, frame bottom 0: would leave its frame', 1, true), err)
    end)

    it("doesn't lift a line the client already draws on more lines than it needs (black)", function()
        -- Two lines by a line break, though its text fits on one: nothing to add,
        -- and nothing taken away either.
        local broken = text("Two lines", 40, 50)
        broken.GetNumLines = function() return 2 end
        local line = checks.PushedDownInside(page({ broken }), "page")
        assert.are.equal('LAYOUT page pushed down by wrapped text: lowest "Two lines" ends at 28, frame bottom 0', line)
    end)

    it("adds nothing for a line whose edges can't be read, and raises no error (black)", function()
        local unreadable = text("Note", 40, 1000)
        unreadable.GetLeft = function() error("no") end
        local line = checks.PushedDownInside(page({ text("Heading", 280, 50), unreadable }), "page")
        -- Placed by its top and bottom as the client gives them, with no wrapping added.
        assert.are.equal('LAYOUT page pushed down by wrapped text: lowest "Note" ends at 28, frame bottom 0', line)
    end)

    it("doesn't count a line that can't wrap (white)", function()
        local cut = text("Row", 40, 1000)
        cut.CanWordWrap = function() return false end
        local line = checks.PushedDownInside(page({ text("Heading", 280, 50), cut }), "page")
        assert.are.equal('LAYOUT page pushed down by wrapped text: lowest "Row" ends at 28, frame bottom 0', line)
    end)
end)

describe("UI simulator layout check for an options tab (TabTextInside, #112)", function()
    local checks, printed

    before_each(function() checks, printed = loadChecks() end)

    -- A text line pinned on its left only, at left, one line high from top
    -- 280: it grows to its text, width wide.
    local function text(label, left, width, visible)
        return region({ left = left, right = left + 10, top = 280, bottom = 268, points = { "TOPLEFT" } }, {
            GetObjectType = function() return "FontString" end,
            IsVisible = function() return visible ~= false end,
            GetText = function() return label end,
            GetStringWidth = function() return width end,
            GetNumLines = function() return 1 end,
        })
    end

    -- A frame (a checkbox or a button) 26 wide at left, holding regions.
    local function frame(kind, left, regions, visible, methods)
        local f = region({ left = left, right = left + 26, top = 284, bottom = 258 }, methods)
        function f.GetObjectType() return kind end
        function f.IsVisible() return visible ~= false end
        function f.GetRegions() return unpack(regions or {}) end
        return f
    end

    -- A checkbox at left, its label just right of it.
    local function checkbox(label, left, width, visible)
        return frame("CheckButton", left, { text(label, left + 28, width) }, visible)
    end

    -- A button from left to right, its label width wide from 4 inside it.
    local function button(label, left, right, width)
        local fs = text(label, left + 4, width)
        local b = frame("Button", left, {}, true, { GetFontString = function() return fs end })
        b.GetRight = function() return right end
        return b
    end

    -- The panel's scrolling content: 600 wide, 300 high.
    local function content(regions, children)
        local c = region({ left = 0, right = 600, top = 300, bottom = 0 })
        function c.GetRegions() return unpack(regions or {}) end
        function c.GetChildren() return unpack(children or {}) end
        return c
    end

    local function anyLine(prefix)
        for _, line in ipairs(printed) do
            if line:sub(1, #prefix) == prefix then return line end
        end
    end

    it("passes a tab whose labels, checkboxes and buttons are inside, each LAYOUT line naming the tab (white)", function()
        checks.TabTextInside(content({ text("Buff Back  (sent to /say)", 16, 200) },
            { checkbox("Say a line once my buff lands", 12, 180), button("Up", 300, 344, 20) }), "Buff Back tab")
        assert.are.equal(4, #printed)
        assert.are.equal('LAYOUT Buff Back tab "Buff Back  (sent to /say)": text 16..216, frame 0..600; '
            .. "up and down: text 268..280, frame 0..300", printed[1])
        assert.are.equal('LAYOUT Buff Back tab checkbox "Say a line once my buff lands": text 40..220, '
            .. "frame 0..600; up and down: text 268..280, frame 0..300, 1 line", printed[2])
        assert.truthy(anyLine('LAYOUT Buff Back tab button "Up": text 304..324, frame 300..344'), printed[3])
        assert.truthy(anyLine('LAYOUT Buff Back tab button on the panel "Up": text 304..324, frame 0..600'), printed[4])
    end)

    it("fails a checkbox label that spills out of the panel, naming the tab (black)", function()
        local err = fails(function()
            checks.TabTextInside(content({}, { checkbox("Show the button in capital cities", 400, 300) }),
                "Buff Back tab")
        end)
        assert.truthy(err:find('LAYOUT Buff Back tab checkbox "Show the button in capital cities": text 428..728, '
            .. "frame 0..600", 1, true), err)
        assert.truthy(err:find("spills out of its frame", 1, true), err)
    end)

    it("fails a checkbox label wrapped onto two lines, though inside the panel (black)", function()
        local box = checkbox("Stay quiet in capital cities", 12, 180)
        local label = box.GetRegions()
        label.GetNumLines = function() return 2 end
        local err = fails(function() checks.TabTextInside(content({}, { box }), "Buff Thanks tab") end)
        assert.truthy(err:find('LAYOUT Buff Thanks tab checkbox "Stay quiet in capital cities": text 40..220, '
            .. "frame 0..600; up and down: text 268..280, frame 0..300, 2 lines: wraps onto more lines than 1",
            1, true), err)
    end)

    it("fails a label on the panel that spills out of it (black)", function()
        local err = fails(function()
            checks.TabTextInside(content({ text("Welcomes joiners, several per line", 16, 700) }), "Party Join tab")
        end)
        assert.truthy(err:find('LAYOUT Party Join tab "Welcomes joiners, several per line": text 16..716, '
            .. "frame 0..600", 1, true), err)
    end)

    it("fails a button whose label is wider than the button, though inside the panel (black)", function()
        local err = fails(function()
            checks.TabTextInside(content({}, { button("How to thank: a line and a /thank emote", 100, 390, 300) }),
                "Buff Thanks tab")
        end)
        assert.truthy(err:find('LAYOUT Buff Thanks tab button "How to thank: a line and a /thank emote": text 104..404, '
            .. "frame 100..390", 1, true), err)
        -- The same label is inside the panel: only its button check failed.
        assert.truthy(anyLine('LAYOUT Buff Thanks tab button on the panel "How to thank: a line and a /thank emote": '
            .. "text 104..404, frame 0..600"))
    end)

    it("checks every line before failing, so one spill can't hide another (black)", function()
        local err = fails(function()
            checks.TabTextInside(content({ text("Too wide", 16, 700) }, { checkbox("Also too wide", 500, 200),
                checkbox("Fits", 12, 40) }), "Guild Login tab")
        end)
        assert.truthy(err:find('"Too wide"', 1, true) and err:find('"Also too wide"', 1, true), err)
        assert.are.equal(3, #printed)
    end)

    it("skips what another tab shows, hidden here, even when it would spill (white)", function()
        -- A button with no label (the buff mode key before it's filled) has
        -- nothing to check, even when it sits past the panel's edge.
        checks.TabTextInside(content({ text("Heading", 16, 50), text("Hidden note", 16, 900, false) },
            { checkbox("Hidden box", 500, 300, false), checkbox("Shown box", 12, 60), button("", 590, 900, 300) }),
            "Guild Join tab")
        assert.are.equal(2, #printed)
        assert.is_nil(anyLine('LAYOUT Guild Join tab button'))
        assert.is_nil(anyLine('LAYOUT Guild Join tab "Hidden note"'))
        assert.is_nil(anyLine('LAYOUT Guild Join tab checkbox "Hidden box"'))
    end)

    it("fails a tab that shows no text at all, rather than passing it (black)", function()
        local err = fails(function()
            checks.TabTextInside(content({ text("", 16, 0) }, { checkbox("Hidden", 12, 60, false) }), "Hello Again tab")
        end)
        assert.truthy(err:find("Hello Again tab: no text to check", 1, true), err)
    end)
end)

describe("UI simulator: the message rows' order and settling a tab's layout (#112)", function()
    local checks, printed

    before_each(function() checks, printed = loadChecks() end)

    -- A visible region on the content with text, top to top - 12.
    local function at(label, top, kind)
        return region({ left = 16, right = 40, top = top, bottom = top - 12 }, {
            GetObjectType = function() return kind or "FontString" end,
            IsVisible = function() return true end,
            GetText = function() return label end,
        })
    end

    -- Rows "1." to "n." 20 px apart from 600 down, except where tops says.
    local function rows(n, tops)
        local list = {}
        for i = 1, n do list[i] = at(i .. ".", (tops or {})[i] or (620 - 20 * i)) end
        return list
    end

    local function content(regions, children)
        local c = region({ left = 0, right = 600, top = 1000, bottom = -900 })
        function c.GetRegions() return unpack(regions) end
        function c.GetChildren() return unpack(children or {}) end
        return c
    end

    it("passes rows drawn top to bottom with the button below the last (white)", function()
        local line = checks.RowsInOrder(content(rows(30), { at("Preview random", -20, "Button") }), "Buff Back tab",
            "Preview random")
        assert.are.equal('LAYOUT Buff Back tab message rows: 1. to 30. in order top to bottom, then "Preview random"',
            line)
        assert.are.same({ line }, printed)
    end)

    it("fails a row left in the last tab's place, above the row before it (black)", function()
        -- As the simulator left Buff Thanks: 17. moved down to 280, 18. stayed at 440.
        local err = fails(function()
            checks.RowsInOrder(content(rows(30, { [17] = 280, [18] = 440 }), { at("Preview random", -20, "Button") }),
                "Buff Thanks tab", "Preview random")
        end)
        assert.truthy(err:find("18. at 440 is not below 17. at 280", 1, true), err)
        assert.truthy(err:find("the layout is stale or out of order", 1, true), err)
    end)

    it("fails a row drawn at the same place as the row before it (black)", function()
        local err = fails(function()
            checks.RowsInOrder(content(rows(30, { [18] = 280 }), { at("Preview random", -20, "Button") }),
                "Guild Join tab", "Preview random")
        end)
        assert.truthy(err:find("18. at 280 is not below 17. at 280", 1, true), err)
    end)

    it("compares a row past an unreadable one with the last row read (black)", function()
        local list = rows(3, { [3] = 650 })
        list[2].GetTop = function() error("no") end
        local err = fails(function()
            checks.RowsInOrder(content(list, { at("Preview random", 0, "Button") }), "tab", "Preview random")
        end)
        assert.truthy(err:find("3. at 650 is not below 1. at 600", 1, true), err)
        -- And the button with the last row read, when the last row can't be.
        list = rows(3)
        list[3].GetTop = function() error("no") end
        err = fails(function()
            checks.RowsInOrder(content(list, { at("Preview random", 590, "Button") }), "tab", "Preview random")
        end)
        assert.truthy(err:find('"Preview random" at 590 is not below 2. at 580', 1, true), err)
    end)

    it("reads only the rows and the visible button, not other text with numbers or a hidden copy (white)", function()
        local list = rows(30)
        -- Other lines with numbers, out of the rows' order.
        list[#list + 1] = at("Offer for (minutes): 10", 900)
        list[#list + 1] = at("10", 900)
        local hidden = at("Preview random", 500, "Button")
        hidden.IsVisible = function() return false end
        local line = checks.RowsInOrder(content(list, { at("Preview random", -20, "Button"), hidden }), "Buff Back tab",
            "Preview random")
        assert.are.equal('LAYOUT Buff Back tab message rows: 1. to 30. in order top to bottom, then "Preview random"',
            line)
    end)

    it("fails a button left above the last row (black)", function()
        local err = fails(function()
            checks.RowsInOrder(content(rows(30), { at("Preview random", 154, "Button") }), "Party Join tab",
                "Preview random")
        end)
        assert.truthy(err:find('"Preview random" at 154 is not below 30. at 20', 1, true), err)
    end)

    it("fails when the rows or the button can't be read or found, rather than passing (black)", function()
        local unreadable = rows(3)
        unreadable[2].GetTop = function() error("no") end
        local err = fails(function()
            checks.RowsInOrder(content(unreadable, { at("Preview random", 0, "Button") }), "tab", "Preview random")
        end)
        assert.truthy(err:find("2. can't be read", 1, true), err)
        err = fails(function() checks.RowsInOrder(content(rows(3)), "tab", "Preview random") end)
        assert.truthy(err:find('"Preview random" can\'t be read', 1, true), err)
        err = fails(function() checks.RowsInOrder(content({ at("Heading", 900) }), "tab", "Preview random") end)
        assert.truthy(err:find("tab: no message rows", 1, true), err)
    end)

    -- A stand-in that records what is done to its anchors.
    local function anchored(name, points, log)
        local r = { points = points }
        function r.GetNumPoints() return #r.points end
        function r.GetPoint(_, i) return unpack(r.points[i], 1, 5) end
        function r.ClearAllPoints() r.points = {}; log[#log + 1] = name .. " clear" end
        function r.SetPoint(_, ...) r.points[#r.points + 1] = { ... }; log[#log + 1] = name .. " set" end
        function r.GetTop() log[#log + 1] = name .. " read"; return 1 end
        function r.GetBottom() return 0 end
        return r
    end

    it("sets every region's anchors again, the same, in order, laying each out before the next (white)", function()
        local log = {}
        local first = anchored("1.", { { "TOPLEFT", "header", "BOTTOMLEFT", 0, -10 } }, log)
        local second = anchored("2.", { { "TOPLEFT", first, "BOTTOMLEFT", 0, -8 } }, log)
        local button = anchored("Preview", { { "TOPLEFT", second, "BOTTOMLEFT", 0, -16 },
            { "RIGHT", "content", "RIGHT", -24, 0 } }, log)
        local loose = anchored("loose", {}, log)
        checks.Settle(content({ first, second, loose }, { button }))
        assert.are.same({ { "TOPLEFT", "header", "BOTTOMLEFT", 0, -10 } }, first.points)
        assert.are.same({ { "TOPLEFT", first, "BOTTOMLEFT", 0, -8 } }, second.points)
        assert.are.same({ { "TOPLEFT", second, "BOTTOMLEFT", 0, -16 }, { "RIGHT", "content", "RIGHT", -24, 0 } },
            button.points)
        local once = { "1. clear", "1. set", "1. read", "2. clear", "2. set", "2. read",
            "Preview clear", "Preview set", "Preview set", "Preview read" }
        local twice = {}
        for _ = 1, 2 do for _, step in ipairs(once) do twice[#twice + 1] = step end end
        assert.are.same(twice, log, "a region with no anchors is left alone")
    end)
end)

describe("UI simulator layout check at more than one resolution (OnScreen, #148)", function()
    -- A screen of the given pixel size, as the simulator's UIParent answers it
    -- at scale 1: one canvas unit a pixel (src/bin/wow_sim/gui_commands.rs).
    local function atResolution(width, height)
        return loadChecks({
            GetPhysicalScreenSize = function() return width, height end,
            UIParent = {
                GetWidth = function() return width end,
                GetHeight = function() return height end,
                GetEffectiveScale = function() return 1 end,
            },
        })
    end

    -- A frame at scale 1 with these edges.
    local function frameAt(left, right, bottom, top)
        local f = region({ left = left, right = right, bottom = bottom, top = top })
        f.GetEffectiveScale = function() return 1 end
        return f
    end

    it("names the resolution in each LAYOUT line (white)", function()
        for _, size in ipairs({ { 1024, 768 }, { 1920, 1080 } }) do
            local checks, printed = atResolution(size[1], size[2])
            checks.OnScreen(frameAt(100, 300, 100, 200), "panel")
            local expected = ("LAYOUT [%dx%d] panel: 100..300 x 100..200, screen %d x %d"):format(
                size[1], size[2], size[1], size[2])
            assert.are.same({ expected }, printed)
        end
    end)

    it("fails a frame that is off screen at 1920 x 1080 and on screen at 2560 x 1440 (black)", function()
        local frame = frameAt(1800, 1925, 100, 200)
        local err = fails(function() atResolution(1920, 1080).OnScreen(frame, "right edge") end)
        assert.truthy(err:find("screen 1920 x 1080", 1, true) and err:find("off the screen", 1, true), err)
        atResolution(2560, 1440).OnScreen(frame, "right edge")
    end)

    it("passes at 1920 x 1080 a frame that is off screen at 1024 x 768, so each size is judged on its own (black)", function()
        local frame = frameAt(1000, 1100, 700, 800)
        local err = fails(function() atResolution(1024, 768).OnScreen(frame, "wide") end)
        assert.truthy(err:find("off the screen", 1, true), err)
        atResolution(1920, 1080).OnScreen(frame, "wide")
    end)

    it("leaves the line as it was where the client can't give a size, as in these specs (white)", function()
        local checks, printed = loadChecks({
            UIParent = {
                GetWidth = function() return 1024 end, GetHeight = function() return 768 end,
                GetEffectiveScale = function() return 1 end,
            },
        })
        checks.OnScreen(frameAt(0, 100, 0, 100), "panel")
        assert.is_truthy(printed[1]:find("^LAYOUT panel: "), printed[1])
    end)
end)
