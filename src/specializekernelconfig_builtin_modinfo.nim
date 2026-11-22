import std/[algorithm, os, sets, strformat, strutils, syncio, tables]
import builtin_modinfo

proc cfnmatch(pattern, string: cstring; flags: cint): cint {.importc: "fnmatch", header: "<fnmatch.h>".}

iterator walkDirRecSortedWithfile(dir, file: string): string =
  var dirs = newSeqOfCap[string](256)
  for path in walkDirRec(dir, {pcDir}, checkDir = true):
    if (path / file).fileExists:
      dirs.add path

  sort dirs
  for path in dirs:
    yield path

proc readExcludedModules(path: string): HashSet[string] =
  result = initHashSet[string]()
  var f: File = nil
  if syncio.open(f, path):
    for l in f.lines:
      let l2 = l.strip
      if l2.len != 0 and l2[0] != '#':
        result.incl l2
    close f

proc main =
  let modules = readModinfo()
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
              for d in descs:
                echo "      description: ", d
            withValue m.modFields, "skc_file", files:
              if files.len > 0:
                echo "      source path: ", files[0]
            withValue m.modFields, "file", files:
              if files.len > 0:
                echo "      source path: ", files[0]
            withValue m.modFields, "depends", deps:
              for d in deps:
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
