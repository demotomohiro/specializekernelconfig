import std/[strutils, syncio, tables]

proc loadMod2Config*(path = "skc_config2mod.txt"): Table[string, seq[string]] =
  # read a file written by `config2mod.writeConfig2Mod` proc.
  result = initTable[string, seq[string]]()

  for l in path.lines:
    var i = l.find(' ')
    doAssert i != -1 and i > 0, path & " is not valid config2mod"
    let configName = l.substr(0, i - 1)
    inc i
    while i < l.len:
      let j = l.find(',', i)
      if j != -1 and j != i:
        let modName = l.substr(i, j - 1).replace('-', '_')
        result.mgetOrPut(modName).add configName
        i = j + 1
      else:
        doAssert false, path & " is not config2mod"
