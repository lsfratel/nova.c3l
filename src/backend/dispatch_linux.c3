module nova::backend @if(env::LINUX);

import nova @norecurse;
import nova::op @public;
import nova::backend::epoll @public;
import nova::backend::uring @public;

<*
 Route a backend operation to the resolved engine for `loop`.

 Selects the io_uring expression when the loop runs on io_uring, otherwise the
 epoll expression. Both arguments are unevaluated until selected, so only the
 chosen engine call runs. Combined with `@inline` entry points this collapses the
 dispatch to a single predicted branch with no extra call frames.

 @param loop : "Loop whose resolved backend selects the engine"
 @param #io_uring_expr : "Expression evaluated on the io_uring engine"
 @param #epoll_expr : "Expression evaluated on the epoll engine"
*>
macro @route(Loop* loop, #io_uring_expr, #epoll_expr) @local
{
	if (loop.backend_kind == BackendKind.IO_URING) return #io_uring_expr;
	return #epoll_expr;
}

<*
 Resolve the backend engine requested in `Options.backend`.

 This is the Linux backend dispatch: the canonical `backend::*` entry points the
 typed layer and the shared reactor call. `init` resolves the engine and records
 it in `loop.backend_kind`; every other entry point routes to that engine — the
 epoll reactor (`nova::backend::epoll`) or the io_uring proactor
 (`nova::backend::uring`).

 `EPOLL` forces the epoll reactor. `IO_URING` probes the kernel and fails with
 `UNSUPPORTED` when io_uring is unavailable or lacks the required capabilities.
 `AUTO` prefers io_uring when usable and otherwise falls back to epoll.

 @param requested : "Backend selection from Options"
 @return "Concrete resolved engine (never AUTO)"
 @return ? nova::UNSUPPORTED : "io_uring was forced but is unavailable"
*>
fn BackendKind? resolve_backend(BackendKind requested, uring::Caps caps) @private
{
	if (requested == BackendKind.EPOLL) return BackendKind.EPOLL;
	bool usable = caps.usable();
	if (requested == BackendKind.IO_URING)
	{
		if (!usable) return nova::UNSUPPORTED~;
		return BackendKind.IO_URING;
	}
	return usable ? BackendKind.IO_URING : BackendKind.EPOLL;
}

<*
 Resolve the requested engine, record it in `loop.backend_kind`, and initialize it.

 @param loop : "Loop being initialized"
 @return ? nova::UNSUPPORTED : "io_uring was forced but is unavailable"
 @return ? nova::BACKEND_FAILED : "Engine initialization failed"
 @return ? mem::OUT_OF_MEMORY : "Backend storage allocation failed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? init(Loop* loop) @private
{
	uring::Caps caps;
	if (loop.options.backend != BackendKind.EPOLL) caps = uring::probe_capabilities();
	BackendKind resolved = resolve_backend(loop.options.backend, caps)!;
	loop.backend_kind = resolved;
	if (resolved == BackendKind.IO_URING) return uring::init(loop, caps);
	return epoll::init(loop);
}

<*
 Destroy the active backend engine and release its resources.

 @param loop : "Loop whose backend is being destroyed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void destroy(Loop* loop) @inline @private => @route(loop, uring::destroy(loop), epoll::destroy(loop));

<*
 Wait for backend events up to `timeout_ms` and queue the resulting completions.

 @param loop : "Loop owning the backend"
 @param timeout_ms : "Wait budget: negative blocks, zero polls, positive bounds the wait"
 @return "Number of backend events consumed"
 @require loop != null : "Loop pointer must not be null"
*>
fn sz poll(
	Loop* loop,
	int timeout_ms
) @inline @private => @route(loop, uring::poll(loop, timeout_ms), epoll::poll(loop, timeout_ms));

<*
 Wake a loop blocked in the backend poll.

 @param loop : "Loop to wake"
 @return ? nova::INVALID_STATE : "Wake source is not initialized"
 @return ? nova::BACKEND_FAILED : "Wake signal failed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? wake(Loop* loop) @inline @private => @route(loop, uring::wake(loop), epoll::wake(loop));

<*
 Submit a borrowed-handle readiness watch operation.

 @param loop : "Initialized loop"
 @param op : "Caller-owned watch operation header"
 @param state : "Caller-owned backend state embedded in the watch operation"
 @param handle : "Borrowed native descriptor"
 @param interests : "Normalized watch interests"
 @param callback : "Typed dispatch trampoline"
 @param owner : "Typed watch handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized, or no readable/writable interest is requested"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? watch_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	uint interests,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => @route(
	loop,
	uring::watch_submit(loop, op, state, handle, interests, callback, owner, userdata),
	epoll::watch_submit(loop, op, state, handle, interests, callback, owner, userdata)
);

<*
 Submit a process-exit wait operation on a borrowed pidfd.

 @param loop : "Initialized loop"
 @param op : "Process operation header"
 @param state : "Process-owned backend wait state"
 @param handle : "Open pidfd for the child process"
 @param callback : "Typed dispatch trampoline"
 @param owner : "Process handle"
 @param userdata : "Opaque user pointer captured by the process operation"
 @return "Generation-checked reference for the active process wait"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized, or the pidfd handle is invalid"
 @return ? nova::BUSY : "Process header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? process_wait_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => @route(
	loop,
	uring::process_wait_submit(loop, op, state, handle, callback, owner, userdata),
	epoll::process_wait_submit(loop, op, state, handle, callback, owner, userdata)
);

<*
 Arm the listener-owned accept readiness driver.

 @param loop : "Initialized loop"
 @param op : "Listener-owned accept driver operation"
 @param state : "Listener-owned backend state for the accept driver"
 @param watcher : "Listener-owned backend watcher"
 @param handle : "Native listener descriptor"
 @param callback : "Driver dispatch trampoline"
 @param owner : "Typed listener handle"
 @return "Generation-checked reference for the active driver"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Driver operation is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require watcher != null : "Watcher pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? tcp_accept_driver_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner
) @inline @private => @route(
	loop,
	uring::tcp_accept_driver_submit(loop, op, state, watcher, handle, callback, owner),
	epoll::tcp_accept_driver_submit(loop, op, state, watcher, handle, callback, owner)
);

<*
 Submit a TCP connect, queuing immediate results or waiting on writable readiness.

 @param loop : "Initialized loop"
 @param op : "Caller-owned connect operation header"
 @param state : "Caller-owned backend state embedded in the connect operation"
 @param watcher : "Persistent stream watcher"
 @param handle : "Native stream descriptor"
 @param complete : "Whether connect already reached a terminal result"
 @param status : "Immediate terminal status when complete"
 @param callback : "Typed connect dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? tcp_connect_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	Watcher* watcher,
	NativeHandle handle,
	bool complete,
	fault status,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => @route(
	loop,
	uring::tcp_connect_submit(loop, op, state, watcher, handle, complete, status, callback, owner, userdata),
	epoll::tcp_connect_submit(loop, op, state, watcher, handle, complete, status, callback, owner, userdata)
);

<*
 Whether stream reads run in io_uring completion mode (`RECV`) for this loop.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool stream_completion_read_enabled(
	Loop* loop
) @inline @private => loop.backend_kind == BackendKind.IO_URING && uring::stream_completion_recv(loop);

<*
 Whether stream writes run in io_uring completion mode (`SEND`) for this loop.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool stream_completion_write_enabled(
	Loop* loop
) @inline @private => loop.backend_kind == BackendKind.IO_URING && uring::stream_completion_send(loop);

<*
 Submit a stream read, waiting on the stream watcher's readable readiness. The
 typed layer performs the `recv` after readiness (epoll, or io_uring `POLL_ADD`).
 The completion-mode `RECV` path is `stream_recv_submit`.

 @param loop : "Initialized loop"
 @param op : "Caller-owned read operation header"
 @param state : "Caller-owned backend state embedded in the read operation"
 @param watcher : "Persistent stream watcher"
 @param handle : "Native stream descriptor"
 @param callback : "Typed read dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? stream_read_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => @route(
	loop,
	uring::stream_read_submit(loop, op, state, watcher, handle, callback, owner, userdata),
	epoll::stream_read_submit(loop, op, state, watcher, handle, callback, owner, userdata)
);

<*
 Submit a stream write, waiting on the stream watcher's writable readiness. The
 typed layer performs the `send` after readiness. The completion-mode `SEND` path
 is `stream_send_submit`.

 @param loop : "Initialized loop"
 @param op : "Caller-owned write operation header"
 @param state : "Caller-owned backend state embedded in the write operation"
 @param watcher : "Persistent stream watcher"
 @param handle : "Native stream descriptor"
 @param callback : "Typed write dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? stream_write_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => @route(
	loop,
	uring::stream_write_submit(loop, op, state, watcher, handle, callback, owner, userdata),
	epoll::stream_write_submit(loop, op, state, watcher, handle, callback, owner, userdata)
);

<*
 Submit a stream read as an io_uring `IORING_OP_RECV` completion: the kernel reads
 into `buffer` and reports the byte count (or `-errno`) in the CQE. Selected by the
 typed layer only when `stream_completion_read_enabled` holds and the handle is a
 socket (the typed layer supplied a completion fault mapper).

 @param loop : "Initialized loop on io_uring with `RECV` support"
 @param op : "Caller-owned read operation header"
 @param state : "Caller-owned backend state embedded in the read operation"
 @param handle : "Native socket descriptor"
 @param buffer : "Caller destination bytes the kernel reads into"
 @param callback : "Typed read dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? stream_recv_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	char[] buffer,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => uring::stream_recv_submit(loop, op, state, handle, buffer, callback, owner, userdata);

<*
 Submit a stream write as an io_uring `IORING_OP_SEND` completion: the kernel
 writes from `bytes` and reports the byte count (or `-errno`) in the CQE. Selected
 by the typed layer only when `stream_completion_write_enabled` holds and the
 handle is a socket.

 @param loop : "Initialized loop on io_uring with `SEND` support"
 @param op : "Caller-owned write operation header"
 @param state : "Caller-owned backend state embedded in the write operation"
 @param handle : "Native socket descriptor"
 @param bytes : "Caller source bytes the kernel writes from"
 @param callback : "Typed write dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? stream_send_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	char[] bytes,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => uring::stream_send_submit(loop, op, state, handle, bytes, callback, owner, userdata);

<*
 Submit a UDP receive readiness operation.

 @param loop : "Initialized loop"
 @param op : "Caller-owned receive operation header"
 @param state : "Caller-owned backend state embedded in the receive operation"
 @param handle : "Native datagram descriptor"
 @param callback : "Typed receive dispatch trampoline"
 @param owner : "Typed UDP socket handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? udp_recv_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => @route(
	loop,
	uring::udp_recv_submit(loop, op, state, watcher, handle, callback, owner, userdata),
	epoll::udp_recv_submit(loop, op, state, watcher, handle, callback, owner, userdata)
);

<*
 Submit a UDP send, queuing immediate results or waiting on writable readiness.

 @param loop : "Initialized loop"
 @param op : "Caller-owned send operation header"
 @param state : "Caller-owned backend state embedded in the send operation"
 @param handle : "Native datagram descriptor"
 @param complete : "Whether send already reached a terminal result"
 @param status : "Immediate terminal status when complete"
 @param callback : "Typed send dispatch trampoline"
 @param owner : "Typed UDP socket handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? udp_send_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	Watcher* watcher,
	NativeHandle handle,
	bool complete,
	fault status,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => @route(
	loop,
	uring::udp_send_submit(loop, op, state, watcher, handle, complete, status, callback, owner, userdata),
	epoll::udp_send_submit(loop, op, state, watcher, handle, complete, status, callback, owner, userdata)
);

<*
 Rearm a TCP accept driver after stale readiness found no accepted socket.

 @param loop : "Loop that owns the accept operation"
 @param op : "TCP accept or accept-driver operation to rearm"
 @return ? nova::BACKEND_FAILED : "Backend re-registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? tcp_accept_rearm(
	Loop* loop,
	Header* op
) @inline @private => @route(loop, uring::tcp_accept_rearm(loop, op), epoll::tcp_accept_rearm(loop, op));

<*
 Rearm a stream read after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the read operation"
 @param op : "Stream read operation to rearm"
 @return ? nova::BACKEND_FAILED : "Backend re-registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_read_rearm(
	Loop* loop,
	Header* op
) @inline @private => @route(loop, uring::stream_read_rearm(loop, op), epoll::stream_read_rearm(loop, op));

<*
 Rearm a stream write after partial progress or stale writable readiness.

 @param loop : "Loop that owns the write operation"
 @param op : "Stream write operation to rearm"
 @return ? nova::BACKEND_FAILED : "Backend re-registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_write_rearm(
	Loop* loop,
	Header* op
) @inline @private => @route(loop, uring::stream_write_rearm(loop, op), epoll::stream_write_rearm(loop, op));

<*
 Rearm a UDP receive after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the receive operation"
 @param op : "UDP receive operation to rearm"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? udp_recv_rearm(
	Loop* loop,
	Header* op
) @inline @private => @route(loop, uring::udp_recv_rearm(loop, op), epoll::udp_recv_rearm(loop, op));

<*
 Rearm a UDP send after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the send operation"
 @param op : "UDP send operation to rearm"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? udp_send_rearm(
	Loop* loop,
	Header* op
) @inline @private => @route(loop, uring::udp_send_rearm(loop, op), epoll::udp_send_rearm(loop, op));

<*
 Remove a persistent watcher from the backend and release its counted activity.

 @param loop : "Loop that owns the watcher"
 @param watcher : "Watcher to close"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "Watcher pointer must not be null"
*>
fn void watcher_close(
	Loop* loop,
	Watcher* watcher
) @inline @private => @route(loop, uring::watcher_close(loop, watcher), epoll::watcher_close(loop, watcher));

<*
 Remove an operation-owned descriptor from the backend and clear its state.

 @param loop : "Loop that owns the backend"
 @param op : "Header registered with the backend"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void backend_unregister_op(
	Loop* loop,
	Header* op
) @inline @private => @route(loop, uring::backend_unregister_op(loop, op), epoll::backend_unregister_op(loop, op));

<*
 Re-submit a stream read `RECV` for the still-needed slice (the previous `RECV`
 returned fewer than `min_bytes`). Only reached on io_uring completion ops.

 @param loop : "Loop owning the completion operation"
 @param op : "Stream read operation to continue"
 @param buffer : "Remaining destination slice"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_recv_resubmit(
	Loop* loop,
	Header* op,
	char[] buffer
) @inline @private => uring::stream_recv_resubmit(loop, op, buffer);

<*
 Re-submit a stream write `SEND` for the still-unsent slice (partial `SEND`). Only
 reached on io_uring completion ops.

 @param loop : "Loop owning the completion operation"
 @param op : "Stream write operation to continue"
 @param bytes : "Remaining source slice"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_send_resubmit(
	Loop* loop,
	Header* op,
	char[] bytes
) @inline @private => uring::stream_send_resubmit(loop, op, bytes);

<*
 Asynchronously cancel an in-flight completion operation (`ASYNC_CANCEL`). The op
 and its caller buffer stay alive until the cancel CQE finalizes it. Only reached
 for io_uring completion ops.

 @param loop : "Loop owning the completion operation"
 @param op : "Completion operation to cancel"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void cancel_completion(Loop* loop, Header* op) @inline @private => uring::cancel_completion(loop, op);

<*
 Whether TCP accepts run in io_uring completion mode (`ACCEPT`) for this loop.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool tcp_completion_accept_enabled(
	Loop* loop
) @inline @private => loop.backend_kind == BackendKind.IO_URING && uring::stream_completion_accept(loop);

<*
 Whether TCP connects run in io_uring completion mode (`CONNECT`) for this loop.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool tcp_completion_connect_enabled(
	Loop* loop
) @inline @private => loop.backend_kind == BackendKind.IO_URING && uring::stream_completion_connect(loop);

<*
 Submit a TCP accept as an `IORING_OP_ACCEPT` completion. Only reached when
 `tcp_completion_accept_enabled` holds.

 @param loop : "Initialized loop on io_uring with `ACCEPT` support"
 @param op : "Caller-owned accept operation header"
 @param state : "Caller-owned backend state embedded in the accept operation"
 @param listener : "Native listener descriptor"
 @param addr_ptr : "Pointer to the caller peer sockaddr-out storage"
 @param socklen_ptr : "Pointer to the caller peer socklen storage"
 @param callback : "Typed accept dispatch trampoline"
 @param owner : "Typed listener handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? tcp_accept_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle listener,
	ulong addr_ptr,
	ulong socklen_ptr,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => uring::tcp_accept_submit(
	loop,
	op,
	state,
	listener,
	addr_ptr,
	socklen_ptr,
	callback,
	owner,
	userdata
);

<*
 Submit a TCP connect as an `IORING_OP_CONNECT` completion. Only reached when
 `tcp_completion_connect_enabled` holds.

 @param loop : "Initialized loop on io_uring with `CONNECT` support"
 @param op : "Caller-owned connect operation header"
 @param state : "Caller-owned backend state embedded in the connect operation"
 @param handle : "Native stream descriptor"
 @param addr_ptr : "Pointer to the caller remote sockaddr storage"
 @param addrlen : "Remote address length"
 @param callback : "Typed connect dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? tcp_connect_complete_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	ulong addr_ptr,
	ulong addrlen,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => uring::tcp_connect_complete_submit(
	loop,
	op,
	state,
	handle,
	addr_ptr,
	addrlen,
	callback,
	owner,
	userdata
);

<*
 Whether UDP receives run in io_uring completion mode (`RECVMSG`) for this loop.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool udp_completion_recv_enabled(
	Loop* loop
) @inline @private => loop.backend_kind == BackendKind.IO_URING && uring::stream_completion_recvmsg(loop);

<*
 Whether UDP sends run in io_uring completion mode (`SENDMSG`) for this loop.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool udp_completion_send_enabled(
	Loop* loop
) @inline @private => loop.backend_kind == BackendKind.IO_URING && uring::stream_completion_sendmsg(loop);

<*
 Submit a UDP receive as an `IORING_OP_RECVMSG` completion. Only reached when
 `udp_completion_recv_enabled` holds.

 @param loop : "Initialized loop on io_uring with `RECVMSG` support"
 @param op : "Caller-owned receive operation header"
 @param state : "Caller-owned backend state embedded in the receive operation"
 @param handle : "Native datagram descriptor"
 @param msg_ptr : "Pointer to the caller `msghdr` (peer in `msg_name`, single iovec)"
 @param flags : "recv message flags (`MSG_TRUNC`)"
 @param callback : "Typed receive dispatch trampoline"
 @param owner : "Typed UDP socket handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? udp_recvmsg_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	ulong msg_ptr,
	uint flags,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => uring::recvmsg_submit(
	loop,
	op,
	state,
	Kind.UDP_RECV,
	handle,
	msg_ptr,
	flags,
	callback,
	owner,
	userdata
);

<*
 Submit a UDP send as an `IORING_OP_SENDMSG` completion. Only reached when
 `udp_completion_send_enabled` holds.

 @param loop : "Initialized loop on io_uring with `SENDMSG` support"
 @param op : "Caller-owned send operation header"
 @param state : "Caller-owned backend state embedded in the send operation"
 @param handle : "Native datagram descriptor"
 @param msg_ptr : "Pointer to the caller `msghdr` (peer in `msg_name`, single iovec)"
 @param flags : "send message flags"
 @param callback : "Typed send dispatch trampoline"
 @param owner : "Typed UDP socket handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? udp_sendmsg_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	ulong msg_ptr,
	uint flags,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => uring::sendmsg_submit(
	loop,
	op,
	state,
	Kind.UDP_SEND,
	handle,
	msg_ptr,
	flags,
	callback,
	owner,
	userdata
);

<*
 Whether vectored stream reads run in io_uring completion mode (`RECVMSG`).

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool stream_recvmsg_completion_enabled(
	Loop* loop
) @inline @private => loop.backend_kind == BackendKind.IO_URING && uring::stream_completion_recvmsg(loop);

<*
 Whether vectored stream writes run in io_uring completion mode (`SENDMSG`).

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool stream_sendmsg_completion_enabled(
	Loop* loop
) @inline @private => loop.backend_kind == BackendKind.IO_URING && uring::stream_completion_sendmsg(loop);

<*
 Submit a vectored stream read as an `IORING_OP_RECVMSG` completion over the caller
 `msghdr` at `msg_ptr`. Only reached when `stream_recvmsg_completion_enabled` holds.

 @param loop : "Initialized loop on io_uring with `RECVMSG` support"
 @param op : "Caller-owned read operation header"
 @param state : "Caller-owned backend state embedded in the read operation"
 @param handle : "Native stream descriptor"
 @param msg_ptr : "Pointer to the caller `msghdr` (iovec array, no `msg_name`)"
 @param callback : "Typed read dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? stream_recvmsg_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	ulong msg_ptr,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => uring::recvmsg_submit(
	loop,
	op,
	state,
	Kind.STREAM_READ,
	handle,
	msg_ptr,
	0,
	callback,
	owner,
	userdata
);

<*
 Submit a vectored stream write as an `IORING_OP_SENDMSG` completion over the caller
 `msghdr` at `msg_ptr`. Only reached when `stream_sendmsg_completion_enabled` holds.

 @param loop : "Initialized loop on io_uring with `SENDMSG` support"
 @param op : "Caller-owned write operation header"
 @param state : "Caller-owned backend state embedded in the write operation"
 @param handle : "Native stream descriptor"
 @param msg_ptr : "Pointer to the caller `msghdr` (iovec array, no `msg_name`)"
 @param callback : "Typed write dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn Ref? stream_sendmsg_submit(
	Loop* loop,
	Header* op,
	OpState* state,
	NativeHandle handle,
	ulong msg_ptr,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private => uring::sendmsg_submit(
	loop,
	op,
	state,
	Kind.STREAM_WRITE,
	handle,
	msg_ptr,
	uring::MSG_NOSIGNAL,
	callback,
	owner,
	userdata
);

<*
 Re-submit a vectored stream `RECVMSG` for the still-needed segments. Only reached
 on io_uring completion ops.

 @param loop : "Loop owning the completion operation"
 @param op : "Stream read operation to continue"
 @param msg_ptr : "Pointer to the updated caller `msghdr`"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_recvmsg_resubmit(
	Loop* loop,
	Header* op,
	ulong msg_ptr
) @inline @private => uring::recvmsg_resubmit(loop, op, msg_ptr, 0);

<*
 Re-submit a vectored stream `SENDMSG` for the still-unsent segments. Only reached
 on io_uring completion ops.

 @param loop : "Loop owning the completion operation"
 @param op : "Stream write operation to continue"
 @param msg_ptr : "Pointer to the updated caller `msghdr`"
 @return ? nova::BACKEND_FAILED : "Ring submission failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_sendmsg_resubmit(
	Loop* loop,
	Header* op,
	ulong msg_ptr
) @inline @private => uring::sendmsg_resubmit(loop, op, msg_ptr, uring::MSG_NOSIGNAL);
