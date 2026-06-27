module nova::signal;

import nova @norecurse;
import nova::op @public;

<*
 Callback invoked on the loop owner thread when a signal is delivered.

 Signal callbacks run while `op.header` is still active, so the same signal storage
 is not reusable from inside the callback. Submission userdata is delivered
 through the `userdata` argument; `op.header.userdata` is cleared before the
 callback runs.

 @param loop : "Loop dispatching the signal"
 @param op : "Signal operation storage"
 @param result : "Signal result valid only during the callback"
 @param userdata : "Opaque pointer captured at submission"
*>
alias Callback = fn void(Loop* loop, SignalOp* op, SignalResult* result, void* userdata);

<*
 Result delivered when a process signal is observed or the watcher reaches a
 terminal state.

 `count` may be greater than one when multiple equal signals coalesce before
 the owner loop drains them. It is zero when `error.status` is non-null.
*>
struct SignalResult
{
	ErrorInfo error;
	CInt signum;
	ulong count;
}

<*
 Signal watcher options.

 `oneshot` stops the operation after the first delivered signal. Signal numbers
 are native platform signal values such as `libc::SIGINT` or `libc::SIGTERM`.
*>
struct Options
{
	CInt signum;
	bool oneshot;
}

<*
 Caller-owned signal operation storage.

 `header` must be the first field so the runtime can pass the embedded
 `op::Header*` through the ready queue and recover this typed operation in
 the dispatch trampoline without an allocation or table lookup.
*>
struct SignalOp
{
	inline op::Header header;
	SignalResult result;
	SignalOp* loop_next;
	SignalOp* loop_prev;
	SignalOp* global_next;
	SignalOp* global_prev;
	uint pending;
	ulong ready_count;
	CInt signum;
	bool oneshot;
	bool registered;
	Callback callback;
}

<*
 Initialize caller-owned signal operation storage.

 @param [&inout] self : "Signal operation storage"
 @return "Initialized signal operation"
 @require self.header.state == State.OP_FREE : "Signal operation must not be active"
 @ensure self.header.state == State.OP_FREE : "Initialized signal operation is free"
*>
fn SignalOp* SignalOp.init(&self)
{
	*self = { };
	self.header.kind = Kind.SIGNAL;
	self.header.state = State.OP_FREE;
	return self;
}

<*
 Destroy signal operation storage.

 @param [&inout] self : "Signal operation storage"
 @require self.header.state == State.OP_FREE : "Signal operation must be free"
 @ensure self.header.state == State.OP_FREE : "Destroyed signal operation is free"
*>
fn void SignalOp.destroy(&self)
{
	*self = { };
}

<*
 Report whether this signal operation is currently active.

 @param self : "Signal operation storage"
 @return "True while the embedded operation header is active"
*>
fn bool SignalOp.active(&self) => self.header.active();

<*
 Start observing a process signal.

 The callback runs on the loop owner thread. It does not stop the loop or apply
 application shutdown policy; callers may drain connections, continue accepting
 in a shutdown mode or call `Loop.stop` themselves.

 @param loop : "Loop that owns the signal operation"
 @param op : "Signal operation storage"
 @param options : "Signal number and oneshot policy"
 @param callback : "Callback invoked when the signal is delivered"
 @param userdata : "Opaque user pointer stored in the operation during callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop is not initialized, callback is missing or signal is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Signal operation is already active"
 @return ? nova::BACKEND_FAILED : "Signal handler registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Signal operation pointer must not be null"
*>
fn Ref? start(Loop* loop, SignalOp* op, Options options, Callback callback, void* userdata = null)
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!callback) return nova::INVALID_STATE~;
	if (op.header.active()) return nova::BUSY~;

	op.result = { };
	op.callback = callback;
	Ref? submitted = submit(loop, op, options.signum, options.oneshot, &dispatch_signal, op, userdata);
	if (catch submitted)
	{
		reset_signal_fields(op);
		return submitted;
	}
	return submitted;
}

<*
 Stop an active signal operation and queue a cancellation callback.

 If called while a signal callback is running, this prevents future signal
 callbacks but does not change the result already being delivered.

 @param loop : "Loop that owns the active signal operation"
 @param op : "Signal operation storage"
 @return ? nova::INVALID_STATE : "Loop is not initialized"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? NOT_FOUND : "Signal operation is inactive or belongs to another loop"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Signal operation pointer must not be null"
*>
fn void? stop(Loop* loop, SignalOp* op)
{
	op::cancel_op(loop, &op.header)!;
}

<*
 Dispatch a ready signal operation through its typed callback.

 The cast is valid because `op::Header` is the first field of
 `signal::SignalOp` and the operation storage remains caller-owned and stable while
 active.

 @param loop : "Loop dispatching the signal"
 @param raw : "Header pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_signal(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	SignalOp* op       = (SignalOp*)header.owner;
	Callback callback  = op.callback;
	void* userdata     = header.userdata;
	bool success       = !header.terminal_status;

	op.result.error.status = header.terminal_status;
	op.result.signum = 0;
	op.result.count = 0;
	if (success)
	{
		op.result.signum = op.signum;
		op.result.count = op.ready_count;
	}

	header.userdata = null;
	callback(loop, op, &op.result, userdata);

	bool keep_active = success && !op.oneshot && header.state != State.OP_CANCELLING;
	if (keep_active)
	{
		header.state = State.OP_ACTIVE;
		header.terminal_status = { };
		op.ready_count = 0;
		header.userdata = userdata;
		return;
	}

	op::reset_header(header);
	reset_signal_fields(op);
}

<*
 Clear signal-specific fields after a signal operation leaves the runtime.

 @param op : "Signal operation storage to clear"
 @require op != null : "Signal operation pointer must not be null"
*>
fn void reset_signal_fields(SignalOp* op) @local
{
	op.result = { };
	op.loop_next = null;
	op.loop_prev = null;
	op.global_next = null;
	op.global_prev = null;
	op.pending = 0;
	op.ready_count = 0;
	op.signum = 0;
	op.oneshot = false;
	op.registered = false;
	op.callback = null;
}
