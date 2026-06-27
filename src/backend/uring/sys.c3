module nova::backend::uring @if(env::LINUX);

import std::os::posix;
import libc;

<*
 io_uring syscall numbers.

 These three are identical on x86-64 and on the asm-generic table used by
 aarch64 (verified in `asm/unistd_64.h` and `asm-generic/unistd.h`), so a single
 definition serves both supported targets. Unlike `mmap`/`munmap`, whose numbers
 differ per architecture, these never go through libc, so they are issued with
 `@syscall` directly.
*>
const uint SYS_IO_URING_SETUP    = 425;
const uint SYS_IO_URING_ENTER    = 426;
const uint SYS_IO_URING_REGISTER = 427;

<*
 io_uring operation codes used by this backend. Values from
 `enum io_uring_op` in `linux/io_uring.h`.
*>
const char IORING_OP_POLL_ADD     = 6;
const char IORING_OP_POLL_REMOVE  = 7;
const char IORING_OP_SENDMSG      = 9;
const char IORING_OP_RECVMSG      = 10;
const char IORING_OP_ACCEPT       = 13;
const char IORING_OP_ASYNC_CANCEL = 14;
const char IORING_OP_CONNECT      = 16;
const char IORING_OP_SEND         = 26;
const char IORING_OP_RECV         = 27;

<*
 `send` message flag suppressing `SIGPIPE` when the peer has closed.
*>
const uint MSG_NOSIGNAL = 0x4000;

<*
 `accept4` flags applied by the kernel to a descriptor accepted via
 `IORING_OP_ACCEPT`, giving the same nonblocking close-on-exec stream the readiness
 `accept4` path produces.
*>
const uint SOCK_NONBLOCK = 0o4000;
const uint SOCK_CLOEXEC  = 0o2000000;

<*
 `POLL_ADD` modifier: keep the poll armed and emit one CQE per event
 (`IORING_CQE_F_MORE`) instead of firing once.
*>
const uint IORING_POLL_ADD_MULTI = 1;

<*
 `mmap` offsets selecting the submission ring, completion ring and SQE array.
*>
const ulong IORING_OFF_SQ_RING = 0x0;
const ulong IORING_OFF_CQ_RING = 0x8000000;
const ulong IORING_OFF_SQES    = 0x10000000;

<*
 `io_uring_enter` flags: wait for completions, and pass an extended argument
 carrying a wait timeout.
*>
const uint IORING_ENTER_GETEVENTS = 0x1;
const uint IORING_ENTER_EXT_ARG   = 0x8;

<*
 `io_uring_params.features` bits relied on by this backend: single mmap for both
 rings and timed `io_uring_enter` via EXT_ARG.
*>
const uint IORING_FEAT_SINGLE_MMAP = 0x1;
const uint IORING_FEAT_EXT_ARG     = 0x100;

<*
 `io_uring_register` opcode for capability probing, and the per-op supported bit
 returned in `io_uring_probe_op.flags`.
*>
const uint IORING_REGISTER_PROBE   = 8;
const ushort IO_URING_OP_SUPPORTED = 1;

<*
 Number of opcode slots reserved in `IoUringProbe.ops`. Comfortably above the
 current last opcode so the probe never truncates.
*>
const usz PROBE_OP_COUNT = 256;

<*
 Linux `MAP_POPULATE`: prefault the ring pages on mmap. Absent from the c3 posix
 mman bindings, so defined locally. Pure optimization; safe to drop.
*>
const CInt MAP_POPULATE = 0x8000;

<*
 eventfd flags for the loop wake source, matching the epoll backend.
*>
const int EFD_CLOEXEC  = 0o2000000;
const int EFD_NONBLOCK = 0o4000;

<*
 Poll event bits (`<poll.h>`) used to request and decode readiness. `POLLERR`,
 `POLLHUP` and `POLLRDHUP` are reported by the kernel regardless of the requested
 mask.
*>
const uint POLLIN    = 0x1;
const uint POLLOUT   = 0x4;
const uint POLLERR   = 0x8;
const uint POLLHUP   = 0x10;
const uint POLLRDHUP = 0x2000;

<*
 Completion flag set while a multishot source stays armed and will emit more CQEs.
*>
const uint IORING_CQE_F_MORE = 2;

<*
 `user_data` sentinels. The low bit tags a `Watcher` pointer; `WAKE` marks the
 wake-source poll; `0` marks an ignorable `POLL_REMOVE` completion. Operation
 pointers are pointer-aligned so their low bit is clear and they never collide.
*>
const ulong URING_WATCHER_TAG = 1;
const ulong URING_WAKE_DATA   = 2;

<*
 Submission queue entry. 64-byte ABI layout from `struct io_uring_sqe`; only the
 fields used by this backend are named, the rest are padding to keep the size and
 offsets exact (verified `IoUringSqe::size == 64`).
*>
struct IoUringSqe
{
	char opcode;
	char flags;
	ushort ioprio;
	int fd;
	ulong off;
	ulong addr;
	uint len;
	uint poll_events;
	ulong user_data;
	ushort buf_index;
	ushort personality;
	int splice_fd_in;
	ulong addr3;
	ulong pad2;
}

<*
 Completion queue entry. 16-byte ABI layout from `struct io_uring_cqe` without
 `CQE32` (verified `IoUringCqe::size == 16`).
*>
struct IoUringCqe
{
	ulong user_data;
	int res;
	uint flags;
}

<*
 Submission-ring index offsets returned by `io_uring_setup`.
*>
struct IoSqringOffsets
{
	uint head;
	uint tail;
	uint ring_mask;
	uint ring_entries;
	uint flags;
	uint dropped;
	uint array;
	uint resv1;
	ulong user_addr;
}

<*
 Completion-ring index offsets returned by `io_uring_setup`.
*>
struct IoCqringOffsets
{
	uint head;
	uint tail;
	uint ring_mask;
	uint ring_entries;
	uint overflow;
	uint cqes;
	uint flags;
	uint resv1;
	ulong user_addr;
}

<*
 `io_uring_setup` in/out parameters (verified `IoUringParams::size == 120`).
*>
struct IoUringParams
{
	uint sq_entries;
	uint cq_entries;
	uint flags;
	uint sq_thread_cpu;
	uint sq_thread_idle;
	uint features;
	uint wq_fd;
	uint[3] resv;
	IoSqringOffsets sq_off;
	IoCqringOffsets cq_off;
}

<*
 Extended `io_uring_enter` argument carrying the completion wait timeout in `ts`
 (a `timespec` pointer). Used with `IORING_ENTER_EXT_ARG`.
*>
struct IoUringGeteventsArg
{
	ulong sigmask;
	uint sigmask_sz;
	uint pad;
	ulong ts;
}

<*
 Kernel `timespec` pointed to by `IoUringGeteventsArg.ts` for the enter timeout.
*>
struct KernelTimespec
{
	long sec;
	long nsec;
}

<*
 One opcode entry in a probe result; `flags & IO_URING_OP_SUPPORTED` reports
 support.
*>
struct IoUringProbeOp
{
	char op;
	char resv;
	ushort flags;
	uint resv2;
}

<*
 Capability probe result. `ops` is over-sized to `PROBE_OP_COUNT` so the kernel
 fills it without truncation.
*>
struct IoUringProbe
{
	char last_op;
	char ops_len;
	ushort resv;
	uint[3] resv2;
	IoUringProbeOp[PROBE_OP_COUNT] ops;
}

<*
 Detected io_uring capabilities used to decide backend selection and timing.

 `available` is false when `io_uring_setup` itself failed (kernel without
 io_uring or blocked by seccomp/`io_uring_disabled`). The remaining flags are
 only meaningful when `available` is true.
*>
struct Caps
{
	bool available;
	bool poll_add;
	bool ext_arg;
	bool recv;
	bool send;
	bool accept;
	bool connect;
	bool recvmsg;
	bool sendmsg;
}

<*
 Whether io_uring is usable as a readiness backend: available, with `POLL_ADD`
 and the `EXT_ARG` enter-timeout the loop poll depends on.

 @param self : "Probed capabilities"
 @return "True when io_uring can back the loop"
*>
fn bool Caps.usable(&self) => self.available && self.poll_add && self.ext_arg;

<*
 Issue `io_uring_setup`.

 @param entries : "Requested submission queue depth"
 @param params : "In/out setup parameters"
 @return "Ring file descriptor, or a negative errno"
 @require params != null : "Params pointer must not be null"
*>
fn long sys_setup(uint entries, IoUringParams* params) @private
{
	return (long)@syscall((uptr)SYS_IO_URING_SETUP, (uptr)entries, (uptr)params);
}

<*
 Issue `io_uring_enter`.

 @param fd : "Ring file descriptor"
 @param to_submit : "Number of SQEs to submit"
 @param min_complete : "Minimum completions to wait for"
 @param flags : "Enter flags"
 @param arg : "Extended argument pointer, or null"
 @param argsz : "Extended argument size, or zero"
 @return "Number of SQEs consumed, or a negative errno"
*>
fn long sys_enter(int fd, uint to_submit, uint min_complete, uint flags, void* arg, usz argsz) @private
{
	return (long)@syscall(
		(uptr)SYS_IO_URING_ENTER,
		(uptr)fd,
		(uptr)to_submit,
		(uptr)min_complete,
		(uptr)flags,
		(uptr)arg,
		(uptr)argsz
	);
}

<*
 Issue `io_uring_register`.

 @param fd : "Ring file descriptor"
 @param opcode : "Register opcode"
 @param arg : "Opcode argument pointer"
 @param nr : "Opcode argument count"
 @return "Zero or a positive result, or a negative errno"
*>
fn long sys_register(int fd, uint opcode, void* arg, uint nr) @private
{
	return (long)@syscall((uptr)SYS_IO_URING_REGISTER, (uptr)fd, (uptr)opcode, (uptr)arg, (uptr)nr);
}

<*
 Map one io_uring shared region.

 Uses the libc `mmap` wrapper (not `@syscall`) because the `mmap` syscall number
 is architecture-specific.

 @param fd : "Ring file descriptor"
 @param length : "Region length in bytes"
 @param offset : "One of the `IORING_OFF_*` selectors"
 @return "Mapped address, or null on failure"
 @require length > 0 : "Mapped length must be positive"
*>
fn void* map_region(int fd, usz length, ulong offset)
{
	void* addr = posix::mmap(
		null,
		length,
		(CInt)(posix::PROT_READ | posix::PROT_WRITE),
		posix::MAP_SHARED | MAP_POPULATE,
		(CInt)fd,
		(libc::Off_t)offset
	);
	if (addr == posix::MAP_FAILED) return null;
	return addr;
}

<*
 Unmap a region returned by `map_region`. No-op on a null address.

 @param addr : "Mapped address, or null"
 @param length : "Region length passed to `map_region`"
*>
fn void unmap_region(void* addr, usz length)
{
	if (addr) (void)posix::munmap(addr, length);
}

<*
 Probe io_uring availability and the capabilities this backend depends on.

 Creates a throwaway ring, reads its feature flags, runs `IORING_REGISTER_PROBE`,
 then closes the ring. Allocation-free and side-effect-free beyond the transient
 fd. Intended for one call during loop initialization.

 @return "Detected capabilities; `available == false` when io_uring is unusable"
*>
fn Caps probe_capabilities()
{
	Caps caps;
	IoUringParams params;
	long fd = sys_setup(8, &params);
	if (fd < 0) return caps;
	defer (void)libc::close((int)fd);

	caps.available = true;
	caps.ext_arg = (params.features & IORING_FEAT_EXT_ARG) != 0;

	IoUringProbe probe;
	if (sys_register((int)fd, IORING_REGISTER_PROBE, &probe, (uint)PROBE_OP_COUNT) < 0) return caps;

	caps.poll_add = probe_supports(&probe, IORING_OP_POLL_ADD);
	caps.recv = probe_supports(&probe, IORING_OP_RECV);
	caps.send = probe_supports(&probe, IORING_OP_SEND);
	caps.accept = probe_supports(&probe, IORING_OP_ACCEPT);
	caps.connect = probe_supports(&probe, IORING_OP_CONNECT);
	caps.recvmsg = probe_supports(&probe, IORING_OP_RECVMSG);
	caps.sendmsg = probe_supports(&probe, IORING_OP_SENDMSG);
	return caps;
}

<*
 Report whether a probed opcode is supported by the kernel.

 @param probe : "Filled probe result"
 @param op : "Opcode to check"
 @return "True when the opcode is within range and flagged supported"
 @require probe != null : "Probe pointer must not be null"
*>
fn bool probe_supports(IoUringProbe* probe, char op) @private
{
	if (op > probe.last_op) return false;
	return (probe.ops[op].flags & IO_URING_OP_SUPPORTED) != 0;
}
