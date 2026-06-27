module nova::op;

import nova @norecurse;
import nova::backend @public;
import nova::timer;
import nova::work;
import nova::signal;
import nova::process;

<*
 Callback delivered after an asynchronous cancellation request is applied on
 the loop owner thread.
*>
alias CancelCallback = fn void(Loop* loop, CancelOp* op, fault status, void* userdata);

<*
 Operation kind used by the scheduler and drivers.
*>
constdef Kind : inline char @private
{
	NONE              = 0,
	TCP_ACCEPT        = 1,
	TCP_ACCEPT_DRIVER = 2,
	TCP_CONNECT       = 3,
	STREAM_READ       = 4,
	STREAM_WRITE      = 5,
	TCP_CLOSE         = 6,
	UDP_RECV          = 7,
	UDP_SEND          = 8,
	UDP_CLOSE         = 9,
	PIPE_CLOSE        = 10,
	TIMER             = 11,
	WATCH             = 12,
	SIGNAL            = 13,
	WORK              = 14,
	PROCESS           = 15,
}

<*
 Operation lifecycle state.

 These states are owned by the runtime scheduler. Public code observes them
 only indirectly through operation references, callbacks and cancellation
 results.
*>
constdef State : inline char @private
{
	OP_FREE       = 0,
	OP_ACTIVE     = 2,
	OP_CANCELLING = 3,
	OP_CLOSED     = 5,
	OP_READY      = 6,
	OP_CALLING    = 7,
}

<*
 Generation counter used to reject stale operation references.
*>
typedef Generation @private = inline uint;

<*
 Common runtime header embedded in every async operation type.

 The containing operation storage is caller-owned and must not move while active.

 `owner` is runtime-owned typed context for dispatch, while `userdata` is the
 untouched public pointer captured at submission. Backend adapters may use
 `backend` and `ready_flags`; public code should treat them as internal.
*>
struct Header @private
{
	Loop* loop;
	void* owner;
	void* userdata;
	backend::OpState* backend;
	Header* next_ready;
	Header* loop_prev;
	Header* loop_next;
	timer::Node* timer;
	OperationCallback callback;
	fault terminal_status;
	Generation generation;
	uint ready_flags;
	Kind kind;
	State state;
}

<*
 Stable-by-generation reference to caller-owned operation storage.

 This reference does not own `op` and is valid only while that storage remains
 allocated. A later submission of the same storage advances `generation`, so
 stale references fail `Header.matches` and `cancel_ref` instead of naming
 the reused operation.
*>
struct Ref
{
	Header* op;
	Generation generation;
}

<*
 Caller-owned asynchronous cancellation operation.

 This is a thin `post` wrapper around `cancel_ref`; it lets worker threads
 request cancellation without touching scheduler-owned operation state.
 `post` must remain the first field so the posted callback can recover this
 typed operation from the queued `PostOp*`.
*>
struct CancelOp
{
	PostOp post;
	Ref target;
	CancelCallback callback;
	void* userdata;
	fault status;
}

<*
 Initialize caller-owned cancellation storage.

 @param [&inout] self : "Cancel operation storage"
 @return "Initialized cancel operation"
 @require !self.post.queued() : "Cancel operation must not be queued"
 @ensure !self.post.queued() : "Initialized cancel operation is not queued"
*>
fn CancelOp* CancelOp.init(&self)
{
	*self = { };
	self.post.init();
	return self;
}

<*
 Convert an active header to a generation-checked reference.

 @param self : "Operation header"
 @return "Reference naming this header generation"
*>
fn Ref Header.to_ref(&self)
{
	return { .op = self, .generation = self.generation };
}

<*
 Advance an operation generation, skipping zero as an invalid generation.

 @param generation : "Current generation"
 @return "Next non-zero generation"
*>
fn Generation next_operation_generation(Generation generation) @local
{
	uint next = (uint)generation + 1;
	if (next == 0) next = 1;
	return (Generation)next;
}

<*
 Report whether this operation header is not free.

 @param self : "Operation header"
 @return "True for any lifecycle state except `OP_FREE`"
*>
fn bool Header.active(&self) => self.state != State.OP_FREE;

<*
 Initialize runtime-owned fields for a fresh operation submission.

 The caller must have already verified that the operation is reusable.

 @param op : "Header to initialize"
 @param kind : "Operation kind for dispatch and cancellation"
 @param loop : "Loop that owns this submission"
 @param callback : "Typed dispatch trampoline"
 @param owner : "Typed owner used by the trampoline"
 @param userdata : "Opaque user pointer captured by this submission"
 @require op != null : "Header pointer must not be null"
 @require loop != null : "Loop pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
 @require !op.active() : "Operation header must be reusable"
*>
fn void init_header(Header* op, Kind kind, Loop* loop, OperationCallback callback, void* owner, void* userdata) @private
{
	op.kind = kind;
	op.generation = next_operation_generation(op.generation);
	op.loop = loop;
	op.owner = owner;
	op.userdata = userdata;
	op.backend = null;
	op.next_ready = null;
	op.timer = null;
	op.ready_flags = 0;
	op.callback = callback;
	op.terminal_status = { };
	op.state = State.OP_ACTIVE;
	link_live(loop, op);
}

<*
 Link an active operation into its loop's live-operation registry.

 The link node lives in caller-owned `Header` storage, so registration is
 allocation-free. Owner-thread only (same as submission).
*>
fn void link_live(Loop* loop, Header* op) @local
{
	op.loop_prev = loop.live_tail;
	op.loop_next = null;
	if (loop.live_tail)
	{
		loop.live_tail.loop_next = op;
	}
	else
	{
		loop.live_head = op;
	}
	loop.live_tail = op;
}

<*
 Unlink an operation from its loop's live registry. No-op if not linked.
*>
fn void unlink_live(Header* op) @local
{
	Loop* loop = op.loop;
	if (!loop) return;
	if (op.loop_prev)
	{
		op.loop_prev.loop_next = op.loop_next;
	}
	else
	{
		loop.live_head = op.loop_next;
	}
	if (op.loop_next)
	{
		op.loop_next.loop_prev = op.loop_prev;
	}
	else
	{
		loop.live_tail = op.loop_prev;
	}
	op.loop_prev = null;
	op.loop_next = null;
}

<*
 Reset runtime-owned fields after a terminal dispatcher has detached an
 operation from all queues and backend/timer storage.

 `kind` and `generation` are intentionally preserved so stale
 `Ref` values stay rejected by generation checks while reusable
 storage keeps its family identity.

 @param op : "Header to make reusable"
 @require op != null : "Header pointer must not be null"
*>
fn void reset_header(Header* op) @private
{
	unlink_live(op);
	op.loop = null;
	op.owner = null;
	op.userdata = null;
	if (op.backend) backend::reset_op_state(op.backend);
	op.backend = null;
	op.next_ready = null;
	op.timer = null;
	op.ready_flags = 0;
	op.callback = null;
	op.terminal_status = { };
	op.state = State.OP_FREE;
}

<*
 Check whether a reference still points to this operation generation.

 @param self : "Header to compare"
 @param oref : "Reference to check"
 @return "True when the reference still names this operation generation"
*>
fn bool Header.matches(&self, Ref oref)
{
	return oref.op == self && oref.generation == self.generation;
}

<*
 Request cancellation through the fastest operation-pointer path.

 Callback-backed operations are completed through the ready queue with
 `nova::CANCELLED`. Header-only test/manual operations without a callback are only
 moved to `OP_CANCELLING`.

 Timer operations that are already ready or calling keep the current callback
 result and only suppress future repeat rearm.
 Worker operations can only be cancelled while still queued in the blocking
 pool. Running worker operations report `nova::BUSY` and may only observe cooperative
 cancellation through their typed operation state.
 Process operations cannot be detached while a child may still need reaping;
 use `process::kill` to request child termination explicitly.

 @param loop : "Loop that owns the active operation"
 @param op : "Active caller-owned operation"
 @return ? nova::INVALID_STATE : "Loop is not initialized"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Worker operation has already started or completed worker execution"
 @return ? NOT_FOUND : "Operation is inactive or belongs to another loop"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? cancel_op(Loop* loop, Header* op)
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (op.loop != loop || !op.active()) return NOT_FOUND~;
	if (op.kind == Kind.WORK) return work::cancel(loop, op);
	if (op.kind == Kind.PROCESS) return process::cancel(loop, op);
	if (op.state == State.OP_READY)
	{
		if (op.kind == Kind.TIMER) op.ready_flags |= timer::NO_REARM;
		if (op.kind == Kind.SIGNAL) signal::unregister(loop, op);
		if (op.kind != Kind.TIMER && op.callback)
		{
			op.terminal_status = nova::CANCELLED;
			op.ready_flags = 0;
		}
		return;
	}

	if (op.state == State.OP_CALLING)
	{
		if (op.kind == Kind.TIMER)
		{
			if (op.timer) timer::heap_remove(loop, op.timer);
			op.ready_flags |= timer::NO_REARM;
			op.state = State.OP_CANCELLING;
		}
		if (op.kind == Kind.SIGNAL)
		{
			signal::unregister(loop, op);
			op.state = State.OP_CANCELLING;
		}
		return;
	}

	if (!op.callback)
	{
		op.state = State.OP_CANCELLING;
		return;
	}

	op.state = State.OP_CANCELLING;
	if (op.timer) timer::heap_remove(loop, op.timer);
	if (op.kind == Kind.SIGNAL) signal::unregister(loop, op);
	if (backend::op_completion(op))
	{
		op.terminal_status = nova::CANCELLED;
		backend::cancel_completion(loop, op);
		op.ready_flags = 0;
		return;
	}
	backend::unregister_interest(loop, op);
	op.ready_flags = 0;
	nova::queue_ready(loop, op, nova::CANCELLED);
}

<*
 Request cancellation through a generation-checked operation reference.

 Stale or null references fail before touching operation storage. A valid
 reference follows the same terminal behavior as `cancel_op`.

 @param loop : "Loop that owns the active operation"
 @param oref : "Operation reference returned by submission"
 @return ? nova::INVALID_STATE : "Loop is not initialized"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Worker operation has already started or completed worker execution"
 @return ? NOT_FOUND : "Reference is stale or operation is inactive"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? cancel_ref(Loop* loop, Ref oref)
{
	if (oref.op == null || !oref.op.matches(oref)) return NOT_FOUND~;
	cancel_op(loop, oref.op)!;
}

<*
 Request cancellation of an operation reference from any thread.

 The request is queued through `post` and `cancel_ref` runs later on the loop
 owner thread. `callback` receives null status on successful cancellation or
 the fault returned by `cancel_ref`.

 @param loop : "Initialized loop with thread submit enabled"
 @param op : "Caller-owned cancel operation storage"
 @param target : "Operation reference to cancel"
 @param callback : "Callback invoked on the loop owner thread"
 @param userdata : "Opaque user pointer delivered to callback"
 @return ? nova::INVALID_STATE : "Loop is not initialized, thread submit is disabled, post queue is not initialized or callback is missing"
 @return ? nova::BUSY : "Cancel operation is already queued"
 @return ? nova::BACKEND_FAILED : "Backend wake failed"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Cancel operation pointer must not be null"
*>
fn void? cancel_ref_async(Loop* loop, CancelOp* op, Ref target, CancelCallback callback, void* userdata = null)
{
	if (!loop.initialized || !loop.options.enable_thread_submit
		|| !loop.post_queue_initialized) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;

	loop.post_mutex.lock()!;
	if (op.post.queued())
	{
		loop.post_mutex.unlock();
		return nova::BUSY~;
	}
	op.target = target;
	op.callback = callback;
	op.userdata = userdata;
	op.status = { };
	bool should_wake = loop.post_head == null;
	nova::enqueue_post_locked(loop, &op.post, &dispatch_cancel_ref_async, null);
	if (should_wake)
	{
		if (catch err = backend::wake(loop))
		{
			loop.post_head = null;
			loop.post_tail = null;
			loop.post_count = 0;
			op.post.next = null;
			op.post.callback = null;
			op.post.userdata = null;
			@atomic_store(op.post.in_queue, (uint)0);
			op.target = { };
			op.callback = null;
			op.userdata = null;
			op.status = { };
			loop.post_mutex.unlock();
			return err~;
		}
	}
	loop.post_mutex.unlock();
}

<*
 Dispatch an async cancellation request posted from another thread.

 The cast is valid because `CancelOp.post` is the first field. This function
 runs on the owner thread and is the only place where the posted request touches
 scheduler-owned operation state.

 @param loop : "Loop dispatching the cancellation request"
 @param post_op : "Embedded post operation at the start of `CancelOp`"
 @param userdata : "Unused post userdata"
 @require loop != null : "Loop pointer must not be null"
 @require post_op != null : "Post operation pointer must not be null"
*>
fn void dispatch_cancel_ref_async(Loop* loop, PostOp* post_op, void* userdata) @local
{
	(void)userdata;
	CancelOp* op            = (CancelOp*)post_op;
	fault status            = @catch(cancel_ref(loop, op.target));
	CancelCallback callback = op.callback;
	void* callback_userdata = op.userdata;
	op.target = { };
	op.callback = null;
	op.userdata = null;
	op.status = status;
	if (callback) callback(loop, op, status, callback_userdata);
}

<*
 Complete an active operation with an explicit terminal status.

 Close paths use this to cancel in-flight operations with `nova::CLOSED` while
 keeping normal user cancellation mapped to `nova::CANCELLED`.
 If a queued-from-readiness stream read/write or signal operation is found, its
 readiness flags are cleared and the queued callback receives `status` (signal
 operations are unregistered first). Other already-queued operations keep the
 result captured at readiness, so a completed send still reports success. An
 operation already inside its callback keeps the in-flight callback result.

 @param loop : "Loop that owns the active operation"
 @param op : "Active caller-owned operation"
 @param status : "Terminal status delivered through the operation callback"
 @return ? NOT_FOUND : "Operation is inactive or belongs to another loop"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void? complete(Loop* loop, Header* op, fault status) @private
{
	if (op.loop != loop || !op.active()) return NOT_FOUND~;

	if (op.state == State.OP_READY)
	{
		if (op.kind == Kind.SIGNAL)
		{
			signal::unregister(loop, op);
			op.terminal_status = status;
			op.ready_flags = 0;
			return;
		}
		if ((op.kind == Kind.STREAM_READ || op.kind == Kind.STREAM_WRITE) && op.callback)
		{
			op.terminal_status = status;
			op.ready_flags = 0;
		}
		return;
	}

	if (op.state == State.OP_CALLING) return;

	State terminal_state = State.OP_CANCELLING;
	if (status == nova::CLOSED) terminal_state = State.OP_CLOSED;
	op.state = terminal_state;
	if (op.timer) timer::heap_remove(loop, op.timer);
	if (op.kind == Kind.SIGNAL) signal::unregister(loop, op);
	if (backend::op_completion(op))
	{
		op.terminal_status = status;
		backend::cancel_completion(loop, op);
		op.ready_flags = 0;
		return;
	}
	backend::unregister_interest(loop, op);
	op.ready_flags = 0;
	nova::queue_ready(loop, op, status);
}

module nova::op::pool <OpType> @private;

import std::core::mem, std::core::mem::alloc;

import nova @norecurse;
import nova::op @public;

<*
 Fixed-capacity pool for one concrete caller-owned operation type.

 The pool owns operation storage but does not submit, cancel or complete
 operations. Core APIs still receive plain `OpType*` pointers.
*>
struct Pool
{
	Allocator allocator;
	OpType[] storage;
	sz[] free_stack;
	uint[] generations;
	bool[] leased;
	sz free_count;
	bool initialized;
	bool aligned_storage;
}

<*
 Lease for one operation slot.

 A live lease owns one pool slot until `release` succeeds. The generation makes
 stale copies fail validation after the slot is returned to the pool. Successful
 release clears both the slot storage and the lease value.
*>
struct Lease
{
	Pool* pool;
	OpType* op;
	sz slot;
	uint generation;
}

<*
 Initialize a typed operation pool.

 @param [&inout] self : "Pool storage"
 @param count : "Number of operation slots"
 @param allocator : "Allocator retained for backing memory until destroy; defaults to the heap allocator `mem`"
 @return "Initialized pool"
 @return ? nova::INVALID_STATE : "Pool is already initialized or count is invalid"
 @return ? mem::OUT_OF_MEMORY : "Backing allocation failed"
*>
fn Pool*? Pool.init(&self, sz count, Allocator allocator = mem)
{
	if (self.initialized) return nova::INVALID_STATE~;
	if (count <= 0) return nova::INVALID_STATE~;
	sz? storage_size = OpType::size.overflow_mul(count);
	if (catch storage_size) return nova::INVALID_STATE~;
	if (catch sz::size.overflow_mul(count)) return nova::INVALID_STATE~;
	if (catch uint::size.overflow_mul(count)) return nova::INVALID_STATE~;

	OpType[] storage;
	bool aligned_storage = false;
	$if OpType::alignment > mem::DEFAULT_MEM_ALIGNMENT:
		storage = ((OpType*)alloc::calloc_aligned(allocator, storage_size!, OpType::alignment)!)[:count];
		aligned_storage = true;
	$else
		storage = alloc::new_array_try(allocator, OpType, count)!;
	$endif
	defer catch
	{
		if (aligned_storage)
		{
			alloc::free_aligned(allocator, storage.ptr);
		}
		else
		{
			alloc::free(allocator, storage.ptr);
		}
	}

	sz[] free_stack = alloc::new_array_try(allocator, sz, count)!;
	defer catch alloc::free(allocator, free_stack.ptr);
	uint[] generations = alloc::new_array_try(allocator, uint, count)!;
	defer catch alloc::free(allocator, generations.ptr);
	bool[] leased = alloc::new_array_try(allocator, bool, count)!;
	defer catch alloc::free(allocator, leased.ptr);

	*self = { };
	self.allocator = allocator;
	self.storage = storage;
	self.free_stack = free_stack;
	self.generations = generations;
	self.leased = leased;
	self.free_count = count;
	self.initialized = true;
	self.aligned_storage = aligned_storage;

	for (sz i = 0; i < count; i++)
	{
		self.free_stack[i] = count - i - 1;
		self.generations[i] = 1;
	}

	return self;
}

<*
 Destroy the pool and release all backing memory.

 @param [&inout] self : "Initialized pool with no active leases"
 @require !self.initialized || self.free_count == self.storage.len : "All leases must be released"
*>
fn void Pool.destroy(&self)
{
	if (self.initialized)
	{
		alloc::free(self.allocator, self.leased.ptr);
		alloc::free(self.allocator, self.generations.ptr);
		alloc::free(self.allocator, self.free_stack.ptr);
		if (self.aligned_storage)
		{
			alloc::free_aligned(self.allocator, self.storage.ptr);
		}
		else
		{
			alloc::free(self.allocator, self.storage.ptr);
		}
		*self = { };
	}
}

<*
 Report whether operation pool storage is initialized.

 @param self : "Pool storage to inspect"
 @return "True after successful `Pool.init` and before `Pool.destroy`"
*>
fn bool Pool.is_initialized(&self) => self.initialized;

<*
 Return the fixed number of operation slots in this pool.

 @param self : "Pool storage to inspect"
 @return "Total slot capacity"
*>
fn sz Pool.capacity(&self) => self.storage.len;

<*
 Return the number of currently available operation slots.

 @param self : "Pool storage to inspect"
 @return "Free slot count"
*>
fn sz Pool.available(&self) => self.free_count;

<*
 Acquire one operation slot.

 @param pool : "Initialized operation pool"
 @return "Lease containing a stable operation pointer"
 @return ? nova::INVALID_STATE : "Pool is not initialized"
 @return ? CAPACITY_EXCEEDED : "No operation slots are available"
 @require pool != null : "Pool pointer must not be null"
*>
fn Lease? acquire(Pool* pool)
{
	if (!pool.initialized) return nova::INVALID_STATE~;
	if (!pool.free_count) return CAPACITY_EXCEEDED~;

	pool.free_count--;
	sz slot = pool.free_stack[pool.free_count];
	pool.leased[slot] = true;
	return { .pool = pool, .op = &pool.storage[slot], .slot = slot, .generation = pool.generations[slot], };
}

<*
 Release one operation slot.

 The slot must not contain an active embedded `op::Header` when `OpType`
 exposes a `header` field. On success, `lease` is cleared and copied lease
 values for the same slot become stale.

 @param [&inout] lease : "Lease returned by `acquire`"
 @return ? nova::BUSY : "Operation is still active"
 @return ? NOT_FOUND : "Lease is stale, already released or does not belong to this pool"
 @require lease != null : "Lease pointer must not be null"
*>
fn void? release(Lease* lease)
{
	if (!lease_valid(lease)) return NOT_FOUND~;
	if (operation_active(lease.op)) return nova::BUSY~;

	Pool* pool = lease.pool;
	sz slot    = lease.slot;
	*lease.op = { };
	pool.leased[slot] = false;
	pool.generations[slot] = next_generation(pool.generations[slot]);
	pool.free_stack[pool.free_count] = slot;
	pool.free_count++;
	*lease = { };
}

<*
 Report whether a lease currently owns a live operation slot.

 Null lease pointers are treated as invalid and return false.

 @param lease : "Lease to validate"
 @return "True when the lease still owns a live operation slot"
*>
fn bool lease_valid(Lease* lease)
{
	if (!lease) return false;
	Pool* pool = lease.pool;
	if (!pool || !pool.initialized) return false;
	if (lease.slot < 0 || lease.slot >= pool.storage.len) return false;
	if (!pool.leased[lease.slot]) return false;
	if (pool.generations[lease.slot] != lease.generation) return false;
	return lease.op == &pool.storage[lease.slot];
}

<*
 Return the operation pointer for a live lease.

 @param lease : "Lease to inspect"
 @return "Borrowed operation pointer, or null for invalid leases"
*>
fn OpType* lease_op(Lease* lease)
{
	if (!lease_valid(lease)) return null;
	return lease.op;
}

<*
 Report whether a leased operation type exposes an active embedded operation.

 @param op : "Leased operation storage"
 @return "True when the embedded header is active"
 @require op != null : "Leased operation pointer must not be null"
*>
fn bool operation_active(OpType* op) @local
{
	bool active = false;
	$if OpType::kind == STRUCT:
		$foreach $member : OpType::members:
			$if $member.name == "header" &&& $defined(op.$member.active()):
				active = op.$member.active();
			$endif
		$endforeach
	$endif
	return active;
}

<*
 Advance a lease generation, skipping zero as an invalid generation.

 @param generation : "Current generation"
 @return "Next non-zero generation"
*>
fn uint next_generation(uint generation)
{
	generation++;
	if (generation == 0) generation = 1;
	return generation;
}
