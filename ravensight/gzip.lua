-- ravensight/gzip.lua: a gzip stream from Defold's zlib.deflate.
--
-- Defold's zlib.deflate returns a zlib stream (RFC 1950: a two byte header,
-- raw deflate data, an Adler-32 trailer). The delivery contract asks for
-- Content-Encoding: gzip (RFC 1952), whose body is the same raw deflate
-- data inside a ten byte header and a CRC-32 and length trailer. So the
-- zlib wrapper is swapped for a gzip one; the deflate data is untouched.
--
-- Pure Lua 5.1 over BitOp. MIT licensed, part of ravensight-defold.

local BIT_MODULE = 'bit'
local bit = rawget(_G, 'bit') or require(BIT_MODULE)
local band, bxor, rshift, bnot = bit.band, bit.bxor, bit.rshift, bit.bnot

local Gzip = {}

local TABLE = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if band(c, 1) == 1 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
  end
  TABLE[n] = c
end

--- The CRC-32 (IEEE) of a string, as a number from 0 to 2^32 - 1.
function Gzip.crc32(text)
  local crc = bnot(0)
  for i = 1, #text do
    crc = bxor(TABLE[band(bxor(crc, text:byte(i)), 255)], rshift(crc, 8))
  end
  crc = bnot(crc)
  if crc < 0 then crc = crc + 4294967296 end
  return crc
end

local function u32le(n)
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

--- The gzip stream of `original`, from its zlib stream. nil when the zlib
--- stream is not one (a preset dictionary, a wrong method or too short).
function Gzip.fromZlib(zlibStream, original)
  if type(zlibStream) ~= 'string' or #zlibStream < 6 then return nil end
  local cmf, flg = zlibStream:byte(1, 2)
  -- Method 8 (deflate), a valid header check, and no preset dictionary.
  if band(cmf, 15) ~= 8 or (cmf * 256 + flg) % 31 ~= 0 or band(flg, 32) ~= 0 then return nil end
  local deflate = zlibStream:sub(3, -5)
  local header = '\31\139\8\0\0\0\0\0\0\255'
  return header .. deflate .. u32le(Gzip.crc32(original)) .. u32le(#original % 4294967296)
end

--- A gzip function over a deflate function such as zlib.deflate, or nil
--- when there is none.
function Gzip.over(deflate)
  if type(deflate) ~= 'function' then return nil end
  return function(text)
    local ok, stream = pcall(deflate, text)
    if not ok then return nil end
    return Gzip.fromZlib(stream, text)
  end
end

return Gzip
