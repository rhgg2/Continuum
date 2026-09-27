-- util.filter: the elements of a list that pass a predicate, in a fresh list of their own.

local t = require('support')
local util = require('util')

local function isEven(n) return n % 2 == 0 end

return {
  {
    name = 'filter: keeps exactly the passing elements, in list order',
    run = function()
      local kept = util.filter({ 5, 4, 1, 8, 2, 7 }, isEven)
      t.eq(#kept, 3)
      t.eq(kept[1], 4); t.eq(kept[2], 8); t.eq(kept[3], 2)
    end,
  },
  {
    name = 'filter: none passing is an empty list, not nil',
    run = function()
      local kept = util.filter({ 1, 3, 5 }, isEven)
      t.eq(type(kept), 'table')
      t.eq(#kept, 0)
    end,
  },
  {
    name = 'filter: the result is fresh even when every element passes',
    run = function()
      local list = { 2, 4 }
      local kept = util.filter(list, isEven)
      t.eq(#kept, 2)
      t.truthy(kept ~= list)
      table.remove(kept, 1)
      t.eq(#list, 2); t.eq(list[1], 2)
    end,
  },
  {
    name = 'filter: elements are the originals, not copies',
    run = function()
      local a, b = { n = 2 }, { n = 3 }
      local kept = util.filter({ a, b }, function(x) return isEven(x.n) end)
      t.eq(#kept, 1)
      t.eq(kept[1], a)
    end,
  },
}
