-- Spec: #65
-- The addon's own icon: the minimap button, the addon compartment and the
-- AddOns list all show Media/Icon.tga, and the release zip ships it as a
-- texture WoW can load.
local wow = require("spec.support.wow")

local ICON = "Interface\\AddOns\\FriendlyForever\\Media\\Icon"
local SIZE = 64

-- Checks bytes are a texture WoW loads as our icon: an uncompressed
-- true-colour TGA, SIZE x SIZE, 32 bits with an 8-bit alpha channel that is
-- really used (clear corners, solid middle). Returns true, or false and why.
local function checkTga(data)
    if type(data) ~= "string" or #data < 18 then return false, "too short for a TGA header" end
    local function u8(i) return data:byte(i + 1) end
    local function u16(i) return u8(i) + u8(i + 1) * 256 end
    local idLength, colorMapType, imageType = u8(0), u8(1), u8(2)
    if colorMapType ~= 0 then return false, "has a colour map" end
    if imageType ~= 2 then return false, "image type " .. imageType .. ", not uncompressed true-colour" end
    local width, height, depth, descriptor = u16(12), u16(14), u8(16), u8(17)
    if width ~= SIZE or height ~= SIZE then return false, width .. "x" .. height end
    if depth ~= 32 then return false, depth .. " bits per pixel" end
    if descriptor % 16 ~= 8 then return false, (descriptor % 16) .. " alpha bits" end
    if descriptor >= 64 then return false, "interleaved" end
    local first = 18 + idLength
    if #data < first + width * height * 4 then return false, "pixel data cut short" end
    local clear, solid = 0, 0
    for i = first + 3, first + width * height * 4 - 1, 4 do
        local alpha = u8(i)
        if alpha == 0 then clear = clear + 1 elseif alpha == 255 then solid = solid + 1 end
    end
    if clear == 0 or solid == 0 then return false, "alpha channel unused" end
    return true
end

local function sh(command)
    local handle = io.popen(command)
    local out = handle:read("*a")
    handle:close()
    return out
end

-- A valid header and pixels, for damaging one field at a time. allSolid:
-- every pixel opaque, so the alpha channel carries nothing.
local function goodTga(allSolid)
    local header = string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, SIZE, 0, SIZE, 0, 32, 8)
    local pixels = {}
    for i = 1, SIZE * SIZE do pixels[i] = string.char(10, 20, 30, (allSolid or i % 2 == 0) and 255 or 0) end
    return header .. table.concat(pixels)
end

local function patch(data, offset, byte)
    return data:sub(1, offset) .. string.char(byte) .. data:sub(offset + 2)
end

describe("Addon icon", function()
    describe("in game (white)", function()
        it("the minimap button uses the new icon", function()
            local ns = wow.boot()
            assert.are.equal(ICON, ns.Minimap.ICON)
            assert.are.equal(ICON, _G.FriendlyForeverMinimapButton.icon.texture)
        end)

        it("the compartment entry uses the new icon", function()
            wow.boot()
            assert.are.equal(1, #wow.compartment)
            assert.are.equal(ICON, wow.compartment[1].icon)
        end)

        it("the AddOns list uses the new icon", function()
            local meta = wow.parseToc()
            assert.are.equal(ICON, meta.IconTexture)
        end)

        it("names a texture that's in the repository", function()
            local file = ICON:gsub("^Interface\\AddOns\\FriendlyForever\\", ""):gsub("\\", "/") .. ".tga"
            assert.are.equal("Media/Icon.tga", file)
            assert.is_true(checkTga(wow.readFile(file)))
        end)

        it("leaves no reference to the old icon", function()
            local old = "Achievement_" .. "Reputation_01" -- split, so this file doesn't match
            local files = sh('cd "' .. wow.ROOT .. '" && git ls-files')
            local count = 0
            for path in files:gmatch("[^\n]+") do
                count = count + 1
                local handle = io.open(wow.ROOT .. path, "rb")
                if handle then
                    local text = handle:read("*a")
                    handle:close()
                    assert.is_nil(text:find(old, 1, true), path .. " still names the old icon")
                end
            end
            assert.is_true(count > 0, "no tracked files listed")
        end)
    end)

    describe("in the release zip (black)", function()
        local zip

        setup(function()
            zip = sh('"' .. wow.ROOT .. 'scripts/package.sh" 2>&1'):match("([^\n]*%.zip)")
            assert.is_truthy(zip, "package script did not report a zip")
        end)

        it("contains FriendlyForever/Media/Icon.tga", function()
            local entries = sh('unzip -Z1 "' .. zip .. '"')
            assert.is_truthy(("\n" .. entries):find("\nFriendlyForever/Media/Icon.tga\n", 1, true), entries)
        end)

        it("is a valid 64x64 TGA with an alpha channel", function()
            local data = sh('unzip -p "' .. zip .. '" FriendlyForever/Media/Icon.tga')
            local ok, why = checkTga(data)
            assert.is_true(ok, why)
        end)

        it("the check itself rejects textures WoW wouldn't show as our icon", function()
            local good = goodTga()
            assert.is_true(checkTga(good))
            local bad = {
                ["nothing"] = "",
                ["a cut-off header"] = good:sub(1, 17),
                ["cut-off pixels"] = good:sub(1, #good - 1),
                ["a PNG"] = wow.readFile("art/friendly-forever-logo.png"),
                ["a colour map"] = patch(good, 1, 1),
                ["RLE compression"] = patch(good, 2, 10),
                ["the wrong width"] = patch(good, 12, 32),
                ["the wrong height"] = patch(good, 14, 128),
                ["24 bits, no alpha"] = patch(patch(good, 16, 24), 17, 0),
                ["32 bits but no alpha bits"] = patch(good, 17, 0),
                ["interleaved rows"] = patch(good, 17, 8 + 64),
                ["an unused alpha channel"] = goodTga(true),
            }
            for name, data in pairs(bad) do
                local ok, why = checkTga(data)
                assert.is_false(ok, name .. " passed the check")
                assert.is_string(why, name)
            end
        end)
    end)
end)
