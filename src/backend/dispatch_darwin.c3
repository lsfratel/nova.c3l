module nova::backend @if(env::DARWIN);

import nova @norecurse;
import nova::op @public;
import nova::backend::kqueue @public;

<*
 Reject an io_uring request, record the resolved engine, and initialize kqueue.

 This is the macOS backend dispatch: the canonical `backend::*` entry points the
 typed layer and the shared reactor call. macOS exposes a single readiness engine
 (kqueue), so there is no runtime selection — every entry point forwards to
 `nova::backend::kqueue`.

 @param loop : "Loop being initialized"
 @return ? nova::UNSUPPORTED : "io_uring backend was requested but is not available on macOS"
 @return ? nova::BACKEND_FAILED : "kqueue initialization failed"
 @return ? mem::OUT_OF_MEMORY : "Backend storage allocation failed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? init(Loop* loop) @inline @private
{
	if (loop.options.backend == BackendKind.IO_URING) return nova::UNSUPPORTED~;
	loop.backend_kind = BackendKind.EPOLL;
	return kqueue::init(loop);
}

<*
 Destroy the kqueue backend and release its resources.

 @param loop : "Loop whose backend is being destroyed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void destroy(Loop* loop) @inline @private => kqueue::destroy(loop);

<*
 Wait for backend events up to `timeout_ms` and queue the resulting completions.

 @param loop : "Loop owning the backend"
 @param timeout_ms : "Wait budget: negative blocks, zero polls, positive bounds the wait"
 @return "Number of backend events consumed"
 @require loop != null : "Loop pointer must not be null"
*>
fn sz poll(Loop* loop, int timeout_ms) @inline @private => kqueue::poll(loop, timeout_ms);

<*
 Wake a loop blocked in the backend poll.

 @param loop : "Loop to wake"
 @return ? nova::INVALID_STATE : "Wake source is not initialized"
 @return ? nova::BACKEND_FAILED : "Wake signal failed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? wake(Loop* loop) @inline @private => kqueue::wake(loop);

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
 @return ? nova::INVALID_STATE : "Loop backend is not initialized or interests are invalid"
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
) @inline @private => kqueue::watch_submit(loop, op, state, handle, interests, callback, owner, userdata);

<*
 Submit a process-exit wait operation for a child PID.

 @param loop : "Initialized loop"
 @param op : "Process operation header"
 @param state : "Process-owned backend wait state"
 @param handle : "Child process identifier"
 @param callback : "Typed dispatch trampoline"
 @param owner : "Process handle"
 @param userdata : "Opaque user pointer captured by the process operation"
 @return "Generation-checked reference for the active process wait"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized or the child PID is not positive"
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
) @inline @private => kqueue::process_wait_submit(loop, op, state, handle, callback, owner, userdata);

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
) @inline @private => kqueue::tcp_accept_driver_submit(loop, op, state, watcher, handle, callback, owner);

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
) @inline @private => kqueue::tcp_connect_submit(
	loop,
	op,
	state,
	watcher,
	handle,
	complete,
	status,
	callback,
	owner,
	userdata
);

<*
 Whether stream reads run in completion mode for this loop. macOS has only the
 kqueue readiness engine, so this is always false.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool stream_completion_read_enabled(Loop* loop) @inline @private => false;

<*
 Whether stream writes run in completion mode for this loop. Always false on macOS.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool stream_completion_write_enabled(Loop* loop) @inline @private => false;

<*
 Submit a stream read, waiting on the stream watcher's readable readiness.

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
) @inline @private => kqueue::stream_read_submit(loop, op, state, watcher, handle, callback, owner, userdata);

<*
 Submit a stream write, waiting on the stream watcher's writable readiness.

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
) @inline @private => kqueue::stream_write_submit(loop, op, state, watcher, handle, callback, owner, userdata);

<*
 Completion-mode stream read. Unreachable on macOS: `stream_completion_read_enabled`
 is always false, so the typed layer never selects this path.

 @param loop : "Unused"
 @param op : "Unused"
 @param state : "Unused"
 @param handle : "Unused"
 @param buffer : "Unused"
 @param callback : "Unused"
 @param owner : "Unused"
 @param userdata : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
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
) @inline @private => unreachable();

<*
 Completion-mode stream write. Unreachable on macOS.

 @param loop : "Unused"
 @param op : "Unused"
 @param state : "Unused"
 @param handle : "Unused"
 @param bytes : "Unused"
 @param callback : "Unused"
 @param owner : "Unused"
 @param userdata : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
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
) @inline @private => unreachable();

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
) @inline @private => kqueue::udp_recv_submit(loop, op, state, watcher, handle, callback, owner, userdata);

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
) @inline @private => kqueue::udp_send_submit(
	loop,
	op,
	state,
	watcher,
	handle,
	complete,
	status,
	callback,
	owner,
	userdata
);

<*
 Rearm a TCP accept driver after stale readiness found no accepted socket.

 @param loop : "Loop that owns the accept operation"
 @param op : "TCP accept or accept-driver operation to rearm"
 @return ? nova::BACKEND_FAILED : "Backend re-registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? tcp_accept_rearm(Loop* loop, Header* op) @inline @private => kqueue::tcp_accept_rearm(loop, op);

<*
 Rearm a stream read after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the read operation"
 @param op : "Stream read operation to rearm"
 @return ? nova::BACKEND_FAILED : "Backend re-registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_read_rearm(Loop* loop, Header* op) @inline @private => kqueue::stream_read_rearm(loop, op);

<*
 Rearm a stream write after partial progress or stale writable readiness.

 @param loop : "Loop that owns the write operation"
 @param op : "Stream write operation to rearm"
 @return ? nova::BACKEND_FAILED : "Backend re-registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_write_rearm(Loop* loop, Header* op) @inline @private => kqueue::stream_write_rearm(loop, op);

<*
 Rearm a UDP receive after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the receive operation"
 @param op : "UDP receive operation to rearm"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? udp_recv_rearm(Loop* loop, Header* op) @inline @private => kqueue::udp_recv_rearm(loop, op);

<*
 Rearm a UDP send after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the send operation"
 @param op : "UDP send operation to rearm"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? udp_send_rearm(Loop* loop, Header* op) @inline @private => kqueue::udp_send_rearm(loop, op);

<*
 Remove a persistent watcher from the backend and release its counted activity.

 @param loop : "Loop that owns the watcher"
 @param watcher : "Watcher to close"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "Watcher pointer must not be null"
*>
fn void watcher_close(Loop* loop, Watcher* watcher) @inline @private => kqueue::watcher_close(loop, watcher);

<*
 Remove an operation-owned descriptor from the backend and clear its state.

 @param loop : "Loop that owns the backend"
 @param op : "Header registered with the backend"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void backend_unregister_op(Loop* loop, Header* op) @inline @private => kqueue::backend_unregister_op(loop, op);

<*
 Completion-mode re-submit. Unreachable on macOS: stream reads never run in
 completion mode, so the typed dispatcher never calls this.

 @param loop : "Unused"
 @param op : "Unused"
 @param buffer : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_recv_resubmit(Loop* loop, Header* op, char[] buffer) @inline @private => unreachable();

<*
 Completion-mode re-submit. Unreachable on macOS.

 @param loop : "Unused"
 @param op : "Unused"
 @param bytes : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_send_resubmit(Loop* loop, Header* op, char[] bytes) @inline @private => unreachable();

<*
 Completion-mode async cancel. Unreachable on macOS: no operation carries
 completion state, so the cancel path never reaches here.

 @param loop : "Unused"
 @param op : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void cancel_completion(Loop* loop, Header* op) @inline @private => unreachable();

<*
 Whether TCP accepts run in completion mode for this loop. Always false on macOS.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool tcp_completion_accept_enabled(Loop* loop) @inline @private => false;

<*
 Whether TCP connects run in completion mode for this loop. Always false on macOS.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool tcp_completion_connect_enabled(Loop* loop) @inline @private => false;

<*
 Completion-mode accept. Unreachable on macOS: `tcp_completion_accept_enabled` is
 always false, so the typed layer never selects this path.

 @param loop : "Unused"
 @param op : "Unused"
 @param state : "Unused"
 @param listener : "Unused"
 @param addr_ptr : "Unused"
 @param socklen_ptr : "Unused"
 @param callback : "Unused"
 @param owner : "Unused"
 @param userdata : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
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
) @inline @private => unreachable();

<*
 Completion-mode connect. Unreachable on macOS.

 @param loop : "Unused"
 @param op : "Unused"
 @param state : "Unused"
 @param handle : "Unused"
 @param addr_ptr : "Unused"
 @param addrlen : "Unused"
 @param callback : "Unused"
 @param owner : "Unused"
 @param userdata : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
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
) @inline @private => unreachable();

<*
 Whether UDP receives run in completion mode for this loop. Always false on macOS.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool udp_completion_recv_enabled(Loop* loop) @inline @private => false;

<*
 Whether UDP sends run in completion mode for this loop. Always false on macOS.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool udp_completion_send_enabled(Loop* loop) @inline @private => false;

<*
 Completion-mode UDP receive. Unreachable on macOS: `udp_completion_recv_enabled`
 is always false, so the typed layer never selects this path.

 @param loop : "Unused"
 @param op : "Unused"
 @param state : "Unused"
 @param handle : "Unused"
 @param msg_ptr : "Unused"
 @param flags : "Unused"
 @param callback : "Unused"
 @param owner : "Unused"
 @param userdata : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
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
) @inline @private => unreachable();

<*
 Completion-mode UDP send. Unreachable on macOS.

 @param loop : "Unused"
 @param op : "Unused"
 @param state : "Unused"
 @param handle : "Unused"
 @param msg_ptr : "Unused"
 @param flags : "Unused"
 @param callback : "Unused"
 @param owner : "Unused"
 @param userdata : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
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
) @inline @private => unreachable();

<*
 Whether vectored stream reads run in completion mode. Always false on macOS.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool stream_recvmsg_completion_enabled(Loop* loop) @inline @private => false;

<*
 Whether vectored stream writes run in completion mode. Always false on macOS.

 @param loop : "Loop whose resolved backend is queried"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool stream_sendmsg_completion_enabled(Loop* loop) @inline @private => false;

<*
 Completion-mode vectored stream read. Unreachable on macOS.

 @param loop : "Unused"
 @param op : "Unused"
 @param state : "Unused"
 @param handle : "Unused"
 @param msg_ptr : "Unused"
 @param callback : "Unused"
 @param owner : "Unused"
 @param userdata : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
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
) @inline @private => unreachable();

<*
 Completion-mode vectored stream write. Unreachable on macOS.

 @param loop : "Unused"
 @param op : "Unused"
 @param state : "Unused"
 @param handle : "Unused"
 @param msg_ptr : "Unused"
 @param callback : "Unused"
 @param owner : "Unused"
 @param userdata : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
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
) @inline @private => unreachable();

<*
 Completion-mode vectored stream read re-submit. Unreachable on macOS.

 @param loop : "Unused"
 @param op : "Unused"
 @param msg_ptr : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_recvmsg_resubmit(Loop* loop, Header* op, ulong msg_ptr) @inline @private => unreachable();

<*
 Completion-mode vectored stream write re-submit. Unreachable on macOS.

 @param loop : "Unused"
 @param op : "Unused"
 @param msg_ptr : "Unused"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? stream_sendmsg_resubmit(Loop* loop, Header* op, ulong msg_ptr) @inline @private => unreachable();
