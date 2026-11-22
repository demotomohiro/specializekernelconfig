import std/[memfiles, strformat, tables]

# multiple module alias patterns in one module can match one module alias
type
  KernelModule* = object
    name*: string
    modAliasPatterns*: seq[string]
    modFields*: Table[string, seq[string]]  # field name -> values
    isBuiltInOnly*: bool

func find(s: cstring; sub: char; start, last: int): int {.inline.} =
  for i in start .. last:
    if s[i] == sub:
      return i
  return -1

proc readModinfo(path: string; result: var seq[KernelModule]; isBuiltInOnly: bool) =
  var modules = initOrderedTable[string, KernelModule](128)
  var f = memfiles.open(path)
  for slice in f.memSlices('\0', '\0'):
    doAssert slice.size >= len("x.y=")
    let last = slice.size - 1
    let line = cast[cstring](slice.data) # assume every lines including the last line is always zero-terminated
    doAssert line[last] != '\0'
    var i = 0
    var modName = block:
      let x = find(line, '.', 1, last - 1)
      doAssert x != -1
      i = x + 1
      line.toOpenArray(0, x - 1).substr
    var field = block:
      let x = find(line, '=', i + 1, last)
      doAssert x != -1
      let s = i
      i = x + 1
      line.toOpenArray(s, x - 1).substr
    var value = if i <= last: line.toOpenArray(i, last).substr else: ""

    if modName in modules:
      if field == "alias":
        modules[modName].modAliasPatterns.add value
      else:
        modules[modName].modFields.mgetOrPut(field).add value
    else:
      var fields = initTable[string, seq[string]](8)
      if field == "alias":
        modules[modName] = KernelModule(name: modName, modAliasPatterns: @[value], modFields: fields, isBuiltInOnly: isBuiltInOnly)
      else:
        fields[field] = @[value]
        modules[modName] = KernelModule(name: modName, modFields: fields, isBuiltInOnly: isBuiltInOnly)

  close f

  var i = result.len
  result.setLen(result.len + modules.len)

  for v in modules.values:
    result[i] = v
    inc i

  echo fmt"There are {modules.len} modules in {path}"

proc readModinfo*(): seq[KernelModule] =
  result = newSeq[KernelModule]()
  readModinfo "kernel_build/modules.builtin.modinfo", result, true
  readModinfo "skc_modules.module.modinfo", result, false
