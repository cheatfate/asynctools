#
#
#       Asynchronous tools for Nim Language
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This module implements cross-platform asynchronous pipes communication.
##
## Module uses named pipes for Windows, and anonymous pipes for
## Linux/BSD/MacOS.
##
## .. code-block:: nim
##   var inBuffer = newString(64)
##   var outBuffer = "TEST STRING BUFFER"
##
##   # Create new pipe
##   var o = createPipe()
##
##   # Write string to pipe
##   waitFor write(o, cast[pointer](addr outBuffer[0]), outBuffer.len)
##
##   # Read data from pipe
##   var c = waitFor readInto(o, cast[pointer](addr inBuffer[0]), inBuffer.len)
##
##   inBuffer.setLen(c)
##   doAssert(inBuffer == outBuffer)
##
##   # Close pipe
##   close(o)

import asyncdispatch, os, strutils

when defined(windows):
  import winlean
else:
  import posix

when defined(nimdoc):
  type
    AsyncPipe* = ref object ## Object represents ``AsyncPipe``.

  proc createPipe*(inSize = 65536'i32, outSize = 65536'i32,
                   register = true): tuple[readPipe, writePipe: AsyncPipe] =
    ## Create descriptor pair for interprocess communication.
    ##
    ## Returns ``tuple`` with read side of pipe as ``readPipe`` member
    ## and write side of pipe as ``writePipe`` member.
    ##
    ## If ``register`` is `false`, both pipes will not be registered with
    ## current dispatcher.

  proc closeRead*(pipe: AsyncPipe, unregister = true) =
    ## Closes read side of pipe ``pipe``.
    ##
    ## If ``unregister`` is `false`, pipe will not be unregistered from
    ## current dispatcher.

  proc closeWrite*(pipe: AsyncPipe, unregister = true) =
    ## Closes write side of pipe ``pipe``.
    ##
    ## If ``unregister`` is `false`, pipe will not be unregistered from
    ## current dispatcher.

  proc getReadHandle*(pipe: AsyncPipe): int =
    ## Returns OS specific handle for read side of pipe ``pipe``.

  proc getWriteHandle*(pipe: AsyncPipe): int =
    ## Returns OS specific handle for write side of pipe ``pipe``.

  proc getHandles*(pipe: AsyncPipe): array[2, Handle] =
    ## Returns OS specific handles of ``pipe``.

  proc getHandles*(pipe: AsyncPipe): array[2, cint] =
    ## Returns OS specific handles of ``pipe``.

  proc close*(pipe: AsyncPipe, unregister = true) =
    ## Closes both ends of pipe ``pipe``.
    ##
    ## If ``unregister`` is `false`, pipe will not be unregistered from
    ## current dispatcher.

  proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[void] =
    ## This procedure writes an untyped ``data`` of ``size`` size to the
    ## pipe ``pipe``.
    ##
    ## The returned future will complete once ``all`` data has been sent.

  proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
    ## This procedure reads up to ``size`` bytes from pipe ``pipe``
    ## into ``data``, which must at least be of that size.
    ##
    ## Returned future will complete once all the data requested is read or
    ## part of the data has been read.

  proc wrap*(readHandle: Handle|cint, writeHandle: Handle|cint): AsyncPipe =
    ## Wraps existing OS specific pipe handles to ``AsyncPipe`` and register
    ## it with current dispatcher. ``readHandle`` - read side of pipe, can
    ## be ``0``. ``writeHandle`` - write side of pipe, can be ``0``.
    ##
    ## Returns ``AsyncPipe`` object.
    ##
    ## Windows handles must be named pipes created with ``CreateNamedPipe`` and
    ## ``FILE_FLAG_OVERLAPPED`` in flags. You can use ``ReopenFile()`` function
    ## to convert existing handle to overlapped variant.
    ##
    ## Posix handle will be modified with ``O_NONBLOCK``.

  proc unwrap*(pipe: AsyncPipe) =
    ## Unregisters ``pipe`` handle from current async dispatcher.

else:
  type
    AsyncPipe* = ref object of RootRef
      when defined(windows):
        readPipe: Handle
        writePipe: Handle
      else:
        readPipe: cint
        writePipe: cint

  when defined(windows):

    proc QueryPerformanceCounter(res: var int64)
         {.importc: "QueryPerformanceCounter", stdcall, dynlib: "kernel32".}
    proc connectNamedPipe(hNamedPipe: Handle, lpOverlapped: pointer): WINBOOL
         {.importc: "ConnectNamedPipe", stdcall, dynlib: "kernel32".}

    const
      pipeHeaderName = r"\\.\pipe\asyncpipe_"

    const
      FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000'i32
      PIPE_WAIT = 0x00000000'i32
      #PIPE_NOWAIT = 0x00000001'i32
      #PIPE_TYPE_BYTE = 0x00000000'i32
      #PIPE_READMODE_BYTE = 0x00000000'i32
      PIPE_TYPE_MESSAGE = 0x00000004'i32
      PIPE_READMODE_MESSAGE = 0x00000002'i32
      ERROR_PIPE_CONNECTED = 535
      ERROR_PIPE_BUSY = 231

    proc `$`*(pipe: AsyncPipe): string =
      result = "AsyncPipe [read = 0x" & toHex(cast[int](pipe.readPipe)) &
               ", write = 0x" & toHex(cast[int](pipe.writePipe)) & "]"

    proc createPipe*(inSize = 65536'i32, outSize = 65536'i32,
                     register = true): AsyncPipe =

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
        var pipeMode = PIPE_TYPE_MESSAGE or PIPE_READMODE_MESSAGE or PIPE_WAIT
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

      result = AsyncPipe(readPipe: pipeIn, writePipe: pipeOut)

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

    proc wrap*(readHandle: Handle, writeHandle: Handle): AsyncPipe =
      result = AsyncPipe(readPipe: readHandle, writePipe: writeHandle)
      if result.readPipe != 0:
        register(AsyncFD(result.readPipe))
      if result.writePipe != 0:
        register(AsyncFD(result.writePipe))

    proc unwrap*(pipe: AsyncPipe) =
      if pipe.readPipe != 0:
        unregister(AsyncFD(pipe.readPipe))
      if pipe.writePipe != 0:
        unregister(AsyncFD(pipe.writePipe))

    proc getReadHandle*(pipe: AsyncPipe): Handle {.inline.} =
      result = pipe.readPipe

    proc getWriteHandle*(pipe: AsyncPipe): Handle {.inline.} =
      result = pipe.writePipe

    proc getHandles*(pipe: AsyncPipe): array[2, Handle] {.inline.} =
      result = [pipe.readPipe, pipe.writePipe]

    proc closeRead*(pipe: AsyncPipe, unregister = true) =
      if pipe.readPipe != 0:
        if unregister:
          unregister(AsyncFD(pipe.readPipe))
        if closeHandle(pipe.readPipe) == 0:
          raiseOsError(osLastError())
        pipe.readPipe = 0

    proc closeWrite*(pipe: AsyncPipe, unregister = true) =
      if pipe.writePipe != 0:
        if unregister:
          unregister(AsyncFD(pipe.writePipe))
        if closeHandle(pipe.writePipe) == 0:
          raiseOsError(osLastError())
        pipe.writePipe = 0

    proc close*(pipe: AsyncPipe, unregister = true) =
      closeRead(pipe, unregister)
      closeWrite(pipe, unregister)

    proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[void] =
      var retFuture = newFuture[void]("asyncpipe.write")
      var ol = PCustomOverlapped()

      if pipe.writePipe == 0:
        retFuture.fail(newException(ValueError,
                                  "Write side of pipe closed or not available"))
      else:
        GC_ref(ol)
        ol.data = CompletionData(fd: AsyncFD(pipe.writePipe), cb:
          proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
            if not retFuture.finished:
              if errcode == OSErrorCode(-1):
                assert bytesCount == nbytes.int32
                retFuture.complete()
              else:
                retFuture.fail(newException(OSError, osErrorMsg(errcode)))
        )
        let res = writeFile(pipe.writePipe, data, nbytes.int32, nil,
                            cast[POVERLAPPED](ol)).bool
        if not res:
          let err = osLastError()
          if err.int32 != ERROR_IO_PENDING:
            GC_unref(ol)
            retFuture.fail(newException(OSError, osErrorMsg(err)))
        else:
          var bytesWritten = 0.Dword
          if getOverlappedResult(pipe.writePipe, cast[POVERLAPPED](ol),
                                 bytesWritten, Winbool(false)) == 0:
            retFuture.fail(newException(OSError, osErrorMsg(osLastError())))
          else:
            assert bytesWritten == nbytes
            retFuture.complete()
      return retFuture

    proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
      var retFuture = newFuture[int]("asyncpipe.readInto")
      var ol = PCustomOverlapped()

      if pipe.readPipe == 0:
        retFuture.fail(newException(ValueError,
                                   "Read side of pipe closed or not available"))
      else:
        GC_ref(ol)
        ol.data = CompletionData(fd: AsyncFD(pipe.readPipe), cb:
          proc (fd: AsyncFD, bytesCount: DWord, errcode: OSErrorCode) =
            if not retFuture.finished:
              if errcode == OSErrorCode(-1):
                assert(bytesCount > 0 and bytesCount <= nbytes.int32)
                retFuture.complete(bytesCount)
              else:
                retFuture.fail(newException(OSError, osErrorMsg(errcode)))
        )
        let res = readFile(pipe.readPipe, data, nbytes.int32, nil,
                           cast[POVERLAPPED](ol)).bool
        if not res:
          let err = osLastError()
          echo "err = " & $err
          if err.int32 != ERROR_IO_PENDING:
            GC_unref(ol)
            retFuture.fail(newException(OSError, osErrorMsg(err)))
        else:
          var bytesRead = 0.DWord
          let ores = getOverlappedResult(pipe.readPipe,
                                         cast[POverlapped](ol), bytesRead,
                                         false.WINBOOL)
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

    proc `$`*(pipe: AsyncPipe): string =
      result = "AsyncPipe [read = 0x" & toHex(cast[cint](pipe.readPipe)) &
                ", write = 0x" & toHex(cast[cint](pipe.writePipe)) & "]"

    proc createPipe*(register = true): AsyncPipe =
      var fds: array[2, cint]

      if posix.pipe(fds) == -1:
        raiseOSError(osLastError())
      setNonBlocking(fds[0])
      setNonBlocking(fds[1])

      result = AsyncPipe(readPipe: fds[0], writePipe: fds[1])

      if register:
        register(AsyncFD(fds[0]))
        register(AsyncFD(fds[1]))

    proc wrap*(readHandle: cint, writeHandle: cint): AsyncPipe =
      result = AsyncPipe(readPipe: readHandle, writePipe: writeHandle)
      if result.readPipe != 0:
        setNonBlocking(result.readPipe)
        register(AsyncFD(result.readPipe))
      if result.writePipe != 0:
        setNonBlocking(result.writePipe)
        register(AsyncFD(result.writePipe))

    proc unwrap*(pipe: AsyncPipe) =
      if pipe.readPipe != 0:
        unregister(AsyncFD(pipe.readPipe))
      if pipe.writePipe != 0:
        unregister(AsyncFD(pipe.writePipe))

    proc getReadHandle*(pipe: AsyncPipe): cint {.inline.} =
      result = pipe.readPipe

    proc getWriteHandle*(pipe: AsyncPipe): cint {.inline.} =
      result = pipe.writePipe

    proc getHandles*(pipe: AsyncPipe): array[2, cint] {.inline.} =
      result = [pipe.readPipe, pipe.writePipe]

    proc closeRead*(pipe: AsyncPipe, unregister = true) =
      if pipe.readPipe != 0:
        if unregister:
          unregister(AsyncFD(pipe.readPipe))
        if posix.close(cint(pipe.readPipe)) != 0:
          raiseOSError(osLastError())

    proc closeWrite*(pipe: AsyncPipe, unregister = true) =
      if pipe.writePipe != 0:
        if unregister:
          unregister(AsyncFD(pipe.writePipe))
        if posix.close(cint(pipe.writePipe)) != 0:
          raiseOSError(osLastError())

    proc close*(pipe: AsyncPipe, unregister = true) =
      closeRead(pipe, unregister)
      closeWrite(pipe, unregister)

    proc write*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[void] =
      var retFuture = newFuture[void]("asyncpipe.write")
      var written = 0

      proc cb(fd: AsyncFD): bool =
        result = true
        let reminder = nbytes - written
        let pdata = cast[pointer](cast[uint](data) + written.uint)
        let res = posix.write(pipe.writePipe, pdata, cint(reminder))
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

      if not cb(AsyncFD(pipe.writePipe)):
        addWrite(AsyncFD(pipe.writePipe), cb)
      return retFuture

    proc readInto*(pipe: AsyncPipe, data: pointer, nbytes: int): Future[int] =
      var retFuture = newFuture[int]("asyncpipe.readInto")
      proc cb(fd: AsyncFD): bool =
        result = true
        let res = posix.read(pipe.readPipe, data, cint(nbytes))
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

      if not cb(AsyncFD(pipe.readPipe)):
        addRead(AsyncFD(pipe.readPipe), cb)
      return retFuture

when isMainModule:
  var inBuffer = newString(64)
  var outBuffer = "TEST STRING BUFFER"
  var o = createPipe()
  waitFor write(o, cast[pointer](addr outBuffer[0]),
                outBuffer.len)
  var c = waitFor readInto(o, cast[pointer](addr inBuffer[0]),
                           inBuffer.len)
  inBuffer.setLen(c)
  doAssert(inBuffer == outBuffer)
  close(o)
