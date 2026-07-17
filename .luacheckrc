std = "lua54"

-- Mirrors diagnostics.globals in .luarc.json; keep the two in step.
globals = { "reaper", "gfx" }

-- Colon-defined methods legitimately ignore self in a closures-over-state codebase.
self = false

-- Uniform call-site signatures are the idiom here: dispatch-table families and
-- declared stage protocols keep params they don't read. See generators.lua:6.
unused_args = false

exclude_files = { "design/" }

max_code_line_length    = 120
max_string_line_length  = false
-- Comment length is comment_hygiene.py's job: it knows --shape: is cap-exempt.
max_comment_line_length = false

-- The harness monkeypatches io.open to sandbox fixture reads.
files["tests/harness.lua"] = { globals = { "io" } }
