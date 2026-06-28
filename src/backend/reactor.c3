module nova::backend;

import nova @norecurse;
import nova::op @public;

<*
 Persistent backend readiness state owned by a stream-like handle.

 A watcher separates native readiness from proactor operation completion. The
 fd can stay registered while read/write/accept operations come and go without
 allocation or per-operation backend add/delete churn.
*>
struct Watcher @private
{
	Loop* loop;
	NativeHandle handle;
	Header* read_op;
	Header* write_op;
	uint ready_flags;
	uint interests;
	bool registered;
	bool read_counted;
	bool write_counted;
}

<*
 Per-operation backend readiness state.

 This state is embedded only in operation types that can wait on native
 readiness. `Header.backend` points here from backend attachment until the
 terminal header reset, including ready callbacks that may rearm the operation.

 `completion` marks an operation submitted in io_uring completion mode (the kernel
 performs the I/O); `result` then carries the CQE result (`bytes`/`accepted-fd`/`0`,
 or `-errno`) for the typed dispatcher to deliver without redoing the syscall.
*>
struct OpState @private
{
	NativeHandle handle;
	Watcher* watcher;
	uint interest;
	bool counted;
	bool completion;
	sz result;
}

<*
 Scatter/gather segment, ABI-identical to a C3 slice (`{ptr, len}`) and to the
 native `struct iovec`, so a `char[][]` vector array can be reinterpreted as an
 `IoVec` array without copying.
*>
struct IoVec
{
	void* base;
	usz len;
}

<*
 Message header for completion-mode vectored stream I/O (`RECVMSG`/`SENDMSG`),
 laid out to match the Linux `struct msghdr`. Owned by the typed stream operation
 (cross-platform storage) and only ever populated/submitted on the io_uring path.
*>
struct Msghdr
{
	void* name;
	uint namelen;
	IoVec* iov;
	usz iovlen;
	void* control;
	usz controllen;
	int flags;
}

<*
 Clear per-operation backend state after detach, completion or failed submit.

 @param state : "Backend state to clear"
 @require state != null : "Backend state pointer must not be null"
*>
fn void reset_op_state(OpState* state) @private
{
	*state = { };
}

<*
 Populate a `Msghdr` for a vectored stream transfer over `vectors`, resuming from
 `index`/`offset`.

 When `offset` is zero the remaining `vectors[index:]` are reinterpreted in place as
 the iovec array (no copy). When a transfer stopped mid-segment (`offset > 0`), a
 single adjusted iovec for that segment's remainder is written into `scratch`; the
 next segments are picked up on the following resubmit once the cursor realigns to a
 boundary.

 @param msg : "Caller msghdr storage to populate"
 @param scratch : "Caller iovec storage used for a mid-segment remainder"
 @param vectors : "Caller scatter/gather segments"
 @param index : "First unconsumed segment"
 @param offset : "Bytes already consumed in `vectors[index]`"
 @require msg != null : "msghdr pointer must not be null"
 @require scratch != null : "scratch iovec pointer must not be null"
 @require index < vectors.len : "Segment index must be within the vector array"
 @require offset == 0 || offset < vectors[index].len : "Mid-segment offset must lie within the segment"
*>
fn void msghdr_init_vectors(Msghdr* msg, IoVec* scratch, char[][] vectors, usz index, usz offset) @private
{
	msg.name = null;
	msg.namelen = 0;
	msg.control = null;
	msg.controllen = 0;
	msg.flags = 0;
	if (offset == 0)
	{
		msg.iov = (IoVec*)&vectors[index];
		msg.iovlen = vectors.len - index;
		return;
	}

	char[] current = vectors[index];
	*scratch = { .base = (void*)&current[offset], .len = current.len - offset };
	msg.iov = scratch;
	msg.iovlen = 1;
}

<*
 Report whether an operation was submitted in io_uring completion mode (the kernel
 performs the I/O). Lets the typed layer and the cancel path branch without naming
 the backend-private `OpState` fields.

 @param op : "Operation header"
 @return "True when `op` carries a completion-mode backend state"
 @require op != null : "Header pointer must not be null"
*>
fn bool op_completion(Header* op) @private => op.backend != null && op.backend.completion;

<*
 Return the CQE result cached on a completion operation: bytes transferred, zero
 for EOF, or a negative errno.

 @param op : "Completion-mode operation header"
 @return "Cached CQE result"
 @require op != null : "Header pointer must not be null"
 @require op.backend != null : "Completion operation must carry backend state"
*>
fn sz op_completion_result(Header* op) @private => op.backend.result;

<*
 Attach per-operation backend state to a runtime header.

 @param op : "Operation header that owns the wait"
 @param state : "Caller-owned backend state embedded in the typed operation"
 @param handle : "Native descriptor registered for this wait"
 @param watcher : "Persistent watcher for stream-like waits, or null for one-shot waits"
 @param interest : "Readiness interest requested by this wait"
 @require op != null : "Header pointer must not be null"
 @require state != null : "Backend state pointer must not be null"
*>
fn void attach_op_state(Header* op, OpState* state, NativeHandle handle, Watcher* watcher, uint interest) @private
{
	state.handle = handle;
	state.watcher = watcher;
	state.interest = interest;
	state.counted = false;
	state.completion = false;
	state.result = 0;
	op.backend = state;
}

<*
 Remove backend interest owned by an active operation.

 @param loop : "Loop that owns the backend interest"
 @param op : "Header with possible backend interest"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void unregister_interest(Loop* loop, Header* op) @private
{
	if (!op.backend) return;
	if (op.backend.watcher)
	{
		backend_detach_watcher_op(loop, op);
		return;
	}

	if (op.kind == Kind.WATCH || op.kind == Kind.PROCESS)
	{
		backend_unregister_op(loop, op);
	}
}

<*
 Detach backend interest owned by a typed module's internal driver operation.

 @param loop : "Loop that owns the backend interest"
 @param op : "Internal driver operation"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void detach_interest(Loop* loop, Header* op) @private
{
	unregister_interest(loop, op);
}

<*
 Mark one backend operation as no longer active.

 @param loop : "Loop whose active backend count is decremented"
 @require loop != null : "Loop pointer must not be null"
*>
fn void backend_mark_inactive(Loop* loop) @private
{
	if (loop.backend_active_count > 0) loop.backend_active_count--;
}

<*
 Report whether readiness flags satisfy an operation interest.

 @param ready_flags : "Cached backend-neutral readiness flags"
 @param interest : "Header interest mask"
 @return "True when readiness satisfies the interest"
*>
fn bool backend_ready_matches(uint ready_flags, uint interest) @private
{
	if (ready_flags & (nova::READY_ERROR | nova::READY_HANGUP)) return true;
	return (ready_flags & interest) != 0;
}

<*
 Attach a read operation to a watcher or queue it immediately if readiness is cached.

 @param loop : "Loop that owns the watcher"
 @param watcher : "Persistent stream watcher"
 @param op : "Read operation to attach"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "Watcher pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void backend_wait_read(Loop* loop, Watcher* watcher, Header* op) @private
{
	OpState* state = op.backend;
	always_assert(state != null);
	watcher.read_op = op;
	state.watcher = watcher;
	state.interest = nova::READY_READABLE;
	state.counted = false;

	if (!backend_ready_matches(watcher.ready_flags, nova::READY_READABLE))
	{
		watcher.read_counted = true;
		state.counted = true;
		loop.backend_active_count++;
		return;
	}

	backend_queue_watcher_op(loop, watcher, op, nova::READY_READABLE, watcher.ready_flags);
}

<*
 Attach a write operation to a watcher or queue it immediately if readiness is cached.

 @param loop : "Loop that owns the watcher"
 @param watcher : "Persistent stream watcher"
 @param op : "Write operation to attach"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "Watcher pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void backend_wait_write(Loop* loop, Watcher* watcher, Header* op) @private
{
	OpState* state = op.backend;
	always_assert(state != null);
	watcher.write_op = op;
	state.watcher = watcher;
	state.interest = nova::READY_WRITABLE;
	state.counted = false;

	if (!backend_ready_matches(watcher.ready_flags, nova::READY_WRITABLE))
	{
		watcher.write_counted = true;
		state.counted = true;
		loop.backend_active_count++;
		return;
	}

	backend_queue_watcher_op(loop, watcher, op, nova::READY_WRITABLE, watcher.ready_flags);
}

<*
 Move a watcher-bound operation to the ready queue and reconcile active counts.

 @param loop : "Loop that owns the watcher"
 @param watcher : "Persistent stream watcher"
 @param op : "Attached operation to queue, or null when no operation is waiting"
 @param interest : "Read or write interest being satisfied"
 @param ready_flags : "Readiness flags delivered to the operation"
 @return "True when an operation was queued, false when none was waiting"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "Watcher pointer must not be null"
*>
fn bool backend_queue_watcher_op(Loop* loop, Watcher* watcher, Header* op, uint interest, uint ready_flags) @private
{
	if (!op || op.state != State.OP_ACTIVE) return false;

	if (interest == nova::READY_READABLE)
	{
		if (watcher.read_counted) backend_mark_inactive(loop);
		watcher.read_counted = false;
		watcher.read_op = null;
	}
	else if (interest == nova::READY_WRITABLE)
	{
		if (watcher.write_counted) backend_mark_inactive(loop);
		watcher.write_counted = false;
		watcher.write_op = null;
	}

	if (op.backend) op.backend.counted = false;
	op.ready_flags = ready_flags;
	nova::queue_ready(loop, op, nova::ok_status());
	return true;
}

<*
 Cache watcher readiness and queue any matching attached operations.

 Returns the number of operations actually queued so the poll loop counts only
 real progress: a readiness event that matches no waiting operation (e.g. a
 spurious writable edge on a recv-only socket, which kqueue delivers as its own
 kevent) must not count as progress, or a single `run(ONCE)` could return before
 the awaited operation is dispatched.

 @param loop : "Loop that owns the watcher"
 @param watcher : "Persistent stream or listener watcher, or null for stale userdata"
 @param ready_flags : "Backend-neutral readiness flags to cache"
 @return "Number of attached operations queued ready (0, 1, or 2)"
 @require loop != null : "Loop pointer must not be null"
*>
fn sz backend_watcher_ready(Loop* loop, Watcher* watcher, uint ready_flags) @private
{
	if (!watcher || !watcher.registered || watcher.loop != loop) return 0;

	watcher.ready_flags |= ready_flags;
	sz queued = 0;
	if (backend_ready_matches(ready_flags, nova::READY_READABLE)
		&& backend_queue_watcher_op(loop, watcher, watcher.read_op, nova::READY_READABLE, ready_flags)) queued++;
	if (backend_ready_matches(ready_flags, nova::READY_WRITABLE)
		&& backend_queue_watcher_op(loop, watcher, watcher.write_op, nova::READY_WRITABLE, ready_flags)) queued++;
	return queued;
}

<*
 Clear readiness bits after stream code has consumed them.

 @param op : "Header with an attached backend watcher"
 @param ready_flags : "Readiness bits to clear"
 @require op != null : "Header pointer must not be null"
*>
fn void stream_ready_consumed(Header* op, uint ready_flags) @private
{
	if (op.backend && op.backend.watcher)
	{
		op.backend.watcher.ready_flags &= ~(ready_flags | nova::READY_ERROR | nova::READY_HANGUP);
	}
}

<*
 Detach an operation from its watcher without closing the native descriptor.

 @param loop : "Loop that owns the watcher"
 @param op : "Header to detach"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void backend_detach_watcher_op(Loop* loop, Header* op) @private
{
	OpState* state = op.backend;
	if (!state) return;
	Watcher* watcher = state.watcher;
	if (!watcher) return;

	if (watcher.read_op == op)
	{
		watcher.read_op = null;
		if (watcher.read_counted && state.counted) backend_mark_inactive(loop);
		watcher.read_counted = false;
	}
	if (watcher.write_op == op)
	{
		watcher.write_op = null;
		if (watcher.write_counted && state.counted) backend_mark_inactive(loop);
		watcher.write_counted = false;
	}

	reset_op_state(state);
}
