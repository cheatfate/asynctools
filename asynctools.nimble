# Package
version     = "0.1.1"
author      = "Eugene Kabanov"
description = "Various asynchronous tools for Nim"
license     = "MIT"

# Deps
requires "nim >= 0.19.4"

task test, "Runs the test suite":
  var testCommands = @[
    "asynctools/asyncsync",
    "asynctools/asyncpty",
    "asynctools/asyncproc",
    "asynctools/asyncpipe",
    "asynctools/asyncipc",
    "asynctools/asyncdns"
  ]

  for cmd in testCommands:
    exec "nim c -f -r " & cmd & ".nim"
    rmFile(cmd.toExe())

  when (NimMajor, NimMinor) >= (1, 5):
    for cmd in testCommands:
      exec "nim c -f --gc:orc -r " & cmd & ".nim"
      rmFile(cmd.toExe())
