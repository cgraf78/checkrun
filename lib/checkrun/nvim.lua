-- Optional Neovim protocol adapters for Checkrun.
--
-- Checkrun owns filetype capability metadata and schema association policy.
-- This module translates those public surfaces into Neovim-friendly data
-- structures without depending on shdeps, Sley, LazyVim, Mason, or any local
-- editor policy. Callers that use a dependency manager should resolve paths in
-- their own config and pass explicit `command`, `env`, or `cwd` options here.

local M = {}

local capability_cache = {}
local schema_cache = {}

local empty_capabilities = {
  version = 2,
  filetypes = {
    format = {},
    lint = {},
    custom = {
      filename = {},
      extension = {},
      patterns = {},
    },
  },
}

local empty_editor_metadata = {
  version = 1,
  capabilities = empty_capabilities,
  schemas = {
    json = {},
    yaml = {},
    toml = {},
  },
}

local function deepcopy(value)
  return vim.deepcopy(value)
end

local function expand_home(value, home)
  if type(value) ~= "string" then
    return value
  end
  return value:gsub("%$HOME", (home:gsub("%%", "%%%%")))
end

local regex_magic = {
  ["\\"] = true,
  ["."] = true,
  ["^"] = true,
  ["$"] = true,
  ["*"] = true,
  ["+"] = true,
  ["?"] = true,
  ["{"] = true,
  ["}"] = true,
  ["["] = true,
  ["]"] = true,
  ["("] = true,
  [")"] = true,
  ["|"] = true,
}

local function regex_escape(value)
  local result = {}
  for index = 1, #value do
    local byte = value:sub(index, index)
    result[#result + 1] = regex_magic[byte] and ("\\" .. byte) or byte
  end
  return table.concat(result)
end

local function expand_home_regex(value, home)
  if type(value) ~= "string" then
    return value
  end
  return value:gsub("%$HOME", (regex_escape(home):gsub("%%", "%%%%")))
end

local function read_editor_metadata(opts)
  if type(opts.metadata) == "table" then
    return deepcopy(opts.metadata)
  end
  if type(opts.path) ~= "string" or opts.path == "" then
    return nil
  end

  local file = io.open(opts.path, "rb")
  if not file then
    return nil
  end
  local encoded = file:read("*a")
  file:close()

  local ok, decoded = pcall(vim.json.decode, encoded)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function materialize_editor_url(value, opts, dependency_url_cache)
  if type(value) ~= "string" then
    return nil
  end

  -- `checkrun editor-metadata --json` deliberately leaves dependency assets
  -- portable. The adapter owns the protocol transformation, while callers own
  -- dependency discovery. A callback keeps Checkrun independent of shdeps and
  -- lets other dependency managers consume the same metadata contract.
  local dependency, asset = value:match("^shdeps:([^/]+/[^/]+)/(.*)$")
  if dependency and asset ~= "" then
    if dependency_url_cache[value] ~= nil then
      return dependency_url_cache[value] or nil
    end
    if type(opts.resolve_dependency) ~= "function" then
      dependency_url_cache[value] = false
      return nil
    end
    local path = opts.resolve_dependency(dependency, asset)
    dependency_url_cache[value] = path and vim.uri_from_fname(path) or false
    return dependency_url_cache[value] or nil
  elseif value:sub(1, 7) == "shdeps:" then
    return nil
  end

  local home = opts.home or vim.env.HOME or os.getenv("HOME") or ""
  if value == "file://$HOME" or value:sub(1, 13) == "file://$HOME/" then
    return vim.uri_from_fname(expand_home(value:sub(8), home))
  end
  return expand_home(value, home)
end

local function materialize_editor_patterns(patterns, home)
  local result = {}
  if type(patterns) ~= "table" then
    return result
  end
  for _, pattern in ipairs(patterns) do
    if type(pattern) == "string" then
      result[#result + 1] = expand_home(pattern, home)
    end
  end
  return result
end

local function materialize_editor_schemas(schemas, opts)
  schemas = type(schemas) == "table" and schemas or {}
  local result = { json = {}, yaml = {}, toml = {} }
  local is_list = vim.islist or vim.tbl_islist
  local json_schemas = type(schemas.json) == "table" and is_list(schemas.json) and schemas.json
    or {}
  local yaml_schemas = type(schemas.yaml) == "table" and not is_list(schemas.yaml) and schemas.yaml
    or {}
  local toml_schemas = type(schemas.toml) == "table" and not is_list(schemas.toml) and schemas.toml
    or {}
  local home = opts.home or vim.env.HOME or os.getenv("HOME") or ""
  local dependency_url_cache = {}

  for _, schema in ipairs(json_schemas) do
    if type(schema) == "table" then
      local url = materialize_editor_url(schema.url, opts, dependency_url_cache)
      if url then
        local item = deepcopy(schema)
        item.url = url
        item.fileMatch = materialize_editor_patterns(schema.fileMatch, home)
        result.json[#result.json + 1] = item
      end
    end
  end

  for url, patterns in pairs(yaml_schemas) do
    local materialized = materialize_editor_url(url, opts, dependency_url_cache)
    if materialized then
      result.yaml[materialized] = materialize_editor_patterns(patterns, home)
    end
  end

  for pattern, url in pairs(toml_schemas) do
    local materialized = materialize_editor_url(url, opts, dependency_url_cache)
    if materialized then
      result.toml[expand_home_regex(pattern, home)] = materialized
    end
  end

  return result
end

local function sorted_env(env)
  local result = {}
  for key, value in pairs(env or {}) do
    result[#result + 1] = tostring(key) .. "=" .. tostring(value)
  end
  table.sort(result)
  return result
end

local function cache_key(command, opts)
  return vim.json.encode({
    command = command,
    cwd = opts.cwd,
    env = sorted_env(opts.env),
  })
end

local function executable(command)
  return type(command) == "table"
    and type(command[1]) == "string"
    and command[1] ~= ""
    and vim.fn.executable(command[1]) == 1
end

local function system_json(command, opts)
  opts = opts or {}
  if not executable(command) then
    return nil, "command is not executable: " .. tostring(command and command[1] or "")
  end

  local result
  if vim.system then
    local ok, completed = pcall(function()
      return vim
        .system(command, {
          cwd = opts.cwd,
          env = opts.env,
          text = true,
        })
        :wait()
    end)
    if not ok then
      return nil, "command failed to start: " .. tostring(completed)
    end
    result = completed
  else
    -- Older Neovim fallback. This path cannot honor env/cwd overrides, so
    -- modern callers that need those should run on a Neovim with `vim.system`.
    result = {
      code = 0,
      stdout = vim.fn.system(command),
    }
    if vim.v.shell_error ~= 0 then
      result.code = vim.v.shell_error
    end
  end

  if not result then
    return nil, "command returned no result"
  end
  if result.code ~= 0 then
    local detail = result.stderr or result.stdout or ""
    detail = detail:gsub("%s+$", "")
    if detail == "" then
      detail = "command exited with status " .. tostring(result.code)
    end
    return nil, detail
  end
  if result.stdout == "" then
    return nil, "command produced no JSON output"
  end

  local ok, decoded = pcall(vim.json.decode, result.stdout)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil, "command produced invalid JSON: " .. tostring(decoded)
end

local function normalize_capabilities(capabilities)
  if not (type(capabilities) == "table" and type(capabilities.filetypes) == "table") then
    return nil
  end

  local normalized = deepcopy(capabilities)
  normalized.filetypes.format = normalized.filetypes.format or {}
  normalized.filetypes.lint = normalized.filetypes.lint or {}
  normalized.filetypes.custom = normalized.filetypes.custom or {}
  normalized.filetypes.custom.filename = normalized.filetypes.custom.filename or {}
  normalized.filetypes.custom.extension = normalized.filetypes.custom.extension or {}
  normalized.filetypes.custom.patterns = normalized.filetypes.custom.patterns or {}
  return normalized
end

local function module_dir()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return source:match("^(.*)/[^/]*$") or "."
end

local function default_schema_command(opts)
  local script = opts.script or (module_dir() .. "/schemas/schema_policy.py")
  return { opts.python or "python3", script, "--lsp-schemas" }
end

local function schema_editor_config(opts)
  opts = opts or {}
  if type(opts.config) == "table" then
    return deepcopy(opts.config)
  end

  local command = opts.command or default_schema_command(opts)
  local key = cache_key(command, opts)
  if schema_cache[key] ~= nil then
    return deepcopy(schema_cache[key])
  end

  local config, command_error = system_json(command, opts)
  if config == nil then
    error("checkrun schema policy: " .. tostring(command_error), 2)
  end
  schema_cache[key] = config
  return deepcopy(config)
end

local function schema_config(kind, opts)
  local config = schema_editor_config(opts)[kind]
  if type(config) == "table" then
    return config
  end
  return {}
end

local function append_unique(items, extra)
  local seen = {}
  local result = {}
  for _, item in ipairs(items or {}) do
    seen[item] = true
    result[#result + 1] = item
  end
  for _, item in ipairs(extra or {}) do
    if not seen[item] then
      seen[item] = true
      result[#result + 1] = item
    end
  end
  return result
end

local function merge_schema_maps(base, extra)
  local schemas = deepcopy(base or {})
  for url, matches in pairs(extra or {}) do
    if type(schemas[url]) == "table" and type(matches) == "table" then
      schemas[url] = append_unique(schemas[url], matches)
    else
      schemas[url] = matches
    end
  end
  return schemas
end

local function extensionless_filetype(filetype)
  return function(path)
    local name = path:match("[^/]+$") or path
    if not name:find(".", 1, true) then
      return filetype
    end
    return nil
  end
end

local function glob_to_lua_pattern(glob)
  return glob:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*")
end

--- Read and materialize `checkrun editor-metadata --json` for this Neovim host.
---
--- The CLI output is intentionally portable: HOME remains a literal token and
--- dependency-owned schemas use `shdeps:owner/repo/path` URLs. Keeping the
--- materializer here makes Checkrun the single owner of that versioned
--- contract. Consumers provide only their checked metadata path and an
--- optional dependency resolver; they do not need to duplicate schema-shape,
--- URI, or regex escaping rules.
---
--- Missing, unreadable, malformed, or unsupported metadata degrades to the
--- empty version-one contract. Individual dependency schemas whose assets
--- cannot be resolved are omitted, matching the optional nature of editor
--- integrations without weakening the CLI's stricter generation-time checks.
---
--- @param opts table|nil Options: direct `metadata`, file `path`, `home`, and
---   `resolve_dependency(dependency, asset)` returning a local path or nil.
--- @return table metadata Materialized capabilities and schema configuration.
function M.editor_metadata(opts)
  opts = opts or {}
  local metadata = read_editor_metadata(opts)
  if type(metadata) ~= "table" or metadata.version ~= 1 then
    return deepcopy(empty_editor_metadata)
  end

  return {
    version = 1,
    capabilities = type(metadata.capabilities) == "table" and deepcopy(metadata.capabilities)
      or deepcopy(empty_capabilities),
    schemas = materialize_editor_schemas(metadata.schemas, opts),
  }
end

--- Read and normalize `checkrun capabilities --json`.
---
--- @param opts table|nil Options: `command`, `env`, `cwd`, or direct
---   `capabilities` for tests and pre-fetched callers.
--- @return table capabilities Normalized Checkrun capabilities.
function M.capabilities(opts)
  opts = opts or {}
  if type(opts.capabilities) == "table" then
    return normalize_capabilities(opts.capabilities) or deepcopy(empty_capabilities)
  end

  local command = opts.command or { "checkrun", "capabilities", "--json" }
  local key = cache_key(command, opts)
  if capability_cache[key] ~= nil then
    return deepcopy(capability_cache[key])
  end

  capability_cache[key] = normalize_capabilities(system_json(command, opts))
    or deepcopy(empty_capabilities)
  return deepcopy(capability_cache[key])
end

--- Convert Checkrun custom filetype metadata into `vim.filetype.add` input.
---
--- @param opts table|nil Options accepted by `capabilities`.
--- @return table filetypes Table with `filename`, `extension`, and `pattern`.
function M.filetypes(opts)
  local custom = M.capabilities(opts).filetypes.custom or {}
  local filetypes = {
    filename = deepcopy(custom.filename or {}),
    extension = deepcopy(custom.extension or {}),
    pattern = {},
  }

  for _, item in ipairs(custom.patterns or {}) do
    if type(item.pattern) == "string" and type(item.filetype) == "string" then
      local pattern = glob_to_lua_pattern(item.pattern)
      if item.extensionlessOnly then
        -- Checkrun distinguishes basename-only globs from ordinary extension
        -- inference. Preserve that here so `agent-hook-test` can be shell while
        -- `agent-hook-test.txt` keeps Neovim's normal text handling.
        local callback = extensionless_filetype(item.filetype)
        filetypes.pattern[".*/" .. pattern] = callback
        filetypes.pattern[pattern] = callback
      else
        filetypes.pattern[pattern] = item.filetype
      end
    end
  end

  return filetypes
end

--- Register Checkrun custom filetypes with Neovim.
---
--- @param opts table|nil Options accepted by `filetypes`.
--- @return table filetypes The registered table, useful for tests.
function M.add_filetypes(opts)
  local filetypes = M.filetypes(opts)
  vim.filetype.add(filetypes)
  return filetypes
end

--- Return JSON LSP schema associations from Checkrun schema policy.
function M.json_schemas(opts)
  return schema_config("json", opts)
end

--- Return YAML LSP schema associations from Checkrun schema policy.
function M.yaml_schemas(opts)
  return schema_config("yaml", opts)
end

--- Return TOML LSP schema associations from Checkrun schema policy.
function M.toml_schema_associations(opts)
  return schema_config("toml", opts)
end

--- Build a yamlls `before_init` callback that merges SchemaStore and Checkrun.
---
--- @param opts table|nil Options accepted by the schema helpers.
--- @return function callback Neovim LSP `before_init` callback.
function M.yaml_before_init(opts)
  return function(_, new_config)
    local schema_store = {}
    local ok, schemastore = pcall(require, "schemastore")
    if ok then
      schema_store = schemastore.yaml.schemas()
    end

    new_config.settings = new_config.settings or {}
    new_config.settings.yaml = new_config.settings.yaml or {}
    -- Treat Checkrun's policy as the first integration-owned layer, then let
    -- caller-provided LSP settings win. This keeps the callback useful on its
    -- own while preserving configs that already set `settings.yaml.schemas`.
    local schemas = merge_schema_maps(schema_store, M.yaml_schemas(opts))
    new_config.settings.yaml.schemas = merge_schema_maps(schemas, new_config.settings.yaml.schemas)
  end
end

return M
