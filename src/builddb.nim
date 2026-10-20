import std/[cmdline, os, strformat, strutils, syncio]

if paramCount() != 1:
  echo &"usage: {getAppFilename()} kernel/build/directory"
  quit 1

let targetDir = paramStr(1)
let output = open("module_alias_db.txt", fmWrite)

for path in walkDirRec(targetDir, checkDir = true):
  let name = extractFilename path
  if name.endsWith(".mod.c"):
    let modname = name.substr(0, name.len - ".mod.c".len - 1)
    echo path
    echo modname

    const ModuleAliasPrefix = "MODULE_ALIAS(\""
    var hasModuleAlias = false
    for l in path.lines:
      if l.startsWith(ModuleAliasPrefix):
        let e = rfind(l, '"')
        if e != -1:
          if not hasModuleAlias:
            hasModuleAlias = true
            output.write "# "
            output.write path
            output.write '\n'
            output.write '/'
            output.write modname
            output.write '\n'
          output.write l[ModuleAliasPrefix.len .. (e - 1)]
          output.write '\n'

close(output)
