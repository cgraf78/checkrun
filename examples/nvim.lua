-- A complete, dependency-location-independent Neovim integration.
--
-- Checkrun owns the metadata shape and its translation into Neovim values.
-- Shdeps owns installed asset discovery. This example intentionally leaves
-- LSP/plugin selection and keymaps to the consuming config: those are editor
-- policy, not responsibilities of either reusable repository.

local M = {}

local function required(value, name)
  if type(value) ~= "string" or value == "" then
    error("checkrun Neovim example requires options." .. name, 3)
  end
  return value
end

local function shdeps_api(options)
  if type(options.shdeps) == "table" then
    return options.shdeps
  end

  local home = options.home or os.getenv("HOME")
  local lua_dir = options.shdeps_lua_dir or os.getenv("SHDEPS_LUA_DIR")
  if not lua_dir then
    lua_dir = required(home, "home") .. "/.local/lib/shdeps"
  end

  -- Load the provider-owned bootstrap rather than guessing where dependency
  -- repositories happen to be cloned. The same example therefore works for
  -- source-backed and release-backed Shdeps installations.
  local bootstrap = dofile(lua_dir .. "/shdeps/bootstrap.lua")
  return bootstrap.new({
    home = home,
    conf_dir = options.shdeps_conf_dir,
    bin = options.shdeps_bin,
    bin_dir = options.shdeps_bin_dir,
    root = options.shdeps_root,
    env = options.shdeps_env,
  })
end

function M.setup(options)
  options = options or {}
  local api = shdeps_api(options)
  local adapter_path = api.dep_file("cgraf78/checkrun", "lib/checkrun/nvim.lua")
  if not adapter_path then
    error("Shdeps could not resolve Checkrun's Neovim adapter", 2)
  end
  local adapter = dofile(adapter_path)

  -- Generate this file during an explicit update step with:
  --   checkrun editor-metadata --json > "$metadata_path"
  -- Startup only reads the checked artifact. It never launches Checkrun or
  -- performs dependency/network discovery on Neovim's critical path.
  local metadata = adapter.editor_metadata({
    path = required(options.metadata_path, "metadata_path"),
    home = options.home,
    resolve_dependency = function(dependency, asset)
      return api.dep_file(dependency, asset)
    end,
  })

  local filetypes = adapter.add_filetypes({
    capabilities = metadata.capabilities,
  })

  return {
    metadata = metadata,
    filetypes = filetypes,
    json_schemas = metadata.schemas.json,
    yaml_before_init = adapter.yaml_before_init({ config = metadata.schemas }),
    toml_schema_associations = metadata.schemas.toml,
  }
end

return M
