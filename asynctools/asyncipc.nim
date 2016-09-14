#
#
#       Asynchronous tools for Nim Language
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This module implements cross-platform asynchronous inter-process
## communication. 
## 
## Module uses shared memory implementation for Windows, and fifo(7) for
## Linux/BSD/MacOS.

import asyncdispatch, os

type
  SideType* = enum
    sideReader, sideWriter

when defined(windows):
  import winlean
  import sets, hashes # this import only for HackDispatcher

  const
    mapHeaderName = "asyncipc_"
    eventHeaderName = "asyncpipc_"
    mapMinSize = 4096
    EVENT_MODIFY_STATE = 0x0002.Dword
    FILE_MAP_ALL_ACCESS = 0x000F0000 or 0x01 or 0x02 or 0x04 or 0x08 or 0x10

  type
    AsyncIpc* = object
      handleMap, eventChange: Handle
      name: string
      size: int32

    AsyncIpcHandle* = object
      data: pointer
      handleMap, eventChange: Handle
      size: int
      side: SideType

    CallbackDataImpl = object
      ioPort: Handle
      handleFd: AsyncFD
      waitFd: Handle
      ovl: PCustomOverlapped
    CallbackData = ptr CallbackDataImpl

    HackDispatcherImpl = object
      reserverd: array[56, char]
      ioPort: Handle
      handles: HashSet[AsyncFD]
    HackDispatcher = ptr HackDispatcherImpl

  proc openEvent(dwDesiredAccess: Dword, bInheritHandle: WINBOOL,
                 lpName: WideCString): Handle
       {.importc: "OpenEventW", stdcall, dynlib: "kernel32".}
  proc openFileMapping(dwDesiredAccess: Dword, bInheritHandle: Winbool,
                       lpName: WideCString): Handle
       {.importc: "OpenFileMappingW", stdcall, dynlib: "kernel32".}
  proc interlockedOr(a: ptr int32, b: int32)
       {.importc: "_InterlockedOr", header: "intrin.h".}
  proc interlockedAnd(a: ptr int32, b: int32)
       {.importc: "_InterlockedAnd", header: "intrin.h".}

  proc getCurrentDispatcher(): HackDispatcher =
    result = cast[HackDispatcher](getGlobalDispatcher())

  proc createIpc*(name: string, size = 65536): AsyncIpc =
    ## Creates `AsyncIpc` object with internal buffer size `size`.
    var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                 lpSecurityDescriptor: nil, bInheritHandle: 1)
    let mapName = newWideCString(mapHeaderName & name)
    let nameChange = newWideCString(eventHeaderName & name & "_change")
    let mapSize = size + mapMinSize

    doAssert(size > mapMinSize)

    let handleMap = createFileMappingW(INVALID_HANDLE_VALUE,
                                       cast[pointer](addr sa),
                                       PAGE_READWRITE, 0, mapSize.Dword,
                                       cast[pointer](mapName))
    if handleMap == 0:
      raiseOSError(osLastError())
    var eventChange = createEvent(addr sa, 0, 0, addr nameChange[0])
    if eventChange == 0:
      let err = osLastError()
      discard closeHandle(handleMap)
      raiseOSError(err)

    var data = mapViewOfFileEx(handleMap, FILE_MAP_WRITE, 0, 0, mapMinSize, nil)
    if data == nil:
      let err = osLastError()
      discard closeHandle(handleMap)
      discard closeHandle(eventChange)
      raiseOSError(err)

    cast[ptr int32](cast[uint](data) + sizeof(int32).uint * 2)[] = size.int32

    result = AsyncIpc(
      name: name,
      handleMap: handleMap,
      size: size.int32,
      eventChange: eventChange
    )

  proc close*(ipc: AsyncIpc) =
    ## Closes `AsyncIpc` object.
    if closeHandle(ipc.handleMap) == 0:
      raiseOSError(osLastError())
    if closeHandle(ipc.eventChange) == 0:
      raiseOSError(osLastError())

  proc open*(name: string, side: SideType, register = true): AsyncIpcHandle =
    ## Opens `side` channel to AsyncIpc object.
    ## If `register` is `false`, newly created channel will not be registerd
    ## with current dispatcher.
    let mapName = newWideCString(mapHeaderName & name)
    let nameChange = newWideCString(eventHeaderName & name & "_change")

    var handleMap = openFileMapping(FILE_MAP_ALL_ACCESS, 1, mapName)
    if handleMap == 0:
      raiseOSError(osLastError())

    var eventChange = openEvent(EVENT_MODIFY_STATE or SYNCHRONIZE,
                                0, nameChange)
    if eventChange == 0:
      let err = osLastError()
      discard closeHandle(handleMap)
      raiseOSError(err)

    var data = mapViewOfFileEx(handleMap, FILE_MAP_WRITE, 0, 0, mapMinSize, nil)
    if data == nil:
      let err = osLastError()
      discard closeHandle(handleMap)
      discard closeHandle(eventChange)
      raiseOSError(err)

    var size = cast[ptr int32](cast[uint](data) + sizeof(int32).uint * 2)[]
    doAssert(size > mapMinSize)

    if unmapViewOfFile(data) == 0:
      let err = osLastError()
      discard closeHandle(handleMap)
      discard closeHandle(eventChange)
      raiseOSError(err)

    data = mapViewOfFileEx(handleMap, FILE_MAP_WRITE, 0, 0, size, nil)
    if data == nil:
      let err = osLastError()
      discard closeHandle(handleMap)
      discard closeHandle(eventChange)
      raiseOSError(err)

    if side == sideWriter:
      interlockedOr(cast[ptr int32](data), 2)
    else:
      interlockedOr(cast[ptr int32](data), 1)

    if register:
      let p = getCurrentDispatcher()
      p.handles.incl(AsyncFD(eventChange))

    result = AsyncIpcHandle(
      data: data,
      size: size,
      handleMap: handleMap,
      eventChange: eventChange,
      side: side
    )

  proc close*(ipch: AsyncIpcHandle, unregister = true) =
    ## Closes channel to `AsyncIpc` object.
    ## If `unregister` is false, channel will not be unregistered from
    ## current dispatcher.
    if ipch.side == sideWriter:
      interlockedAnd(cast[ptr int32](ipch.data), not(2))
    else:
      interlockedAnd(cast[ptr int32](ipch.data), not(1))

    if unregister:
      let p = getCurrentDispatcher()
      p.handles.excl(AsyncFD(ipch.eventChange))

    if unmapViewOfFile(ipch.data) == 0:
      raiseOSError(osLastError())
    if closeHandle(ipch.eventChange) == 0:
      raiseOSError(osLastError())
    if closeHandle(ipch.handleMap) == 0:
      raiseOSError(osLastError())

  template getSize(ipch: AsyncIpcHandle): int32 =
    cast[ptr int32](cast[uint](ipch.data) + sizeof(int32).uint)[]

  template getPointer(ipch: AsyncIpcHandle): pointer =
    cast[pointer](cast[uint](ipch.data) + sizeof(int32).uint * 3)

  template setSize(ipc: AsyncIpcHandle, size: int) =
    cast[ptr int32](cast[uint](ipc.data) + sizeof(int32).uint)[] = size.int32

  template setData(ipc: AsyncIpcHandle, data: pointer, size: int) =
    copyMem(getPointer(ipc), data, size)

  template getData(ipc: AsyncIpcHandle, data: pointer, size: int) =
    copyMem(data, getPointer(ipc), size)

  {.push stackTrace:off.}
  proc waitableCallback(param: pointer,
                        timerOrWaitFired: WINBOOL): void {.stdcall.} =
    var p = cast[CallbackData](param)
    discard postQueuedCompletionStatus(p.ioPort, timerOrWaitFired.Dword,
                                       ULONG_PTR(p.handleFd),
                                       cast[pointer](p.ovl))
  {.pop.}

  template registerWaitableChange(ipc: AsyncIpcHandle, pcd, handleCallback) =
    let p = getCurrentDispatcher()
    var flags = (WT_EXECUTEINWAITTHREAD or WT_EXECUTEONLYONCE).Dword
    pcd.ioPort = cast[Handle](p.ioPort)
    pcd.handleFd = AsyncFD(ipc.eventChange)
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: AsyncFD(ipc.eventChange), cb: handleCallback)
    # We need to protect our callback environment value, so GC will not free it
    # accidentally.
    ol.data.cell = system.protect(rawEnv(ol.data.cb))
    pcd.ovl = ol
    if not registerWaitForSingleObject(addr(pcd.waitFd), ipc.eventChange,
                                    cast[WAITORTIMERCALLBACK](waitableCallback),
                                       cast[pointer](pcd), INFINITE, flags):
      GC_unref(ol)
      deallocShared(cast[pointer](pcd))
      raiseOSError(osLastError())

  proc write*(ipch: AsyncIpcHandle, data: pointer, size: int): Future[void] =
    var retFuture = newFuture[void]("asyncipc.write")
    doAssert(ipch.size >= size and size > 0)
    doAssert(ipch.side == sideWriter)

    if getSize(ipch) == 0:
      setData(ipch, data, size)
      setSize(ipch, size)
      if setEvent(ipch.eventChange) == 0:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
      else:
        retFuture.complete()
    else:
      var pcd = cast[CallbackData](allocShared0(sizeof(CallbackDataImpl)))

      proc writecb(fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
        # unregistering wait handle and free `CallbackData`
        if unregisterWait(pcd.waitFd) == 0:
          let err = osLastError()
          if err.int32 != ERROR_IO_PENDING:
            retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
        deallocShared(cast[pointer](pcd))

        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            setData(ipch, data, size)
            setSize(ipch, size)
            if setEvent(ipch.eventChange) == 0:
              retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
            else:
              retFuture.complete()
          else:
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))

      registerWaitableChange(ipch, pcd, writecb)

    return retFuture

  proc readInto*(ipch: AsyncIpcHandle, data: pointer, size: int): Future[int] =
    var retFuture = newFuture[int]("asyncipc.readInto")
    doAssert(size > 0)
    doAssert(ipch.side == sideReader)

    var packetSize = getSize(ipch)
    if packetSize == 0:
      var pcd = cast[CallbackData](allocShared0(sizeof(CallbackDataImpl)))

      proc readcb(fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
        # unregistering wait handle and free `CallbackData`
        if unregisterWait(pcd.waitFd) == 0:
          let err = osLastError()
          if err.int32 != ERROR_IO_PENDING:
            retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
        deallocShared(cast[pointer](pcd))

        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            packetSize = getSize(ipch)
            if packetSize > 0:
              getData(ipch, data, packetSize)
              setSize(ipch, 0)
            if setEvent(ipch.eventChange) == 0:
              retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
            else:
              retFuture.complete(packetSize)
          else:
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))

      registerWaitableChange(ipch, pcd, readcb)
    else:
      if size < packetSize:
        packetSize = size.int32
      getData(ipch, data, packetSize)
      setSize(ipch, 0)
      if setEvent(ipch.eventChange) == 0:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
      else:
        retFuture.complete(packetSize)

    return retFuture
else:
  import posix

  const
    pipeHeaderName = r"/tmp/asyncipc_"

  type
    AsyncIpc* = object
      name: string
      size: int

  type
    AsyncIpcHandle* = object
      fd: AsyncFD
      size: int
      side: SideType

  proc setNonBlocking(fd: cint) {.inline.} =
    var x = fcntl(fd, F_GETFL, 0)
    if x == -1:
      raiseOSError(osLastError())
    else:
      var mode = x or O_NONBLOCK
      if fcntl(fd, F_SETFL, mode) == -1:
        raiseOSError(osLastError())

  proc createIpc*(name: string, size = 65536): AsyncIpc =
    let pipeName = pipeHeaderName & name
    if mkfifo(cstring(pipeName), Mode(0x1B6)) != 0:
      raiseOSError(osLastError())
    result = AsyncIpc(
      name: name,
      size: size
    )

  proc close*(ipc: AsyncIpc) =
    let pipeName = pipeHeaderName & ipc.name
    if posix.unlink(cstring(pipeName)) != 0:
      raiseOSError(osLastError())

  proc open*(name: string, side: SideType, register = true): AsyncIpcHandle =
    var pipeFd: cint = 0
    let pipeName = pipeHeaderName & name

    if side == sideReader:
      pipeFd = open(pipeName, O_NONBLOCK or O_RDWR)
    else:
      pipeFd = open(pipeName, O_NONBLOCK or O_WRONLY)

    if pipeFd < 0:
      raiseOSError(osLastError())

    let afd = AsyncFD(pipeFd)
    if register:
      register(afd)

    result = AsyncIpcHandle(
      fd: afd,
      side: side,
      size: ipc.size
    )

  proc close*(ipch: AsyncIpcHandle) =
    if close(cint(ipch.fd)) != 0:
      raiseOSError(osLastError())

  proc write*(ipch: AsyncIpcHandle, data: pointer, nbytes: int): Future[void] =
    var retFuture = newFuture[void]("asyncipc.write")
    var written = 0

    proc cb(fd: AsyncFD): bool =
      result = true
      let reminder = nbytes - written
      let pdata = cast[pointer](cast[uint](data) + written.uint)
      let res = posix.write(cint(ipch.fd), pdata, cint(reminder))
      if res < 0:
        let err = osLastError()
        if err.int32 != EAGAIN:
          retFuture.fail(newException(OSError, osErrorMsg(err)))
        else:
          result = false # We still want this callback to be called.
      else:
        written.inc(res)
        if res != reminder:
          result = false
        else:
          retFuture.complete()

    doAssert(ipch.side == sideWriter)

    if not cb(ipch.fd):
      addWrite(ipch.fd, cb)

    return retFuture

  proc readInto*(ipch: AsyncIpcHandle, data: pointer,
                 nbytes: int): Future[int] =
    var retFuture = newFuture[int]("asyncipc.readInto")
    proc cb(fd: AsyncFD): bool =
      result = true
      let res = posix.read(cint(ipch.fd), data, cint(nbytes))
      if res < 0:
        let lastError = osLastError()
        if lastError.int32 != EAGAIN:
          retFuture.fail(newException(OSError, osErrorMsg(lastError)))
        else:
          result = false # We still want this callback to be called.
      elif res == 0:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
      else:
        retFuture.complete(res)

    doAssert(ipch.side == sideReader)

    if not cb(ipch.fd):
      addRead(ipch.fd, cb)
    return retFuture

when isMainModule:
  var inBuffer = newString(64)
  var outHeader = "TEST STRING BUFFER"
  var data = ""
  var length = 0

  when not defined(windows):
    discard posix.unlink("/tmp/asyncipc_test")

  var ipc = createIpc("test")
  var readHandle = open("test", sideReader)
  var writeHandle = open("test", sideWriter)

  data = outHeader & " 1"
  waitFor write(writeHandle, cast[pointer](addr data[0]), len(data))
  length = waitFor readInto(readHandle, cast[pointer](addr inBuffer[0]), 64)
  inBuffer.setLen(length)
  doAssert(data == inBuffer)
  close(readHandle)
  close(writeHandle)
  close(ipc)


