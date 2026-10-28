-- Spec: #76
-- The chaos specs' random number generator: the same storms on every computer.
local wow = require("spec.support.wow")
local random = require("spec.support.random")

describe("The chaos specs' random numbers", function()
    describe("a fixed sequence for a fixed seed (white)", function()
        it("gives MINSTD's known values from seed 1, on every platform", function()
            random.seed(1)
            local got = {}
            for i = 1, 5 do got[i] = random.next() end
            assert.are.same({ 48271, 182605794, 1291394886, 1914720637, 2078669041 }, got)
        end)

        it("turns them into the same whole numbers on every platform", function()
            random.seed(1)
            local got = {}
            for i = 1, 10 do got[i] = random.random(6) end
            assert.are.same({ 1, 1, 4, 6, 6, 2, 4, 3, 2, 5 }, got)
            random.seed(1)
            assert.are.equal((48271 - 1) / (2147483647 - 1), random.random(), "the first fraction, exactly")
            random.seed(1)
            got = {}
            for i = 1, 6 do got[i] = random.random(10, 20) end
            assert.are.same({ 10, 10, 16, 19, 20, 12 }, got)
        end)

        it("reaches 399268537 on the 10000th value from seed 1, as the C++ standard requires of minstd_rand",
            function()
                random.seed(1)
                local value
                for _ = 1, 10000 do value = random.next() end
                assert.are.equal(399268537, value)
            end)

        it("gives the same fractions and whole numbers for the same seed, every time", function()
            random.seed(2026)
            local first = { random.random(), random.random(6), random.random(10, 20), random.random() }
            random.seed(2026)
            local again = { random.random(), random.random(6), random.random(10, 20), random.random() }
            assert.are.same(first, again)
            -- And from known values: seed 2026's first raw value is 2026 * 48271 mod (2^31 - 1).
            random.seed(2026)
            assert.are.equal(2026 * 48271 % 2147483647, random.next())
        end)

        it("starts each seed's own sequence", function()
            random.seed(4)
            local a = random.next()
            random.seed(29)
            assert.are_not.equal(a, random.next())
        end)
    end)

    describe("staying in range (black)", function()
        it("keeps random() in [0, 1) over many draws", function()
            random.seed(7)
            for _ = 1, 20000 do
                local r = random.random()
                assert.is_true(r >= 0 and r < 1, tostring(r))
            end
        end)

        it("keeps random(n) in 1..n and reaches every value, including n = 1", function()
            random.seed(81)
            for _, n in ipairs({ 1, 2, 3, 6, 40 }) do
                local seen = {}
                for _ = 1, 5000 do
                    local v = random.random(n)
                    assert.is_true(v >= 1 and v <= n and v == math.floor(v), n .. ": " .. v)
                    seen[v] = true
                end
                for v = 1, n do assert.is_true(seen[v], n .. ": never gave " .. v) end
            end
        end)

        it("keeps random(m, n) in m..n and reaches every value, including m = n and negative bounds", function()
            random.seed(512)
            for _, range in ipairs({ { 1, 1 }, { 0, 1 }, { 1, 8 }, { 0, 200 }, { -3, 2 }, { 5, 5 } }) do
                local m, n = range[1], range[2]
                local seen = {}
                for _ = 1, 5000 do
                    local v = random.random(m, n)
                    assert.is_true(v >= m and v <= n and v == math.floor(v), m .. ".." .. n .. ": " .. v)
                    seen[v] = true
                end
                for v = m, n do assert.is_true(seen[v], m .. ".." .. n .. ": never gave " .. v) end
            end
        end)

        it("rounds fractional bounds down, as math.random does", function()
            random.seed(3)
            for _ = 1, 2000 do
                local v = random.random(2.9)
                assert.is_true(v == 1 or v == 2, tostring(v))
                v = random.random(1.5, 3.7)
                assert.is_true(v >= 1 and v <= 3, tostring(v))
            end
        end)

        it("refuses an empty interval", function()
            assert.has_error(function() random.random(0) end)
            assert.has_error(function() random.random(5, 4) end)
        end)

        it("doesn't stick on seed 0, and takes negative and fractional seeds", function()
            for _, s in ipairs({ 0, 2147483647, -1, -2026, 12.5 }) do
                random.seed(s)
                local a, b = random.next(), random.next()
                assert.is_true(a >= 1 and a <= 2147483646 and a == math.floor(a) and a ~= b, tostring(s))
            end
            assert.has_error(function() random.seed("1") end)
            assert.has_error(function() random.seed(0 / 0) end)
        end)
    end)

    describe("used by every spec", function()
        -- Handing math.random itself to the addon (Messages.random, Flavour.random)
        -- is fine where any sequence passes; calling it to draw a storm isn't.
        it("leaves no spec drawing from math.random, which differs between platforms", function()
            local list = io.popen('cd "' .. wow.ROOT .. '" && ls spec/*.lua spec/support/*.lua')
            local checked = 0
            for path in list:lines() do
                checked = checked + 1
                local n = 0
                for line in (wow.readFile(path) .. "\n"):gmatch("(.-)\n") do
                    n = n + 1
                    assert.is_nil(line:find("math%.random%(") or line:find("math%.randomseed%("),
                        path .. ":" .. n .. " calls math.random; use spec/support/random.lua")
                end
            end
            list:close()
            assert.is_true(checked > 30, "spec files checked: " .. checked)
        end)
    end)
end)
