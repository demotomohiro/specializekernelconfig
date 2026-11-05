import std/[algorithm, memfiles, os, sets, strformat, strutils, syncio, tables]

proc cfnmatch(pattern, string: cstring; flags: cint): cint {.importc: "fnmatch", header: "<fnmatch.h>".}

# multiple module alias patterns in one module can match one module alias
type
  KernelModule = object
    name: string
    modAliasPatterns: seq[string]
    modFields: Table[string, seq[string]]  # field name -> values
    isBuiltInOnly: bool

iterator walkDirRecSortedWithfile(dir, file: string): string =
  var dirs = newSeqOfCap[string](256)
  for path in walkDirRec(dir, {pcDir}, checkDir = true):
    if (path / file).fileExists:
      dirs.add path

  sort dirs
  for path in dirs:
    yield path

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

proc readExcludedModules(path: string): HashSet[string] =
  var f: File = nil
  if syncio.open(f, path):
    for l in f.lines:
      let l2 = l.strip
      if l2.len != 0 and l2[0] != '#':
        result.incl l2
    close f

proc main =
  var modules = newSeq[KernelModule]()
  readModinfo "kernel_build/modules.builtin.modinfo", modules, true
  readModinfo "skc_modules.module.modinfo", modules, false

  var excludedModules = readExcludedModules("excluded_modules.txt")

  var moduleSet = initHashSet[string]()
  const SysFs = "/sys/devices"
  echo "Following paths are relative to ", SysFs
  #for path in walkDirRec(SysFs, {pcDir}, checkDir = true):
  for path in walkDirRecSortedWithfile(SysFs, "modalias"):
    var f: File = nil
    if open(f, path / "modalias"):
      var modalias = readAll f
      close f
      echo path.relativePath(SysFs)
      stripLineEnd modalias
      if modalias.len == 0:
        echo "  Empty modalias!"
      else:
        echo "  modalias: ", modalias
        var matched = newSeq[int](0)
        for i, m in modules.pairs:
          for p in m.modAliasPatterns:
            if cfnmatch(cstring p, cstring modalias, 0) == 0:
              matched.add i
              moduleSet.incl m.name
              break
        if matched.len == 0:
          echo "  No matching modules"
        else:
          echo &"  match {matched.len} modules:"
          for idx in matched:
            template m: untyped {.inject.} = modules[idx]
            echo &"    {m.name}", if m.name in excludedModules: "(excluded)" else: ""
            withValue m.modFields, "description", descs:
              for d in descs[]:
                echo "      description: ", d
            withValue m.modFields, "skc_file", files:
              if files[].len > 0:
                echo "      source path: ", files[][0]
            withValue m.modFields, "file", files:
              if files[].len > 0:
                echo "      source path: ", files[][0]
            withValue m.modFields, "depends", deps:
              for d in deps[]:
                if d != "":
                  echo "      depends: ", d
            if m.isBuiltInOnly:
              echo "      builtin only"
      let driverPath = path / "driver"
      if driverPath.symlinkExists:
        var drv = driverPath.expandSymlink
        drv = path / drv
        normalizePath drv
        #drv = drv.relativePath(SysFs)
        echo &"  currently used driver: {drv.extractFilename} ({drv})" 
        let driverModulePath = drv / "module"
        if driverModulePath.symlinkExists:
          var module = driverModulePath.expandSymlink
          module = drv / module
          normalizePath module
          echo &"  currently used module: {module.extractFilename} ({module})"
    else:
      close f

  block:
    var f = syncio.open("module_list.txt", fmWrite)
    for n in moduleSet:
      if n notin excludedModules:
        write f, n
        write f, '\n'
    close f

main()
