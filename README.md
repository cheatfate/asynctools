# asynctools
Various asynchronous modules for Nim Language [http://www.nim-lang.org](http://nim-lang.org/).

## Main features

[**asyncpipe.nim**](asynctools/asyncpipe.nim)

Asynchronous pipes, using non-blocking pipe(3) on Linux/BSD/MacOS/Solaris and named pipes on Windows.

[**asyncipc.nim**](asynctools/asyncipc.nim)

Asynchronous inter-process communication, using non-blocking mkfifo(3) on Linux/BSD/MacOS/Solaris and named memory maps on Windows.

[**asyncproc.nim**](asynctools/asyncproc.nim)

Asynchronous process manipulation facility with asynchronous pipes as standart input/output/error handles, and asynchronous.

[**asyncdns.nim**](asynctools/asyncdns.nim)

Asynchronous DNS resolver, using default libresolv/libbind on Linux/BSD/MacOS/Solaris, and default dnsapi.dll on Windows.

[**asyncpty.nim**](asynctools/asyncpty.nim)

Asynchronous PTY communication, using pty mechanism of Linux/BSD/MacOS/Solaris, and named pipes on Windows.

## Installation

The most recent version of the modules can be installed directly from GitHub repository

```
$ nimble install https://github.com/cheatfate/asynctools.git
```

## Minimal requirements

- Nim language compiler 0.14.2

## Documentation

Every module have documentation inside, you can obtain it via

```
$ nim doc <modulename>
```
