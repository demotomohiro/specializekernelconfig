import std/[os, osproc, pegs, sets, syncio, strutils, tables]

type
  Config2Mod = Table[string, HashSet[string]]     # "CONFIG_MODULE" -> {"module_name_x", "module_name_y"}
  Value = object
    v: string
    isDeferred: bool
  Variables = Table[string, Value]            # variable name -> value
  InheritVariables = Table[string, Variables] # parent directory of Makefile or Kbuild -> Variables

proc initValue(v: string; isDeferred: bool): Value = Value(v: v, isDeferred: isDeferred)

let subarch = block:
  # copied from `linux/scripts/subarch.include`
  let subarch = execCmdEx(r"uname -m | sed -e s/i.86/x86/ -e s/x86_64/x86/ " &
                          r"-e s/sun4u/sparc64/ " &
                          r"-e /^arm64$$/!s/arm.*/arm/ -e s/sa110/arm/ " &
                          r"-e s/s390x/s390/ " &
                          r"-e s/ppc.*/powerpc/ -e s/mips.*/mips/ " &
                          r"-e s/sh[234].*/sh/ -e s/aarch64.*/arm64/ " &
                          r"-e s/riscv.*/riscv/ -e s/loongarch.*/loongarch/")
  doAssert subarch.exitCode == 0
  subarch.output.strip

proc initVariables(): Variables =
  result = initTable[string, Value]()
  # scripts/Kbuild.include
  result["comma"] = initValue(",", false)
  # scripts/subarch.include
  result["SUBARCH"] = initValue(subarch, false)
  # Makefile
  # probably it need to be changed when cross-compile the kernel
  result["ARCH"] = initValue(subarch, false)
  result["SRCARCH"] = initValue(subarch, false)
  result["KBUILD_BUILTIN"] = initValue("y", false)

  result["BITS"] = initValue($(sizeof(pointer)*8), false)

proc getParent(inheritVariables: InheritVariables; path: string): Variables =
  for d in path.parentDirs(inclusive = false):
    inheritVariables.withValue(d, v):
      return v

  return initVariables()

proc add(inheritVariables: var InheritVariables; variables: Variables; path: string) =
  let parent = path.parentDir
  inheritVariables.withValue(parent, inheritV):
    # some directories have both Makefile and Kbuild
    for k, v in variables:
      inheritV[].withValue(k, oldV):
        oldV.v.add v.v
      do:
        inheritV[k] = v
  do:
    inheritVariables[parent] = variables

iterator makefileLogicalLines(src: string): string =
  # https://www.gnu.org/software/make/manual/make.html#Parsing-Makefiles
  var line = ""
  var i = 0
  while i < src.len:
    if src[i] == '\\':
      if i < src.len - 1:
        if src[i + 1] in Newlines:
          removeSuffix line, Whitespace
          inc i, 2
          while i < src.len and src[i] in (Whitespace - Newlines):
            inc i
          line.add ' '
        else:
          line.add src[i + 1]
          inc i, 2
      else:
        inc i
    elif src[i] notin (Newlines + {'#'}):
      line.add src[i]
      inc i

    if i == src.len or src[i] in (Newlines + {'#'}):
      # lines start with a tab are recipes and probably we don't need to care.
      if line.len != 0 and line[0] != '\t':
        yield line
      line = ""
      if i < src.len:
        if src[i] == '#':
          while i < src.len:
            if src[i] == '\\':
              if i < src.len - 1:
                inc i, 2
              else:
                inc i
            elif src[i] in Newlines:
              inc i
              break
            else:
              inc i
        else:
          inc i

proc expandVarRef(x: string; variables: Variables): string

proc getVariableValue(variables: Variables; varName: string): string =
  if varName.startsWith("CONFIG_"):
    # it is kernel config option and not defined in the Makefile
    result = "y"
  else:
    result = ""
    variables.withValue(varName, val):
      if val.isDeferred:
        result = expandVarRef(val.v, variables)
      else:
        result = val.v
    do:
      result = ""
      #doAssert false, "undefined variable is referenced: " & varName

proc expandVarRef(x: string; variables: Variables): string =
  const InvalidVarChar = {')', '}', ':', '#', '='} + Whitespace
  result = ""
  var i = 0
  var stack = newSeq[tuple[res: string, advRef: int]]()
  while i < x.len:
    let n = x.find('$', i)
    if n == -1 or n == x.high:
      result.add x.substr(i)
      break
    elif x[n + 1] == '$':
      result.add x.substr(i, n)
      i = n + 2
    elif x[n + 1] in InvalidVarChar:
      doAssert false, "invalid variable name: " & x
    elif x[n + 1] in {'(', '{'}:
      result.add x.substr(i, n - 1)
      stack.add (res: ensureMove result, advRef: -1)
      result = ""
      doAssert n + 2 < x.high, x
      var advRef = -1
      # ignore any variable references in function call or Substitution References.
      # So $(foo) is ignored even if foo is not defined
      # $(subst y,m,$(foo))
      var inAdvRef = 0  # 0: Not in function call or substitution ref, 1: in fuction call, 2 or more: in func call in func call
      i = n + 2
      while i < x.len and stack.len > 0:
        let n2 = x.find({'$', ' ', ')', '}', ':'}, i)
        if n2 == -1:
          doAssert false, "unclosed variable reference: " & x
        else:
          case x[n2]:
          of '$':
            if n2 == -1 or n2 == x.high:
              doAssert false, "unclosed variable reference: " & x
            elif x[n2 + 1] == '$':
              result.add x.substr(i, n2)
              i = n2 + 2
            elif x[n + 1] in InvalidVarChar:
              doAssert false, "invalid variable name: " & x
            elif x[n2 + 1] in {'(', '{'}:
              if inAdvRef == 0:
                result.add x.substr(i, n2 - 1)
              stack.add (res: ensureMove result, advRef: advRef)
              result = ""
              doAssert n2 + 2 < x.high, x
              advRef = -1
              i = n2 + 2
            else:
              # single character variable name
              if inAdvRef == 0:
                result.add x.substr(i, n2 - 1)
                result.add variables.getVariableValue($x[n2 + 1])
              i = n2 + 2
          of ' ', ':':
            advRef = n2
            inc inAdvRef
            i = n2 + 1
          of ')', '}':
            let prev = stack.pop
            if inAdvRef == 0:
              result.add x.substr(i, n2 - 1)
              let varName = ensureMove result
              result = ensureMove prev.res
              result.add variables.getVariableValue(varName)
            else:
              if advRef != -1:
                dec inAdvRef
              doAssert inAdvRef >= 0
              result = ensureMove prev.res
            advRef = prev.advRef
            i = n2 + 1
          else:
            doAssert false
    else:
      # single character variable name
      result.add x.substr(i, n - 1)
      result.add variables.getVariableValue($x[n + 1])
      i = n + 2

let simplePattern = peg"^ 'obj-$' ('(' / '{') 'CONFIG_' {[A-Z0-9_]+} (')' / '}') \s* [:+]? '=' \s* {.*}$"
let substPattern = peg"^ 'obj-$' ('(' / '{') 'subst' @',' @',' '$' ('(' / '{') 'CONFIG_' {[A-Z0-9_]+} ('))' / '}}') \s* [:+]? '=' \s* {.*}$"

proc matchConfig(x: string; variables: Variables): tuple[conf: string, moduleNames: HashSet[string]] =
  # need to parse lines like "obj-$(CONFIG_FOO) += foo.o"
  # but also need to parse lines like:
  # `obj-$(subst m,y,$(CONFIG_Foo)) += foo.o bar.o`
  # or
  # `obj-$(subst y,$(CONFIG_BAR),$(CONFIG_FOO)) += foo.o`
  #
  # this command shows such special case lines in Makafile:
  # find /usr/src/linux-6.18.62-gentoo -name Makefile -or -name Kbuild | xargs grep -m 4 -P '^obj-(?!(y|m|(\$[({]C)))'
  var matches = ["", ""]
  if match(x, simplePattern, matches) or match(x, substPattern, matches):
    var moduleNames = initHashSet[string]()
    let rhs = expandVarRef(matches[1], variables)
    for n in rhs.split:
      if n.endsWith(".o"):
        moduleNames.incl n[0 ..^ 3]
    result = (matches[0], moduleNames)
  else:
    result = ("", HashSet[string]())

let assignPattern = peg"^ [ ]* {(\w / [-$(){}])+} \s* {('?' / ':::' / '::' / ':' / '+' / '!')? '='} \s* {.*}$"
const IgnoredVarAssign = toHashSet(["obj-y", "cc_has_k_constraint", "clean-files"])
proc matchAssign(x: string; variables: var Variables): bool =
  # `x = y` and `x := y` are actually different:
  # https://www.gnu.org/software/make/manual/make.html#Flavors
  # https://www.gnu.org/software/make/manual/make.html#Reading-Makefiles
  var matches = ["", "", ""]
  if match(x, assignPattern, matches):
    let varName = matches[0].expandVarRef(variables)
    if varName in IgnoredVarAssign:
      return true
    let v = matches[2]
    case matches[1][0]
    of '=':
      variables[varName] = initValue(v, true)
    of '?':
      if varName notin variables:
        variables[varName] = initValue(v, true)
    of ':':
      doAssert matches[1] != ":::=", "':::=' is not implemented"
      variables[varName] = initValue(v.expandVarRef(variables), false)
    of '+':
      variables.withValue(varName, val):
        if val.v.len == 0:
          val.v = if val.isDeferred: v else: expandVarRef(v, variables)
        else:
          val.v.add ' ' 
          val.v.add if val.isDeferred: v else: expandVarRef(v, variables)
      do:
        variables[varName] = initValue(v, true)
    else:
      doAssert false, "Got unsupported assignment: " & x
    if varName.endsWith("-y"):
      # if variable name is like `foo-$(CONFIG_FOO)`, `CONFIG_FOO` can be `y`, `m` or `n`.
      # `$(CONFIG_FOO)` is already expanded to `y`, so also create `foo-m`.
      variables[varName[0..^3] & "-m"] = initValue("", false)
    result = true
  else:
    # not an assignment
    result = false

let definePattern = peg"^define\s+{\w+}$"
proc matchDefine(x: string): string =
  var matches = [""]
  if match(x, definePattern, matches):
    result = matches[0]
  else:
    result = ""

proc parseKbuild(path: string; result: var Config2Mod; inheritVariables: var InheritVariables) =
  #echo "parse ", path
  let content = readFile path
  var variables = inheritVariables.getParent(path)
  var inDefine = false
  var defineVarName = ""
  var defineValue = ""
  for l in makefileLogicalLines(content):
    if inDefine:
      if l == "endef":
        inDefine = false
        if defineValue.len > 0:
          defineValue.setLen(defineValue.high) # remove last '\n'
        variables[defineVarName] = initValue(ensureMove defineValue, true)
        defineValue = ""
      else:
        defineValue.add l
        defineValue.add '\n'
    else:
      let m = matchConfig(l, variables)
      if m.conf != "":
        if m.moduleNames.len > 0:
          result.mgetOrPut(m.conf).incl m.moduleNames
      elif matchAssign(l, variables):
        discard
      elif (defineVarName = matchDefine(l); defineVarName != ""):
        inDefine = true
      else:
        discard
  add inheritVariables, variables, path

proc initConfig2Mod*(kernelSrcDir: string): Config2Mod =
  result = initTable[string, HashSet[string]]()
  var inheritVariables = InheritVariables()
  for p in walkDirRec(kernelSrcDir, checkDir = true):
    let split = splitFile p
    if (split.name == "Makefile" or split.name == "Kbuild") and
       split.dir != kernelSrcDir and
       not split.dir.isRelativeTo(kernelSrcDir / "Documentation") and
       not split.dir.isRelativeTo(kernelSrcDir / "tools") and
       not split.dir.isRelativeTo(kernelSrcDir / "samples") and
       not split.dir.isRelativeTo(kernelSrcDir / "scripts"):
      parseKbuild(p, result, inheritVariables)

proc writeConfig2Mod*(config2Mod: Config2Mod; path: string) =
  ## Output file is used to create a map from module name to kernel option name
  ## a file that maps module names to kernel option names probably larger as one kernel option can enables multiple modules
  var f = open(path, fmWrite)
  for k, v in config2Mod:
    f.write k, ' '
    for i in v:
      f.write i, ','
    f.write '\n'
  close f

when isMainModule:
  import std/sequtils

  doAssert makefileLogicalLines("").toSeq == @[]
  doAssert makefileLogicalLines("\n").toSeq == @[]
  doAssert makefileLogicalLines("\n\n").toSeq == @[]
  doAssert makefileLogicalLines("a").toSeq == @["a"]
  doAssert makefileLogicalLines("ab").toSeq == @["ab"]
  doAssert makefileLogicalLines("a\nb").toSeq == @["a", "b"]
  doAssert makefileLogicalLines("a\nbc").toSeq == @["a", "bc"]
  doAssert makefileLogicalLines("a\nb\nc").toSeq == @["a", "b", "c"]
  doAssert makefileLogicalLines("a\nb\nc\n").toSeq == @["a", "b", "c"]
  doAssert makefileLogicalLines("a\\\nb").toSeq == @["a b"]
  doAssert makefileLogicalLines("a  \\\n  b").toSeq == @["a b"]
  doAssert makefileLogicalLines("#").toSeq == @[]
  doAssert makefileLogicalLines("#a\nb").toSeq == @["b"]
  doAssert makefileLogicalLines("#a\n#b").toSeq == @[]
  doAssert makefileLogicalLines("#a\\\nb").toSeq == @[]
  doAssert makefileLogicalLines("a#b\\\nc").toSeq == @["a"]
  doAssert makefileLogicalLines("#a\\\nb\nc").toSeq == @["c"]
  doAssert makefileLogicalLines("\\#").toSeq == @["#"]
  doAssert makefileLogicalLines("\\#a").toSeq == @["#a"]
  doAssert makefileLogicalLines("#\\#a\n#b").toSeq == @[]
  doAssert makefileLogicalLines("#\\#a\n#b\nc").toSeq == @["c"]
  doAssert makefileLogicalLines(r"\\").toSeq == @[r"\"]
  doAssert makefileLogicalLines("""\\
\#""").toSeq == @[r"\", "#"]
  doAssert makefileLogicalLines("""\\
""").toSeq == @[r"\"]
  doAssert makefileLogicalLines("""abc#\
comment\
more comment\\\
last\ comment
123
""").toSeq == @["abc", "123"]

  block:
    var variables = initVariables()
    doAssert expandVarRef("", variables) == ""
    doAssert expandVarRef("a", variables) == "a"
    doAssert expandVarRef("abc", variables) == "abc"
    doAssert expandVarRef("$$", variables) == "$"
    doAssert expandVarRef("a$$", variables) == "a$"
    doAssert expandVarRef("$$b", variables) == "$b"
    doAssert expandVarRef("a$$b", variables) == "a$b"
    doAssert expandVarRef("$$$$", variables) == "$$"
    doAssert expandVarRef("a$$$$b", variables) == "a$$b"
    doAssert expandVarRef("$$(x)", variables) == "$(x)"
    variables["x"] = initValue("y", false)
    doAssert expandVarRef("$(x)", variables) == "y"
    doAssert expandVarRef("${x}", variables) == "y"
    doAssert expandVarRef("$x", variables) == "y"
    doAssert expandVarRef("a$(x)", variables) == "ay"
    doAssert expandVarRef("$(x)b", variables) == "yb"
    doAssert expandVarRef("a$(x)b", variables) == "ayb"
    doAssert expandVarRef("$(x)$(x)", variables) == "yy"
    doAssert expandVarRef("a$(x)b$(x)c", variables) == "aybyc"
    doAssert expandVarRef("x$xx", variables) == "xyx"
    variables["abc"] = initValue("def", false)
    doAssert expandVarRef("$(abc)", variables) == "def"
    doAssert expandVarRef("$$(abc)", variables) == "$(abc)"
    variables["deferredx"] = initValue("$(x)", true)
    doAssert expandVarRef("$(deferredx)", variables) == "y"
    variables["deferredxabc"] = initValue("$(x)$(abc)", true)
    doAssert expandVarRef("$(deferredxabc)", variables) == "ydef"
    variables["deferredxabc2"] = initValue("a${deferredxabc}b", true)
    doAssert expandVarRef("$(deferredxabc2)", variables) == "aydefb"
    doAssert expandVarRef("$(dummyfunc, x,y,z)", variables) == ""
    doAssert expandVarRef("a$(dummyfunc, x,y,z)", variables) == "a"
    doAssert expandVarRef("$(dummyfunc, x,y,z)b", variables) == "b"
    doAssert expandVarRef("a$(dummyfunc, x,y,z)b", variables) == "ab"

    variables["var-y"] = initValue("var-y-val", false)
    doAssert expandVarRef("$(var-$(x))", variables) == "var-y-val"
    variables["var-def-y"] = initValue("var-def-y-val", false)
    doAssert expandVarRef("$(var-$(abc)-y)", variables) == "var-def-y-val"
    variables["var-y-def-y"] = initValue("val2", false)
    doAssert expandVarRef("a$(var-$(x)-$(abc)-y)b", variables) == "aval2b"
    variables["val2"] = initValue("val3", false)
    doAssert expandVarRef("$($(var-$(x)-$(abc)-y))", variables) == "val3"
    variables["obj$y"] = initValue("val4", false)
    doAssert expandVarRef("$$$(obj$$$(x))$$", variables) == "$val4$"

    doAssert expandVarRef("$(subst, $(undefined))", variables) == ""
    doAssert expandVarRef("$(x$(subst a,b,c))", variables) == "y"
    doAssert expandVarRef("$(x$(subst $(undef),b,c))", variables) == "y"
    doAssert expandVarRef("$(x$(subst $(undef$(f $(x))),b,c))", variables) == "y"
    doAssert expandVarRef("$(f a)$(f $(a))$(f $(g a) $(b))", variables) == ""
    doAssert expandVarRef("$(f $x)", variables) == ""

  block:
    var variables = initVariables()
    doAssert matchConfig("obj-y += a.o", variables) == ("", HashSet[string]())
    doAssert matchConfig("obj-$(CONFIG_A) += a.o", variables) == ("A", toHashSet(["a"]))
    doAssert matchConfig("obj-$(CONFIG_A) := a.o", variables) == ("A", toHashSet(["a"]))
    doAssert matchConfig("obj-$(CONFIG_A) = a.o", variables) == ("A", toHashSet(["a"]))
    doAssert matchConfig("obj-$(CONFIG_FOO) += foo.o foo2.o", variables) == ("FOO", toHashSet(["foo", "foo2"]))
    doAssert matchConfig("obj-$(CONFIG_FOO) += foo/", variables) == ("FOO", HashSet[string]())
    doAssert matchConfig("obj-$(CONFIG_ABC123) += abc123/ abc123.o", variables) == ("ABC123", toHashSet(["abc123"]))
    doAssert matchConfig("obj-$(subst m,y,$(CONFIG_FOO)) += foo.o", variables) == ("FOO", toHashSet(["foo"]))
    doAssert matchConfig("obj-$(subst y,$(CONFIG_BAR),$(CONFIG_FOO)) += foo.o bar.o", variables) == ("FOO", toHashSet(["foo", "bar"]))
    doAssert matchAssign("x = y.o", variables)
    doAssert matchConfig("obj-$(CONFIG_X) += $(x)", variables) == ("X", toHashSet(["y"]))
    doAssert matchAssign("abc-y$(CONFIG_Y) += def.o", variables)
    doAssert matchConfig("obj-$(CONFIG_ABC) += $(abc-yy)", variables) == ("ABC", toHashSet(["def"]))

  block:
    var variables = initVariables()
    clear variables
    doAssert matchAssign("x = y", variables)
    doAssert variables == {"x": initValue("y", true)}.toTable
    doAssert matchAssign("abc = def", variables)
    doAssert variables == {"x": initValue("y", true), "abc": initValue("def", true)}.toTable
    doAssert matchAssign("recurfoo = $(foo)", variables)
    doAssert variables == {"x": initValue("y", true), "abc": initValue("def", true), "recurfoo": initValue("$(foo)", true)}.toTable
    doAssert matchAssign("foo = f", variables)
    doAssert expandVarRef("$(recurfoo)", variables) == "f"
    doAssert matchAssign("var-$(CONFIG_X) = var-x", variables)
    doAssert expandVarRef("$(var-y)", variables) == "var-x"
    doAssert matchAssign("var-$(var-y) = value", variables)
    doAssert expandVarRef("$(var-var-x)", variables) == "value"
    doAssert matchAssign("    indentedVar = zzz", variables)
    doAssert expandVarRef("$(indentedVar)", variables) == "zzz"

  block:
    var variables = initVariables()
    clear variables
    doAssert matchAssign("x = y", variables)
    doAssert matchAssign("x ?= z", variables)
    doAssert variables == {"x": initValue("y", true)}.toTable

  block:
    var variables = initVariables()
    clear variables
    doAssert matchAssign("x := y", variables)
    doAssert variables == {"x": initValue("y", false)}.toTable
    doAssert matchAssign("abc ::= def", variables)
    doAssert variables == {"x": initValue("y", false), "abc": initValue("def", false)}.toTable
    doAssert matchAssign("x2 ::= $(x)", variables)
    doAssert variables == {"x": initValue("y", false), "abc": initValue("def", false), "x2": initValue("y", false)}.toTable
    doAssert matchAssign("x3 ::= $(x2)$(x)", variables)
    doAssert variables == {"x": initValue("y", false), "abc": initValue("def", false), "x2": initValue("y", false), "x3": initValue("yy", false)}.toTable

  block:
    var variables = initVariables()
    clear variables
    doAssert matchAssign("abc := def", variables)
    doAssert matchAssign("x := y", variables)
    doAssert matchAssign("x += $(abc)", variables)
    doAssert variables == {"abc": initValue("def", false), "x": initValue("y def", false)}.toTable
    doAssert matchAssign("foo += $(abc)", variables)
    doAssert variables == {"abc": initValue("def", false), "x": initValue("y def", false), "foo": initValue("$(abc)", true)}.toTable
    doAssert matchAssign("foo += $(x)", variables)
    doAssert variables == {"abc": initValue("def", false), "x": initValue("y def", false), "foo": initValue("$(abc) $(x)", true)}.toTable
    doAssert matchAssign("bar := $(foo)", variables)
    doAssert variables == {"abc": initValue("def", false), "x": initValue("y def", false), "foo": initValue("$(abc) $(x)", true), "bar": initValue("def y def", false)}.toTable

  #[
  let config2Mod = initConfig2Mod("/usr/src/linux")
  echo "find ", config2Mod.len, " kernel options"
  writeConfig2Mod config2Mod, "config2mod.txt"
  ]#

  initConfig2Mod("/usr/src/linux").writeConfig2Mod("skc_config2mod.txt")
