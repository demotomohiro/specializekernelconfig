import std/[os, strscans, strutils, syncio, tables]

type
  USBVendorIDType = uint16
  USBProductIDType = uint16
  USBClassType = uint8
  USBSubClassType = uint8
  USBProtocolType = uint8

  USBVendor = object
    vendorName: string
    products: Table[USBProductIDType, string]

  USBSubClass = object
    subClassName: string
    protocols: Table[USBProtocolType, string]

  USBClass = object
    className: string
    subClasses: Table[USBSubClassType, USBSubClass]

var isInitUSBIDs = false
var usbIDs = initTable[USBVendorIDType, USBVendor](256*32)
var usbClasses = initTable[USBClassType, USBClass](32)

proc readNextLine(f: File; line: var string): bool =
  result = false
  while (result = readLine(f, line); result):
    if line.len != 0 and line[0] != '#':
      break

proc getUSBDeviceName(vendorID:   USBVendorIDType;
                      productID:  USBProductIDType;
                      classID:    USBClassType;
                      subClassID: USBSubClassType;
                      protocolID: USBProtocolType): string =
  result = ""
  if not isInitUSBIDs:
    const USBIDSPath = "/usr/share/hwdata/usb.ids"
    var f: File = nil
    if open(f, USBIDSPath):
      var l = ""
      var has = readNextLine(f, l)
      while has:
        doAssert l.len > 0
        if l[0] notin {'0' .. '9', 'a' .. 'f'}:
          break
        var vid = 0
        var v = ""
        if scanf(l, "$h  $+", vid, v):
          var vendor = USBVendor(vendorName: v, products: initTable[USBProductIDType, string]())
          has = readNextLine(f, l)
          while has and l[0] == '\t':
            var pid = 0
            var p = ""
            if scanf(l, "\t$h  $+", pid, p):
              doAssert pid <= USBProductIDType.high.int
              vendor.products[pid.USBProductIDType] = p
            has = readNextLine(f, l)
          doAssert vid <= USBVendorIDType.high.int
          usbIDs[vid.USBVendorIDType] = ensureMove vendor
        else:
          has = readNextLine(f, l)
      while has:
        if l[0] != 'C':
          break
        var cid = 0
        var c = ""
        if scanf(l, "C $h  $+", cid, c):
          var class = USBClass(className: c, subClasses: initTable[USBSubClassType, USBSubClass]())
          has = readNextLine(f, l)
          while has and l[0] == '\t':
            var scid = 0
            var sc = ""
            if scanf(l, "\t$h  $+", scid, sc):
              var subClass = USBSubClass(subClassName: sc, protocols: initTable[USBProtocolType, string]())
              has = readNextLine(f, l)
              while has and l.len > 1 and l[0] == '\t' and l[1] == '\t':
                var prtclid = 0
                var prtcl = ""
                if scanf(l, "\t\t$h  $+", prtclid, prtcl):
                  doAssert prtclid <= USBProtocolType.high.int
                  subClass.protocols[prtclid.USBProtocolType] = prtcl
                has = readNextLine(f, l)
              doAssert scid <= USBSubClassType.high.int
              class.subClasses[scid.USBSubClassType] = ensureMove subClass
            else:
              has = readNextLine(f, l)
          doAssert cid <= USBClassType.high.int
          usbClasses[USBClassType(cid)] = ensureMove class
        else:
          has = readNextLine(f, l)
      close f
    else:
      echo "Warning: ", USBIDSPath, " is unreable and cannot print USB device names"

    isInitUSBIDs = true

  usbIDs.withValue(vendorID, v):
    result = v.vendorName
    v.products.withValue(productID, p):
      result.add " " & p[]

  usbClasses.withValue(classID, c):
    result.add '('
    result.add c.className
    c.subClasses.withValue(subClassID, sc):
      result.add '/'
      if subClassID != 0:
        result.add sc.subClassName
      sc.protocols.withValue(protocolID, prtcl):
        result.add '/'
        result.add prtcl[]
    result.add ')'

proc readAll(path: string): tuple[content: string, success: bool] = 
  result = ("", false)
  var f: File = nil
  if open(f, path):
    result.content = readAll f
    close f
    stripLineEnd result.content
    result.success = true

proc getDeviceName*(path, modalias: string): string =
  result = ""

  if modalias.startsWith("usb"):
    var r = readAll(path.parentDir / "idVendor")
    if not r.success:
      return

    let vendorID = r.content.fromHex[:USBVendorIDType]()
    r = readAll(path.parentDir / "idProduct")
    if not r.success:
      return
    let productID = r.content.fromHex[:USBProductIDType]()

    r = readAll(path / "bInterfaceClass")
    let classID = if r.success:
                    r.content.fromHex[:USBClassType]()
                  else:
                    0
    r = readAll(path / "bInterfaceSubClass")
    let subClassID = if r.success:
                       r.content.fromHex[:USBSubClassType]()
                     else:
                       0
    r = readAll(path / "bInterfaceProtocol")
    let protocolID = if r.success:
                       r.content.fromHex[:USBProtocolType]()
                     else:
                       0
    result = getUSBDeviceName(vendorID, productID, classID, subClassID, protocolID)

when false:
  proc getDeviceName*(modalias: string): string =
    # /usr/src/linux/scripts/mod/file2alias.c creates modalias patterns in modules.
    # modalias_show function in
    # /usr/src/linux/drivers/pci/pci-sysfs.c 
    # /usr/src/linux/drivers/usb/core/sysfs.c
    # creates modalias string in sysfs.

    const
      HexDigits = {'0'..'9', 'A'..'F'}
      NotHexDigits = HexDigits.complement
      PCIStart = "pci:v"
    if modalias.startsWith(PCIStart) and modalias.len > PCIStart.len:
      var i = PCIStart.len
      var j = modalias.find(NotHexDigits, i)
