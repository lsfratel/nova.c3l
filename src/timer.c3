module nova::timer;

import nova @norecurse;
import nova::op @public;

<*
 Callback invoked when a timer fires or reaches a terminal result.

 Timer callbacks run while `op.header` is still active, so the same timer storage
 is not reusable from inside the callback. Submission userdata is delivered
 through the `userdata` argument; `op.header.userdata` is cleared before the
 callback runs.

 @param loop : "Loop dispatching the timer"
 @param op : "Timer operation storage"
 @param result : "Timer result valid only during the callback"
 @param userdata : "Opaque pointer captured at submission"
*>
alias Callback = fn void(Loop* loop, TimerOp* op, TimerResult* result, void* userdata);

<*
 Timer-only flag stored in `Header.ready_flags` to suppress repeat rearm.
*>
const uint NO_REARM = 0x1_0000;

<*
 Result delivered when a timer fires or reaches a terminal state.

 The result pointer is valid only during the timer callback. `expirations`
 contains the number of due timer expirations for successful callbacks,
 including intermediate callbacks from a repeating timer. It is zero when the
 timer completes with an error status, such as cancellation.
*>
struct TimerResult
{
	ErrorInfo error;
	ulong expirations;
}

<*
 Intrusive binary-heap node carrying a deadline.

 Embedded only in operation types that can time out, so operations without a
 deadline pay no timer storage beyond a null `Header.timer` pointer. The loop
 timer heap links and orders these nodes; `header` recovers the owning operation
 for dispatch and expiry.
*>
struct Node
{
	Node* heap_left;
	Node* heap_right;
	Node* heap_parent;
	op::Header* header;
	Clock deadline;
	bool in_heap;
}

<*
 Caller-owned timer operation storage.

 `header` must be the first field so the runtime can pass the embedded
 `op::Header*` through the ready queue and recover this typed operation in
 the dispatch trampoline without an allocation or table lookup. `timeout` is the
 deadline node linked into the loop heap while the timer is armed.
*>
struct TimerOp
{
	inline op::Header header;
	Node timeout;
	TimerResult result;
	Duration interval;
	Callback callback;
	uint remaining_repeats;
	bool infinite;
}

<*
 Timer scheduling options.

 `interval == 0` is a one-shot timer (`repeat` must then be 0). A positive
 `interval` is a repeating timer: `repeat` is an optional cap on the number of
 additional expirations after the first, and `repeat == 0` repeats indefinitely
 until `stop`. Negative `delay` and `interval` values are rejected.
*>
struct Options
{
	Duration delay;
	Duration interval;
	uint repeat;
}

<*
 Initialize caller-owned timer operation storage.

 @param [&inout] self : "Timer operation storage"
 @return "Initialized timer operation"
 @require self.header.state == State.OP_FREE : "Timer operation must not be active"
 @ensure self.header.state == State.OP_FREE : "Initialized timer operation is free"
*>
fn TimerOp* TimerOp.init(&self)
{
	self.header = { };
	self.header.kind = Kind.TIMER;
	self.header.state = State.OP_FREE;
	self.timeout = { };
	self.result = { };
	self.interval = (Duration)0;
	self.remaining_repeats = 0;
	self.infinite = false;
	self.callback = null;
	return self;
}

<*
 Destroy timer operation storage.

 @param [&inout] self : "Timer operation storage"
 @require self.header.state == State.OP_FREE : "Timer operation must be free"
 @ensure self.header.state == State.OP_FREE : "Destroyed timer operation is free"
*>
fn void TimerOp.destroy(&self)
{
	self.header = { };
	self.timeout = { };
	self.result = { };
	self.interval = (Duration)0;
	self.remaining_repeats = 0;
	self.infinite = false;
	self.callback = null;
}

<*
 Report whether this timer operation is currently active.

 @param self : "Timer operation storage"
 @return "True while the embedded operation header is active"
*>
fn bool TimerOp.active(&self) => self.header.active();

<*
 Submit a one-shot, finite-repeating, or indefinitely-repeating timer operation.

 Repeating timers reserve a heap slot at submission, including when the first
 deadline is immediate, so the operation stays in the intrusive heap and can be
 rearmed in place. Timer callbacks run before the operation storage becomes
 reusable.

 @param loop : "Loop that owns the timer operation"
 @param op : "Timer operation storage"
 @param options : "Delay, interval and repeat policy for this timer"
 @param callback : "Callback invoked when the timer fires or reaches a terminal result"
 @param userdata : "Opaque user pointer stored in the operation during callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop is not initialized or timer options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Timer operation is already active"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Timer operation pointer must not be null"
 @require callback != null : "Timer callback must not be null"
*>
fn Ref? start(Loop* loop, TimerOp* op, Options options, Callback callback, void* userdata = null)
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (op.header.active()) return nova::BUSY~;
	if ((long)options.delay < 0 || (long)options.interval < 0) return nova::INVALID_STATE~;
	if ((long)options.interval == 0 && options.repeat > 0) return nova::INVALID_STATE~;
	if ((long)options.interval > 0) (void)duration_to_ns(options.interval)!;

	Clock now      = loop.update_now();
	Clock deadline = now;
	if ((long)options.delay > 0) deadline = deadline_after(now, duration_to_ns(options.delay)!);

	op.result = { };
	op.interval = options.interval;
	op.remaining_repeats = options.repeat;
	op.infinite = (long)options.interval > 0 && options.repeat == 0;
	op.callback = callback;
	Ref? submitted = submit(
		loop,
		&op.header,
		&op.timeout,
		deadline,
		&dispatch_timer,
		op,
		userdata,
		(long)options.interval > 0
	);
	if (catch submitted)
	{
		reset_timer_fields(op);
		return submitted;
	}
	return submitted;
}

<*
 Stop an active timer operation and queue a cancellation callback.

 If called while a repeating timer callback is running, this suppresses the
 next rearm but does not change the callback result already being delivered.

 @param loop : "Loop that owns the active timer operation"
 @param op : "Timer operation storage"
 @return ? nova::INVALID_STATE : "Loop is not initialized"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? NOT_FOUND : "Timer is inactive or belongs to another loop"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Timer operation pointer must not be null"
*>
fn void? stop(Loop* loop, TimerOp* op)
{
	op::cancel_op(loop, &op.header)!;
}

<*
 Dispatch a ready timer operation through its typed callback.

 The cast is valid because `op::Header` is the first field of `timer::TimerOp`
 and the operation storage remains caller-owned and stable while active.

 @param loop : "Loop dispatching the timer"
 @param raw : "Header pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_timer(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	TimerOp* op        = (TimerOp*)header.owner;
	Callback callback  = op.callback;
	void* userdata     = header.userdata;
	bool stopped       = (header.ready_flags & NO_REARM) != 0;
	bool success       = !header.terminal_status;
	ulong expirations  = 0;
	if (success) expirations = expirations_due(loop, op);
	bool should_rearm = success && !stopped && (long)op.interval > 0
		&& (op.infinite || expirations <= (ulong)op.remaining_repeats);

	op.result.error.status = header.terminal_status;
	op.result.expirations = expirations;

	if (should_rearm)
	{
		if (!op.infinite)
		{
			ulong total_left = (ulong)op.remaining_repeats + 1 - expirations;
			op.remaining_repeats = (uint)(total_left - 1);
		}
		Clock next_deadline = deadline_after(op.timeout.deadline, interval_delta_ns(op.interval, expirations));
		rearm(loop, header, next_deadline);
	}
	if (!should_rearm) op.remaining_repeats = 0;

	header.userdata = null;
	callback(loop, op, &op.result, userdata);

	bool rearmed_after_callback = should_rearm && header.state != State.OP_CANCELLING
		&& !(header.ready_flags & NO_REARM);
	if (rearmed_after_callback)
	{
		header.state = State.OP_ACTIVE;
		header.terminal_status = { };
		header.ready_flags = 0;
		header.userdata = userdata;
		return;
	}

	op::reset_header(header);
	reset_timer_fields(op);
}

<*
 Clear timer-specific fields after a timer operation leaves the runtime.

 @param op : "Timer operation storage to clear"
 @require op != null : "Timer operation pointer must not be null"
*>
fn void reset_timer_fields(TimerOp* op) @local
{
	op.result = { };
	op.interval = (Duration)0;
	op.remaining_repeats = 0;
	op.infinite = false;
	op.callback = null;
}

<*
 Convert a non-negative microsecond duration to nanoseconds.

 @param duration : "Duration in microseconds"
 @return "Nanoseconds"
 @return ? nova::INVALID_STATE : "Duration is negative or too large"
*>
fn ulong? duration_to_ns(Duration duration) @local
{
	if ((long)duration < 0) return nova::INVALID_STATE~;
	ulong micros = (ulong)((long)duration);
	if (micros > ulong::max / 1000) return nova::INVALID_STATE~;
	return micros * 1000;
}

<*
 Convert a previously validated positive duration to nanoseconds.

 @param duration : "Validated duration in microseconds"
 @return "Nanoseconds"
*>
fn ulong duration_to_ns_unchecked(Duration duration) @local
{
	return (ulong)((long)duration) * 1000;
}

<*
 Add nanoseconds to a deadline, saturating at the maximum clock value.

 @param deadline : "Base absolute clock value"
 @param delta_ns : "Nanoseconds to add"
 @return "Saturated absolute clock value"
*>
fn Clock deadline_after(Clock deadline, ulong delta_ns) @local
{
	ulong base = (ulong)deadline;
	if (delta_ns > ulong::max - base) return (Clock)ulong::max;
	return (Clock)(base + delta_ns);
}

<*
 Multiply an interval by an expiration count, saturating on overflow.

 @param interval : "Timer interval in microseconds"
 @param expirations : "Expiration count"
 @return "Nanosecond delta"
*>
fn ulong interval_delta_ns(Duration interval, ulong expirations) @local
{
	ulong interval_ns = duration_to_ns_unchecked(interval);
	if (expirations > ulong::max / interval_ns) return ulong::max;
	return interval_ns * expirations;
}

<*
 Count due expirations for a repeating timer without allocating.

 @param loop : "Loop with cached current time"
 @param op : "Timer operation storage"
 @return "Due expiration count capped by remaining repeats"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Timer operation pointer must not be null"
*>
fn ulong expirations_due(Loop* loop, TimerOp* op)
{
	ulong expirations = 1;
	ulong available   = (ulong)op.remaining_repeats + 1;
	if ((long)op.interval > 0 && loop.cached_now > op.timeout.deadline)
	{
		ulong interval_ns = duration_to_ns_unchecked(op.interval);
		ulong elapsed     = ((ulong)loop.cached_now - (ulong)op.timeout.deadline) / interval_ns;
		if (elapsed >= available) return available;
		expirations += elapsed;
	}

	if (expirations > available) return available;
	return expirations;
}

<*
 Compute the backend wait timeout from the current timer heap.

 Backend polling accepts this timeout in milliseconds. Future sub-millisecond
 deadlines round up to one millisecond to avoid busy spinning.

 @param loop : "Loop that owns the timer heap"
 @param can_block : "Allow an infinite wait when no timers are active"
 @return "Backend timeout in milliseconds"
 @require loop != null : "Loop pointer must not be null"
*>
fn int next_timeout_ms(Loop* loop, bool can_block)
{
	if (!can_block) return 0;
	if (loop.timer_count <= 0) return -1;

	Clock deadline = loop.timer_min.deadline;
	if (deadline <= loop.cached_now) return 0;

	ulong delta_ns = (ulong)deadline - (ulong)loop.cached_now;
	if (delta_ns > 2_147_483_647UL * 1_000_000) return 2_147_483_647;
	ulong timeout_ms = (delta_ns + 999_999) / 1_000_000;
	return (int)timeout_ms;
}

<*
 Move all due timers from the heap to the ready queue as successful firings.

 Only `timer` operations live in the heap. Operations already ready or calling
 have produced their dispatch result, so expiry only drops their stale entry.

 @param loop : "Loop that owns the timer heap"
 @require loop != null : "Loop pointer must not be null"
*>
fn void expire_due(Loop* loop)
{
	while (loop.timer_count > 0)
	{
		Node* node = loop.timer_min;
		if (node.deadline > loop.cached_now)
		{
			break;
		}

		Header* op = node.header;
		heap_remove(loop, node);
		if (op.state == State.OP_READY || op.state == State.OP_CALLING)
		{
			continue;
		}
		if (!op.active()) continue;

		nova::queue_ready(loop, op, nova::ok_status());
	}
}

<*
 Report whether timer operation `a` is due strictly before `b`.

 @param a : "First timer-backed operation"
 @param b : "Second timer-backed operation"
 @return "True when `a` has the earlier deadline"
*>
fn bool less_than(Node* a, Node* b) @local => a.deadline < b.deadline;

<*
 Swap a parent node with one of its children in the intrusive heap.

 Only the embedded link fields move; node payload stays in place. This is a
 direct port of the libuv pointer-based binary heap node swap.

 @param loop : "Loop that owns the timer heap"
 @param parent : "Parent node moving away from the root"
 @param child : "Child node moving toward the root"
 @require loop != null : "Loop pointer must not be null"
 @require parent != null : "Parent pointer must not be null"
 @require child != null : "Child pointer must not be null"
*>
fn void heap_node_swap(Loop* loop, Node* parent, Node* child) @local
{
	Node* pl = parent.heap_left;
	Node* pr = parent.heap_right;
	Node* pp = parent.heap_parent;
	parent.heap_left = child.heap_left;
	parent.heap_right = child.heap_right;
	child.heap_left = pl;
	child.heap_right = pr;
	child.heap_parent = pp;

	parent.heap_parent = child;

	Node* sibling;
	if (child.heap_left == child)
	{
		child.heap_left = parent;
		sibling = child.heap_right;
	}
	else
	{
		child.heap_right = parent;
		sibling = child.heap_left;
	}
	if (sibling != null) sibling.heap_parent = child;

	if (parent.heap_left != null) parent.heap_left.heap_parent = parent;
	if (parent.heap_right != null) parent.heap_right.heap_parent = parent;

	if (child.heap_parent == null)
	{
		loop.timer_min = child;
	}
	else if (child.heap_parent.heap_left == parent)
	{
		child.heap_parent.heap_left = child;
	}
	else
	{
		child.heap_parent.heap_right = child;
	}
}

<*
 Insert a deadline node into the intrusive binary min-heap.

 The heap is unbounded: nodes live in caller-owned operation storage, so an
 insertion only relinks pointers and never allocates or fails on capacity.

 @param loop : "Loop that owns the timer heap"
 @param node : "Deadline node to insert"
 @require loop != null : "Loop pointer must not be null"
 @require node != null : "Node pointer must not be null"
 @require !node.in_heap : "Node must not already be in heap"
*>
fn void heap_push(Loop* loop, Node* node) @local
{
	node.heap_left = null;
	node.heap_right = null;
	node.heap_parent = null;

	usz path = 0;
	usz k    = 0;
	for (usz n = 1 + (usz)loop.timer_count; n >= 2; n /= 2)
	{
		path = (path << 1) | (n & 1);
		k += 1;
	}

	Node** parent = &loop.timer_min;
	Node** child  = &loop.timer_min;
	while (k > 0)
	{
		parent = child;
		if (path & 1)
		{
			child = &(*child).heap_right;
		}
		else
		{
			child = &(*child).heap_left;
		}
		path >>= 1;
		k -= 1;
	}

	node.heap_parent = *parent;
	*child = node;
	loop.timer_count++;
	node.in_heap = true;

	while (node.heap_parent != null && less_than(node, node.heap_parent))
	{
		heap_node_swap(loop, node.heap_parent, node);
	}
}

<*
 Remove a deadline node from the intrusive binary min-heap.

 @param loop : "Loop that owns the timer heap"
 @param node : "Deadline node to remove"
 @require loop != null : "Loop pointer must not be null"
 @require node != null : "Node pointer must not be null"
*>
fn void heap_remove(Loop* loop, Node* node)
{
	if (!node.in_heap || loop.timer_count == 0) return;

	usz path = 0;
	usz k    = 0;
	for (usz n = (usz)loop.timer_count; n >= 2; n /= 2)
	{
		path = (path << 1) | (n & 1);
		k += 1;
	}

	Node** max = &loop.timer_min;
	while (k > 0)
	{
		if (path & 1)
		{
			max = &(*max).heap_right;
		}
		else
		{
			max = &(*max).heap_left;
		}
		path >>= 1;
		k -= 1;
	}

	loop.timer_count--;
	Node* child = *max;
	*max = null;

	if (child == node)
	{
		if (child == loop.timer_min) loop.timer_min = null;
		node.in_heap = false;
		return;
	}

	child.heap_left = node.heap_left;
	child.heap_right = node.heap_right;
	child.heap_parent = node.heap_parent;
	if (child.heap_left != null) child.heap_left.heap_parent = child;
	if (child.heap_right != null) child.heap_right.heap_parent = child;

	if (node.heap_parent == null)
	{
		loop.timer_min = child;
	}
	else if (node.heap_parent.heap_left == node)
	{
		node.heap_parent.heap_left = child;
	}
	else
	{
		node.heap_parent.heap_right = child;
	}

	while (true)
	{
		Node* smallest = child;
		if (child.heap_left != null && less_than(child.heap_left, smallest)) smallest = child.heap_left;
		if (child.heap_right != null && less_than(child.heap_right, smallest)) smallest = child.heap_right;
		if (smallest == child) break;
		heap_node_swap(loop, child, smallest);
	}
	while (child.heap_parent != null && less_than(child, child.heap_parent))
	{
		heap_node_swap(loop, child.heap_parent, child);
	}

	node.in_heap = false;
}

<*
 Submit an operation into the loop timer heap or immediate ready queue.

 This is an internal runtime entry point used by typed operation modules.

 @param loop : "Initialized loop"
 @param op : "Caller-owned timer operation header"
 @param node : "Deadline node embedded in the operation storage"
 @param deadline : "Absolute deadline in loop clock ticks"
 @param callback : "Typed dispatch trampoline"
 @param owner : "Typed operation owner used by the trampoline"
 @param userdata : "Opaque user pointer captured by this operation"
 @param reserve_heap : "Force a heap slot even when the first deadline is due"
 @return "Generation-checked reference for the submitted operation"
*>
fn Ref? submit(
	Loop* loop,
	Header* op,
	Node* node,
	Clock deadline,
	OperationCallback callback,
	void* owner,
	void* userdata,
	bool reserve_heap = false
)
{
	bool immediate = deadline <= loop.cached_now;

	op::init_header(op, Kind.TIMER, loop, callback, owner, userdata);

	if (immediate && !reserve_heap)
	{
		nova::queue_ready(loop, op, nova::ok_status());
		return op.to_ref();
	}

	arm(loop, op, node, deadline);
	return op.to_ref();
}

<*
 Arm a deadline node and link it into the loop timer heap.

 Used by typed operation modules at submission to attach the embedded `Node` of
 an operation to its header and the heap.

 @param loop : "Initialized loop"
 @param op : "Caller-owned operation header"
 @param node : "Deadline node embedded in the operation storage"
 @param deadline : "Absolute deadline in loop clock ticks"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require node != null : "Node pointer must not be null"
*>
fn void arm(Loop* loop, Header* op, Node* node, Clock deadline)
{
	node.header = op;
	node.deadline = deadline;
	node.in_heap = false;
	op.timer = node;
	heap_push(loop, node);
}

<*
 Mark an operation's deadline as consumed before its terminal callback.

 Typed IO dispatchers call this once they know the operation will invoke user
 code. This prevents stale heap entries after the operation storage becomes
 reusable.

 @param loop : "Loop that owns the operation"
 @param op : "Caller-owned operation header"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void deadline_done(Loop* loop, Header* op)
{
	if (op.timer) heap_remove(loop, op.timer);
}

<*
 Reinsert an active timer operation into its deadline node.

 Repeating timers call this before invoking the user callback so the node stays
 linked while callback code runs.

 @param loop : "Initialized loop"
 @param op : "Timer operation currently being dispatched"
 @param deadline : "Next absolute deadline"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
 @require op.kind == Kind.TIMER : "Only timer operations can be rearmed"
 @require op.loop == loop : "Timer operation must belong to this loop"
 @require op.timer != null : "Timer must have a deadline node"
 @require !op.timer.in_heap : "Timer node must not already be in heap"
*>
fn void rearm(Loop* loop, Header* op, Clock deadline)
{
	op.timer.deadline = deadline;
	op.terminal_status = { };
	heap_push(loop, op.timer);
}
