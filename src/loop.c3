module nova @if(!(env::LINUX || env::DARWIN));

$error("nova: unsupported target OS; supported targets are Linux and macOS");

module nova;

import std::core::mem::alloc;
import std::thread;
import std::time::clock;
import libc;

import nova::op @public;
import nova::backend @public;
import nova::timer;
import nova::signal;
import nova::work;
import nova::process;

<*
 Internal dispatch trampoline used by typed operation modules.

 @param loop : "Loop dispatching the operation"
 @param op : "Header pointer passed as opaque storage"
*>
alias OperationCallback = fn void(Loop* loop, void* op);

<*
 Callback delivered on the loop owner thread for a posted operation.

 `PostOp` storage remains caller-owned and may be reused after the callback
 returns.
*>
alias PostCallback = fn void(Loop* loop, PostOp* op, void* userdata);

<*
 Normalized readiness flags stored in `Header.ready_flags`.
*>
const uint READY_READABLE = 1;
const uint READY_WRITABLE = 2;
const uint READY_ERROR    = 4;
const uint READY_HANGUP   = 8;

<*
 Default backend readiness capacity used by `Loop.init` when the caller does not
 pass options. A no-argument `loop.init()` is therefore usable for I/O out of the
 box; pass `{ .max_events = 0 }` explicitly for a wake/timer-only loop.
*>
const sz DEFAULT_MAX_EVENTS = 256;

<*
 Loop execution mode.

 `NO_WAIT` polls once without blocking, `ONCE` may block for ready work, and
 `UNTIL_STOPPED` runs until the loop is stopped or has no work.
*>
constdef RunMode : inline char
{
	NO_WAIT       = 0,
	ONCE          = 1,
	UNTIL_STOPPED = 2,
}

<*
 Socket shutdown direction.

 Values map to native send, receive or bidirectional shutdown requests.
*>
constdef ShutdownMode : inline char
{
	SEND = 0,
	RECV = 1,
	BOTH = 2,
}

<*
 Event backend engine selection requested through `Options.backend`.

 `AUTO` selects io_uring when the kernel supports it and otherwise falls back to
 the default readiness reactor without failing. `EPOLL` forces the default
 readiness reactor (epoll on Linux, kqueue on macOS). `IO_URING` forces io_uring
 and fails initialization with `UNSUPPORTED` when it is not available.
*>
constdef BackendKind : inline char
{
	AUTO     = 0,
	EPOLL    = 1,
	IO_URING = 2,
}

<*
 Public backend selection values for `Options.backend`.
*>
const BackendKind BACKEND_AUTO     = BackendKind.AUTO;
const BackendKind BACKEND_EPOLL    = BackendKind.EPOLL;
const BackendKind BACKEND_IO_URING = BackendKind.IO_URING;

<*
 Monotonic loop clock tick value in nanoseconds.
*>
typedef Clock = inline ulong;

<*
 Relative duration in microseconds.

 Negative values are rejected by timeout conversion helpers. A zero duration
 means immediate scheduling for APIs that accept timeouts.
*>
typedef Duration = inline long;

<*
 Portable native handle storage.

 Platform modules cast this to the OS descriptor or socket type at syscall
 boundaries.
*>
typedef NativeHandle = inline sz;

<*
 Fixed loop capacities and scheduling budgets.

 All storage controlled by these capacities is allocated during `Loop.init`.
 Submission, polling, cancellation and callback dispatch must not grow runtime
 storage after initialization succeeds.

 `max_events` limits simultaneous backend readiness registrations; zero still
 initializes the backend wake source but makes I/O submissions fail with
 `CAPACITY_EXCEEDED` (a wake/timer-only loop). A no-argument `Loop.init()`
 defaults `max_events` to `DEFAULT_MAX_EVENTS` so it is usable for I/O.
 Timers use an intrusive heap embedded in caller-owned
 operation storage, so the timer count is unbounded and never allocates.
 Negative capacities or budgets are invalid, as are capacities that overflow
 native backend limits.
 `dispatch_budget == 0` dispatches all ready callbacks in one tick.
 `io_progress_budget == 0` lets stream read/write dispatchers make progress until
 the socket would block or the operation completes.
 `blocking_pool` schedules worker-backed operations such as generic work, files
 and DNS. The loop borrows this pool; callers must keep it initialized until all
 worker-backed operations on the loop have completed.
 `enable_thread_submit` initializes the thread-safe submission queue used by
 worker threads to wake the owner loop and publish work. With it enabled,
 `UNTIL_STOPPED` waits for future cross-thread posts until the loop is stopped.
 `backend` selects the event backend engine; it defaults to `AUTO` so an
 unset `Options` keeps the platform default and `Loop.init()` stays usable.
*>
struct Options
{
	sz max_events;
	sz dispatch_budget;
	sz io_progress_budget;
	work::Pool* blocking_pool;
	bool enable_thread_submit;
	BackendKind backend;
}

<*
 Caller-owned event loop object.

 The runtime owns only resources initialized from this object. Header,
 handle, buffer and callback storage remain caller-owned.

 Thread-ready loops record the initializing thread as the owner. Cross-thread
 callers may request stop or post work, but scheduler, timer and backend state
 still run only on the owner thread.

 Backend fields are internal and may hold typed storage behind `void*` to keep
 platform-specific stdlib types out of the public root module.
*>
struct Loop
{
	Allocator allocator;
	Options options;
	Clock cached_now;
	NativeHandle backend_handle;
	NativeHandle wake_handle;
	NativeHandle wake_write_handle;
	void* backend_events;
	sz backend_event_capacity;
	sz backend_active_count;
	BackendKind backend_kind;
	void* backend_uring;
	timer::Node* timer_min;
	sz timer_count;
	Header* ready_head;
	Header* ready_tail;
	sz ready_count;
	Header* live_head;
	Header* live_tail;
	thread::Thread owner_thread;
	thread::Mutex post_mutex;
	PostOp* post_head;
	PostOp* post_tail;
	sz post_count;
	sz worker_active_count;
	signal::SignalOp* signal_head;
	signal::SignalOp* signal_tail;
	sz signal_count;
	process::Process* process_head;
	process::Process* process_tail;
	signal::SignalOp process_signal;
	sz process_count;
	sz process_backed_count;
	uint stop_requested;
	bool initialized;
	bool stopped;
	bool running;
	bool owner_thread_set;
	bool post_queue_initialized;
	bool process_signal_ready;
}

<*
 Caller-owned cross-thread post operation.

 The post queue only makes submission thread-safe. Posted callbacks always run
 on the loop owner thread and may use normal loop APIs.
*>
struct PostOp
{
	PostOp* next;
	PostCallback callback;
	void* userdata;
	uint in_queue;
}

<*
 Initialize caller-owned loop storage.

 @param [&inout] self : "Caller-owned loop storage"
 @param options : "Fixed loop capacities and run budgets"
 @param allocator : "Allocator used for timer heap and backend event storage; defaults to the heap allocator `mem`"
 @return "Initialized loop"
 @return ? INVALID_STATE : "Loop is already initialized or options are invalid"
 @return ? UNSUPPORTED : "Requested event backend is unavailable on this platform or kernel"
 @return ? mem::OUT_OF_MEMORY : "Backend event allocation failed"
 @return ? thread::INIT_FAILED : "Thread submission mutex initialization failed"
 @return ? BACKEND_FAILED : "Backend initialization failed"
 @ensure self.is_initialized() : "Loop is initialized when init succeeds"
*>
fn Loop*? Loop.init(&self, Options options = { .max_events = DEFAULT_MAX_EVENTS }, Allocator allocator = mem)
{
	if (self.initialized) return INVALID_STATE~;
	if (options.max_events < 0) return INVALID_STATE~;
	if (options.max_events > (sz)int::max - 1) return INVALID_STATE~;
	if (options.dispatch_budget < 0) return INVALID_STATE~;
	if (options.io_progress_budget < 0) return INVALID_STATE~;
	if (options.backend != BackendKind.AUTO && options.backend != BackendKind.EPOLL
		&& options.backend != BackendKind.IO_URING) return INVALID_STATE~;
	*self = { };
	self.allocator = allocator;
	self.options = options;
	self.cached_now = clock_now();
	self.backend_handle = (NativeHandle)-1;
	self.wake_handle = (NativeHandle)-1;
	self.wake_write_handle = (NativeHandle)-1;
	self.owner_thread = thread::current();
	self.owner_thread_set = true;
	if (options.enable_thread_submit || options.blocking_pool)
	{
		if (catch err = self.post_mutex.init())
		{
			*self = { };
			return err~;
		}
		self.post_queue_initialized = true;
	}
	if (catch err = backend::init(self))
	{
		if (self.post_queue_initialized) self.post_mutex.destroy();
		*self = { };
		return err~;
	}
	self.initialized = true;
	return self;
}

<*
 Destroy an initialized loop.

 @param [&inout] self : "Loop with no active operations or handles"
 @require self.initialized : "Loop must be initialized"
 @require !self.running : "Loop must not be running"
 @require self.timer_count == 0 : "Loop must have no active timers"
 @require self.backend_active_count == 0 : "Loop must have no active backend operations"
 @require self.ready_count == 0 : "Loop must have no queued callbacks"
 @require self.post_count == 0 : "Loop must have no queued thread submissions"
 @require self.worker_active_count == 0 : "Loop must have no active worker operations"
 @require self.signal_count == 0 : "Loop must have no active signal operations"
 @require self.process_count == 0 : "Loop must have no active process handles"
 @ensure !self.is_initialized() : "Loop is uninitialized after destroy"
*>
fn void Loop.destroy(&self)
{
	backend::destroy(self);
	if (self.post_queue_initialized) self.post_mutex.destroy();
	*self = { };
	self.backend_handle = (NativeHandle)-1;
	self.wake_handle = (NativeHandle)-1;
	self.wake_write_handle = (NativeHandle)-1;
}

<*
 Cancel or close every live operation so the loop can be drained and destroyed.

 Walks the live-operation registry issuing best-effort `op::cancel_op` on each
 (timers, signals, stream/udp/pipe/watch I/O, accepts and connects are cancelled;
 their callbacks fire with `CANCELLED` during the next `drain`/`run`; queued work
 is cancelled). Child processes are sent `SIGKILL` so they exit and are reaped.

 Work already executing on a worker thread cannot be cancelled and drains
 naturally. This does NOT close caller-owned socket/handle fds — the caller owns
 those (e.g. `tcp::stream_close_now` after the read/write op is cancelled).

 Typical graceful shutdown: `close_all()` → `drain()` → `destroy()`.

 @param [&inout] self : "Initialized loop owned by the current thread"
 @return ? nova::INVALID_STATE : "Loop is not initialized"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn void? Loop.close_all(&self)
{
	if (!self.initialized) return nova::INVALID_STATE~;
	if (!self.is_owner_thread()) return nova::NOT_OWNER~;

	Header* op = self.live_head;
	while (op != null)
	{
		Header* next = op.loop_next;
		(void)op::cancel_op(self, op);
		op = next;
	}

	process::Process* proc = self.process_head;
	while (proc != null)
	{
		process::Process* proc_next = proc.loop_next;
		(void)process::kill(proc, libc::SIGKILL);
		proc = proc_next;
	}
}

<*
 Report whether the loop still has real (non-thread-submit) work pending.
*>
fn bool drain_pending(Loop* loop) @local
{
	return loop.ready_count > 0 || loop.timer_count > 0 || loop.backend_active_count > 0
		|| loop.worker_active_count > 0
		|| loop.signal_count > 0
		|| loop.process_count > 0;
}

<*
 Run the loop until all real work drains, then return.

 Unlike `run(UNTIL_STOPPED)`, drain ignores the `enable_thread_submit` liveness
 term, so it terminates once ready/timer/backend/worker/signal/process work is
 gone — leaving the loop in a state that satisfies `destroy`. Intended right
 after `close_all()` (or after the caller closed its own handles).

 NOTE: if a completion callback re-arms new work (e.g. re-accepts a connection),
 drain may not terminate; such callers must stop re-arming during shutdown or use
 `force_destroy`.

 @param [&inout] self : "Initialized loop owned by the current thread"
 @return ? nova::INVALID_STATE : "Loop is not initialized or already running"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn void? Loop.drain(&self)
{
	if (!self.initialized) return nova::INVALID_STATE~;
	if (!self.is_owner_thread()) return nova::NOT_OWNER~;
	if (self.running) return nova::INVALID_STATE~;
	self.running = true;
	defer self.running = false;
	apply_thread_requests(self);
	while (drain_pending(self))
	{
		(void)tick(self, true);
	}
}

<*
 Destroy a loop without requiring it to be drained first.

 Closes the backend (dropping all kernel readiness registrations) and frees loop
 storage even with operations still outstanding. In-flight operation callbacks
 are NOT delivered, and caller-owned socket/handle fds are NOT closed (the caller
 owns those). Worker-backed operations must already be finished (the caller must
 `work::Pool.shutdown` the borrowed pool first). Use for abrupt shutdown / process
 exit; prefer `close_all` + `drain` + `destroy` for graceful teardown.

 @param [&inout] self : "Initialized loop"
 @require self.initialized : "Loop must be initialized"
 @require !self.running : "Loop must not be running"
 @ensure !self.is_initialized() : "Loop is uninitialized after force_destroy"
*>
fn void Loop.force_destroy(&self)
{
	backend::destroy(self);
	if (self.post_queue_initialized) self.post_mutex.destroy();
	*self = { };
	self.backend_handle = (NativeHandle)-1;
	self.wake_handle = (NativeHandle)-1;
	self.wake_write_handle = (NativeHandle)-1;
}

<*
 Report whether loop storage has been initialized.

 @param self : "Loop storage to inspect"
 @return "True after successful `Loop.init` and before `Loop.destroy`"
*>
fn bool Loop.is_initialized(&self) => self.initialized;

<*
 Return the resolved event backend engine.

 Reports the readiness backend chosen during `init`. `AUTO` is never returned:
 it is resolved to a concrete engine before init succeeds.

 @param self : "Initialized loop"
 @return "Resolved backend engine"
 @require self.initialized : "Loop must be initialized"
*>
fn BackendKind Loop.backend(&self) => self.backend_kind;

<*
 Report whether stream reads on this loop run in io_uring completion mode (the
 kernel performs the `recv` via `IORING_OP_RECV`). False on epoll/kqueue and on
 io_uring kernels that lack the `RECV` opcode (those use readiness).

 @param self : "Initialized loop"
 @return "True when stream reads are submitted as io_uring completions"
 @require self.initialized : "Loop must be initialized"
*>
fn bool Loop.stream_read_completion(&self) => backend::stream_completion_read_enabled(self);

<*
 Report whether stream writes on this loop run in io_uring completion mode (the
 kernel performs the `send` via `IORING_OP_SEND`). False on epoll/kqueue and on
 io_uring kernels that lack the `SEND` opcode (those use readiness).

 @param self : "Initialized loop"
 @return "True when stream writes are submitted as io_uring completions"
 @require self.initialized : "Loop must be initialized"
*>
fn bool Loop.stream_write_completion(&self) => backend::stream_completion_write_enabled(self);

<*
 Report whether TCP accepts on this loop run in io_uring completion mode (the
 kernel accepts via `IORING_OP_ACCEPT`). False on epoll/kqueue and on io_uring
 kernels that lack the `ACCEPT` opcode (those use the readiness accept driver).

 @param self : "Initialized loop"
 @return "True when TCP accepts are submitted as io_uring completions"
 @require self.initialized : "Loop must be initialized"
*>
fn bool Loop.tcp_accept_completion(&self) => backend::tcp_completion_accept_enabled(self);

<*
 Report whether TCP connects on this loop run in io_uring completion mode (the
 kernel connects via `IORING_OP_CONNECT`). False on epoll/kqueue and on io_uring
 kernels that lack the `CONNECT` opcode (those use the readiness `SO_ERROR` path).

 @param self : "Initialized loop"
 @return "True when TCP connects are submitted as io_uring completions"
 @require self.initialized : "Loop must be initialized"
*>
fn bool Loop.tcp_connect_completion(&self) => backend::tcp_completion_connect_enabled(self);

<*
 Report whether UDP receives on this loop run in io_uring completion mode (the
 kernel receives via `IORING_OP_RECVMSG`). False on epoll/kqueue and on io_uring
 kernels that lack the `RECVMSG` opcode (those use one-shot readiness + `recvmsg`).

 @param self : "Initialized loop"
 @return "True when UDP receives are submitted as io_uring completions"
 @require self.initialized : "Loop must be initialized"
*>
fn bool Loop.udp_recv_completion(&self) => backend::udp_completion_recv_enabled(self);

<*
 Report whether UDP sends on this loop run in io_uring completion mode (the kernel
 sends via `IORING_OP_SENDMSG`). False on epoll/kqueue and on io_uring kernels that
 lack the `SENDMSG` opcode (those send inline and fall back to readiness).

 @param self : "Initialized loop"
 @return "True when UDP sends are submitted as io_uring completions"
 @require self.initialized : "Loop must be initialized"
*>
fn bool Loop.udp_send_completion(&self) => backend::udp_completion_send_enabled(self);

<*
 Return the cached monotonic loop time.

 @param self : "Initialized loop"
 @return "Cached monotonic loop time"
 @require self.initialized : "Loop must be initialized"
*>
fn Clock Loop.now(&self) => self.cached_now;

<*
 Refresh and return the cached monotonic loop time.

 @param [&inout] self : "Initialized loop"
 @return "Updated cached monotonic loop time"
 @require self.initialized : "Loop must be initialized"
*>
fn Clock Loop.update_now(&self)
{
	self.cached_now = clock_now();
	return self.cached_now;
}

<*
 Report whether the loop storage is initialized and not stopped.

 This is a public lifecycle predicate. Run-loop liveness uses the private
 active-work predicate so empty initialized loops do not force `UNTIL_STOPPED`
 to block forever.

 @param self : "Loop storage to inspect"
 @return "True when the loop is initialized and not stopped"
*>
fn bool Loop.alive(&self) => self.initialized && !self.stopped;

<*
 Report whether the current thread owns the loop.

 The owner thread is captured by `Loop.init`. Posted callbacks run on this
 thread, so this predicate can be used inside callbacks to assert loop-local
 execution.

 @param self : "Loop storage to inspect"
 @return "True when loop storage is initialized and called from the owner thread"
*>
fn bool Loop.is_owner_thread(&self)
{
	if (!self.initialized || !self.owner_thread_set) return false;
	return self.owner_thread.equals(thread::current());
}

<*
 Request the loop to stop after the current run step.

 This sets a sticky lifecycle flag. Later `ONCE` and `UNTIL_STOPPED` runs
 return without blocking while the flag remains set, and `alive` reports false.

 @param [&inout] self : "Initialized loop"
 @require self.initialized : "Loop must be initialized"
*>
fn void Loop.stop(&self) => self.stopped = true;

<*
 Request the loop to stop from any thread.

 This is the thread-safe stop path. It records a sticky stop request and wakes a
 blocked `run`. The owner thread applies the request during the next tick so
 normal loop state remains owner-thread local.

 @param [&inout] self : "Initialized loop"
 @return ? INVALID_STATE : "Loop is not initialized"
 @return ? BACKEND_FAILED : "Backend wake failed"
*>
fn void? Loop.request_stop(&self)
{
	if (!self.initialized) return INVALID_STATE~;
	@atomic_store(self.stop_requested, (uint)1);
	backend::wake(self)!;
}

<*
 Wake a loop blocked in `run`.

 This delegates to the runtime poller wake source initialized by `Loop.init`.
 Wake notifications may coalesce and do not enqueue a callback or change the
 stopped flag.

 @param [&inout] self : "Initialized loop"
 @return ? INVALID_STATE : "Loop is not initialized"
 @return ? BACKEND_FAILED : "Backend wake failed"
*>
fn void? Loop.wake(&self)
{
	if (!self.initialized) return INVALID_STATE~;
	backend::wake(self)!;
}

<*
 Read the platform monotonic clock and convert it to `nova::Clock`.

 @return "Current monotonic clock value"
*>
fn nova::Clock clock_now() @local
{
	return (nova::Clock)clock::now();
}

<*
 Queue one operation for ready callback dispatch.

 The queue is intrusive through `Header.next_ready` and does not allocate.
 Most queued callbacks are terminal completions; repeating timers also use this
 queue for intermediate timer firings before they are rearmed.
 Operations already queued or currently calling are left unchanged so the same
 intrusive node cannot be linked into the ready queue twice.

 @param loop : "Loop that owns the ready queue"
 @param op : "Header to queue"
 @param status : "Status stored for callback dispatch"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void queue_ready(Loop* loop, Header* op, fault status) @private
{
	if (op.state == State.OP_READY || op.state == State.OP_CALLING) return;

	op.terminal_status = status;
	op.state = State.OP_READY;
	op.next_ready = null;
	Header* tail = loop.ready_tail;
	if (tail)
	{
		tail.next_ready = op;
	}
	else
	{
		loop.ready_head = op;
	}

	loop.ready_tail = op;
	loop.ready_count++;
}

<*
 Pop the oldest ready operation.

 @param loop : "Loop that owns the ready queue"
 @return "Oldest ready operation, or null"
 @require loop != null : "Loop pointer must not be null"
*>
fn Header* pop_ready(Loop* loop) @local
{
	Header* op = loop.ready_head;
	if (!op) return null;
	loop.ready_head = op.next_ready;
	if (!loop.ready_head) loop.ready_tail = null;
	op.next_ready = null;
	loop.ready_count--;
	return op;
}

<*
 Dispatch queued ready callbacks up to `Options.dispatch_budget`.

 @param loop : "Loop that owns the ready queue"
 @return "Number of ready operations dispatched"
 @require loop != null : "Loop pointer must not be null"
*>
fn sz dispatch_ready(Loop* loop) @local
{
	sz dispatched = 0;
	sz budget     = loop.options.dispatch_budget;
	while (loop.ready_head && (!budget || dispatched < budget))
	{
		Header* op                 = pop_ready(loop);
		OperationCallback callback = op.callback;
		op.state = State.OP_CALLING;
		if (!callback)
		{
			op.state = State.OP_FREE;
			dispatched++;
			continue;
		}
		callback(loop, (void*)op);
		dispatched++;
	}
	return dispatched;
}

<*
 Return the zero fault value used to represent success in result storage.

 @return "Zero fault value"
*>
fn fault ok_status() @private
{
	fault status;
	return status;
}

<*
 Helper layers use this for caller-owned housekeeping operations that need to
 run after the current callback returns and after the active core operation has
 reset its storage.

 @param loop : "Initialized loop"
 @param op : "Caller-owned operation header"
 @param kind : "Internal operation kind"
 @param callback : "Dispatch trampoline"
 @param owner : "Typed helper owner"
 @param userdata : "Opaque pointer captured by this operation"
 @param status : "Terminal status delivered through the ready queue"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BUSY : "Operation is already active"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? submit_immediate(
	Loop* loop,
	Header* op,
	Kind kind,
	OperationCallback callback,
	void* owner,
	void* userdata,
	fault status
) @private
{
	if (op.active()) return nova::BUSY~;

	op::init_header(op, kind, loop, callback, owner, userdata);
	queue_ready(loop, op, status);
	return op.to_ref();
}

<*
 Prepare one caller-owned TCP accept result operation without touching the
 backend.

 Listener readiness is driven by an internal listener operation. Each public
 accept operation remains independently cancellable and may own a timer heap
 slot, but it does not register the listener descriptor with the readiness
 backend.

 @param loop : "Initialized loop"
 @param op : "Caller-owned accept operation header"
 @param handle : "Native listener descriptor captured for diagnostics"
 @param callback : "Typed accept dispatch trampoline"
 @param owner : "Typed listener handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BUSY : "Operation is already active"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? submit_tcp_accept_prepare(
	Loop* loop,
	Header* op,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @private
{
	if (op.active()) return nova::BUSY~;

	op::init_header(op, Kind.TCP_ACCEPT, loop, callback, owner, userdata);
	return op.to_ref();
}

<*
 Queue an immediate TCP close completion.

 Close operations do not register with the readiness backend. The typed TCP
 layer has already detached backend state and attempted native close before it
 uses this helper to deliver the close result through the ready queue.

 @param loop : "Initialized loop"
 @param op : "Caller-owned close operation header"
 @param callback : "Typed close dispatch trampoline"
 @param owner : "Typed TCP handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @param status : "Close result status"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BUSY : "Operation is already active"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? submit_tcp_close(
	Loop* loop,
	Header* op,
	OperationCallback callback,
	void* owner,
	void* userdata,
	fault status
) @private
{
	if (op.active()) return nova::BUSY~;

	op::init_header(op, Kind.TCP_CLOSE, loop, callback, owner, userdata);
	queue_ready(loop, op, status);
	return op.to_ref();
}

<*
 Queue an immediate UDP close completion.

 UDP close operations do not register with the readiness backend. The typed UDP
 layer has already attempted native close before it uses this helper to deliver
 the close result through the ready queue.

 @param loop : "Initialized loop"
 @param op : "Caller-owned close operation header"
 @param callback : "Typed close dispatch trampoline"
 @param owner : "Typed UDP socket handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @param status : "Close result status"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BUSY : "Operation is already active"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? submit_udp_close(
	Loop* loop,
	Header* op,
	OperationCallback callback,
	void* owner,
	void* userdata,
	fault status
) @private
{
	if (op.active()) return nova::BUSY~;

	op::init_header(op, Kind.UDP_CLOSE, loop, callback, owner, userdata);
	queue_ready(loop, op, status);
	return op.to_ref();
}

<*
 Queue an immediate pipe endpoint close completion.

 Pipe close operations do not register with the readiness backend. The typed
 pipe layer has already detached backend state and attempted native close when
 the endpoint owns the handle before it uses this helper to deliver the close
 result through the ready queue.

 @param loop : "Initialized loop"
 @param op : "Caller-owned close operation header"
 @param callback : "Typed close dispatch trampoline"
 @param owner : "Typed pipe endpoint"
 @param userdata : "Opaque user pointer captured by this operation"
 @param status : "Close result status"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BUSY : "Operation is already active"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? submit_pipe_close(
	Loop* loop,
	Header* op,
	OperationCallback callback,
	void* owner,
	void* userdata,
	fault status
) @private
{
	if (op.active()) return nova::BUSY~;

	op::init_header(op, Kind.PIPE_CLOSE, loop, callback, owner, userdata);
	queue_ready(loop, op, status);
	return op.to_ref();
}

<*
 Initialize caller-owned post storage.

 @param [&inout] self : "Post operation storage"
 @return "Initialized post operation"
 @require !self.queued() : "Post operation must not be queued"
 @ensure !self.queued() : "Initialized post operation is not queued"
*>
fn PostOp* PostOp.init(&self)
{
	*self = { };
	return self;
}

<*
 Report whether this post operation is already queued.

 @param self : "Post operation storage"
 @return "True when the operation is linked in the thread-submit queue"
*>
fn bool PostOp.queued(&self) => @atomic_load(self.in_queue) != 0;

<*
 Queue a callback to run on the loop owner thread.

 This function may be called from any thread when `enable_thread_submit` was set
 during `Loop.init`. It does not make the callback or referenced userdata
 lifetime-safe; callers must keep storage alive until dispatch.
 This is the shared submission primitive intended for future worker-backed
 domains such as files and DNS.

 @param loop : "Initialized loop"
 @param op : "Caller-owned post storage"
 @param callback : "Callback to run on the owner thread"
 @param userdata : "Opaque user pointer delivered to callback"
 @return ? nova::INVALID_STATE : "Loop is not initialized, thread submit is disabled or callback is missing"
 @return ? nova::BUSY : "Post operation is already queued"
 @return ? nova::BACKEND_FAILED : "Backend wake failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Post operation pointer must not be null"
*>
fn void? post(Loop* loop, PostOp* op, PostCallback callback, void* userdata = null)
{
	if (!loop.initialized || !loop.options.enable_thread_submit
		|| !loop.post_queue_initialized) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	post_internal(loop, op, callback, userdata)!;
}

<*
 Queue a callback from runtime-owned worker infrastructure.

 Unlike the public `post`, this only requires the post queue to be initialized.
 It is used by internal worker completions when `Loop.Options.blocking_pool` was
 supplied without exposing public cross-thread submit behavior.

 @param loop : "Initialized loop"
 @param op : "Caller-owned post storage"
 @param callback : "Callback to run on the owner thread"
 @param userdata : "Opaque user pointer delivered to callback"
 @return ? nova::INVALID_STATE : "Loop is not initialized, post queue is disabled or callback is missing"
 @return ? nova::BUSY : "Post operation is already queued"
 @return ? nova::BACKEND_FAILED : "Backend wake failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Post operation pointer must not be null"
*>
fn void? post_internal(Loop* loop, PostOp* op, PostCallback callback, void* userdata = null) @private
{
	if (!loop.initialized || !loop.post_queue_initialized) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;

	loop.post_mutex.lock()!;
	if (op.queued())
	{
		loop.post_mutex.unlock();
		return nova::BUSY~;
	}
	bool should_wake = loop.post_head == null;
	enqueue_post_locked(loop, op, callback, userdata);
	if (should_wake)
	{
		if (catch err = backend::wake(loop))
		{
			loop.post_head = null;
			loop.post_tail = null;
			loop.post_count = 0;
			op.next = null;
			op.callback = null;
			op.userdata = null;
			@atomic_store(op.in_queue, (uint)0);
			loop.post_mutex.unlock();
			return err~;
		}
	}
	loop.post_mutex.unlock();
}

<*
 Append a post operation while the post mutex is held.

 @param loop : "Loop that owns the post queue"
 @param op : "Caller-owned post storage"
 @param callback : "Callback to run on the owner thread"
 @param userdata : "Opaque user pointer delivered to callback"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Post operation pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn void enqueue_post_locked(Loop* loop, PostOp* op, PostCallback callback, void* userdata) @private
{
	op.next = null;
	op.callback = callback;
	op.userdata = userdata;
	@atomic_store(op.in_queue, (uint)1);
	if (loop.post_tail)
	{
		loop.post_tail.next = op;
		loop.post_tail = op;
	}
	else
	{
		loop.post_head = op;
		loop.post_tail = op;
	}
	loop.post_count++;
}

<*
 Apply cross-thread control requests on the owner thread.

 Cross-thread callers only update atomic request state. The loop lifecycle flag
 is changed here so normal runtime state remains owner-thread local.

 @param loop : "Initialized loop"
 @require loop != null : "Loop pointer must not be null"
 @require loop.initialized : "Loop must be initialized"
*>
fn void apply_thread_requests(Loop* loop) @local
{
	if (@atomic_load(loop.stop_requested) != 0) loop.stopped = true;
}

<*
 Drain posted callbacks onto the owner thread.

 The mutex protects only the producer queue. The queue is detached while locked,
 then callbacks run without holding the mutex so callbacks may post more work or
 call normal loop APIs.

 @param loop : "Initialized loop"
 @return "Number of posted callbacks dispatched"
 @require loop != null : "Loop pointer must not be null"
 @require loop.initialized : "Loop must be initialized"
*>
fn sz drain_post_queue(Loop* loop) @local
{
	if (!loop.post_queue_initialized) return 0;
	if (loop.post_head == null) return 0;

	always_assert(@ok(loop.post_mutex.lock()));
	PostOp* head = loop.post_head;
	loop.post_head = null;
	loop.post_tail = null;
	loop.post_count = 0;
	loop.post_mutex.unlock();

	sz progress = 0;
	while (head)
	{
		PostOp* op = head;
		head = op.next;

		PostCallback callback = op.callback;
		void* userdata        = op.userdata;
		op.next = null;

		if (callback) callback(loop, op, userdata);
		complete_post(loop, op);
		apply_thread_requests(loop);
		progress++;
	}
	return progress;
}

<*
 Mark a dispatched post operation reusable.

 @param loop : "Loop that owns the post queue"
 @param op : "Post operation that just dispatched"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Post operation pointer must not be null"
*>
fn void complete_post(Loop* loop, PostOp* op) @local
{
	(void)loop;
	op.callback = null;
	op.userdata = null;
	@atomic_store(op.in_queue, (uint)0);
}

<*
 Drive loop progress according to `mode`.

 `NO_WAIT` performs one non-blocking tick. `ONCE` waits until one progress
 event, deadline or wake when active work exists, otherwise it returns after a
 non-blocking wake drain. `UNTIL_STOPPED` continues while the loop has active
 work and has not been stopped. When thread submission is enabled, future posts
 are also treated as possible work until the loop is stopped.

 @param loop : "Initialized loop"
 @param mode : "Polling and blocking behavior"
 @return ? nova::INVALID_STATE : "Loop is not initialized, is already running or mode is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? run(Loop* loop, RunMode mode = RunMode.UNTIL_STOPPED)
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (loop.running) return nova::INVALID_STATE~;
	if (mode != RunMode.NO_WAIT && mode != RunMode.ONCE && mode != RunMode.UNTIL_STOPPED) return nova::INVALID_STATE~;
	loop.running = true;
	defer loop.running = false;
	apply_thread_requests(loop);

	if (mode == RunMode.NO_WAIT)
	{
		(void)tick(loop, false);
		return;
	}

	if (mode == RunMode.ONCE)
	{
		while (!loop.stopped)
		{
			bool can_block = has_work(loop);
			sz progress    = tick(loop, can_block);
			if (progress > 0 || !can_block || !has_work(loop)) break;
		}
		return;
	}

	while (!loop.stopped && has_work(loop))
	{
		(void)tick(loop, true);
	}
}

<*
 Run one loop step.

 This first applies cross-thread control requests, drains posted callbacks and
 drains signal notifications onto the owner thread. It then expires due
 timer-backed operations, dispatches queued callbacks, derives the backend wait
 timeout from the timer heap, polls, and drains posts/signals again so
 wake-originated submissions can complete in the same tick.

 @param loop : "Initialized loop"
 @param can_block : "Allow backend polling to wait for work"
 @return "Number of callbacks or backend events processed"
 @require loop != null : "Loop pointer must not be null"
 @require loop.initialized : "Loop must be initialized"
*>
fn sz tick(Loop* loop, bool can_block) @private
{
	sz progress = 0;
	apply_thread_requests(loop);
	progress += drain_post_queue(loop);
	progress += signal::drain(loop);
	loop.update_now();
	timer::expire_due(loop);
	progress += dispatch_ready(loop);
	if (progress > 0)
	{
		if (loop.backend_active_count > 0)
		{
			progress += backend::poll(loop, 0);
			apply_thread_requests(loop);
			progress += drain_post_queue(loop);
			progress += signal::drain(loop);
			loop.update_now();
			timer::expire_due(loop);
			progress += dispatch_ready(loop);
		}
		return progress;
	}

	int backend_timeout_ms = timer::next_timeout_ms(loop, can_block);
	progress += backend::poll(loop, backend_timeout_ms);
	apply_thread_requests(loop);
	progress += drain_post_queue(loop);
	progress += signal::drain(loop);
	loop.update_now();
	timer::expire_due(loop);
	progress += dispatch_ready(loop);
	return progress;
}

<*
 Report whether the runtime has active or externally-submittable work.

 @param loop : "Initialized loop"
 @return "True when ready, timer, backend, worker, process or thread-submitted work is possible"
 @require loop != null : "Loop pointer must not be null"
 @require loop.initialized : "Loop must be initialized"
*>
fn bool has_work(Loop* loop) @private
{
	return loop.options.enable_thread_submit || loop.ready_count > 0 || loop.timer_count > 0
		|| loop.backend_active_count > 0
		|| loop.worker_active_count > 0
		|| loop.signal_count > 0
		|| loop.process_count > 0;
}

<*
 Report whether owner-thread-only runtime state may be touched now.

 @param loop : "Loop storage to check"
 @return "True when the loop is initialized and the current thread owns it"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool owner_ready(Loop* loop) @private
{
	return loop.initialized && loop.is_owner_thread();
}
