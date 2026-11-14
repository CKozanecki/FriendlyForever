-- A seeded random number generator for the chaos (red) specs, the same on
-- every computer. Lua 5.1's math.random uses the platform's C rand(), so a
-- seed runs one storm on Linux and another on macOS (#76).
--
-- This is MINSTD (Park and Miller, multiplier 48271, modulus 2^31 - 1), the
-- generator C++ calls std::minstd_rand. Its arithmetic stays below 2^47, so
-- Lua's doubles hold every step exactly.
--
-- Like math.random: random() is in [0, 1), random(n) in 1..n and
-- random(m, n) in m..n, and fractional bounds are rounded down.
local M = {}

local MODULUS = 2147483647 -- 2^31 - 1, a prime
local MULTIPLIER = 48271

local state = 1

-- MINSTD's first output is seed * 48271 mod (2^31 - 1), so for a small seed it
-- is near 0 (#165). seed() discards this many outputs, so the first draw a
-- spec sees is spread over the range whatever the seed.
M.WARMUP = 5

-- Start the sequence from seed s. The state is s mod (2^31 - 1); 0, where
-- the generator would stay forever, starts at 1 instead. Then the first
-- WARMUP outputs are discarded (#165).
function M.seed(s)
    assert(type(s) == "number" and s == s, "seed must be a number")
    state = math.floor(s) % MODULUS
    if state == 0 then state = 1 end
    for _ = 1, M.WARMUP do M.next() end
end

-- The next raw value, an integer in 1..2^31 - 2.
function M.next()
    state = (state * MULTIPLIER) % MODULUS
    return state
end

function M.random(m, n)
    local r = (M.next() - 1) / (MODULUS - 1) -- [0, 1)
    if m == nil then return r end
    if n == nil then m, n = 1, m end
    m, n = math.floor(m), math.floor(n)
    assert(m <= n, "interval is empty")
    return m + math.floor(r * (n - m + 1))
end

return M
