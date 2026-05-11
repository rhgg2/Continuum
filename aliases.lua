-- See design/aliases.md for the model.
-- Phase 1: pure helpers — apply xforms, append ops, navigate spec trees.
-- Depends only on util.

--@map:invariant pure module — no module-level mutable state
--@map:invariant per-field op lists; ops applied left-to-right
--@map:invariant fail-closed: fields outside the event type's vocabulary are skipped
--@map:invariant coalescence is trailing-op only and requires same opcode AND all-literal args
--@map:shape Op = { opcode, arg1[, arg2, ...] }   -- numeric arg is a literal; table arg is a producing-op sub-expression
--@map:shape Xform = { [field] = { Op, ... }, ... }
--@map:shape SpecNode = { id, xform, children }   -- id is base36 string; children is list

aliases = {}
local M = aliases

----- Vocabulary

-- Logical-frame canonical: ppq / endppq are derived in tm's walker via
-- the root's authoring-frame swing snapshot. delay is its own field
-- (absolute realised offset, e.g. flam / phasing); the walker folds it
-- into ppq after deriving from ppqL.
--
-- pitch and octave are tuning-step deltas (NOT MIDI semitones). The
-- realiser resolves them to (midi, detune) at emit via
-- tuning.transposeStep. detune itself is not in the alias vocabulary:
-- alias children inherit the root's detune; tonal transposition lives
-- in pitch/octave under the active temper.
local NOTE_FIELDS = {
  ppqL = true, durL = true,
  pitch = true, octave = true, vel = true,
  chan = true, lane = true, delay = true,
}

local CC_FIELDS = {
  ppqL = true, val = true,
  chan = true, delay = true,
}

-- Applied opcodes consume one numeric value and produce a new running value.
-- Producing opcodes emit a value; valid only as args to applied opcodes.
local APPLIED   = { add = true, mul = true, snap = true }
local PRODUCING = { rand = true }

function M.validFields(evtType)
  if evtType == 'note' then return NOTE_FIELDS end
  if evtType == 'cc'   then return CC_FIELDS   end
  error('aliases: unknown event type ' .. tostring(evtType))
end

function M.isAppliedOp(opcode)   return APPLIED[opcode]   == true end
function M.isProducingOp(opcode) return PRODUCING[opcode] == true end

----- Argument evaluation

function M.isLiteral(arg) return type(arg) == 'number' end

-- Evaluate an arg into a number. A literal passes through; a table is a
-- producing-op sub-expression evaluated through `rng`.
function M.evalArg(arg, rng)
  if type(arg) == 'number' then return arg end
  if type(arg) == 'table' then
    local opcode = arg[1]
    if opcode == 'rand' then
      if not rng then error('aliases.evalArg: rand requires rng') end
      local lo, hi = M.evalArg(arg[2], rng), M.evalArg(arg[3], rng)
      return rng(lo, hi)
    end
    error('aliases.evalArg: unknown producing opcode ' .. tostring(opcode))
  end
  error('aliases.evalArg: invalid arg ' .. tostring(arg))
end

----- RNG

-- LCG factory. Returns a closure (lo, hi) → number in [lo, hi).
function M.makeRng(seed)
  local s = seed
  return function(lo, hi)
    s = (s * 1103515245 + 12345) % 2147483648
    return lo + (s / 2147483648) * (hi - lo)
  end
end

----- Apply

local function applyOne(running, op, rng)
  local opcode = op[1]
  local v      = M.evalArg(op[2], rng)
  if opcode == 'add'  then return running + v end
  if opcode == 'mul'  then return running * v end
  if opcode == 'snap' then return util.round(running / v) * v end
  error('aliases.applyOne: not an applied opcode: ' .. tostring(opcode))
end

M.applyOp = applyOne

-- Apply `xform` to `resolved`, returning a NEW table. Inputs unchanged.
-- Fields outside the event type's vocabulary are skipped silently.
-- Fields in the xform whose resolved value is missing raise.
function M.applyXform(resolved, xform, evtType, rng)
  local valid = M.validFields(evtType)
  local out = util.clone(resolved)
  for field, ops in pairs(xform) do
    if valid[field] and #ops > 0 then
      if resolved[field] == nil then
        error('aliases.applyXform: missing resolved field ' .. field)
      end
      local running = resolved[field]
      for _, op in ipairs(ops) do running = applyOne(running, op, rng) end
      out[field] = running
    end
  end
  return out
end

----- Coalescence

local function allLiteralArgs(op)
  for i = 2, #op do
    if type(op[i]) ~= 'number' then return false end
  end
  return true
end

-- Two ops coalesce iff: same applied opcode AND both have all-literal
-- args. Snap pairs additionally require commensurate steps (one divides
-- the other) — non-commensurate snaps don't reduce to any single op, so
-- they're kept separate and applied sequentially.
function M.coalescable(a, b)
  if a[1] ~= b[1] then return false end
  if not APPLIED[a[1]] then return false end
  if not (allLiteralArgs(a) and allLiteralArgs(b)) then return false end
  if a[1] == 'snap' then
    return a[2] % b[2] == 0 or b[2] % a[2] == 0
  end
  return true
end

local function combine(a, b)
  -- Both are same-opcode, all-literal. Phase 1 ops are 1-arg.
  local opcode = a[1]
  if opcode == 'add'  then return { 'add',  a[2] + b[2] } end
  if opcode == 'mul'  then return { 'mul',  a[2] * b[2] } end
  if opcode == 'snap' then return { 'snap', math.max(a[2], b[2]) } end
  error('aliases.combine: not coalescable: ' .. tostring(opcode))
end

-- Append `op` to `xform[field]`. Returns a NEW xform; input untouched.
-- If the trailing op coalesces with `op`, merges in place of appending.
function M.appendOp(xform, field, op)
  local out = {}
  for f, ops in pairs(xform) do
    local copy = {}
    for i, o in ipairs(ops) do copy[i] = o end
    out[f] = copy
  end
  local list = out[field] or {}
  out[field] = list
  local tail = list[#list]
  if tail and M.coalescable(tail, op) then
    list[#list] = combine(tail, op)
  else
    list[#list + 1] = op
  end
  return out
end

----- Spec-tree navigation

local function splitPath(specPath)
  local parts = {}
  for s in specPath:gmatch('[^.]+') do parts[#parts + 1] = s end
  return parts
end

local function findInList(list, id)
  for _, node in ipairs(list) do
    if node.id == id then return node end
  end
end

-- Walk the spec tree at `root.aliases`. specPath is dotted base36 ('1.2.1').
function M.find(root, specPath)
  local parts = splitPath(specPath)
  local list, node = root.aliases, nil
  for _, id in ipairs(parts) do
    if not list then return nil end
    node = findInList(list, id)
    if not node then return nil end
    list = node.children
  end
  return node
end

-- Returns (parent_children_list, last_id) or nil if any intermediate is
-- missing. Top-level paths return (root.aliases, id).
function M.parentOf(root, specPath)
  local parts = splitPath(specPath)
  if #parts == 0 then return nil end
  local list = root.aliases
  for i = 1, #parts - 1 do
    local node = list and findInList(list, parts[i])
    if not node then return nil end
    list = node.children
  end
  if not list then return nil end
  return list, parts[#parts]
end

-- Mutates `root`: removes the subtree at specPath from its parent's
-- children list. Returns the plucked node, or nil if not found.
function M.pluckSubtree(root, specPath)
  local list, id = M.parentOf(root, specPath)
  if not list then return nil end
  for i, node in ipairs(list) do
    if node.id == id then
      table.remove(list, i)
      return node
    end
  end
  return nil
end

----- Selection-shape helpers

-- Filter `events` to its *local roots*: events whose parentUuid is
-- absent OR refers to a uuid not present in the same input. A child
-- whose parent is in the set drops out — the parent's mutation will
-- re-derive the child through the spec tree, so touching both would
-- double-mutate. Plain events (no parentUuid) always survive.
function M.localRoots(events)
  local present = {}
  for _, e in ipairs(events) do present[e.uuid] = true end
  local out = {}
  for _, e in ipairs(events) do
    if not (e.parentUuid and present[e.parentUuid]) then
      out[#out + 1] = e
    end
  end
  return out
end

----- Routing

-- Append `op` to the spec node at `evt.specPath` under `root`. Mutates
-- the node's xform in place (within `root.aliases`) and returns the
-- updated `root.aliases`. Returns nil if the spec path doesn't resolve
-- — caller should fall back to direct mutation.
function M.route(root, evt, field, op)
  if not (root and root.aliases and evt and evt.specPath) then return nil end
  local node = M.find(root, evt.specPath)
  if not node then return nil end
  node.xform = M.appendOp(node.xform, field, op)
  return root.aliases
end

----- Construction

function M.allocId(root)
  local n = root.aliasCtr or 1
  root.aliasCtr = n + 1
  return util.toBase36(n)
end

function M.emptyXform() return {} end
