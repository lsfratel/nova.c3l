module nova::backend::uring @if(env::LINUX);

import std::core::mem, std::core::mem::alloc;
import libc;

import nova @norecurse;
import nova::op @public;
import nova::backend @public;

<*
 Create an eventfd counter used as the loop wake source, mirroring the epoll
 backend. Declared here as the libc wrapper because the `eventfd2` syscall number
 is architecture-specific.
*>
extern fn int eventfd(uint initval, int flags);

<*
 Initialize the io_uring backend for a loop.

 Sets up and maps the ring (the only mapping/allocation, both done here), opens a
 nonblocking close-on-exec eventfd wake source, and stages a multishot poll on it
 (submitted on the first `poll`). Submission depth follows `Options.max_events`
 (with a small floor) plus one slot for the wake source.

 @param loop : "Loop selecting the io_uring backend"
 @param caps : "Capabilities already probed during backend resolution"
 @return ? nova::BACKEND_FAILED : "Ring setup, mapping, eventfd or wake arming failed"
 @return ? mem::OUT_OF_MEMORY : "Ring state allocation failed"
*>
fn void? init(Loop* loop, Caps caps) @inline @private
{
	sz entries = loop.options.max_events + 1;
	if (entries < 8) entries = 8;

	UringState[] arr = alloc::new_array_try(loop.allocator, UringState, 1)!;
	UringState* st   = &arr[0];

	if (!st.init((uint)entries))
	{
		alloc::free(loop.allocator, arr.ptr);
		return nova::BACKEND_FAILED~;
	}

	st.cap_recv = caps.recv;
	st.cap_send = caps.send;
	st.cap_accept = caps.accept;
	st.cap_connect = caps.connect;
	st.cap_recvmsg = caps.recvmsg;
	st.cap_sendmsg = caps.sendmsg;

	int wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	if (wake_fd < 0)
	{
		st.destroy();
		alloc::free(loop.allocator, arr.ptr);
		return nova::BACKEND_FAILED~;
	}

	if (!st.stage_poll(wake_fd, POLLIN, URING_WAKE_DATA, true))
	{
		(void)libc::close(wake_fd);
		st.destroy();
		alloc::free(loop.allocator, arr.ptr);
		return nova::BACKEND_FAILED~;
	}

	loop.backend_uring = st;
	loop.backend_handle = (NativeHandle)st.ring_fd;
	loop.wake_handle = (NativeHandle)wake_fd;
	loop.wake_write_handle = (NativeHandle)-1;
}

<*
 Destroy the io_uring backend, unmapping the ring, closing the ring and wake fds,
 and freeing ring state. Safe on a loop that never finished io_uring init.

 @param loop : "Loop whose io_uring backend is released"
*>
fn void destroy(Loop* loop) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	if ((int)loop.wake_handle >= 0) (void)libc::close((int)loop.wake_handle);
	if (st)
	{
		st.destroy();
		alloc::free(loop.allocator, st);
	}
	loop.backend_uring = null;
	loop.backend_handle = (NativeHandle)-1;
	loop.wake_handle = (NativeHandle)-1;
	loop.wake_write_handle = (NativeHandle)-1;
}

<*
 Wait for and drain io_uring completions.

 Blocks in `io_uring_enter` until a completion arrives or the timer-derived
 timeout elapses (via `EXT_ARG`); a zero timeout reaps without blocking. Each
 completion is dispatched, then the completion ring is fully drained.

 @param loop : "Loop owning the io_uring backend"
 @param timeout_ms : "Wait budget: negative blocks, zero polls, positive bounds the wait"
 @return "Number of completions consumed"
*>
fn sz poll(Loop* loop, int timeout_ms) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	if (!st) return 0;

	uint flags        = IORING_ENTER_GETEVENTS;
	uint min_complete = 1;
	void* argp        = null;
	usz argsz         = 0;
	IoUringGeteventsArg arg;
	KernelTimespec ts;

	if (timeout_ms == 0)
	{
		min_complete = 0;
	}
	else if (timeout_ms > 0)
	{
		ts.sec = (long)(timeout_ms / 1000);
		ts.nsec = (long)((timeout_ms % 1000) * 1000000);
		arg.sigmask = 0;
		arg.sigmask_sz = 0;
		arg.pad = 0;
		arg.ts = (ulong)(uptr)&ts;
		argp = &arg;
		argsz = IoUringGeteventsArg::size;
		flags |= IORING_ENTER_EXT_ARG;
	}

	(void)st.flush(min_complete, flags, argp, argsz);

	uint head   = *st.cq_head;
	uint tail   = @atomic_load(*st.cq_tail, mem::AtomicOrdering.ACQUIRE);
	sz progress = 0;
	while (head != tail)
	{
		dispatch_cqe(loop, st, &st.cqes[head & st.cq_mask]);
		head++;
		progress++;
	}
	if (progress > 0) @atomic_store(*st.cq_head, head, mem::AtomicOrdering.RELEASE);
	return progress;
}

<*
 Dispatch one completion.

 Routes by `user_data`: the wake source (drained and re-armed if its multishot
 poll ended), persistent stream/listener watchers (delivered to the shared
 readiness machine, re-armed only on a clean multishot end), completion-mode I/O
 operations (`RECV`/`SEND`/... — the CQE result is cached on the op and queued; a
 cancelled op, left `OP_CANCELLING`, is finalized with `CANCELLED`), and one-shot
 readiness polls (udp/watch/process — queued as a completion). Negative results
 (`ECANCELED`, poll errors) and bare cancel completions (`POLL_REMOVE`/
 `ASYNC_CANCEL`, `user_data == 0`) are handled without re-arming or spurious
 readiness.

 @param loop : "Loop owning the backend"
 @param st : "Mapped ring state"
 @param cqe : "Completion to dispatch"
 @require loop != null : "Loop pointer must not be null"
 @require st != null : "Ring state pointer must not be null"
 @require cqe != null : "Completion pointer must not be null"
*>
fn void dispatch_cqe(Loop* loop, UringState* st, IoUringCqe* cqe) @private
{
	ulong ud     = cqe.user_data;
	bool ok      = cqe.res >= 0;
	bool armed   = ((uint)cqe.flags & IORING_CQE_F_MORE) != 0;
	uint revents = ok ? (uint)cqe.res : 0;

	if (ud == 0) return;

	if (ud == URING_WAKE_DATA)
	{
		drain_wake(loop);
		if (ok && !armed && (int)loop.wake_handle >= 0)
		{
			(void)st.stage_poll((int)loop.wake_handle, POLLIN, URING_WAKE_DATA, true);
		}
		return;
	}

	if (ud & URING_WATCHER_TAG)
	{
		backend::Watcher* watcher = (backend::Watcher*)(uptr)(ud & ~(ulong)URING_WATCHER_TAG);
		if (ok) backend::backend_watcher_ready(loop, watcher, ready_flags_from_poll(revents));
		if (ok && !armed) rearm_watcher(loop, st, watcher);
		return;
	}

	Header* op = (Header*)(uptr)ud;
	if (op.loop != loop) return;

	if (op.backend && op.backend.completion)
	{
		bool terminating = op.state == State.OP_CANCELLING || op.state == State.OP_CLOSED;
		if (op.state != State.OP_ACTIVE && !terminating) return;
		op.backend.result = (sz)cqe.res;
		if (op.backend.counted)
		{
			backend::backend_mark_inactive(loop);
			op.backend.counted = false;
		}
		nova::queue_ready(loop, op, terminating ? op.terminal_status : nova::ok_status());
		return;
	}

	if (op.state != State.OP_ACTIVE) return;

	if (op.kind == Kind.WATCH || op.kind == Kind.PROCESS)
	{
		op.ready_flags = ok ? ready_flags_from_poll(revents) : nova::READY_ERROR;
		unregister_fired_op(loop, op);
		nova::queue_ready(loop, op, nova::ok_status());
	}
}

<*
 Clear a fired one-shot operation's backend state without a `POLL_REMOVE`.

 The kernel auto-removes a one-shot poll when it completes, so only the active
 count and operation state need releasing; staging a `POLL_REMOVE` here would just
 cost an extra SQE and an ignored `ENOENT` completion. The `POLL_REMOVE` path
 (`backend_unregister_op`) is still used when an operation is cancelled before it
 fires.

 @param loop : "Loop owning the operation"
 @param op : "Operation whose one-shot poll just completed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void unregister_fired_op(Loop* loop, Header* op) @private
{
	backend::OpState* state = op.backend;
	if (!state) return;
	if (state.counted) backend::backend_mark_inactive(loop);
	backend::reset_op_state(state);
}

<*
 Re-arm a watcher's multishot poll after the kernel terminated it (no more CQEs),
 if the watcher is still registered on this loop.

 @param loop : "Loop owning the watcher"
 @param st : "Mapped ring state"
 @param watcher : "Watcher whose poll may need re-arming"
 @require loop != null : "Loop pointer must not be null"
 @require st != null : "Ring state pointer must not be null"
 @require watcher != null : "Watcher pointer must not be null"
*>
fn void rearm_watcher(Loop* loop, UringState* st, backend::Watcher* watcher) @private
{
	if (!watcher.registered || watcher.loop != loop) return;
	(void)st.stage_poll((int)watcher.handle, poll_events_from_interests(watcher.interests), watcher_tag(watcher), true);
}

<*
 Convert backend-neutral interests into the requested poll event mask.

 @param interests : "Readiness interests"
 @return "poll(2) event mask"
*>
fn uint poll_events_from_interests(uint interests) @private
{
	uint events = 0;
	if (interests & nova::READY_READABLE) events |= POLLIN;
	if (interests & nova::READY_WRITABLE) events |= POLLOUT;
	return events;
}

<*
 Convert poll(2) revents into backend-neutral readiness flags.

 @param revents : "poll(2) returned events"
 @return "Backend-neutral readiness flags"
*>
fn uint ready_flags_from_poll(uint revents) @private
{
	uint flags = 0;
	if (revents & POLLIN) flags |= nova::READY_READABLE;
	if (revents & POLLOUT) flags |= nova::READY_WRITABLE;
	if (revents & POLLERR) flags |= nova::READY_ERROR;
	if (revents & (POLLHUP | POLLRDHUP)) flags |= nova::READY_HANGUP;
	return flags;
}

<*
 Tag a watcher pointer as io_uring `user_data`.

 @param watcher : "Watcher to tag"
 @return "Tagged user_data"
 @require watcher != null : "Watcher pointer must not be null"
*>
fn ulong watcher_tag(backend::Watcher* watcher) @private => (ulong)((uptr)watcher | (uptr)URING_WATCHER_TAG);

<*
 Wake a loop blocked in `io_uring_enter` by signaling the eventfd wake source.

 @param loop : "Loop to wake"
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
fn void drain_wake(Loop* loop) @private
{
	if ((int)loop.wake_handle < 0) return;

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

<*
 io_uring readiness engine.

 These functions mirror the epoll engine's readiness state machine (same
 watcher/operation model, counting and stale-event guards) but register interest
 with multishot/one-shot `POLL_ADD` and cancel with `POLL_REMOVE` instead of
 `epoll_ctl`. They reuse the backend-neutral machinery in `interest.c3`
 (`backend_wait_read`/`backend_wait_write`/`backend_watcher_ready`/
 `attach_op_state`/`reset_op_state`/`backend_mark_inactive`). Fault semantics match
 the correspondingly-named epoll entry points.
*>
fn void? backend_register_stream(Loop* loop, backend::Watcher* watcher, NativeHandle handle) @private
{
	UringState* st = (UringState*)loop.backend_uring;
	if (watcher.registered)
	{
		if (watcher.loop != loop) return nova::INVALID_STATE~;
		if (watcher.handle == handle) return;
		if (watcher.read_op || watcher.write_op || watcher.read_counted || watcher.write_counted) return nova::BUSY~;
		(void)st.stage_poll_remove(watcher_tag(watcher));
		watcher.registered = false;
		watcher.ready_flags = 0;
	}
	if (!st.stage_poll((int)handle, POLLIN | POLLOUT, watcher_tag(watcher), true))
	{
		return nova::BACKEND_FAILED~;
	}
	watcher.loop = loop;
	watcher.handle = handle;
	watcher.interests = nova::READY_READABLE | nova::READY_WRITABLE;
	watcher.registered = true;
}

<*
 Register a TCP listener watcher with a multishot readable poll.
*>
fn void? backend_register_tcp_listener(Loop* loop, backend::Watcher* watcher, NativeHandle handle) @private
{
	UringState* st = (UringState*)loop.backend_uring;
	if (watcher.registered)
	{
		if (watcher.loop != loop) return nova::INVALID_STATE~;
		if (watcher.handle == handle) return;
		if (watcher.read_op || watcher.write_op || watcher.read_counted || watcher.write_counted) return nova::BUSY~;
		(void)st.stage_poll_remove(watcher_tag(watcher));
		watcher.registered = false;
		watcher.ready_flags = 0;
	}
	if (!st.stage_poll((int)handle, POLLIN, watcher_tag(watcher), true))
	{
		return nova::BACKEND_FAILED~;
	}
	watcher.loop = loop;
	watcher.handle = handle;
	watcher.interests = nova::READY_READABLE;
	watcher.registered = true;
}

<*
 Cancel an operation-owned poll and clear its backend state.
*>
fn void backend_unregister_op(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	if (!state) return;
	if (state.counted)
	{
		UringState* st = (UringState*)loop.backend_uring;
		(void)st.stage_poll_remove((ulong)(uptr)op);
		backend::backend_mark_inactive(loop);
	}
	backend::reset_op_state(state);
}

<*
 Cancel a watcher's poll and release activity counted for its attached operations.
*>
fn void watcher_close(Loop* loop, backend::Watcher* watcher) @inline @private
{
	if (watcher.read_counted) backend::backend_mark_inactive(loop);
	if (watcher.write_counted) backend::backend_mark_inactive(loop);
	if (watcher.registered)
	{
		UringState* st = (UringState*)loop.backend_uring;
		(void)st.stage_poll_remove(watcher_tag(watcher));
	}
	*watcher = { };
}

<*
 Submit a borrowed-handle watch operation as a one-shot poll.
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

	UringState* st = (UringState*)loop.backend_uring;
	if (!st.stage_poll(
		(int)handle,
		poll_events_from_interests(interests),
		(ulong)(uptr)op,
		false
	)) return nova::BACKEND_FAILED~;

	op::init_header(op, Kind.WATCH, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, interests);
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Submit a pidfd-backed process wait as a one-shot readable poll.
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

	UringState* st = (UringState*)loop.backend_uring;
	if (!st.stage_poll((int)handle, POLLIN, (ulong)(uptr)op, false))
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
 Arm the listener-owned accept driver on a multishot readable watcher poll.
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
 Submit a TCP connect, queuing immediate results or waiting on writable readiness.
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
 Submit a stream read, waiting on a multishot stream watcher's readable readiness.
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
 Submit a stream write, waiting on a multishot stream watcher's writable readiness.
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
 Submit a one-shot UDP receive readiness operation.
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
 Submit a UDP send, queuing immediate results or waiting on writable readiness.
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
 Rearm a TCP accept driver after stale readiness (the multishot poll stays armed).
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
 Rearm a stream read after stale readiness (the multishot poll stays armed).
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
 Rearm a stream write after partial progress (the multishot poll stays armed).
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
 Rearm a one-shot UDP receive poll after stale readiness.
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
 Rearm a one-shot UDP send poll after stale readiness.
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
 io_uring completion-mode stream I/O.

 When the kernel supports `RECV`/`SEND` (probed in `init`, cached in
 `UringState.cap_recv`/`cap_send`), stream reads and writes are submitted as the
 actual I/O operation: the kernel reads into / writes from the caller buffer and
 reports the byte count (or `-errno`) in the CQE. The typed dispatcher consumes
 `OpState.result` directly, without a `recv`/`send` syscall. Falls back to the
 readiness path (`stream_read_submit`/`stream_write_submit`) when an opcode is
 missing.
*>
fn bool stream_completion_recv(Loop* loop) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	return st && st.cap_recv;
}

<*
 Whether stream writes run in io_uring completion mode for this loop.
*>
fn bool stream_completion_send(Loop* loop) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	return st && st.cap_send;
}

<*
 Submit a stream read as an `IORING_OP_RECV` completion into `buffer`.
*>
fn Ref? stream_recv_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	NativeHandle handle,
	char[] buffer,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	UringState* st = (UringState*)loop.backend_uring;
	op::init_header(op, Kind.STREAM_READ, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, nova::READY_READABLE);
	state.completion = true;
	if (!st.stage_rw(IORING_OP_RECV, (int)handle, buffer, 0, (ulong)(uptr)op))
	{
		op::reset_header(op);
		return nova::BACKEND_FAILED~;
	}
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Submit a stream write as an `IORING_OP_SEND` completion from `bytes`.
*>
fn Ref? stream_send_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	NativeHandle handle,
	char[] bytes,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	UringState* st = (UringState*)loop.backend_uring;
	op::init_header(op, Kind.STREAM_WRITE, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, nova::READY_WRITABLE);
	state.completion = true;
	if (!st.stage_rw(IORING_OP_SEND, (int)handle, bytes, MSG_NOSIGNAL, (ulong)(uptr)op))
	{
		op::reset_header(op);
		return nova::BACKEND_FAILED~;
	}
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Re-submit a stream read for the still-needed slice (the previous `RECV` returned
 fewer than `min_bytes`).
*>
fn void? stream_recv_resubmit(Loop* loop, Header* op, char[] buffer) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null);
	UringState* st = (UringState*)loop.backend_uring;
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	state.completion = true;
	if (!st.stage_rw(IORING_OP_RECV, (int)state.handle, buffer, 0, (ulong)(uptr)op)) return nova::BACKEND_FAILED~;
	loop.backend_active_count++;
	state.counted = true;
}

<*
 Re-submit a stream write for the still-unsent slice (partial `SEND`).
*>
fn void? stream_send_resubmit(Loop* loop, Header* op, char[] bytes) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null);
	UringState* st = (UringState*)loop.backend_uring;
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	state.completion = true;
	if (!st.stage_rw(
		IORING_OP_SEND,
		(int)state.handle,
		bytes,
		MSG_NOSIGNAL,
		(ulong)(uptr)op
	)) return nova::BACKEND_FAILED~;
	loop.backend_active_count++;
	state.counted = true;
}

<*
 Cancel an in-flight completion operation by submitting `ASYNC_CANCEL`.

 The operation stays active and counted, and its caller buffer stays pinned, until
 the target CQE arrives as `-ECANCELED` (or its real result if it already
 completed) and `dispatch_cqe` finalizes it. The cancel SQE uses `user_data == 0`,
 so its own completion is ignored.

 @param loop : "Loop owning the io_uring backend"
 @param op : "Completion operation to cancel"
*>
fn void cancel_completion(Loop* loop, Header* op) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	if (st) (void)st.stage_cancel((ulong)(uptr)op);
}

<*
 io_uring completion-mode accept and connect.

 When the kernel supports `ACCEPT`/`CONNECT` (probed in `init`, cached in
 `UringState.cap_accept`/`cap_connect`), `tcp::accept` and `tcp::connect` submit the
 real operation: the kernel accepts/connects and reports the accepted descriptor or
 `0`/`-errno` in the CQE. The typed dispatcher consumes `OpState.result` directly.
 Falls back to the readiness driver / `SO_ERROR` path when an opcode is missing.
*>
fn bool stream_completion_accept(Loop* loop) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	return st && st.cap_accept;
}

<*
 Whether TCP connects run in io_uring completion mode for this loop.
*>
fn bool stream_completion_connect(Loop* loop) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	return st && st.cap_connect;
}

<*
 Submit a TCP accept as an `IORING_OP_ACCEPT` completion. The kernel writes the
 peer address into `addr_ptr`/`socklen_ptr` and reports the accepted descriptor in
 the CQE.
*>
fn Ref? tcp_accept_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	NativeHandle listener,
	ulong addr_ptr,
	ulong socklen_ptr,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	UringState* st = (UringState*)loop.backend_uring;
	op::init_header(op, Kind.TCP_ACCEPT, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, listener, null, nova::READY_READABLE);
	state.completion = true;
	if (!st.stage_accept((int)listener, addr_ptr, socklen_ptr, SOCK_NONBLOCK | SOCK_CLOEXEC, (ulong)(uptr)op))
	{
		op::reset_header(op);
		return nova::BACKEND_FAILED~;
	}
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Submit a TCP connect as an `IORING_OP_CONNECT` completion to the sockaddr at
 `addr_ptr` (length `addrlen`). The CQE result is `0` on success or `-errno`.
*>
fn Ref? tcp_connect_complete_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	NativeHandle handle,
	ulong addr_ptr,
	ulong addrlen,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	UringState* st = (UringState*)loop.backend_uring;
	op::init_header(op, Kind.TCP_CONNECT, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, nova::READY_WRITABLE);
	state.completion = true;
	if (!st.stage_connect((int)handle, addr_ptr, addrlen, (ulong)(uptr)op))
	{
		op::reset_header(op);
		return nova::BACKEND_FAILED~;
	}
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 io_uring completion-mode message I/O (`RECVMSG`/`SENDMSG`).

 When the kernel supports `RECVMSG`/`SENDMSG` (probed in `init`, cached in
 `UringState.cap_recvmsg`/`cap_sendmsg`), UDP receive/send and vectored stream
 read/write submit the real scatter/gather message: the kernel performs the I/O
 through the caller `msghdr` and reports the byte count (or `-errno`) in the CQE.
*>
fn bool stream_completion_recvmsg(Loop* loop) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	return st && st.cap_recvmsg;
}

<*
 Whether `SENDMSG` completion is available for this loop.
*>
fn bool stream_completion_sendmsg(Loop* loop) @inline @private
{
	UringState* st = (UringState*)loop.backend_uring;
	return st && st.cap_sendmsg;
}

<*
 Submit one `IORING_OP_RECVMSG` completion for the caller `msghdr` at `msg_ptr`.
 Used by UDP receive (peer in `msg_name`) and vectored stream reads (iovec array).
*>
fn Ref? recvmsg_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	Kind kind,
	NativeHandle handle,
	ulong msg_ptr,
	uint flags,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	UringState* st = (UringState*)loop.backend_uring;
	op::init_header(op, kind, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, nova::READY_READABLE);
	state.completion = true;
	if (!st.stage_msg(IORING_OP_RECVMSG, (int)handle, msg_ptr, flags, (ulong)(uptr)op))
	{
		op::reset_header(op);
		return nova::BACKEND_FAILED~;
	}
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Submit one `IORING_OP_SENDMSG` completion for the caller `msghdr` at `msg_ptr`.
 Used by UDP send (peer in `msg_name`) and vectored stream writes (iovec array).
*>
fn Ref? sendmsg_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	Kind kind,
	NativeHandle handle,
	ulong msg_ptr,
	uint flags,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	UringState* st = (UringState*)loop.backend_uring;
	op::init_header(op, kind, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, nova::READY_WRITABLE);
	state.completion = true;
	if (!st.stage_msg(IORING_OP_SENDMSG, (int)handle, msg_ptr, flags, (ulong)(uptr)op))
	{
		op::reset_header(op);
		return nova::BACKEND_FAILED~;
	}
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Re-submit a vectored stream `RECVMSG` for the still-needed segments after a short
 read (the caller `msghdr` was updated to the remaining iovec).
*>
fn void? recvmsg_resubmit(Loop* loop, Header* op, ulong msg_ptr, uint flags) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null);
	UringState* st = (UringState*)loop.backend_uring;
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	state.completion = true;
	if (!st.stage_msg(
		IORING_OP_RECVMSG,
		(int)state.handle,
		msg_ptr,
		flags,
		(ulong)(uptr)op
	)) return nova::BACKEND_FAILED~;
	loop.backend_active_count++;
	state.counted = true;
}

<*
 Re-submit a vectored stream `SENDMSG` for the still-unsent segments after a partial
 write (the caller `msghdr` was updated to the remaining iovec).
*>
fn void? sendmsg_resubmit(Loop* loop, Header* op, ulong msg_ptr, uint flags) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null);
	UringState* st = (UringState*)loop.backend_uring;
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	state.completion = true;
	if (!st.stage_msg(
		IORING_OP_SENDMSG,
		(int)state.handle,
		msg_ptr,
		flags,
		(ulong)(uptr)op
	)) return nova::BACKEND_FAILED~;
	loop.backend_active_count++;
	state.counted = true;
}
