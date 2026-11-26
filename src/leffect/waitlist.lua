--- Internal: a line of waiters, in arrival order
--- (specifications/33-primitives.md §33.3).
---
--- An intrusive doubly linked list. A node is any table: the list adds the
--- fields `_prev`, `_next` and `_list` to it. A node leaves in O(1), and a
--- walk goes in arrival order, which a Lua table's `pairs` doesn't promise.
---
--- To walk the list while nodes may leave, read the next node first:
---
--- ```lua
--- local node = list.head
--- while node do
---   local nextNode = node._next
---   -- ... may remove node ...
---   node = nextNode
--- end
--- ```

local Waitlist = {}

---@class leffect.Waitlist
---@field head table?
---@field tail table?
---@field size integer

--- A new empty line.
---@return leffect.Waitlist
function Waitlist.new()
  return { head = nil, tail = nil, size = 0 }
end

--- Adds `node` at the end of `list`.
---@param list leffect.Waitlist
---@param node table
function Waitlist.push(list, node)
  local tail = list.tail
  node._prev, node._next, node._list = tail, nil, list
  if tail then
    tail._next = node
  else
    list.head = node
  end
  list.tail = node
  list.size = list.size + 1
end

--- Removes `node` from `list`. Returns whether it was there.
---@param list leffect.Waitlist
---@param node table
---@return boolean
function Waitlist.remove(list, node)
  if node._list ~= list then
    return false
  end
  local prev, nextNode = node._prev, node._next
  if prev then
    prev._next = nextNode
  else
    list.head = nextNode
  end
  if nextNode then
    nextNode._prev = prev
  else
    list.tail = prev
  end
  node._prev, node._next, node._list = nil, nil, nil
  list.size = list.size - 1
  return true
end

--- Whether `node` is in `list`.
---@param list leffect.Waitlist
---@param node table
---@return boolean
function Waitlist.has(list, node)
  return node._list == list
end

--- Removes and returns the first node, or nil if the line is empty.
---@param list leffect.Waitlist
---@return table?
function Waitlist.shift(list)
  local node = list.head
  if node then
    Waitlist.remove(list, node)
  end
  return node
end

--- Empties the line, and returns its nodes in arrival order.
---@param list leffect.Waitlist
---@return table[]
function Waitlist.clear(list)
  local nodes, n = {}, 0
  local node = list.head
  while node do
    local nextNode = node._next
    n = n + 1
    nodes[n] = node
    node._prev, node._next, node._list = nil, nil, nil
    node = nextNode
  end
  list.head, list.tail, list.size = nil, nil, 0
  return nodes
end

return Waitlist
