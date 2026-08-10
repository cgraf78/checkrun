# Checkrun examples

These files show the reusable boundary around Checkrun configuration and editor
integration. They are deliberately generic: a consuming dotfiles repository
chooses which files and schemas matter, while Checkrun owns how that policy is
validated and projected to tools.

## Schema associations

Copy [`associations.json`](associations.json) to
`$XDG_CONFIG_HOME/checkrun/associations.json` (normally
`~/.config/checkrun/associations.json`) and replace the synthetic associations
with your own policy.

The three entries demonstrate distinct ownership models:

- `Example application config` is host-owned. Copy
  [`schemas/application.schema.json`](schemas/application.schema.json) to
  `$XDG_DATA_HOME/checkrun/schemas/application.schema.json` (normally
  `~/.local/share/checkrun/schemas/application.schema.json`). A bare schema
  filename resolves from that XDG data directory.
- `Dependency-owned tool config` names the repository that owns the schema.
  Checkrun asks `shdeps dep-file` for the asset instead of copying or updating
  it in the host policy repository.
- `Editor-native settings` is completion-only. With `enforce: false` and only
  an `editorSource`, offline hooks do not claim they can validate it.

Use `checkrun schema refresh` only for host-owned entries that also declare a
real, stable `source` URL. Dependency-owned payloads should be updated by their
own repositories.

## Formatter fallback

[`shfmt.toml`](shfmt.toml) belongs at
`$XDG_CONFIG_HOME/checkrun/shfmt.toml`. It is fallback policy: a project's
`.editorconfig` remains authoritative when present.

## Neovim

[`nvim.lua`](nvim.lua) composes the Checkrun adapter with Shdeps without
hard-coding a source checkout path. First generate portable metadata during
your normal update workflow:

```sh
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/checkrun"
checkrun editor-metadata --json > \
  "${XDG_CACHE_HOME:-$HOME/.cache}/checkrun/editor-metadata.json"
```

Then load the example from your Neovim config and pass that checked artifact:

```lua
local checkrun = dofile(vim.fn.expand("~/.config/nvim/checkrun.lua"))
local integration = checkrun.setup({
  metadata_path = vim.fn.expand("~/.cache/checkrun/editor-metadata.json"),
})

-- The consumer still chooses its LSP plugin. For example, pass this callback
-- as yamlls' `before_init` option and pass `json_schemas` to jsonls.
local yaml_before_init = integration.yaml_before_init
```

Copy the Lua file into your own config if desired. It returns data and a YAML
callback rather than selecting an LSP manager, formatter plugin, or keymap, so
those policy decisions stay with the consuming editor configuration.
