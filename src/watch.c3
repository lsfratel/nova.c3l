module nova::watch;

import nova @norecurse;
import nova::op @public;
import nova::backend @public;

<*
 Callback invoked when a watch operation reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` is cleared before the callback runs.

 @param loop : "Loop dispatching the watch"
 @param watch : "Watch handle that owns the operation"
 @param op : "Watch operation storage"
 @param result : "Watch result valid only during the callback"
 @param userdata : "Opaque pointer captured at submission"
*>
alias Callback = fn void(Loop* loop, Watch* watch, WatchOp* op, WatchResult* result, void* userdata);

<*
 Readiness interests requested for a borrowed native handle.

 `READABLE | WRITABLE` requests both directions. Other bit combinations are
 rejected when the watch operation is started.
*>
constdef Interest : inline char
{
	READABLE = 1,
	WRITABLE = 2,
}

<*
 Readiness event snapshot delivered to watch callbacks.

 `error` and `hangup` are backend readiness flags, not terminal operation
 faults. Check `WatchResult.error.status` for cancellation, timeout or backend
 failure before interpreting these flags. Error or hangup readiness may satisfy
 either readable or writable interests.
*>
struct Event
{
	bool readable;
	bool writable;
	bool error;
	bool hangup;
}

<*
 Result delivered for a watch operation.

 The result pointer is valid only during the watch callback. `events` is the
 readiness snapshot reported for the watched file descriptor. Check
 `error.status` before interpreting readiness bits; cancellation and timeout
 completions may carry no event flags.
*>
struct WatchResult
{
	ErrorInfo error;
	Event events;
}

<*
 Caller-owned watch handle for a borrowed native handle.

 The native handle is borrowed and is never closed by nova. Each watch allows
 one active one-shot readiness operation at a time.
*>
struct Watch
{
	NativeHandle handle;
	Loop* loop;
	WatchOp* active_op;
	Interest interests;
	bool initialized;
	bool registered;
}

<*
 Caller-owned watch operation storage.

 `header` must be the first field so backends can store the embedded
 `op::Header*` directly and dispatch can recover `watch::WatchOp*`.
*>
struct WatchOp
{
	inline op::Header header;
	backend::OpState backend;
	WatchResult result;
	Callback callback;
}

<*
 Initialize a watch around a borrowed native handle.

 The native handle remains owned by the caller.
 Interest validation is deferred until `start`.

 @param [&inout] self : "Watch storage"
 @param handle : "Borrowed native handle"
 @param interests : "Initial readiness interests"
 @return "Initialized watch"
 @return ? nova::INVALID_STATE : "Watch is already initialized"
 @ensure self.initialized : "Watch is initialized when init succeeds"
*>
fn Watch*? Watch.init(&self, NativeHandle handle, Interest interests)
{
	if (self.initialized) return nova::INVALID_STATE~;
	*self = { };
	self.handle = handle;
	self.interests = interests;
	self.initialized = true;
	return self;
}

<*
 Destroy watch storage after it has been stopped.

 @param [&inout] self : "Watch storage"
 @require self.initialized : "Watch must be initialized"
 @require self.active_op == null : "Watch must have no active operation"
 @ensure !self.initialized : "Watch is uninitialized after destroy"
*>
fn void Watch.destroy(&self)
{
	self.handle = (NativeHandle)-1;
	self.interests = (Interest)0;
	self.loop = null;
	self.active_op = null;
	self.initialized = false;
	self.registered = false;
}

<*
 Report whether this watch has an active operation.

 @param self : "Initialized watch storage"
 @return "True when a watch operation is active"
 @require self.initialized : "Watch must be initialized"
*>
fn bool Watch.active(&self) => self.active_op != null;

<*
 Initialize caller-owned watch operation storage.

 @param [&inout] self : "Watch operation storage"
 @return "Initialized watch operation"
 @require self.header.state == State.OP_FREE : "Watch operation must not be active"
 @ensure self.header.state == State.OP_FREE : "Initialized watch operation is free"
*>
fn WatchOp* WatchOp.init(&self)
{
	self.header = { };
	self.header.kind = Kind.WATCH;
	self.header.state = State.OP_FREE;
	self.result = { };
	self.callback = null;
	return self;
}

<*
 Destroy caller-owned watch operation storage.

 @param [&inout] self : "Watch operation storage"
 @require self.header.state == State.OP_FREE : "Watch operation must be free"
 @ensure self.header.state == State.OP_FREE : "Destroyed watch operation is free"
*>
fn void WatchOp.destroy(&self)
{
	self.header = { };
	self.result = { };
	self.callback = null;
}

<*
 Report whether this watch operation is currently active.

 @param self : "Watch operation storage"
 @return "True while the embedded operation header is active"
*>
fn bool WatchOp.active(&self) => self.header.active();

<*
 Submit a one-shot watch operation.

 The borrowed native handle must remain valid until the terminal callback
 returns or the operation is stopped and its cancellation callback returns.
 The watch interest must be `READABLE`, `WRITABLE` or `READABLE | WRITABLE`.
 The callback starts after `op` is reusable. The result pointer is valid only
 during the callback. Submission userdata is delivered through the `userdata`
 argument; `op.header.userdata` is cleared before the callback runs.

 @param loop : "Loop that owns the watch operation"
 @param watch : "Watch handle for the borrowed native handle"
 @param op : "Watch operation storage"
 @param callback : "Callback invoked when readiness reaches a terminal result"
 @param userdata : "Opaque user pointer stored in the operation during callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop or watch is not initialized, callback is missing or interests are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Watch or operation is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require watch != null : "Watch pointer must not be null"
 @require op != null : "Watch operation pointer must not be null"
*>
fn Ref? start(Loop* loop, Watch* watch, WatchOp* op, Callback callback, void* userdata = null)
{
	if (!loop.initialized || !watch.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!callback) return nova::INVALID_STATE~;
	if (watch.active_op || op.header.active()) return nova::BUSY~;
	if (watch.interests != Interest.READABLE && watch.interests != Interest.WRITABLE
		&& watch.interests != (Interest.READABLE | Interest.WRITABLE)) return nova::INVALID_STATE~;

	uint interests = 0;
	if (watch.interests & Interest.READABLE) interests |= nova::READY_READABLE;
	if (watch.interests & Interest.WRITABLE) interests |= nova::READY_WRITABLE;
	if (!interests) return nova::INVALID_STATE~;

	op.result = { };
	Ref oref = backend::watch_submit(
		loop,
		&op.header,
		&op.backend,
		watch.handle,
		interests,
		&dispatch_watch,
		watch,
		userdata
	)!;
	op.callback = callback;
	watch.loop = loop;
	watch.active_op = op;
	watch.registered = true;
	return oref;
}

<*
 Stop an active watch operation and queue a cancellation callback.

 @param loop : "Loop that owns the active watch operation"
 @param watch : "Watch handle that owns the operation"
 @param op : "Watch operation storage"
 @return ? nova::INVALID_STATE : "Loop is not initialized"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? NOT_FOUND : "Watch operation is inactive or belongs to another loop"
 @require loop != null : "Loop pointer must not be null"
 @require watch != null : "Watch pointer must not be null"
 @require op != null : "Watch operation pointer must not be null"
*>
fn void? stop(Loop* loop, Watch* watch, WatchOp* op)
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (watch.active_op != op || op.header.loop != loop) return NOT_FOUND~;
	op::cancel_op(loop, &op.header)!;
}

<*
 Dispatch a ready watch operation through its typed callback.

 The cast is valid because `op::Header` is the first field of `watch::WatchOp`.
 `Header.owner` carries the typed `Watch*`; submission userdata is snapshotted
 before the header is reset and delivered only through the callback argument, so
 `op.header.userdata` is cleared while the callback runs.

 @param loop : "Loop dispatching the watch operation"
 @param raw : "Header pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_watch(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	WatchOp* op        = (WatchOp*)raw;
	Watch* watch       = (Watch*)header.owner;
	Callback callback  = op.callback;
	void* userdata     = header.userdata;
	WatchResult result;

	result.error.status = header.terminal_status;
	result.events.readable = (header.ready_flags & nova::READY_READABLE) != 0;
	result.events.writable = (header.ready_flags & nova::READY_WRITABLE) != 0;
	result.events.error = (header.ready_flags & nova::READY_ERROR) != 0;
	result.events.hangup = (header.ready_flags & nova::READY_HANGUP) != 0;

	watch.loop = null;
	watch.active_op = null;
	watch.registered = false;

	op.result = { };
	op::reset_header(header);
	op.callback = null;

	callback(loop, watch, op, &result, userdata);
}
