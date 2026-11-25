import std/[algorithm, os, strutils]

type
  DeviceDir* = object
    path*: string
    modalias*: string

proc getDeviceDirs*(dir: string): seq[DeviceDir] =
  result = newSeqOfCap[DeviceDir](256)
  for path in walkDirRec(dir, {pcDir}, checkDir = true):
    var f: File = nil
    if open(f, path / "modalias"):
      var modalias = readAll f
      stripLineEnd modalias
      result.add DeviceDir(path: path, modalias: modalias)
      close f

  sort result, proc (x, y: DeviceDir): int = cmp(x.path, y.path)
