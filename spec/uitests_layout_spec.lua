-- Spec: #90
-- The UI simulator's layout check (uitests/scenarios.lua), run here against
-- stand-in regions whose edges, anchors and text sizes each test sets
-- itself, so the expected answer comes from those numbers and not from the
-- check. The scenarios themselves run only in the simulator.

-- Loads the scenario file the way the simulator does, with test() and
-- A_Print stubbed, and returns its layout checks and what they printed.
local function loadChecks()
    local printed = {}
    local env = setmetatable({
        test = function() end,
        A_Print = function(text) printed[#printed + 1] = text end,
    }, { __index = _G })
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
            assert.are.equal("LAYOUT hint: text 46..214, frame 0..220 x 6..18, frame 0..44, 1 line", line)
            assert.are.same({ line }, printed)
        end)

        it("fails a hint that wraps onto two lines, though they still fit inside the button", function()
            local err = fails(function() checks.TextInside(region(BUTTON), hint(2), "long favour", 1) end)
            assert.truthy(err:find("x 6..30, frame 0..44, 2 lines: wraps onto more lines than 1", 1, true), err)
        end)

        it("passes a hint that wraps when no line limit is asked for", function()
            local line = checks.TextInside(region(BUTTON), hint(2), "hint")
            assert.are.equal("LAYOUT hint: text 46..214, frame 0..220 x 6..30, frame 0..44", line)
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
            assert.truthy(err:find("x -12..24, frame 0..30: spills out of its frame", 1, true), err)
        end)

        it("fails a line pinned on its bottom whose text grows above the frame's top", function()
            -- The region is one line high, but its text is four: up to 54.
            local err = fails(function()
                checks.TextInside(region(BUTTON), hint(1, { GetStringHeight = function() return 48 end }), "hint")
            end)
            assert.truthy(err:find("x 6..54, frame 0..44: spills out of its frame", 1, true), err)
        end)

        it("fails a line pinned by its middle whose text grows past the frame both ways", function()
            local centred = region({
                left = 46, right = 214, top = 28, bottom = 16,
                points = { "LEFT" }, width = 150, height = 60,
            })
            local err = fails(function() checks.TextInside(region(BUTTON), centred, "centred") end)
            assert.truthy(err:find("x -8..52, frame 0..44: spills out", 1, true), err)
        end)

        it("passes a line pinned on its top and bottom, which keeps between them however tall its text", function()
            local boxed = region({
                left = 46, right = 214, top = 38, bottom = 6,
                points = { "TOPLEFT", "BOTTOMRIGHT" }, width = 150, height = 200,
            })
            local line = checks.TextInside(region(BUTTON), boxed, "boxed")
            assert.are.equal("LAYOUT boxed: text 46..214, frame 0..220 x 6..38, frame 0..44", line)
        end)

        it("notes a line pinned on its right whose text is cut short there", function()
            local cut = hint(1, { GetStringWidth = function() return 200 end })
            local line = checks.TextInside(region(BUTTON), cut, "hint")
            assert.are.equal(
                "LAYOUT hint: text 46..214, frame 0..220, cut short (its text is 200 wide) x 6..18, frame 0..44", line)
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
                "x 6..30, frame 0..44, 2 lines once wrapped at its width: wraps onto more lines than 1", 1, true), err)
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
                .. " x 6..18, frame 0..44, 1 line", line)
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
            assert.truthy(err:find("x -12..24, frame 0..30: spills out of its frame", 1, true), err)
        end)

        it("grows the line's own height when its text height can't be read", function()
            local err = fails(function()
                checks.TextInside(region(BUTTON), wide(true, { GetStringHeight = false,
                    GetStringWidth = function() return 600 end }), "hint")
            end)
            assert.truthy(err:find("x 6..54, frame 0..44: spills out", 1, true), err)
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
            assert.truthy(err:find("x 6..54, frame 0..44: spills out", 1, true), err)
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
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220, top and bottom can't be read here", line)
                assert.are.same({ line }, printed)
            end)

            it("reports the text line's bottom giving " .. what .. " in its LAYOUT line", function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetBottom = fn }), "hint")
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220, top and bottom can't be read here", line)
            end)

            it("reports a line count giving " .. what .. " in its LAYOUT line", function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetNumLines = fn }), "hint", 1)
                assert.are.equal(
                    "LAYOUT hint: text 46..214, frame 0..220 x 6..18, frame 0..44, lines can't be counted here", line)
            end)
        end

        for what, fn in pairs(unreadable()) do
            it("falls back to the line's own top and bottom when its text height gives " .. what, function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetStringHeight = fn }), "hint")
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220 x 6..18, frame 0..44", line)
            end)

            it("counts lines from the client, with word wrap on, when the text width gives " .. what, function()
                local line = checks.TextInside(region(BUTTON),
                    hint(1, { GetStringWidth = fn, CanWordWrap = function() return true end }), "hint", 1)
                assert.truthy(line:find(", 1 line$"), line)
            end)

            it("falls back to the line's own left and right when its text width gives " .. what, function()
                local line = checks.TextInside(region(BUTTON), hint(1, { GetStringWidth = fn }), "hint")
                assert.are.equal("LAYOUT hint: text 46..214, frame 0..220 x 6..18, frame 0..44", line)
            end)
        end

        it("reports a frame whose left and right can't be read, as before", function()
            local line = checks.TextInside(region(BUTTON, { GetLeft = false }), hint(1), "hint", 1)
            assert.are.equal("LAYOUT hint: edges can't be read here", line)
            assert.are.same({ line }, printed)
        end)
    end)
end)
