-- Hl.bin data layout:
--
--   offset  size                content
--   0       16                  header: magic(8) key_count(2)
--                                       theme_count(4) name_len(2)
--   16      key_count×name_len  vocab: name_len bytes cstring
--   ...     theme_count×record  record: ascending by colorscheme name
--
--   record = name(name_len)
--          + dark : fg_bitmap | bg_bitmap | fg_colors | bg_colors
--          + light: the same as dark
--   bitmap = ceil(key_count/8) bytes, each bit indicates whether the group
--            has fg/bg in this background
--   colors = key_count×3 bytes, 3 bytes big-endian RGB.

local M = {}

local HEADER_SIZE = 16
local MAGIC = "HLBIN\0\0\1"
local KEY_COUNT_OFFSET = 9
local THEME_COUNT_OFFSET = 11
local NAME_LEN_OFFSET = 15

---@return string[]
local function candidate_paths()
  local paths = {}
  local local_bin = vim.api.nvim_get_runtime_file(
    "lua/theme/hl.bin", false
  )[1]
  local cache_bin = vim.fn.stdpath("cache") .. "/theme.nvim/catalog.bin"
  if local_bin then table.insert(paths, local_bin) end
  if vim.loop.fs_stat(cache_bin) then table.insert(paths, cache_bin) end
  return paths
end

local function read_u16(str, offset)
  local low, high = str:byte(offset, offset + 1)
  return low + high * 256
end

local function read_u32(str, offset)
  local b1, b2, b3, b4 = str:byte(offset, offset + 3)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function read_rgb(str, offset)
  local r, g, b = str:byte(offset, offset + 2)
  return r * 65536 + g * 256 + b
end

--- fixed-length cstring, read until first NULL
---@param str string
---@return string
local function read_cstring(str)
  local nul = str:find("\0", 1, true)
  return nul and str:sub(1, nul - 1) or str
end

---@param db ThemeHlDb
---@param offset integer
---@param length integer
---@return string
local function read_at(db, offset, length)
  db.handle:seek("set", offset - 1)
  return db.handle:read(length)
end

---@class ThemeHlDb
---@field handle file*
---@field key_count integer
---@field theme_count integer
---@field name_len integer
---@field bitmap_len integer
---@field palette_len integer
---@field record_len integer
---@field vocab string[]
---@field vocab_offset integer
---@field records_offset integer

---@param path string
---@return ThemeHlDb?
local function open_db(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end

  local header = handle:read(HEADER_SIZE)
  if not header or header:sub(1, #MAGIC) ~= MAGIC then
    handle:close()
    return nil
  end

  local db = {
    handle = handle,
    key_count = read_u16(header, KEY_COUNT_OFFSET),
    theme_count = read_u32(header, THEME_COUNT_OFFSET),
    name_len = read_u16(header, NAME_LEN_OFFSET),
  }
  db.bitmap_len = math.ceil(db.key_count / 8)
  db.palette_len = 2 * db.bitmap_len + db.key_count * 6
  db.record_len = db.name_len + 2 * db.palette_len
  db.vocab_offset = HEADER_SIZE + 1
  db.records_offset = db.vocab_offset + db.key_count * db.name_len

  db.vocab = {}
  for index = 0, db.key_count - 1 do
    db.vocab[index + 1] = read_cstring(read_at(
      db, db.vocab_offset + index * db.name_len, db.name_len
    ))
  end

  return db
end

---@param db ThemeHlDb
---@param record_index integer
---@return string
local function record_name(db, record_index)
  return read_cstring(read_at(
    db,
    db.records_offset + record_index * db.record_len,
    db.name_len
  ))
end

--- Binary search for a record by name. Names are stored in ascending byte
--- order
---@param db ThemeHlDb
---@param name string
---@return integer? -- record index, nil if not found
local function find_record(db, name)
  local low, high = 0, db.theme_count - 1
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local candidate = record_name(db, mid)
    if candidate == name then
      return mid
    elseif candidate < name then
      low = mid + 1
    else
      high = mid - 1
    end
  end
  return nil
end

---@param db ThemeHlDb
---@param record_index integer
---@param background "light"|"dark"
---@return table<string, {fg: integer?, bg: integer?}>?
local function read_palette(db, record_index, background)
  local base = db.records_offset + record_index * db.record_len + db.name_len
  if background == "light" then
    base = base + db.palette_len
  end

  local fg_bitmap = read_at(db, base, db.bitmap_len)
  local bg_bitmap = read_at(
    db, base + db.bitmap_len, db.bitmap_len
  )
  local fg_colors = read_at(
    db, base + 2 * db.bitmap_len, db.key_count * 3
  )
  local bg_colors = read_at(
    db, base + 2 * db.bitmap_len + db.key_count * 3,
    db.key_count * 3
  )

  local palette = {}
  for index = 1, db.key_count do
    local byte_index = math.floor((index - 1) / 8)
    local mask = bit.lshift(1, (index - 1) % 8)

    local fg = nil
    if bit.band(fg_bitmap:byte(byte_index + 1), mask) ~= 0 then
      fg = read_rgb(fg_colors, (index - 1) * 3 + 1)
    end

    local bg = nil
    if bit.band(bg_bitmap:byte(byte_index + 1), mask) ~= 0 then
      bg = read_rgb(bg_colors, (index - 1) * 3 + 1)
    end

    if fg or bg then
      palette[db.vocab[index]] = { fg = fg, bg = bg }
    end
  end
  return palette
end

---@type ThemeHlDb[]
local databases = nil

---@return ThemeHlDb[]
local function load_databases()
  if databases then
    return databases
  end
  databases = {}
  for _, path in ipairs(candidate_paths()) do
    local db = open_db(path)
    if db then
      databases[#databases + 1] = db
    end
  end
  return databases
end

--- Query colorscheme highlight groups from hl.bin
---@param name string
---@param background? "light"|"dark"  -- default to vim.o.background
---@return table<string, {fg: integer?, bg: integer?}>?
function M.query_hl(name, background)
  local wanted = background or vim.o.background
  for _, db in ipairs(load_databases()) do
    local record_index = find_record(db, name)
    if record_index then
      return read_palette(db, record_index, wanted)
    end
  end
  return nil
end

return M

