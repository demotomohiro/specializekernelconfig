import std/[algorithm, memfiles, os, sets, strformat, strutils, syncio, tables]

proc cfnmatch(pattern, string: cstring; flags: cint): cint {.importc: "fnmatch", header: "<fnmatch.h>".}

# multiple module alias patterns in one module can match one module alias
type
  KernelModule = object
    name: string
    modAliasPatterns: seq[string]
    modFields: Table[string, seq[string]]  # field name -> values

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

proc readModinfo(path: string): seq[KernelModule] =
  var modules = initOrderedTable[string, KernelModule](128)
  var f = memfiles.open("modules.builtin.modinfo")
  for slice in f.memSlices('\0', '\0'):
    doAssert slice.size >= len("x.y=z")
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
      let x = find(line, '=', i + 1, last - 1)
      doAssert x != -1
      let s = i
      i = x + 1
      line.toOpenArray(s, x - 1).substr
    var value = line.toOpenArray(i, last).substr

    if modName in modules:
      if field == "alias":
        modules[modName].modAliasPatterns.add value
      else:
        modules[modName].modFields.mgetOrPut(field).add value
    else:
      var fields = initTable[string, seq[string]](8)
      if field == "alias":
        modules[modName] = KernelModule(name: modName, modAliasPatterns: @[value], modFields: fields)
      else:
        fields[field] = @[value]
        modules[modName] = KernelModule(name: modName, modFields: fields)

  close f

  result = newSeq[KernelModule](modules.len)

  var i = 0
  for v in modules.values:
    result[i] = v
    inc i

  echo fmt"There are {i} modules in {path}"

proc main =
  var modules = readModinfo("modules.builtin.modinfo")

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
            echo &"    {m.name}"
            if "description" in m.modFields:
              for d in m.modFields["description"]:
                echo "      description: ", d
            if "file" in m.modFields and m.modFields["file"].len > 0:
              echo "      source path: ", m.modFields["file"][0]
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
      write f, n
      write f, '\n'
    close f

main()
