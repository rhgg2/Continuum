std = "lua54"

-- Mirrors diagnostics.globals in .luarc.json; keep the two in step.
globals = { "reaper", "gfx" }

-- Colon-defined methods legitimately ignore self in a closures-over-state codebase.
self = false

-- Uniform call-site signatures are the idiom here: dispatch-table families and
-- declared stage protocols keep params they don't read. See generators.lua:6.
unused_args = false

exclude_files = { "design/", "tests/spikes/" }

-- "Take any element of an iterator" (tm_rebind_gate_spec.lua:34) is a deliberate
-- idiom -- next() can't drive a stateful iterator. W512 can't tell it from a bug.
ignore = { "512" }

-- A runaway guard, not a style rule: aligned tables (timing.lua:133) are
-- deliberate and read better wide than reflowed.
max_code_line_length    = 150
max_string_line_length  = false
-- Comment length is comment_hygiene.py's job: it knows --shape: is cap-exempt.
max_comment_line_length = false

-- The harness monkeypatches io.open to sandbox fixture reads.
files["tests/harness.lua"] = { globals = { "io" } }

-- Fixtures are hex blob data, not prose to reflow.
files["tests/fixtures/"] = { max_code_line_length = false }
