import std/tables
import builtin_modinfo, mod2config

proc test =
  let modules = readModinfo()
  let mod2config = loadMod2Config()

  for m in modules:
    if m.name notin mod2config:
      echo m.name

test()
