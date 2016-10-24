# asynctools
Various asynchronous modules for Nim language.

### asyncpipe.nim
Asynchronous pipes, using non-blocking pipe(2) on Linux/BSD/MacOS/Solaris and named pipes on Windows.

### asyncipc.nim
Asynchronous inter-process communication, using non-blocking mkfifo(3) on Linux/BSD/MacOS and named memory maps on Windows.

### asyncproc.nim
Asynchronous process manipulation facility with asynchronous pipes as standart input/output/error handles.

### asyncdns.nim
Asynchronous DNS resolver, using default libresolv/libbind on Linux/BSD/MacOS/Solaris, and dnsapi.dll on Windows.

### asyncpty.nim
Asynchronous PTY communication.
