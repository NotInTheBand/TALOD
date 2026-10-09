-- TALOD - signature check: is a note signed with the author's key?
--
-- RSA with the public exponent 65537. The author's tool signs a short note
-- ("<name>|<version>|<date>") laid out as 00 01 FF..FF 00 <note>, the width of
-- the key; a copy of the addon raises the signature to 65537 mod n and
-- compares. Checking needs only the public key (Release.lua); making a
-- signature needs the private key, which never leaves the author's machine.
--
-- Numbers are arrays of 24-bit limbs, least significant first (index 0):
-- a product of two limbs (2^48) plus carries stays below 2^53, where Lua's
-- doubles are exact. Multiplication is Montgomery's (CIOS), so no division
-- by n is needed; R^2 mod n and -1/n mod 2^24 come with the key.

local ADDON_NAME, ns = ...

local Signature = {}
ns.Signature = Signature

local B = 16777216            -- 2^24
local floor = math.floor

---------------------------------------------------------------------------
-- Bytes and limbs
---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUE = {}
for i = 1, #B64 do B64_VALUE[B64:sub(i, i)] = i - 1 end

-- Base64 -> array of bytes, or nil.
function Signature.Base64(text)
    if type(text) ~= "string" or #text % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #text, 4 do
        local n, pad = 0, 0
        for k = 0, 3 do
            local c = text:sub(i + k, i + k)
            local v = B64_VALUE[c]
            if c == "=" and i + 3 >= #text then
                v, pad = 0, pad + 1
            elseif not v or pad > 0 then
                return nil
            end
            n = n * 64 + v
        end
        local b1, b2, b3 = floor(n / 65536), floor(n / 256) % 256, n % 256
        out[#out + 1] = b1
        if pad < 2 then out[#out + 1] = b2 end
        if pad < 1 then out[#out + 1] = b3 end
    end
    return out
end

local function HexBytes(hex)
    if type(hex) ~= "string" or #hex % 2 ~= 0 or hex:find("[^%x]") then return nil end
    local out = {}
    for i = 1, #hex, 2 do out[#out + 1] = tonumber(hex:sub(i, i + 1), 16) end
    return out
end

-- Big-endian bytes -> L limbs; nil when the number does not fit.
local function Limbs(bytes, L)
    local limbs = {}
    for i = 0, L - 1 do limbs[i] = 0 end
    local i, pos = 0, #bytes
    while pos >= 1 do
        local v = bytes[pos] + (bytes[pos - 1] or 0) * 256 + (bytes[pos - 2] or 0) * 65536
        if i >= L then
            if v ~= 0 then return nil end
        else
            limbs[i] = v
        end
        i, pos = i + 1, pos - 3
    end
    return limbs
end

---------------------------------------------------------------------------
-- Arithmetic mod n
---------------------------------------------------------------------------
-- a * b / R mod n (R = 2^(24 L)), for a, b < n.
local function MontMul(a, b, n, ninv, L)
    local t = {}
    for i = 0, L + 1 do t[i] = 0 end
    for i = 0, L - 1 do
        local bi, C, x = b[i], 0, 0
        for j = 0, L - 1 do
            x = t[j] + a[j] * bi + C
            C = floor(x / B)
            t[j] = x - C * B
        end
        x = t[L] + C
        C = floor(x / B)
        t[L] = x - C * B
        t[L + 1] = C
        local m = (t[0] * ninv) % B
        x = t[0] + m * n[0]
        C = floor(x / B)
        for j = 1, L - 1 do
            x = t[j] + m * n[j] + C
            C = floor(x / B)
            t[j - 1] = x - C * B
        end
        x = t[L] + C
        C = floor(x / B)
        t[L - 1] = x - C * B
        t[L] = t[L + 1] + C
    end
    -- The result is below 2n: one subtraction at most.
    local ge = t[L] > 0
    if not ge then
        ge = true
        for j = L - 1, 0, -1 do
            if t[j] ~= n[j] then ge = t[j] > n[j] break end
        end
    end
    local out = {}
    if ge then
        local borrow = 0
        for j = 0, L - 1 do
            local x = t[j] - n[j] - borrow
            if x < 0 then x, borrow = x + B, 1 else borrow = 0 end
            out[j] = x
        end
    else
        for j = 0, L - 1 do out[j] = t[j] end
    end
    return out
end

local function Less(a, n, L)
    for j = L - 1, 0, -1 do
        if a[j] ~= n[j] then return a[j] < n[j] end
    end
    return false
end

-- Parsed keys, by the key table.
local parsed = setmetatable({}, { __mode = "k" })

local function Parse(key)
    if type(key) ~= "table" then return false end
    if parsed[key] ~= nil then return parsed[key] end
    local k = type(key) == "table" and tonumber(key.bytes)
    local L = k and math.ceil(k * 8 / 24)
    local nb, rb = key and HexBytes(key.n), key and HexBytes(key.r2)
    local p = false
    if L and nb and rb and #nb == k and type(key.ninv) == "number" then
        local n, r2 = Limbs(nb, L), Limbs(rb, L)
        if n and r2 then p = { n = n, r2 = r2, ninv = key.ninv, L = L, k = k } end
    end
    parsed[key] = p
    return p
end

-- The note as the signer laid it out: 00 01 FF..FF 00 <note>, k bytes.
local function Padded(text, k)
    if #text > k - 11 then return nil end
    local bytes = { 0, 1 }
    for _ = 1, k - 3 - #text do bytes[#bytes + 1] = 255 end
    bytes[#bytes + 1] = 0
    for i = 1, #text do bytes[#bytes + 1] = text:byte(i) end
    return bytes
end

-- True when sig (base64) is the key owner's signature of text.
function Signature.Verify(text, sig, key)
    local p = Parse(key)
    if not p or type(text) ~= "string" then return false end
    local bytes = Signature.Base64(sig)
    if not bytes or #bytes ~= p.k then return false end
    local s = Limbs(bytes, p.L)
    local want = Padded(text, p.k)
    if not s or not want or not Less(s, p.n, p.L) then return false end
    want = Limbs(want, p.L)
    local n, ninv, L = p.n, p.ninv, p.L
    local x = MontMul(s, p.r2, n, ninv, L)        -- s R
    local y = x
    for _ = 1, 16 do y = MontMul(y, y, n, ninv, L) end
    y = MontMul(y, x, n, ninv, L)                 -- s^65537 R
    local one = { [0] = 1 }
    for j = 1, L - 1 do one[j] = 0 end
    y = MontMul(y, one, n, ninv, L)               -- s^65537
    for j = 0, L - 1 do
        if y[j] ~= want[j] then return false end
    end
    return true
end
