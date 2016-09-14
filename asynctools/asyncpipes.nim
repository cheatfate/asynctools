#
#
#       Asynchronous tools for Nim Language
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

import asyncdispatch, os

type
  AsyncPipe* = distinct AsyncFD

proc `==`*(x: AsyncPipe, y: AsyncPipe): bool {.borrow.}

when defined(windows):
  import winlean

  proc QueryPerformanceCounter(res: var int64)
       {.importc: "QueryPerformanceCounter", stdcall, dynlib: "kernel32".}
  proc connectNamedPipe(hNamedPipe: Handle, lpOverlapped: pointer): WINBOOL
       {.importc: "ConnectNamedPipe", stdcall, dynlib: "kernel32".}

  const
    pipeHeaderName = r"\\.\pipe\asyncpipe_"

  const
    FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000'i32
    PIPE_WAIT = 0x00000000'i32
    PIPE_TYPE_BYTE = 0x00000000'i32
    ERROR_PIPE_CONNECTED = 535
    ERROR_PIPE_BUSY = 231

  proc wrap*(handle: Handle): AsyncPipe =
    register(AsyncFD(handle))
    result = AsyncPipe(handle)

  proc unwrap*(pipe: AsyncPipe) =
    unregister(AsyncFD(pipe))

  proc asyncPipes*(inSize = 65536'i32,
                   outSize = 65536'i32,
                   register = true): tuple[readPipe, writePipe: AsyncPipe] =
    ## Create descriptor pair for interprocess communication.
    var number = 0'i64
    var pipeName: WideCString
    var pipeIn: Handle
    var pipeOut: Handle
    var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                 lpSecurityDescriptor: nil, bInheritHandle: 1)
    while true:
      QueryPerformanceCounter(number)
      let p = pipeHeaderName & $number
      pipeName = newWideCString(p)
      var openMode = FILE_FLAG_FIRST_PIPE_INSTANCE or FILE_FLAG_OVERLAPPED or
                     PIPE_ACCESS_INBOUND
      var pipeMode = PIPE_TYPE_BYTE or PIPE_WAIT
      pipeIn = createNamedPipe(pipeName, openMode, pipeMode, 1'i32,
                               inSize, outSize,
                               1'i32, addr sa)
      if pipeIn == INVALID_HANDLE_VALUE:
        let err = osLastError()
        if err.int32 != ERROR_PIPE_BUSY:
          raiseOsError(err)
      else:
        break

    pipeOut = createFileW(pipeName, GENERIC_WRITE, 0, addr(sa), OPEN_EXISTING,
                          FILE_FLAG_OVERLAPPED, 0)
    if pipeOut == INVALID_HANDLE_VALUE:
      let err = osLastError()
      discard closeHandle(pipeIn)
      raiseOsError(err)

    result = (readPipe: AsyncPipe(pipeIn), writePipe: AsyncPipe(pipeOut))

    var ovl = OVERLAPPED()
    let res = connectNamedPipe(pipeIn, cast[pointer](addr ovl))
    if res == 0:
      let err = osLastError()
      if err.int32 == ERROR_PIPE_CONNECTED:
        discard
      elif err.int32 == ERROR_IO_PENDING:
        var bytesRead = 0.Dword
        if getOverlappedResult(pipeIn, addr ovl, bytesRead, 1) == 0:
          let oerr = osLastError()
          discard closeHandle(pipeIn)
          discard closeHandle(pipeOut)
          raiseOsError(oerr)
      else:
        discard closeHandle(pipeIn)
        discard closeHandle(pipeOut)
        raiseOsError(err)

    if register:
      register(AsyncFD(pipeIn))
      register(AsyncFD(pipeOut))

  proc close*(pipe: AsyncPipe, unregister = true) =
    if unregister:
      unregister(AsyncFD(pipe))
    if closeHandle(Handle(pipe)) == 0:
      raiseOsError(osLastError())

  proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[void] =
    var retFuture = newFuture[void]("asyncpipes.write")
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: AsyncFD(pipe), cb:
      proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            assert bytesCount == nbytes.int32
            retFuture.complete()
          else:
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )
    let res = writeFile(Handle(pipe), data, nbytes.int32, nil,
                        cast[POVERLAPPED](ol)).bool
    if not res:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    else:
      var bytesWritten = 0.Dword
      if getOverlappedResult(Handle(pipe), cast[POVERLAPPED](ol),
                             bytesWritten, Winbool(false)) == 0:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
      else:
        assert bytesWritten == nbytes
        retFuture.complete()
    return retFuture

  proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
    var retFuture = newFuture[int]("asyncpipes.readInto")
    var ol = PCustomOverlapped()
    GC_ref(ol)
    ol.data = CompletionData(fd: AsyncFD(pipe), cb:
      proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            assert(bytesCount > 0 and bytesCount <= nbytes.int32)
            retFuture.complete(bytesCount)
          else:
            retFuture.fail(newException(OSError, osErrorMsg(errcode)))
    )
    let res = readFile(Handle(pipe), data, nbytes.int32, nil,
                       cast[POVERLAPPED](ol)).bool
    if not res:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        retFuture.fail(newException(OSError, osErrorMsg(err)))
    else:
      var bytesRead = 0.DWord
      let ores = getOverlappedResult(Handle(pipe), cast[POverlapped](ol),
                                     bytesRead, false.WINBOOL)
      if not ores.bool:
        retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
      else:
        assert(bytesRead > 0 and bytesRead <= nbytes)
        retFuture.complete(bytesRead)
    return retFuture
else:
  import posix

  proc setNonBlocking(fd: cint) {.inline.} =
    var x = fcntl(fd, F_GETFL, 0)
    if x == -1:
      raiseOSError(osLastError())
    else:
      var mode = x or O_NONBLOCK
      if fcntl(fd, F_SETFL, mode) == -1:
        raiseOSError(osLastError())

  proc wrap*(fd: cint): AsyncPipe =
    setNonBlocking(fd)
    register(AsyncFD(fd))
    result = AsyncPipe(fd)

  proc unwrap*(pipe: AsyncPipe) =
    unregister(AsyncFD(pipe))

  proc asyncPipes*(register = true): tuple[readPipe, writePipe: AsyncPipe] =
    var fds: array[2, cint]

    if posix.pipe(fds) == -1:
      raiseOSError(osLastError())
    setNonBlocking(fds[0])
    setNonBlocking(fds[1])

    result = (readPipe: AsyncPipe(fds[0]), writePipe: AsyncPipe(fds[1]))

    if register:
      register(AsyncFD(fds[0]))
      register(AsyncFD(fds[1]))

  proc close*(pipe: AsyncPipe, unregister = true) =
    if unregister:
      unregister(AsyncFD(pipe))

    if posix.close(cint(pipe)) != 0:
      raiseOSError(osLastError())

  proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[void] =
    var retFuture = newFuture[void]("asyncpipes.write")
    var written = 0

    proc cb(fd: AsyncFD): bool =
      result = true
      let reminder = nbytes - written
      let pdata = cast[pointer](cast[uint](data) + written.uint)
      let res = posix.write(cint(pipe), pdata, cint(reminder))
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

    if not cb(AsyncFD(pipe)):
      addWrite(AsyncFD(pipe), cb)
    return retFuture

  proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
    var retFuture = newFuture[int]("asyncpipes.readInto")
    proc cb(fd: AsyncFD): bool =
      result = true
      let res = posix.read(cint(pipe), data, cint(nbytes))
      if res < 0:
        let err = osLastError()
        if err.int32 != EAGAIN:
          retFuture.fail(newException(OSError, osErrorMsg(err)))
        else:
          result = false # We still want this callback to be called.
      elif res == 0:
        retFuture.complete(0)
      else:
        retFuture.complete(res)

    if not cb(AsyncFD(pipe)):
      addRead(AsyncFD(pipe), cb)
    return retFuture

when isMainModule:
  var inBuffer = newString(64)
  var outBuffer = "TEST STRING BUFFER"
  var o = asyncPipes()
  waitFor write(o.writePipe, cast[pointer](addr outBuffer[0]),
                outBuffer.len)
  var c = waitFor readInto(o.readPipe, cast[pointer](addr inBuffer[0]),
                           inBuffer.len)
  inBuffer.setLen(c)
  doAssert(inBuffer == outBuffer)
