-- See docs/wiringManager.md for the model.
-- @noindex

--invariant: project-wide singleton; the user graph lives in one cm project-tier key (wiringGraph). No per-take or per-track state at Stage 1; wiringClass is declared for the Stage 2 differ but unread here.
--invariant: every authoring gesture goes through wm:mutate — clone draft, mutate, validate via DAG.validate, swap + persist + fire on success, return false+err on failure. The on-disk graph and the wiringChanged broadcast have therefore always passed validation.
--invariant: master node is a regular entry in graph.nodes under the fixed id 'master'; freshGraph materialises it on first load of an empty project; DAG.validate enforces the singleton.

local util = require 'util'
local DAG  = require 'DAG'

local cm = (...).cm

local wm = {}
local fire = util.installHooks(wm)

local _graph = nil

----- Helpers

local function freshGraph()
  return {
    nodes = {
      master = { kind = 'master', pos = { x = 0, y = 0 },
                 audio = { ins = { 'L', 'R' } } },
    },
    edges = {},
    _nextId = 1,
  }
end

local function readPersisted()
  local g = cm:get('wiringGraph')
  if g and g.nodes then return g end
  return freshGraph()
end

local function ensureLoaded()
  if not _graph then _graph = readPersisted() end
end

----------- PUBLIC

--contract: re-reads wiringGraph from cm (rebuilding master via freshGraph if empty) and fires wiringChanged{kind='load'}
function wm:load()
  _graph = readPersisted()
  fire('wiringChanged', { kind = 'load' })
end

--contract: persists the current in-memory graph to the project tier; mutate calls this, callers normally don't
function wm:save()
  cm:set('project', 'wiringGraph', _graph)
end

--contract: returns a deep copy of the user graph; caller mutations never leak into wm state
function wm:graph()
  ensureLoaded()
  return util.deepClone(_graph)
end

--contract: clone-validate-swap; on DAG.validate failure returns false,err with no state change and no signal; on success persists and fires wiringChanged{kind='mutate'}
function wm:mutate(mutator)
  ensureLoaded()
  local draft = util.deepClone(_graph)
  mutator(draft)
  local err = DAG.validate(draft)
  if err then return false, err end
  _graph = draft
  self:save()
  fire('wiringChanged', { kind = 'mutate' })
  return true
end

--contract: returns DAG.lower of the current user graph; pure, no caching at Stage 1
function wm:compile()
  ensureLoaded()
  return DAG.lower(_graph)
end

--contract: list of intra-class capacity overflows on the lowered compile graph; empty when the user graph is within budget
function wm:errors()
  local compile = self:compile()
  return DAG.capacityErrors(compile, DAG.classes(compile))
end

return wm
