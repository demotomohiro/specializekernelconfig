## Collect module infos from kernel modules in the specified kernel build directory and write them on one file.

# Some modules in Linux kernel can compile only as module, not as builtin.
# Even if you run `make allyesconfig`, some options are set to module.
import std/[cmdline, memfiles, os, osproc, strformat, syncio, tempfiles]

let appName = getAppFilename().extractFilename
if paramCount() != 1:
  quit &"usage: {appName} /path/to/kernel/build/directory"

if findExe("objcopy") == "":
  quit"objcopy in binutils is required but missing"

let targetDir = paramStr(1)

var modulePaths = newSeqOfCap[string](256)
for l in lines(targetDir / "modules.order"):
  if l.len == 0:
    continue
  else:
    modulePaths.add l

let output = syncio.open("skc_modules.module.modinfo", fmWrite)
let modInfoPath = genTempPath(appName, ".modinfo")
for mp in modulePaths:
  let mpSplit = mp.splitFile
  let modname = mpSplit.name
  let modPath = (targetDir / mpSplit.dir / mpSplit.name) & ".ko"

  block:
    var objCopyPrc = startProcess("objcopy", args = ["-O", "binary", "--only-section=.modinfo", modPath, modInfoPath], options = {poUsePath, poParentStreams})

    doAssert waitForExit(objCopyPrc) == 0
    close objCopyPrc

  block:
    var f = memfiles.open(modInfoPath)
    for slice in f.memSlices('\0', '\0'):
      # write each field in the same way as "modules.builtin.modinfo" so that I can reuse the proc to read it.
      output.write modname
      output.write '.'
      doAssert output.writeBuffer(slice.data, slice.size) == slice.size
      output.write '\0'
    output.write modname
    output.write '.'
    output.write "skc_file="
    output.write (mpSplit.dir / mpSplit.name)
    output.write '\0'
    close f

removeFile modInfoPath
close output
