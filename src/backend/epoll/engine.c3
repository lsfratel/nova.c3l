module nova::backend::epoll @if(env::LINUX);

import std::core::mem::alloc, std::os::linux;
import libc;

import nova @norecurse;
import nova::op @public;
import nova::backend @public;
import nova::timer;

<*
 Linux `EPOLL_CLOEXEC` flag used with `epoll_create1`.
*>
const int EPOLL_CLOEXEC = 0o2000000;

<*
 Linux `eventfd` flags used for the loop wake source.
*>
const int EFD_CLOEXEC  = 0o2000000;
const int EFD_NONBLOCK = 0o4000;

<*
 Low-bit tag used to distinguish persistent watcher pointers from operation
 pointers in `epoll_event.data.u64`.
*>
const ulong BACKEND_WATCHER_TAG = 1;

<*
 Create an eventfd counter for loop wakeups.
*>
extern fn int eventfd(uint initval, int flags);

<*
 Store a tagged watcher pointer inside an epoll event.

 @param [out] event : "Epoll event to tag"
 @param watcher : "Persistent backend watcher"
 @require event != null : "Epoll event pointer must not be null"
 @require watcher != null : "backend::Watcher pointer must not be null"
*>
fn void backend_event_set_watcher(linux::EpollEvent* event, backend::Watcher* watcher) @local
{
	event.data.u64 = (ulong)((uptr)watcher | (uptr)BACKEND_WATCHER_TAG);
}

<*
 Report whether an epoll event contains a tagged watcher pointer.

 @param event : "Epoll event to inspect"
 @return "True when event stores a watcher pointer"
 @require event != null : "Epoll event pointer must not be null"
*>
fn bool backend_event_is_watcher(linux::EpollEvent* event) @private
{
	return (event.data.u64 & BACKEND_WATCHER_TAG) != 0;
}

<*
 Recover the watcher pointer stored in a tagged epoll event.

 @param event : "Tagged epoll event"
 @return "Backend watcher stored in the event"
 @require event != null : "Epoll event pointer must not be null"
*>
fn backend::Watcher* backend_event_watcher(linux::EpollEvent* event) @private
{
	return (backend::Watcher*)((uptr)(event.data.u64 & ~BACKEND_WATCHER_TAG));
}

<*
 Initialize the Linux epoll backend using loop-owned fixed storage.

 The event array is the only backend allocation and happens during `Loop.init`.
 One extra event slot is reserved for the loop wake source, so a timer-only loop
 can still block in `run` and be woken through `Loop.wake`.

 @param loop : "Loop being initialized"
 @return ? mem::OUT_OF_MEMORY : "Event array allocation failed"
 @return ? nova::BACKEND_FAILED : "epoll creation failed"
*>
fn void? init(Loop* loop) @inline @private
{
	sz event_capacity          = loop.options.max_events + 1;
	linux::EpollEvent[] events = alloc::new_array_try(loop.allocator, linux::EpollEvent, event_capacity)!;
	loop.backend_events = events.ptr;
	loop.backend_event_capacity = events.len;

	int epfd = linux::epoll_create1(EPOLL_CLOEXEC);
	if (epfd < 0)
	{
		alloc::free(loop.allocator, loop.backend_events);
		loop.backend_events = null;
		loop.backend_event_capacity = 0;
		return nova::BACKEND_FAILED~;
	}

	int wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	if (wake_fd < 0)
	{
		(void)libc::close(epfd);
		alloc::free(loop.allocator, loop.backend_events);
		loop.backend_events = null;
		loop.backend_event_capacity = 0;
		return nova::BACKEND_FAILED~;
	}

	linux::EpollEvent event;
	event.events = linux::EPOLLIN;
	event.data.ptr = null;
	if (linux::epoll_ctl(epfd, (int)linux::EPOLL_CTL_ADD, wake_fd, &event) < 0)
	{
		(void)libc::close(wake_fd);
		(void)libc::close(epfd);
		alloc::free(loop.allocator, loop.backend_events);
		loop.backend_events = null;
		loop.backend_event_capacity = 0;
		return nova::BACKEND_FAILED~;
	}

	loop.backend_handle = (NativeHandle)epfd;
	loop.wake_handle = (NativeHandle)wake_fd;
	loop.wake_write_handle = (NativeHandle)-1;
}

<*
 Destroy the Linux epoll backend.

 Borrowed watched handles are never closed here.

 @param loop : "Loop whose backend is being destroyed"
*>
fn void destroy(Loop* loop) @inline @private
{
	if (!loop.initialized && !loop.backend_events && !loop.backend_event_capacity && !loop.backend_active_count)
	{
		loop.backend_handle = (NativeHandle)-1;
		loop.wake_handle = (NativeHandle)-1;
		loop.wake_write_handle = (NativeHandle)-1;
		return;
	}

	if ((int)loop.wake_handle >= 0)
	{
		(void)libc::close((int)loop.wake_handle);
	}
	if ((int)loop.backend_handle >= 0)
	{
		(void)libc::close((int)loop.backend_handle);
	}
	alloc::free(loop.allocator, loop.backend_events);
	loop.backend_handle = (NativeHandle)-1;
	loop.wake_handle = (NativeHandle)-1;
	loop.wake_write_handle = (NativeHandle)-1;
	loop.backend_events = null;
	loop.backend_event_capacity = 0;
	loop.backend_active_count = 0;
}

<*
 Submit a borrowed-handle watch operation to epoll.

 Epoll stores the caller-owned `Header*` directly in `data.ptr`, avoiding a
 completion table lookup on the hot event path.

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
 @return ? nova::BACKEND_FAILED : "epoll_ctl add failed"
*>
fn Ref? watch_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	NativeHandle handle,
	uint interests,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;
	if (!(interests & (nova::READY_READABLE | nova::READY_WRITABLE))) return nova::INVALID_STATE~;

	linux::EpollEvent event;
	event.events = linux_events_from_interests(interests);
	event.data.ptr = op;

	if (linux::epoll_ctl((int)loop.backend_handle, (int)linux::EPOLL_CTL_ADD, (int)handle, &event) < 0)
	{
		return nova::BACKEND_FAILED~;
	}

	op::init_header(op, Kind.WATCH, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, interests);
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Submit a Linux pidfd-backed process wait operation to epoll.

 The pidfd is owned by the process handle. This backend only reports readiness;
 `process.c3` still performs the native reap before invoking the user callback.

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
 @return ? nova::BACKEND_FAILED : "epoll_ctl add failed"
*>
fn Ref? process_wait_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;
	if ((int)handle < 0) return nova::INVALID_STATE~;

	linux::EpollEvent event;
	event.events = linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP;
	event.data.ptr = op;

	if (linux::epoll_ctl((int)loop.backend_handle, (int)linux::EPOLL_CTL_ADD, (int)handle, &event) < 0)
	{
		return nova::BACKEND_FAILED~;
	}

	op::init_header(op, Kind.PROCESS, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, nova::READY_READABLE);
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Arm the listener-owned accept driver operation.

 Public accept operations are queued on the listener. This internal operation is
 the only object attached to listener readiness, which keeps the fd registered
 persistently while still allowing many caller-owned accept completions.

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
 @return ? nova::BACKEND_FAILED : "epoll_ctl add failed"
*>
fn Ref? tcp_accept_driver_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	backend_register_tcp_listener(loop, watcher, handle)!;

	op::init_header(op, Kind.TCP_ACCEPT_DRIVER, loop, callback, owner, null);
	backend::attach_op_state(op, state, handle, watcher, nova::READY_READABLE);
	backend::backend_wait_read(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit one TCP connect operation to epoll or the ready queue.

 Immediate success or immediate semantic failure is queued without registering
 the descriptor. In-progress connects wait for writable/error readiness and are
 confirmed later through `SO_ERROR` by the TCP driver.

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
 @return ? nova::BACKEND_FAILED : "epoll_ctl add failed"
*>
fn Ref? tcp_connect_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	bool complete,
	fault status,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (!complete && loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	if (!complete) backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.TCP_CONNECT, loop, callback, owner, userdata);

	if (complete)
	{
		nova::queue_ready(loop, op, status);
		return op.to_ref();
	}

	backend::attach_op_state(op, state, handle, watcher, nova::READY_WRITABLE);
	backend::backend_wait_write(loop, watcher, op);

	return op.to_ref();
}

<*
 Submit one stream read operation to epoll.

 The caller-owned operation stores the borrowed buffer in typed stream storage.
 Epoll stores the embedded `Header*` directly and reports readiness as a
 proactor completion for the stream driver to execute one nonblocking read.

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
 @return ? nova::BACKEND_FAILED : "epoll_ctl add failed"
*>
fn Ref? stream_read_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.STREAM_READ, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, watcher, nova::READY_READABLE);
	backend::backend_wait_read(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit one stream write operation to epoll.

 The caller-owned operation stores the borrowed byte slice in the typed
 stream storage. Epoll stores the embedded `Header*` directly and reports
 writable/error readiness as a proactor completion.

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
 @return ? nova::BACKEND_FAILED : "epoll_ctl add failed"
*>
fn Ref? stream_write_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.STREAM_WRITE, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, watcher, nova::READY_WRITABLE);
	backend::backend_wait_write(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit one UDP receive operation to epoll.

 The caller-owned operation stores the borrowed receive buffer in the typed
 `udp::RecvOp`. Epoll stores the embedded `Header*` directly and reports
 readable/error readiness as a proactor completion.

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
 @return ? nova::BACKEND_FAILED : "epoll_ctl add failed"
*>
fn Ref? udp_recv_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.UDP_RECV, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, watcher, nova::READY_READABLE);
	backend::backend_wait_read(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit one UDP send operation to epoll or the ready queue.

 The caller-owned operation stores the borrowed byte slice and copied remote
 endpoint in the typed `udp::SendOp`. Epoll stores the embedded `Header*`
 directly only when the initial send would block; immediate send results are
 queued without backend registration.

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
 @return ? nova::BACKEND_FAILED : "epoll_ctl add failed"
*>
fn Ref? udp_send_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	bool complete,
	fault status,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (!complete && loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	if (!complete) backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.UDP_SEND, loop, callback, owner, userdata);
	if (!complete)
	{
		backend::attach_op_state(op, state, handle, watcher, nova::READY_WRITABLE);
		backend::backend_wait_write(loop, watcher, op);
	}

	if (complete) nova::queue_ready(loop, op, status);

	return op.to_ref();
}

<*
 Rearm a TCP accept operation after stale readiness found no accepted socket.

 @param loop : "Loop that owns the accept operation"
 @param op : "TCP accept or accept-driver operation to rearm"
 @require op.kind == Kind.TCP_ACCEPT || op.kind == Kind.TCP_ACCEPT_DRIVER : "Only TCP accept operations can be rearmed"
 @require op.loop == loop : "Accept operation must belong to this loop"
*>
fn void? tcp_accept_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_read(loop, state.watcher, op);
}

<*
 Rearm a stream read operation after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the read operation"
 @param op : "Stream read operation to rearm"
 @require op.kind == Kind.STREAM_READ : "Only stream read operations can be rearmed"
 @require op.loop == loop : "Read operation must belong to this loop"
*>
fn void? stream_read_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_read(loop, state.watcher, op);
}

<*
 Rearm a stream write operation after partial progress or stale writable readiness.

 @param loop : "Loop that owns the write operation"
 @param op : "Stream write operation to rearm"
 @require op.kind == Kind.STREAM_WRITE : "Only stream write operations can be rearmed"
 @require op.loop == loop : "Write operation must belong to this loop"
*>
fn void? stream_write_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_write(loop, state.watcher, op);
}

<*
 Rearm a UDP receive operation after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the receive operation"
 @param op : "UDP receive operation to rearm"
 @require op.kind == Kind.UDP_RECV : "Only UDP receive operations can be rearmed"
 @require op.loop == loop : "Receive operation must belong to this loop"
*>
fn void? udp_recv_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_read(loop, state.watcher, op);
}

<*
 Rearm a UDP send operation after stale readiness produced `WOULD_BLOCK`.

 @param loop : "Loop that owns the send operation"
 @param op : "UDP send operation to rearm"
 @require op.kind == Kind.UDP_SEND : "Only UDP send operations can be rearmed"
 @require op.loop == loop : "Send operation must belong to this loop"
*>
fn void? udp_send_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_write(loop, state.watcher, op);
}

<*
 Poll epoll and queue terminal backend completions.

 This hot path does not allocate. Stale events are ignored by checking the
 operation's loop, kind and active state before queuing a result.

 @param loop : "Loop that owns the epoll backend"
 @param timeout_ms : "epoll_wait timeout in milliseconds"
 @return "Number of backend events consumed"
*>
fn sz poll(Loop* loop, int timeout_ms) @inline @private
{
	if ((int)loop.backend_handle < 0 || loop.backend_event_capacity <= 0) return 0;

	linux::EpollEvent* events = (linux::EpollEvent*)loop.backend_events;
	int count = linux::epoll_wait((int)loop.backend_handle, events, (int)loop.backend_event_capacity, timeout_ms);
	if (count <= 0) return 0;

	sz progress = 0;
	for (int i = 0; i < count; i++)
	{
		if (!events[i].data.u64)
		{
			backend_drain_wake(loop);
			progress++;
			continue;
		}
		if (backend_event_is_watcher(&events[i]))
		{
			backend::Watcher* watcher = backend_event_watcher(&events[i]);
			progress += backend::backend_watcher_ready(loop, watcher, ready_flags_from_linux_events(events[i].events));
			continue;
		}

		Header* op = (Header*)events[i].data.ptr;
		if (op.loop != loop || op.state != State.OP_ACTIVE) continue;

		if (op.kind == Kind.WATCH || op.kind == Kind.PROCESS)
		{
			op.ready_flags = ready_flags_from_linux_events(events[i].events);
			backend_unregister_op(loop, op);
			nova::queue_ready(loop, op, nova::ok_status());
			progress++;
		}
	}
	return progress;
}

<*
 Remove an operation-owned descriptor from epoll and clear cached backend state.

 @param loop : "Loop that owns the epoll backend"
 @param op : "Header registered with epoll"
*>
fn void backend_unregister_op(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	if (!state) return;
	if (state.counted && (int)loop.backend_handle >= 0)
	{
		(void)linux::epoll_ctl((int)loop.backend_handle, (int)linux::EPOLL_CTL_DEL, (int)state.handle, null);
		backend::backend_mark_inactive(loop);
	}
	backend::reset_op_state(state);
}

<*
 Register a TCP listener watcher once and keep it in epoll until close.

 @param loop : "Loop that owns the epoll backend"
 @param watcher : "Persistent listener watcher"
 @param handle : "Native listener descriptor"
 @return ? nova::INVALID_STATE : "backend::Watcher is registered on another loop"
 @return ? nova::BUSY : "backend::Watcher still has active operations"
 @return ? nova::BACKEND_FAILED : "epoll_ctl add or modify failed"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "backend::Watcher pointer must not be null"
*>
fn void? backend_register_tcp_listener(Loop* loop, backend::Watcher* watcher, NativeHandle handle) @private
{
	if (watcher.registered)
	{
		if (watcher.loop != loop) return nova::INVALID_STATE~;
		if (watcher.handle == handle) return;
		if (watcher.read_op || watcher.write_op || watcher.read_counted || watcher.write_counted) return nova::BUSY~;
		(void)linux::epoll_ctl((int)loop.backend_handle, (int)linux::EPOLL_CTL_DEL, (int)watcher.handle, null);
		watcher.registered = false;
		watcher.ready_flags = 0;
	}

	linux::EpollEvent event;
	event.events = linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLET;
	backend_event_set_watcher(&event, watcher);

	backend_upsert_watcher_event(loop, handle, &event, watcher.registered)!;

	watcher.loop = loop;
	watcher.handle = handle;
	watcher.interests = nova::READY_READABLE;
	watcher.registered = true;
}

<*
 Register a stream watcher once with read and write readiness.

 @param loop : "Loop that owns the epoll backend"
 @param watcher : "Persistent stream watcher"
 @param handle : "Native stream descriptor"
 @return ? nova::INVALID_STATE : "backend::Watcher is registered on another loop"
 @return ? nova::BUSY : "backend::Watcher still has active operations"
 @return ? nova::BACKEND_FAILED : "epoll_ctl add or modify failed"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "backend::Watcher pointer must not be null"
*>
fn void? backend_register_stream(Loop* loop, backend::Watcher* watcher, NativeHandle handle) @private
{
	if (watcher.registered)
	{
		if (watcher.loop != loop) return nova::INVALID_STATE~;
		if (watcher.handle == handle) return;
		if (watcher.read_op || watcher.write_op || watcher.read_counted || watcher.write_counted) return nova::BUSY~;
		(void)linux::epoll_ctl((int)loop.backend_handle, (int)linux::EPOLL_CTL_DEL, (int)watcher.handle, null);
		watcher.registered = false;
		watcher.ready_flags = 0;
	}

	linux::EpollEvent event;
	event.events = linux::EPOLLIN | linux::EPOLLOUT | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP
		| linux::EPOLLET;
	backend_event_set_watcher(&event, watcher);

	backend_upsert_watcher_event(loop, handle, &event, watcher.registered)!;

	watcher.loop = loop;
	watcher.handle = handle;
	watcher.interests = nova::READY_READABLE | nova::READY_WRITABLE;
	watcher.registered = true;
}

<*
 Add or update an epoll watcher, retrying with the opposite operation when
 kernel state is already out of sync with local watcher state.

 @param loop : "Loop that owns the epoll backend"
 @param handle : "Native descriptor registered with epoll"
 @param event : "Epoll event payload"
 @param registered : "Whether local state expects an existing registration"
 @return ? nova::BACKEND_FAILED : "epoll_ctl add or modify failed"
 @require loop != null : "Loop pointer must not be null"
 @require event != null : "Epoll event pointer must not be null"
*>
fn void? backend_upsert_watcher_event(Loop* loop, NativeHandle handle, linux::EpollEvent* event, bool registered) @local
{
	int ctl_op = (int)linux::EPOLL_CTL_ADD;
	if (registered) ctl_op = (int)linux::EPOLL_CTL_MOD;
	if (linux::epoll_ctl((int)loop.backend_handle, ctl_op, (int)handle, event) >= 0) return;

	Errno err = libc::errno();
	if (ctl_op == (int)linux::EPOLL_CTL_MOD && err == ENOENT)
	{
		if (linux::epoll_ctl((int)loop.backend_handle, (int)linux::EPOLL_CTL_ADD, (int)handle, event) >= 0) return;
		return nova::BACKEND_FAILED~;
	}

	if (ctl_op == (int)linux::EPOLL_CTL_ADD && err == EEXIST)
	{
		if (linux::epoll_ctl((int)loop.backend_handle, (int)linux::EPOLL_CTL_MOD, (int)handle, event) >= 0) return;
		return nova::BACKEND_FAILED~;
	}

	return nova::BACKEND_FAILED~;
}

<*
 Remove a watcher from epoll and release any activity counted for attached operations.

 @param loop : "Loop that owns the watcher"
 @param watcher : "backend::Watcher to close"
*>
fn void watcher_close(Loop* loop, backend::Watcher* watcher) @inline @private
{
	if (watcher.read_counted) backend::backend_mark_inactive(loop);
	if (watcher.write_counted) backend::backend_mark_inactive(loop);

	if (watcher.registered && (int)loop.backend_handle >= 0)
	{
		(void)linux::epoll_ctl((int)loop.backend_handle, (int)linux::EPOLL_CTL_DEL, (int)watcher.handle, null);
	}
	*watcher = { };
}

<*
 Wake a loop blocked in epoll.

 Multiple wake calls may coalesce in the eventfd counter. A saturated
 nonblocking counter is treated as already-woken.

 @param loop : "Loop whose wake eventfd is signaled"
 @return ? nova::INVALID_STATE : "Wake source is not initialized"
 @return ? nova::BACKEND_FAILED : "eventfd write failed"
*>
fn void? wake(Loop* loop) @inline @private
{
	if ((int)loop.wake_handle < 0) return nova::INVALID_STATE~;

	ulong value = 1;
	bool done   = false;
	while (!done)
	{
		sz written = libc::write((int)loop.wake_handle, &value, (usz)ulong::size);
		if (written == (sz)ulong::size)
		{
			done = true;
			continue;
		}
		Errno err = libc::errno();
		if (err == EAGAIN)
		{
			done = true;
			continue;
		}
		if (err != EINTR) return nova::BACKEND_FAILED~;
	}
}

<*
 Drain all pending eventfd wake notifications.

 @param loop : "Loop whose wake eventfd is drained"
 @require loop != null : "Loop pointer must not be null"
*>
fn void backend_drain_wake(Loop* loop) @private
{
	if ((int)loop.wake_handle >= 0)
	{
		ulong value   = 0;
		bool draining = true;
		while (draining)
		{
			sz read = libc::read((int)loop.wake_handle, &value, (usz)ulong::size);
			if (read == (sz)ulong::size) continue;
			if (read < 0 && libc::errno() == EINTR) continue;
			draining = false;
		}
	}
}

<*
 Convert public watch interests into epoll readiness bits.

 @param interests : "Backend-neutral interest flags"
 @return "Linux epoll event mask"
*>
fn uint linux_events_from_interests(uint interests) @local
{
	uint events = 0;
	if (interests & nova::READY_READABLE) events |= linux::EPOLLIN;
	if (interests & nova::READY_WRITABLE) events |= linux::EPOLLOUT;
	events |= linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP;
	return events;
}

<*
 Convert epoll readiness bits into backend-neutral flags.

 @param events : "Linux epoll event mask"
 @return "Backend-neutral readiness flags"
*>
fn uint ready_flags_from_linux_events(uint events) @local
{
	uint flags = 0;
	if (events & linux::EPOLLIN) flags |= nova::READY_READABLE;
	if (events & linux::EPOLLOUT) flags |= nova::READY_WRITABLE;
	if (events & linux::EPOLLERR) flags |= nova::READY_ERROR;
	if (events & (linux::EPOLLHUP | linux::EPOLLRDHUP)) flags |= nova::READY_HANGUP;
	return flags;
}
