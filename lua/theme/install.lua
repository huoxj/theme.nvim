-- Install / update / uninstall for the themes theme.nvim manages itself.
--
-- theme.nvim owns exactly one tree: its own pack dir,
-- `stdpath("data")/site/pack/theme/start/<repo-basename>`. An install clones
-- there and puts the clone on `runtimepath` (`:packadd`); every later start
-- picks it up for free, because `pack/*/start` is on `runtimepath` at startup.
-- Anything the user's own config provides is only DETECTED and surfaced --
-- never moved, overwritten, or adjudicated.
local M = {}

--- Our pack dir: the only tree this module ever writes.
---@return string
local function pack_dir()
  local data = vim.fn.stdpath("data")
  return vim.fs.joinpath(data, "site", "pack", "theme", "start")
end

--- The directory we install `repo` into.
---@param repo string "owner/name"
---@return string
function M.dir(repo)
  return vim.fs.joinpath(pack_dir(), vim.fs.basename(repo))
end

--- Make sure our pack dir can actually be found.
---
--- `pack/*` auto-loading and `:packadd` resolve through `packpath`, NOT through
--- `runtimepath`. A config that trims `packpath` (keeping only `$VIMRUNTIME` is
--- enough to break this) leaves our clone on a path nobody scans, and applying
--- one of our themes then fails with E185 even though the clone is right there.
--- Idempotent: only prepends when the entry is missing.
local function ensure_packpath()
  local site = vim.fs.joinpath(vim.fn.stdpath("data"), "site")
  local want = vim.fs.normalize(site)
  for _, path in ipairs(vim.opt.packpath:get()) do
    if vim.fs.normalize(path) == want then return end
  end
  vim.opt.packpath:prepend(site)
end

ensure_packpath()

--- Whether a runtimepath entry outside our pack dir (and outside $VIMRUNTIME)
--- already provides a directory named `name`.
---
--- A matching basename is not enough: the user's config directory is almost
--- always on the runtimepath and is routinely named after the theme it
--- configures, so `~/.config/nvim` would make every repo named `nvim` look
--- provided. A path provides a theme only if it is a theme provider itself,
--- which means it ships a `colors/` directory.
---@param name string
---@return boolean
local function provided_elsewhere(name)
  local base = pack_dir() .. "/"
  local runtime = vim.env.VIMRUNTIME or ""
  runtime = runtime ~= "" and (vim.fs.normalize(runtime) .. "/") or ""
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    path = vim.fs.normalize(path)
    if vim.fs.basename(path) == name
      and path:sub(1, #base) ~= base
      and (runtime == "" or path:sub(1, #runtime) ~= runtime)
      and vim.uv.fs_stat(vim.fs.joinpath(path, "colors")) then
      return true
    end
  end
  return false
end

--- Every theme in our pack dir, as `{ name, dir }`. `name` is the directory
--- basename -- the same key `M.dir` builds its path from. Clone temp dirs are
--- scratch, not themes, so they are skipped.
---@return { name: string, dir: string }[]
function M.installed()
  local base = pack_dir()
  local out = {}
  for name, kind in vim.fs.dir(base) do
    if kind == "directory" and not name:match("%.tmp%-%d+$") then
      out[#out + 1] = { name = name, dir = vim.fs.joinpath(base, name) }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- How `repo` is currently provided. Precedence: shadow > ours > elsewhere.
---@param repo string "owner/name"
---@return "ours"|"shadow"|"elsewhere"|"none"
function M.status(repo)
  local ours = vim.uv.fs_stat(M.dir(repo)) ~= nil
  local other = provided_elsewhere(vim.fs.basename(repo))
  if ours and other then return "shadow" end
  if ours then return "ours" end
  if other then return "elsewhere" end
  return "none"
end

---@param repo string
---@return string
local function github_url(repo)
  return "https://github.com/" .. repo
end

---@param verb string past tense, for the end notification
---@param repo string
---@param ok boolean
---@param err string?
local function report(verb, repo, ok, err)
  if ok then
    vim.notify(("theme: %s %s"):format(verb, repo), vim.log.levels.INFO)
  else
    vim.notify(
      ("theme: %s %s failed: %s"):format(verb, repo, err or "unknown error"),
      vim.log.levels.ERROR)
  end
end

--- Clone `repo` into `dir` atomically: clone into a sibling temp dir, verify
--- the clone actually ships colors/, then rename it into place. Any failure
--- removes the temp dir, so a failed install leaves nothing behind.
---@param repo string
---@param dir string
---@param opts { url?: fun(repo: string): string }? test seam
---@param cb fun(ok: boolean, err: string?)
local function clone(repo, dir, opts, cb)
  local tmp = ("%s.tmp-%d"):format(dir, vim.fn.getpid())
  local url = opts and opts.url and opts.url(repo) or github_url(repo)
  vim.fn.mkdir(vim.fs.dirname(dir), "p")
  vim.system({ "git", "clone", "--depth", "1", url, tmp }, { text = true },
    function(res)
      -- vim.system's callback runs in a fast event context; the vim.* calls
      -- below (packadd, notify, rm) must happen on the main loop.
      vim.schedule(function()
        local ok, err = true, nil
        if res.code ~= 0 then
          local msg = (res.stderr or ""):gsub("%s+$", "")
          ok, err = false, (msg ~= "" and msg or "git clone failed")
        elseif not vim.uv.fs_stat(vim.fs.joinpath(tmp, "colors")) then
          ok, err = false, "no colors/ directory"
        else
          local renamed, rerr = vim.uv.fs_rename(tmp, dir)
          if renamed then
            pcall(vim.cmd.packadd, vim.fs.basename(dir))
          else
            ok, err = false, tostring(rerr)
          end
        end
        if not ok then
          pcall(vim.fs.rm, tmp, { recursive = true, force = true })
        end
        cb(ok, err)
      end)
    end)
end

--- Install `repo` into our pack dir. Notifies on start and finish; `cb` gets
--- the outcome.
---@param repo string "owner/name"
---@param cb fun(ok: boolean, err: string?)
---@param opts { url?: fun(repo: string): string }? test seam
function M.install(repo, cb, opts)
  vim.notify(("theme: installing %s\u{2026}"):format(repo), vim.log.levels.INFO)
  clone(repo, M.dir(repo), opts, function(ok, err)
    report("installed", repo, ok, err)
    cb(ok, err)
  end)
end

--- Re-clone `repo` from scratch. A shallow pull would miss a deleted or
--- renamed colors file; rm + clone keeps update and install identical.
---@param repo string "owner/name"
---@param cb fun(ok: boolean, err: string?)
---@param opts { url?: fun(repo: string): string }? test seam
function M.update(repo, cb, opts)
  vim.notify(("theme: updating %s\u{2026}"):format(repo), vim.log.levels.INFO)
  pcall(vim.fs.rm, M.dir(repo), { recursive = true, force = true })
  clone(repo, M.dir(repo), opts, function(ok, err)
    report("updated", repo, ok, err)
    cb(ok, err)
  end)
end

--- Remove OUR copy of `repo`; nothing outside our pack dir is ever touched.
--- When the repo is not ours this is a no-op.
---@param repo string "owner/name"
---@param cb fun(ok: boolean, err: string?)
function M.uninstall(repo, cb)
  local ok, err = pcall(vim.fs.rm, M.dir(repo),
    { recursive = true, force = true })
  if ok then
    vim.notify(("theme: %s removed"):format(repo), vim.log.levels.INFO)
    cb(true)
  else
    vim.notify(("theme: removing %s failed: %s"):format(repo, err),
      vim.log.levels.ERROR)
    cb(false, tostring(err))
  end
end

return M
