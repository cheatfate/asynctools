#
#
#       Asynchronous tools for Nim Language
#        (c) Copyright 2016 Eugene Kabanov
#
#      See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#
import strutils, os, strtabs
import asyncdispatch, asyncpipe

when defined(windows):
  import winlean
else:
  import posix

when defined(linux):
  import linux

type
  ProcessOption* = enum  ## options that can be passed `startProcess`
    poEchoCmd,           ## echo the command before execution
    poUsePath,           ## Asks system to search for executable using PATH
                         ## environment variable.
                         ## On Windows, this is the default.
    poEvalCommand,       ## Pass `command` directly to the shell, without
                         ## quoting.
                         ## Use it only if `command` comes from trusted source.
    poStdErrToStdOut,    ## merge stdout and stderr to the stdout stream
    poParentStreams,     ## use the parent's streams
    poInteractive,       ## optimize the buffer handling for responsiveness for
                         ## UI applications. Currently this only affects
                         ## Windows: Named pipes are used so that you can peek
                         ## at the process' output streams.
    poDemon              ## Windows: The program creates no Window.

  ProcessObj = object of RootObj
    inHandleRead, inHandleWrite: AsyncPipe
    outHandleRead, outHandleWrite: AsyncPipe
    errHandleRead, errHandleWrite: AsyncPipe
    
    when defined(windows):
      fProcessHandle: Handle
      fThreadHandle: Handle
      procId: int32
      threadId: int32
      isWow64: bool
    else:
      procId: Pid
    exitCode: cint
    options: set[ProcessOption]

  Process* = ref ProcessObj ## represents an operating system process

proc quoteShellWindows*(s: string): string =
  ## Quote s, so it can be safely passed to Windows API.
  ## Based on Python's subprocess.list2cmdline
  ## See http://msdn.microsoft.com/en-us/library/17w5ykft.aspx
  let needQuote = {' ', '\t'} in s or s.len == 0

  result = ""
  var backslashBuff = ""
  if needQuote:
    result.add("\"")

  for c in s:
    if c == '\\':
      backslashBuff.add(c)
    elif c == '\"':
      result.add(backslashBuff)
      result.add(backslashBuff)
      backslashBuff.setLen(0)
      result.add("\\\"")
    else:
      if backslashBuff.len != 0:
        result.add(backslashBuff)
        backslashBuff.setLen(0)
      result.add(c)

  if needQuote:
    result.add("\"")

proc quoteShellPosix*(s: string): string =
  ## Quote ``s``, so it can be safely passed to POSIX shell.
  ## Based on Python's pipes.quote
  const safeUnixChars = {'%', '+', '-', '.', '/', '_', ':', '=', '@',
                         '0'..'9', 'A'..'Z', 'a'..'z'}
  if s.len == 0:
    return "''"

  let safe = s.allCharsInSet(safeUnixChars)

  if safe:
    return s
  else:
    return "'" & s.replace("'", "'\"'\"'") & "'"

proc quoteShell*(s: string): string =
  ## Quote ``s``, so it can be safely passed to shell.
  when defined(Windows):
    return quoteShellWindows(s)
  elif defined(posix):
    return quoteShellPosix(s)
  else:
    {.error:"quoteShell is not supported on your system".}

proc inputHandle*(p: Process): AsyncPipe =
  result = p.inHandleWrite

proc outputHandle*(p: Process): AsyncPipe =
  result = p.outHandleRead

proc errorHandle*(p: Process): AsyncPipe =
  result = p.errHandleRead

proc processID*(p: Process): int =
  return p.procId

when defined(windows):
  const zeroPipe = AsyncPipe(0)
  const STILL_ACTIVE = 0x00000103'i32

  proc isWow64Process(hProcess: Handle, wow64Process: var WinBool): WinBool
       {.importc: "IsWow64Process", stdcall, dynlib: "kernel32".}
  proc wow64SuspendThread(hThread: Handle): Dword
       {.importc: "Wow64SuspendThread", stdcall, dynlib: "kernel32".}

  proc buildCommandLine(a: string, args: openArray[string]): cstring =
    var res = quoteShell(a)
    for i in 0..high(args):
      res.add(' ')
      res.add(quoteShell(args[i]))
    result = cast[cstring](alloc0(res.len+1))
    copyMem(result, cstring(res), res.len)

  proc buildEnv(env: StringTableRef): tuple[str: cstring, len: int] =
    var L = 0
    for key, val in pairs(env): inc(L, key.len + val.len + 2)
    var str = cast[cstring](alloc0(L+2))
    L = 0
    for key, val in pairs(env):
      var x = key & "=" & val
      copyMem(addr(str[L]), cstring(x), x.len+1) # copy \0
      inc(L, x.len+1)
    (str, L)

  proc close*(p: Process) =
    if p.inHandleRead != zeroPipe:
      if closeHandle(Handle(p.inHandleRead)) == 0:
        raiseOsError(osLastError())
    if p.inHandleWrite != zeroPipe:
      if closeHandle(Handle(p.inHandleWrite)) == 0:
        raiseOsError(osLastError())
    if p.outHandleRead != zeroPipe:
      if closeHandle(Handle(p.outHandleRead)) == 0:
        raiseOsError(osLastError())
    if p.outHandleWrite != zeroPipe:
      if closeHandle(Handle(p.outHandleWrite)) == 0:
        raiseOsError(osLastError())
    if poStdErrToStdOut notin p.options:
      if p.errHandleRead != zeroPipe:
        if closeHandle(Handle(p.errHandleRead)) == 0:
          raiseOsError(osLastError())
      if p.errHandleWrite != zeroPipe:
        if closeHandle(Handle(p.errHandleWrite)) == 0:
          raiseOsError(osLastError())

  proc startProcess*(command: string, workingDir: string = "",
                     args: openArray[string] = [],
                     env: StringTableRef = nil,
                     options: set[ProcessOption] = {poStdErrToStdOut},
                     pipeStdin = Handle(-1),
                     pipeStdout = Handle(-1),
                     pipeStderr = Handle(-1)): Process =
    var
      si: STARTUPINFO
      procInfo: PROCESS_INFORMATION

    result = Process(options: options)
    si.cb = sizeof(STARTUPINFO).cint

    if pipeStdin != INVALID_HANDLE_VALUE:
      si.hStdInput = pipeStdin
    else:
      if poParentStreams in options:
        si.hStdInput = getStdHandle(STD_INPUT_HANDLE)
      else:
        let pipes = createPipe()
        if poInteractive in options:
          result.inHandleRead = pipes.readPipe
          result.inHandleWrite = pipes.writePipe
          si.hStdInput = Handle(pipes.readPipe)
        else:
          result.inHandleRead = pipes.readPipe
          result.inHandleWrite = pipes.writePipe
          si.hStdInput = Handle(pipes.readPipe)

    if pipeStdout != INVALID_HANDLE_VALUE:
      si.hStdOutput = pipeStdout
    else:
      if poParentStreams in options:
        si.hStdInput = getStdHandle(STD_OUTPUT_HANDLE)
      else:
        let pipes = createPipe()
        if poInteractive in options:
          result.outHandleRead = pipes.readPipe
          result.outHandleWrite = pipes.writePipe
          si.hStdOutput = Handle(pipes.writePipe)
        else:
          result.outHandleRead = pipes.readPipe
          result.outHandleWrite = pipes.writePipe
          si.hStdOutput = Handle(pipes.writePipe)

    if pipeStderr != INVALID_HANDLE_VALUE:
      si.hStdError = pipeStderr
    else:
      if poParentStreams in options:
        si.hStdError = getStdHandle(STD_ERROR_HANDLE)
      else:
        if poInteractive in options:
          let pipes = createPipe()
          result.errHandleRead = pipes.readPipe
          result.errHandleWrite = pipes.writePipe
          si.hStdError = Handle(pipes.writePipe)
        else:
          if poStdErrToStdOut in options:
            result.errHandleRead = result.outHandleRead
            result.errHandleWrite = result.outHandleWrite
            si.hStdError = si.hStdOutput
          else:
            let pipes = createPipe()
            result.errHandleRead = pipes.readPipe
            result.errHandleWrite = pipes.writePipe
            si.hStdError = Handle(pipes.writePipe)

    if si.hStdInput != 0 or si.hStdOutput != 0 or si.hStdError != 0:
      si.dwFlags = STARTF_USESTDHANDLES

    # building command line
    var cmdl: cstring
    if poEvalCommand in options:
      cmdl = command
      assert args.len == 0
    else:
      cmdl = buildCommandLine(command, args)
    # building environment
    var e = (str: nil.cstring, len: -1)
    if env != nil: e = buildEnv(env)
    # building working directory
    var wd: cstring = nil
    if len(workingDir) > 0: wd = workingDir
    # processing echo command line
    if poEchoCmd in options: echo($cmdl)
    # building security attributes for process and mainthread
    var psa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                  lpSecurityDescriptor: nil, bInheritHandle: 1)
    var tsa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).cint,
                                  lpSecurityDescriptor: nil, bInheritHandle: 1)

    var tmp = newWideCString(cmdl)
    var ee =
      if e.str.isNil: nil
      else: newWideCString(e.str, e.len)
    var wwd = newWideCString(wd)
    var flags = NORMAL_PRIORITY_CLASS or CREATE_UNICODE_ENVIRONMENT
    if poDemon in options: flags = flags or CREATE_NO_WINDOW
    let res = winlean.createProcessW(nil, tmp, addr psa, addr tsa, 1, flags,
                                     ee, wwd, si, procInfo)
    if e.str != nil: dealloc(e.str)
    if res == 0:
      close(result)
      raiseOsError(osLastError())
    else:
      result.fProcessHandle = procInfo.hProcess
      result.procId = procInfo.dwProcessId
      result.fThreadHandle = procInfo.hThread
      result.threadId = procInfo.dwThreadId
      when sizeof(int) == 8:
        # If sizeof(int) == 8, then our process is 64bit, and we need to check
        # architecture of just spawned process.
        var iswow64 = WinBool(0)
        if isWow64Process(procInfo.hProcess, iswow64) == 0:
          raiseOsError(osLastError())
        result.isWow64 = (iswow64 != 0)
      else:
        result.isWow64 = false

  proc suspend*(p: Process) =
    var res = 0'i32
    if p.isWow64:
      res = wow64SuspendThread(p.fThreadHandle)
    else:
      res = suspendThread(p.fThreadHandle)
    if res < 0:
      raiseOsError(osLastError())

  proc resume*(p: Process) =
    let res = resumeThread(p.fThreadHandle)
    if res < 0:
      raiseOsError(osLastError())

  proc running*(p: Process): bool =
    var value = 0'i32
    let res = getExitCodeProcess(p.fProcessHandle, value)
    if res == 0:
      raiseOsError(osLastError())
    else:
      if value == STILL_ACTIVE:
        result = true

  proc terminate*(p: Process) =
    if running(p):
      discard terminateProcess(p.fProcessHandle, 0)

  proc kill*(p: Process) =
    terminate(p)

  proc peekExitCode*(p: Process): int =
    var value = 0'i32
    let res = getExitCodeProcess(p.fProcessHandle, value)
    if res == 0:
      raiseOsError(osLastError())
    else:
      if value == STILL_ACTIVE:
        result = -1
      else:
        result = value

else:
  const
    readIdx = 0
    writeIdx = 1

  proc envToCStringArray(t: StringTableRef): cstringArray =
    result = cast[cstringArray](alloc0((t.len + 1) * sizeof(cstring)))
    var i = 0
    for key, val in pairs(t):
      var x = key & "=" & val
      result[i] = cast[cstring](alloc(x.len+1))
      copyMem(result[i], addr(x[0]), x.len+1)
      inc(i)

  proc envToCStringArray(): cstringArray =
    var counter = 0
    for key, val in envPairs(): inc counter
    result = cast[cstringArray](alloc0((counter + 1) * sizeof(cstring)))
    var i = 0
    for key, val in envPairs():
      var x = key.string & "=" & val.string
      result[i] = cast[cstring](alloc(x.len+1))
      copyMem(result[i], addr(x[0]), x.len+1)
      inc(i)

  type StartProcessData = object
    sysCommand: cstring
    sysArgs: cstringArray
    sysEnv: cstringArray
    workingDir: cstring
    pStdin, pStdout, pStderr, pErrorPipe: array[0..1, cint]
    optionPoUsePath: bool
    optionPoParentStreams: bool
    optionPoStdErrToStdOut: bool

  const useProcessAuxSpawn = declared(posix_spawn) and not defined(useFork) and
                             not defined(useClone) and not defined(linux)
  when useProcessAuxSpawn:
    proc startProcessAuxSpawn(data: StartProcessData): Pid {.
      tags: [ExecIOEffect, ReadEnvEffect], gcsafe.}
  else:
    proc startProcessAuxFork(data: StartProcessData): Pid {.
      tags: [ExecIOEffect, ReadEnvEffect], gcsafe.}
  
  {.push stacktrace: off, profiler: off.}
  proc startProcessAfterFork(data: ptr StartProcessData) {.
    tags: [ExecIOEffect, ReadEnvEffect], cdecl, gcsafe.}
  {.pop.}

  proc startProcess*(command: string, workingDir: string = "",
                     args: openArray[string] = [],
                     env: StringTableRef = nil,
                     options: set[ProcessOption] = {poStdErrToStdOut},
                     pipeStdin = cint(0),
                     pipeStdout = cint(0),
                     pipeStderr = cint(0)): Process =
    var
      pStdin, pStdout, pStderr: array[0..1, cint]

    if pipeStdin != 0:
      discard

  proc running(p: Process): bool = 
    result = true
    var status = cint(0)
    let res = posix.waitpid(p.procId, status, WNOHANG or WNOWAIT)
    if res == 0:
      result = true
    elif res < 0:
      raiseOsError(osLastError())
    else:
      if WIFEXITED(status) or WIFSIGNALED(status):
        result = false

  proc peekExitCode*(p: Process): int =
    result = -1
    var status = cint(0)
    let res = posix.waitpid(p.procId, status, WNOHANG)
    if res < 0:
      raiseOsError(osLastError())
    elif res > 0:
      result = (status and 0xFF00) shr 8

  proc suspend*(p: Process) =
    if kill(p.id, SIGSTOP) != 0'i32: raiseOsError(osLastError())

  proc resume*(p: Process) =
    if kill(p.id, SIGCONT) != 0'i32: raiseOsError(osLastError())

  proc terminate*(p: Process) =
    if kill(p.id, SIGTERM) != 0'i32:
      raiseOsError(osLastError())

  proc kill*(p: Process) =
    if kill(p.id, SIGKILL) != 0'i32:
      raiseOsError(osLastError())

when isMainModule:
  var data: array[1024, char]
  var p: Process
  when defined(windows):
    p = startProcess("cmd.exe", args = ["/c", "echo test"])
  else:
    discard

  echo repr(p)

  var t = waitFor(p.outputHandle.readInto(addr data[0], 1024))
  echo "t = " & $t
  echo $data
  if p.running():
    terminate(p)
    echo peekExitCode(p)
  else:
    echo peekExitCode(p)
  close(p)