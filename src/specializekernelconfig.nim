import std/[os, strutils, syncio]

proc cfnmatch(pattern, string: cstring; flags: cint): cint {.importc: "fnmatch", header: "<fnmatch.h>".}

# multiple module alias patterns in one module can match one module alias
type
  KernelModule = object
    name: string
    modAliasPatterns: seq[string]

proc main =
  var modules = newSeq[KernelModule]()
  var currentMod = KernelModule()
  for l in lines("module_alias_db.txt"):
    if l.len == 0 or l[0] == '#':
      continue
    elif l[0] == '/':
      let name = l.substr(1)
      if currentMod.name.len == 0:
        currentMod.name = name
        assert currentMod.modAliasPatterns.len == 0
      else:
        modules.add ensureMove currentMod
        currentMod = KernelModule(name: name)
    else:
      assert currentMod.name.len != 0
      currentMod.modAliasPatterns.add l

  const SysFs = "/sys"
  for path in walkDirRec(SysFs, checkDir = true):
    let name = extractFilename path
    if name == "modalias":
      echo path
      var modalias = readFile path
      stripLineEnd modalias
      if modalias.len == 0:
        echo "!!! empty !!!"
      else:
        echo modalias
        var numMatch = 0
        for m in modules:
          for p in m.modAliasPatterns:
            if cfnmatch(p, modalias, 0) == 0:
              echo m.name
              inc numMatch
              break
        if numMatch == 0:
          echo "No match"
        elif numMatch > 1:
          echo "match ", numMatch, " modules"

main()
