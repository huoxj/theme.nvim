local M = {}

---@param name string
---@return string? name
function M.apply_colorscheme(name)
  local ok, err = pcall(function() vim.cmd.colorscheme(name) end)
  if not ok then
    vim.notify(
      "theme-manager: " .. tostring(err), vim.log.levels.ERROR
    )
    return nil
  end
end

---@param set_a table<string, true>
---@param set_b table<string, true>
---@return table<string, true> result
function M.set_difference(set_a, set_b)
  local result = {}
  for k in pairs(set_a) do
    if not set_b[k] then result[k] = true end
  end
  return result
end

function M.print_r(t)
  local print_r_cache = {}
  local function sub_print_r(t, indent)
    if (print_r_cache[tostring(t)]) then
      print(indent .. "*" .. tostring(t))
    else
      print_r_cache[tostring(t)] = true
      if (type(t) == "table") then
        for pos, val in pairs(t) do
          if (type(val) == "table") then
            print(indent .. "[" .. pos .. "] => " .. tostring(t) .. " {")
            sub_print_r(val, indent .. string.rep(" ", string.len(pos) + 8))
            print(indent .. string.rep(" ", string.len(pos) + 6) .. "}")
          elseif (type(val) == "string") then
            print(indent .. "[" .. pos .. '] => "' .. val .. '"')
          else
            print(indent .. "[" .. pos .. "] => " .. tostring(val))
          end
        end
      else
        print(indent .. tostring(t))
      end
    end
  end
  if (type(t) == "table") then
    print(tostring(t) .. " {")
    sub_print_r(t, "  ")
    print("}")
  else
    sub_print_r(t, "  ")
  end
  print()
end

return M
