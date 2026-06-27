module nova::fs::poll;

import std::io;

import nova @norecurse;
import nova::fs @public, nova::op @public, nova::timer, nova::work;

<*
 Callback invoked when fs_poll observes a snapshot, change or terminal status.

 @param loop : "Loop dispatching the callback"
 @param poll : "Polling handle"
 @param result : "Result valid only during this callback"
 @param userdata : "Opaque pointer provided to `start`"
*>
alias Callback = fn void(Loop* loop, Poll* poll, PollResult* result, void* userdata);

<*
 Filesystem polling options.
*>
struct PollOptions
{
	Duration interval;
}

<*
 Filesystem polling callback result.

 Missing paths are reported with `current_exists = false` and no error. Other
 stat failures are delivered through `error` and polling continues.
*>
struct PollResult
{
	nova::ErrorInfo error;
	fs::Stat previous;
	fs::Stat current;
	bool previous_exists;
	bool current_exists;
	bool changed;
}

<*
 Caller-owned filesystem polling handle.
*>
struct Poll
{
	timer::TimerOp timer;
	work::WorkOp work;
	char* path;
	char[fs::FS_PATH_MAX] path_buf;
	fs::Stat previous;
	fs::Stat current;
	nova::ErrorInfo current_error;
	Callback callback;
	void* userdata;
	Loop* loop;
	Duration interval;
	bool initialized;
	bool started;
	bool stopping;
	bool in_callback;
	bool previous_exists;
	bool current_exists;
	bool have_snapshot;
}

<*
 Initialize caller-owned filesystem polling storage.

 @param [&inout] self : "Polling handle storage"
 @return "Initialized polling handle"
 @ensure self.initialized : "Polling handle is initialized after init"
*>
fn Poll* Poll.init(&self)
{
	*self = { };
	self.timer.init();
	self.work.init();
	self.initialized = true;
	return self;
}

<*
 Destroy inactive filesystem polling storage.

 @param [&inout] self : "Polling handle storage"
 @require self.initialized : "Polling handle must be initialized"
 @require !self.timer.active() : "Timer must not be active"
 @require !self.work.active() : "Worker must not be active"
 @ensure !self.initialized : "Polling handle is uninitialized after destroy"
*>
fn void Poll.destroy(&self)
{
	poll_cleanup(self);
	self.timer.destroy();
	self.work.destroy();
	*self = { };
}

<*
 Report whether this polling handle has active timer or worker state.

 @param self : "Polling handle storage"
 @return "True while polling is started or completing cancellation"
*>
fn bool Poll.active(&self) => self.started || self.timer.active() || self.work.active();

<*
 Start polling a path with a worker-backed `stat` loop.

 @param loop : "Loop that owns callbacks"
 @param poll : "Initialized polling handle"
 @param path : "Path to observe"
 @param options : "Polling interval"
 @param callback : "Callback invoked for snapshots, changes and terminal status"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Reference to the initial stat worker operation"
 @return ? nova::INVALID_STATE : "Loop, pool, path, interval or callback state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Polling handle is already active"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
*>
fn op::Ref? start(Loop* loop, Poll* poll, String path, PollOptions options, Callback callback, void* userdata = null)
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!loop.options.blocking_pool || !loop.post_queue_initialized) return nova::INVALID_STATE~;
	if (!poll || !poll.initialized || !callback || !path.len
		|| (long)options.interval <= 0) return nova::INVALID_STATE~;
	if (poll.active()) return nova::BUSY~;

	poll.path = poll_copy_path(poll, path)!;
	poll.callback = callback;
	poll.userdata = userdata;
	poll.loop = loop;
	poll.interval = options.interval;
	poll.started = true;

	op::Ref? ref = queue_poll_work(loop, poll);
	if (catch ref)
	{
		poll_cleanup(poll);
		return ref;
	}
	return ref;
}

<*
 Stop an active filesystem poll.

 When a timer or stat worker is pending, a final callback with
 `nova::CANCELLED` is delivered. When called from inside the poll callback, the
 handle is cleaned up after the callback returns and no extra callback is queued.

 @param loop : "Loop that owns the polling handle"
 @param poll : "Polling handle to stop"
 @return ? nova::INVALID_STATE : "Loop or polling handle state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? NOT_FOUND : "Polling handle is inactive or belongs to another loop"
*>
fn void? stop(Loop* loop, Poll* poll)
{
	if (!nova::owner_ready(loop) || !poll || !poll.initialized) return nova::INVALID_STATE~;
	if (!poll.started || poll.loop != loop) return NOT_FOUND~;

	poll.stopping = true;
	if (poll.in_callback) return;

	bool pending = false;
	if (poll.timer.active())
	{
		pending = true;
		if (catch err = timer::stop(loop, &poll.timer))
		{
			if (err != NOT_FOUND) return err~;
		}
	}
	if (poll.work.active())
	{
		pending = true;
		if (catch err = op::cancel_op(loop, &poll.work.header))
		{
			if (err != nova::BUSY && err != NOT_FOUND) return err~;
		}
	}
	if (!pending) poll_cleanup(poll);
}

<*
 Copy a path into zero-terminated poll-owned storage.

 @param poll : "Polling handle owning the inline path storage"
 @param path : "Path to copy"
 @return "Zero-terminated path copy inside `poll.path_buf`"
 @return ? nova::INVALID_STATE : "Path is empty or exceeds `FS_PATH_MAX`"
*>
fn char*? poll_copy_path(Poll* poll, String path) @local
{
	if (!path.len || path.len >= fs::FS_PATH_MAX) return nova::INVALID_STATE~;
	mem::copy(&poll.path_buf[0], path.ptr, path.len);
	poll.path_buf[path.len] = 0;
	return &poll.path_buf[0];
}

<*
 Queue one stat worker for a polling handle.

 @param loop : "Loop owning the worker"
 @param poll : "Polling handle to inspect"
 @return "Worker operation reference"
*>
fn op::Ref? queue_poll_work(Loop* loop, Poll* poll) @local
{
	return work::queue(loop, &poll.work, &poll_work, &poll_after_work, poll);
}

<*
 Run one blocking stat sample.

 @param op : "Worker operation embedded in `Poll`"
 @return ? nova::CANCELLED : "Cancellation was requested before sampling"
*>
fn void? poll_work(work::WorkOp* op) @local
{
	Poll* poll = (Poll*)op.header.userdata;
	if (op.cancel_requested()) return nova::CANCELLED~;

	fs::Result result = fs::native_poll_stat_result(poll.path);
	poll.current_error = result.error;
	if (result.error.status == io::FILE_NOT_FOUND)
	{
		poll.current = { };
		poll.current_exists = false;
		poll.current_error = { };
		return;
	}
	if (result.error.status)
	{
		poll.current = { };
		poll.current_exists = false;
		return;
	}
	poll.current = result.stat;
	poll.current_exists = true;
}

<*
 Finish one stat worker on the owner thread.
*>
fn void poll_after_work(Loop* loop, work::WorkOp* op, fault status, void* userdata) @local
{
	(void)op;
	Poll* poll = (Poll*)userdata;
	if (!poll.started) return;

	if (status == nova::CANCELLED || poll.stopping)
	{
		deliver_poll_cancelled(loop, poll);
		return;
	}

	PollResult result = build_poll_result(poll);
	poll.in_callback = true;
	poll.callback(loop, poll, &result, poll.userdata);
	poll.in_callback = false;

	if (poll.stopping)
	{
		poll_cleanup(poll);
		return;
	}

	commit_poll_snapshot(poll);
	if (catch err = timer::start(loop, &poll.timer, { .delay = poll.interval }, &poll_timer, poll))
	{
		deliver_poll_error(loop, poll, err);
	}
}

<*
 Dispatch a poll timer tick by queuing the next worker sample.
*>
fn void poll_timer(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata) @local
{
	(void)op;
	Poll* poll = (Poll*)userdata;
	if (!poll.started) return;
	if (result.error.status == nova::CANCELLED || poll.stopping)
	{
		deliver_poll_cancelled(loop, poll);
		return;
	}
	if (result.error.status)
	{
		deliver_poll_error(loop, poll, result.error.status);
		return;
	}
	if (catch err = queue_poll_work(loop, poll))
	{
		deliver_poll_error(loop, poll, err);
	}
}

<*
 Build a public result from the latest worker sample.
*>
fn PollResult build_poll_result(Poll* poll) @local
{
	bool changed = false;
	if (poll.have_snapshot)
	{
		changed = poll.previous_exists != poll.current_exists
			|| (poll.previous_exists && poll.current_exists && stat_changed(
			poll.previous,
			poll.current
		));
	}

	return {
		.error = poll.current_error,
		.previous = poll.previous,
		.current = poll.current,
		.previous_exists = poll.previous_exists,
		.current_exists = poll.current_exists,
		.changed = changed,
	};
}

<*
 Commit the latest worker sample as the next previous snapshot.
*>
fn void commit_poll_snapshot(Poll* poll) @local
{
	if (!poll.current_error.status)
	{
		poll.previous = poll.current;
		poll.previous_exists = poll.current_exists;
		poll.have_snapshot = true;
	}
}

<*
 Compare portable stat fields used to detect polling changes.
*>
fn bool stat_changed(fs::Stat previous, fs::Stat current) @local
{
	return previous.type != current.type || previous.mode != current.mode || previous.uid != current.uid
		|| previous.gid != current.gid
		|| previous.dev != current.dev
		|| previous.ino != current.ino
		|| previous.nlink != current.nlink
		|| previous.rdev != current.rdev
		|| previous.size != current.size
		|| previous.modified.seconds != current.modified.seconds
		|| previous.modified.nanoseconds != current.modified.nanoseconds
		|| previous.changed.seconds != current.changed.seconds
		|| previous.changed.nanoseconds != current.changed.nanoseconds;
}

<*
 Deliver a terminal cancellation callback and release poll-owned storage.
*>
fn void deliver_poll_cancelled(Loop* loop, Poll* poll) @local
{
	PollResult result = { .error = { .status = nova::CANCELLED } };
	poll.in_callback = true;
	poll.callback(loop, poll, &result, poll.userdata);
	poll.in_callback = false;
	poll_cleanup(poll);
}

<*
 Deliver a terminal setup/scheduling error callback and release poll-owned storage.
*>
fn void deliver_poll_error(Loop* loop, Poll* poll, fault status) @local
{
	PollResult result = { .error = { .status = status } };
	poll.in_callback = true;
	poll.callback(loop, poll, &result, poll.userdata);
	poll.in_callback = false;
	poll_cleanup(poll);
}

<*
 Release poll-owned path storage and reset runtime fields.
*>
fn void poll_cleanup(Poll* poll) @local
{
	bool initialized = poll.initialized;
	poll.timer.result = { };
	poll.work.worker_status = { };
	poll.path = null;
	poll.previous = { };
	poll.current = { };
	poll.current_error = { };
	poll.callback = null;
	poll.userdata = null;
	poll.loop = null;
	poll.interval = (Duration)0;
	poll.started = false;
	poll.stopping = false;
	poll.in_callback = false;
	poll.previous_exists = false;
	poll.current_exists = false;
	poll.have_snapshot = false;
	poll.initialized = initialized;
}
