# Nova

An asynchronous event loop written in [C3](https://c3-lang.org).
Proactor-style (submit an operation, get a completion callback),
zero-allocation on the hot path, with all operation storage owned by the caller.

## Overview

`nova` gives you one event loop that drives timers, sockets, pipes, child
processes, signals, filesystem work and DNS through a single completion model:

- You submit an operation against caller-owned storage.
- The loop runs it on the platform backend (`epoll` or `io_uring` on Linux,
  `kqueue` on macOS).
- When it finishes, your callback runs on the loop's owner thread.

There is **no per-operation allocation**: every operation embeds an intrusive
runtime header and is stored wherever you put it. The loop only allocates during
`init`.

## Feature highlights

- **TCP** — listen / accept / connect / read / write / shutdown, socket options.
- **UDP** — bind / connect / send / recv, multicast join/leave, source filters.
- **Pipes** — anonymous pipe pairs, adopt existing descriptors.
- **Timers** — one-shot and finite-repeat, intrusive unbounded binary heap.
- **Signals** — async-signal-safe delivery dispatched on the owner thread.
- **Processes** — spawn with stdio pipes, env/cwd control, kill, reaping.
- **Filesystem** — open/read/write/stat/…/copyfile/sendfile on a worker pool.
- **fs-poll** — watch a path for change by stat polling.
- **fd watch** — readiness watching (readable/writable/hangup/error).
- **DNS** — forward and reverse resolution on the worker pool.
- **Work pool** — offload blocking or CPU-heavy work, complete on the loop.

## Buffering layers (optional)

Two connection helpers sit over `tcp::Stream`, both zero-allocation after init:

- **`nova::buffered` — `StreamConn` (ring buffer).** For byte-stream / line
  protocols: bytes flow through a fixed ring, framed with `find_byte`, with
  coalesced vectored writes and read/write watermarks.
- **`nova::framed` — `FramedConn` (linear buffer + compaction).** For message /
  frame protocols: contiguous `peek`/`reserve` for in-place zero-copy response
  building, plus `read_into` to stream a large body straight into caller storage
  without buffering it.

## Example

A repeating timer (`Duration` is microseconds; `repeat = 2` means 1 initial fire
plus 2 repeats):

```c3
import std::io;
import nova @norecurse, nova::timer;

fn void on_tick(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop; (void)op; (void)userdata;
	if (result.error.status) return;
	(void)io::printfn("tick (%d expirations)", result.expirations);
}

fn void main()
{
	Loop loop;
	timer::TimerOp op;

	loop.init()!!;
	defer loop.destroy();

	op.init();
	defer op.destroy();

	timer::start(&loop, &op, { .interval = (Duration)100_000, .repeat = 2 }, &on_tick, null)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
}
```

Prints `tick (1 expirations)` three times, then exits when the loop drains.

See [`examples/`](examples/) for TCP/UDP echo servers, an HTTP server, a worker
pool, `cat`, a file watcher, process spawning and pipes.

## Design

- **Proactor, not reactor.** You submit a complete operation and receive a
  completion; you do not get raw readiness events to handle yourself.
- **Caller-owned storage.** Operation handles (`TimerOp`, `tcp::ReadOp`, …) live
  wherever you allocate them — stack, struct field, pool. The library never
  takes ownership and never allocates per operation.
- **Zero-allocation hot path.** Allocation happens only in `*.init`. Submit,
  dispatch and callback paths allocate nothing (enforced by tracking-allocator
  tests).
- **Single owner thread.** The loop runs on one thread; cross-thread work is
  posted in and dispatched back on the owner. Calls from another thread are
  rejected with `nova::NOT_OWNER`.
- **Contracts.** Caller obligations are `@require`/`@ensure` contracts;
  recoverable failures are `fault` values via `T?`; release-critical invariants
  use `always_assert`.

## Install

`nova` is a C3 library bundle (`nova.c3l/`). Put it on a dependency search path
and depend on the `nova` library:

```json5
{
  "dependency-search-paths": [ "lib" ],
  "dependencies": [ "nova" ]
}
```

(place `nova.c3l/` under `lib/`), then in your code:

```c3
import nova;
import nova::timer; // and the submodules you use: net, net::tcp, net::udp, fs, ...
```

For a standalone file: `c3c compile-run main.c3 --libdir lib --lib nova`.

## Build & test

Requires the [`c3c`](https://github.com/c3lang/c3c) compiler.

```sh
c3c test                          # run the test suite (257 tests)
cd examples && c3c build all --trust=full   # build every example
```

## Examples

| Target | Shows |
|--------|-------|
| `timer` | periodic + one-shot timers |
| `tcp-echo` | TCP accept → read → echo |
| `ping-pong` | client request cancelled by a one-shot timer timeout (server sleeps) |
| `udp-echo` | UDP recv → echo to peer |
| `buffered-echo` | line echo over the ring `StreamConn` (`nova::buffered`) |
| `framed-echo` | length-prefixed message echo over `FramedConn` (`nova::framed`), incl. `read_into` for large bodies |
| `http` / `http-multithread` / `http-signal` | HTTP server variants |
| `work-pool` | offload compute + cancel a queued job |
| `fs-cat` | stream a file to stdout |
| `fs-watch` | detect file change via fs-poll |
| `watch` | readiness-watch a raw fd (`nova::watch`) with one-shot re-arm |
| `process` | spawn a child with stdio pipes |
| `pipe` | anonymous pipe read/write |
| `dns` | forward/reverse resolution |

## Acknowledgments

Design, API shape and test coverage were informed by studying three mature
event loops: [libuv](https://github.com/libuv/libuv),
[libxev](https://github.com/mitchellh/libxev) and
[libevent](https://github.com/libevent/libevent).

## License

See [LICENSE](LICENSE).
