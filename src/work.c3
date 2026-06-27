module nova::work;

import std::core::mem::alloc;
import std::thread;

import nova @norecurse;
import nova::op @public;

<*
 Callback executed on a worker thread for a generic work operation.

 The callback must not touch owner-thread-only loop state. It may return a
 recoverable fault that is delivered to the after-work callback.
*>
alias WorkCallback = fn void?(WorkOp* op);

<*
 Callback invoked on the loop owner thread after worker execution finishes.

 `status == null` means the worker callback completed successfully. Non-null
 status values come from cancellation before start or from the worker callback.
*>
alias AfterWorkCallback = fn void(Loop* loop, WorkOp* op, fault status, void* userdata);

<*
 Callback executed by a worker thread for one scheduled task.

 @param task : "Task storage scheduled on the pool"
*>
alias Callback = fn void(Task* task);

<*
 Worker task lifecycle states stored atomically in `Task.state`.
*>
const uint TASK_FREE    = 0;
const uint TASK_QUEUED  = 1;
const uint TASK_RUNNING = 2;

<*
 Caller-owned generic worker operation.

 `header` must be the first field so generic cancellation and dispatch can use the
 embedded `Header*`. The storage must remain pointer-stable while active.
*>
struct WorkOp
{
	inline Header header;
	Task task;
	PostOp post;
	WorkCallback work_callback;
	AfterWorkCallback after_callback;
	void* after_userdata;
	fault worker_status;
	uint cancel_requested_flag;
}

<*
 Worker pool configuration.

 `workers` is the fixed number of worker threads created during `Pool.init`.
 `queue_capacity` limits queued, not currently running, tasks.
 `thread_settings` is passed to each native thread creation.
*>
struct Config
{
	sz workers;
	sz queue_capacity;
	thread::ThreadSettings thread_settings;
}

<*
 Intrusive task submitted to a worker pool.

 Task storage is caller-owned and must remain pointer-stable until the worker
 callback has returned or the task has been cancelled while queued.
 The same task must not be scheduled in more than one pool at a time.
*>
struct Task
{
	Task* next;
	Task* prev;
	Pool* pool;
	Callback callback;
	Callback done;
	void* userdata;
	uint state;
}

<*
 Fixed-size worker pool for blocking or CPU-heavy work.

 The pool owns its worker threads and synchronization primitives. Task storage
 remains caller-owned and no task allocation happens while scheduling.
*>
struct Pool
{
	Allocator allocator;
	thread::Thread[] workers;
	thread::Mutex mutex;
	thread::ConditionVariable notify;
	Task* head;
	Task* tail;
	sz queued_count;
	sz queue_capacity;
	bool initialized;
	bool stopping;
}

<*
 Initialize caller-owned work operation storage.

 @param [&inout] self : "Work operation storage"
 @return "Initialized work operation"
 @require self.header.state == State.OP_FREE : "Work operation must not be active"
 @ensure self.header.state == State.OP_FREE : "Initialized work operation is free"
*>
fn WorkOp* WorkOp.init(&self)
{
	*self = { };
	self.header.kind = Kind.WORK;
	self.header.state = State.OP_FREE;
	self.task.init();
	self.post.init();
	return self;
}

<*
 Destroy caller-owned work operation storage.

 @param [&inout] self : "Work operation storage"
 @require self.header.state == State.OP_FREE : "Work operation must be free"
 @require !self.task.active() : "Worker task must not be queued or running"
 @require !self.post.queued() : "Completion post must not be queued"
 @ensure self.header.state == State.OP_FREE : "Destroyed work operation is free"
*>
fn void WorkOp.destroy(&self)
{
	*self = { };
	self.header.kind = Kind.WORK;
	self.header.state = State.OP_FREE;
}

<*
 Report whether this worker operation is queued, running or completing.

 @param self : "Work operation storage to inspect"
 @return "True while the embedded operation header is active"
*>
fn bool WorkOp.active(&self) => self.header.active();

<*
 Report whether cancellation has been requested for this operation.

 Worker callbacks can poll this for cooperative cancellation. Blocking system
 calls are not interrupted by this flag.

 @param self : "Work operation storage to inspect"
 @return "True when cancellation was requested"
*>
fn bool WorkOp.cancel_requested(&self) => @atomic_load(self.cancel_requested_flag) != 0;

<*
 Submit generic work to the loop's blocking pool.

 The worker callback runs on a worker thread. The after-work callback always
 runs on the loop owner thread. `loop.options.blocking_pool` must remain
 initialized until the after-work callback returns.

 @param loop : "Loop configured with `Options.blocking_pool`"
 @param op : "Caller-owned work operation storage"
 @param work_callback : "Callback executed on a worker thread"
 @param after_callback : "Callback executed on the loop owner thread"
 @param userdata : "Opaque pointer delivered to the after-work callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop is invalid, has no blocking pool or callbacks are missing"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Operation is already active"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Work operation pointer must not be null"
*>
fn Ref? queue(
	Loop* loop,
	WorkOp* op,
	WorkCallback work_callback,
	AfterWorkCallback after_callback,
	void* userdata = null
)
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!loop.options.blocking_pool || !loop.post_queue_initialized) return nova::INVALID_STATE~;
	if (!work_callback || !after_callback) return nova::INVALID_STATE~;
	if (op.header.active()) return nova::BUSY~;

	op.work_callback = work_callback;
	op.after_callback = after_callback;
	op.after_userdata = userdata;
	op.worker_status = { };
	@atomic_store(op.cancel_requested_flag, (uint)0);
	op::init_header(&op.header, Kind.WORK, loop, &dispatch_work_ready, op, userdata);
	loop.worker_active_count++;

	if (catch err = loop.options.blocking_pool.schedule(&op.task, &run_work_task, op, &emit_work_completion))
	{
		loop.worker_active_count--;
		reset_work_fields(op);
		op::reset_header(&op.header);
		return err~;
	}
	return op.header.to_ref();
}

<*
 Execute the user work callback on a worker thread.

 The result is stored on the caller-owned operation. Completion is published to
 the owner thread separately by `emit_work_completion`, run as the task `done`
 hook once the worker has released the task slot.

 @param task : "Pool task embedded in a `WorkOp`"
 @require task != null : "Task pointer must not be null"
 @require task.userdata != null : "Task must carry a `WorkOp` pointer"
*>
fn void run_work_task(Task* task) @local
{
	WorkOp* op = (WorkOp*)task.userdata;
	if (op.cancel_requested())
	{
		op.worker_status = nova::CANCELLED;
	}
	else
	{
		op.worker_status = @catch(op.work_callback(op));
	}
}

<*
 Publish a finished worker operation to the owner loop.

 Invoked as the pool task `done` hook, after the worker has released the task
 slot, so an after-work callback that reuses the same `WorkOp` cannot race the
 slot back to `TASK_RUNNING`.

 @param task : "Pool task embedded in a completed `WorkOp`"
 @require task != null : "Task pointer must not be null"
 @require task.userdata != null : "Task must carry a `WorkOp` pointer"
*>
fn void emit_work_completion(Task* task) @local
{
	WorkOp* op = (WorkOp*)task.userdata;
	always_assert(@ok(nova::post_internal(op.header.loop, &op.post, &dispatch_work_post, op)));
}

<*
 Publish a completed worker operation into the owner loop's ready queue.

 @param loop : "Loop that owns the work operation"
 @param post : "Internal post operation used for worker completion"
 @param userdata : "Completed `WorkOp` pointer"
 @require loop != null : "Loop pointer must not be null"
 @require userdata != null : "Work operation pointer must not be null"
*>
fn void dispatch_work_post(Loop* loop, PostOp* post, void* userdata) @local
{
	(void)post;
	WorkOp* op = (WorkOp*)userdata;
	if (op.header.loop != loop || !op.header.active()) return;
	nova::queue_ready(loop, &op.header, op.worker_status);
}

<*
 Finish a worker operation on the owner loop thread.

 The operation is reset before the after-work callback so the callback can reuse
 the same `WorkOp` immediately.

 @param loop : "Loop that owns the ready operation"
 @param raw : "Ready operation header"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_work_ready(Loop* loop, void* raw) @local
{
	Header* header             = (Header*)raw;
	WorkOp* op                 = (WorkOp*)header.owner;
	AfterWorkCallback callback = op.after_callback;
	void* userdata             = op.after_userdata;
	fault status               = header.terminal_status;

	always_assert(loop.worker_active_count > 0);
	loop.worker_active_count--;
	op::reset_header(header);
	reset_work_fields(op);
	if (callback) callback(loop, op, status, userdata);
}

<*
 Cancel a work operation from owner-loop code.

 Queued tasks are removed from the blocking pool and completed as `nova::CANCELLED`.
 Running or already-completed tasks are not interrupted and report `nova::BUSY`.

 @param loop : "Loop that owns the work operation"
 @param header : "Active work operation header"
 @return ? nova::INVALID_STATE : "Loop has no blocking pool"
 @return ? nova::BUSY : "Work has already started running or is being completed"
 @return ? NOT_FOUND : "Work task is no longer queued"
 @require loop != null : "Loop pointer must not be null"
 @require header != null : "Header pointer must not be null"
*>
fn void? cancel(Loop* loop, Header* header)
{
	if (!loop.options.blocking_pool) return nova::INVALID_STATE~;
	WorkOp* op = (WorkOp*)header.owner;
	@atomic_store(op.cancel_requested_flag, (uint)1);

	if (header.state == State.OP_READY)
	{
		return nova::BUSY~;
	}
	if (header.state == State.OP_CALLING) return nova::BUSY~;
	if (op.post.queued()) return nova::BUSY~;

	loop.options.blocking_pool.cancel(&op.task)!;
	nova::queue_ready(loop, header, nova::CANCELLED);
	return;
}

<*
 Clear transient callbacks and status after a work operation completes or fails
 to submit.

 @param op : "Work operation storage to reset"
 @require op != null : "Work operation pointer must not be null"
*>
fn void reset_work_fields(WorkOp* op) @local
{
	op.work_callback = null;
	op.after_callback = null;
	op.after_userdata = null;
	op.worker_status = { };
	@atomic_store(op.cancel_requested_flag, (uint)0);
}

<*
 Initialize caller-owned task storage.

 @param [&inout] self : "Task storage"
 @return "Initialized task"
 @require !self.active() : "Task must not be queued or running"
 @ensure !self.active() : "Initialized task is not queued or running"
*>
fn Task* Task.init(&self)
{
	*self = { };
	return self;
}

<*
 Report whether this task is queued or running.

 @param self : "Task storage to inspect"
 @return "True while the task is not free"
*>
fn bool Task.active(&self) => @atomic_load(self.state) != TASK_FREE;

<*
 Initialize a fixed worker pool.

 @param [&inout] self : "Pool storage"
 @param config : "Worker and queue sizing"
 @param allocator : "Allocator used for the worker thread array; defaults to the heap allocator `mem`"
 @return "Initialized pool"
 @return ? nova::INVALID_STATE : "Pool is already initialized or config is invalid"
 @return ? mem::OUT_OF_MEMORY : "Worker array allocation failed"
 @return ? thread::INIT_FAILED : "A worker thread could not be created"
 @return ? thread::INVALID_THREAD_SETTINGS : "Thread settings were rejected"
 @ensure self.initialized : "Pool is initialized when init succeeds"
*>
fn Pool*? Pool.init(&self, Config config = { .workers = 4, .queue_capacity = 1024 }, Allocator allocator = mem)
{
	if (self.initialized) return nova::INVALID_STATE~;
	if (config.workers <= 0 || config.queue_capacity <= 0) return nova::INVALID_STATE~;
	if (catch thread::Thread::size.overflow_mul(config.workers)) return nova::INVALID_STATE~;

	*self = { };
	self.allocator = allocator;
	self.queue_capacity = config.queue_capacity;
	self.workers = alloc::new_array_try(allocator, thread::Thread, config.workers)!;
	defer catch
	{
		alloc::free(allocator, self.workers.ptr);
		*self = { };
	}

	self.mutex.init()!;
	defer catch self.mutex.destroy();
	self.notify.init()!;
	defer catch self.notify.destroy();
	self.initialized = true;

	for (sz i = 0; i < self.workers.len; i++)
	{
		if (catch err = self.workers[i].create(&pool_worker_main, self, config.thread_settings))
		{
			self.workers = self.workers[0:i];
			self.shutdown();
			pool_join_workers(self);
			return err~;
		}
	}
	return self;
}

<*
 Stop accepting new tasks and let workers finish queued and running work.

 @param [&inout] self : "Initialized pool"
*>
fn void Pool.shutdown(&self)
{
	if (!self.initialized) return;
	self.mutex.lock();
	self.stopping = true;
	self.notify.broadcast();
	self.mutex.unlock();
}

<*
 Destroy a worker pool after all workers exit.

 Pending queued work is drained before workers stop. Running callbacks are not
 interrupted.

 @param [&inout] self : "Initialized pool"
 @ensure !self.initialized : "Pool is uninitialized after destroy"
*>
fn void Pool.destroy(&self)
{
	if (!self.initialized) return;
	self.shutdown();
	pool_join_workers(self);
	self.notify.destroy();
	self.mutex.destroy();
	alloc::free(self.allocator, self.workers.ptr);
	*self = { };
}

<*
 Schedule one task on the pool.

 @param [&inout] self : "Initialized pool"
 @param task : "Caller-owned task storage"
 @param callback : "Worker-thread callback"
 @param userdata : "Opaque pointer available to the callback through `task.userdata`"
 @param done : "Optional completion hook invoked on the worker thread after the task slot is released, so a completion can resubmit the same task storage without racing the slot"
 @return ? nova::INVALID_STATE : "Pool is not initialized or callback is missing"
 @return ? nova::CLOSED : "Pool is shutting down"
 @return ? nova::BUSY : "Task is already queued or running"
 @return ? nova::BACKPRESSURE : "Queue capacity has been reached"
 @require task != null : "Task pointer must not be null"
*>
fn void? Pool.schedule(&self, Task* task, Callback callback, void* userdata = null, Callback done = null)
{
	if (!self.initialized || !callback) return nova::INVALID_STATE~;

	self.mutex.lock();
	defer self.mutex.unlock();
	if (self.stopping) return nova::CLOSED~;
	if (task.active()) return nova::BUSY~;
	if (self.queued_count >= self.queue_capacity) return nova::BACKPRESSURE~;

	task.next = null;
	task.pool = self;
	task.callback = callback;
	task.done = done;
	task.userdata = userdata;
	@atomic_store(task.state, TASK_QUEUED);
	if (self.tail)
	{
		task.prev = self.tail;
		self.tail.next = task;
		self.tail = task;
	}
	else
	{
		task.prev = null;
		self.head = task;
		self.tail = task;
	}
	self.queued_count++;
	self.notify.signal();
}

<*
 Cancel a task that has not started running.

 @param [&inout] self : "Initialized pool"
 @param task : "Scheduled task storage"
 @return ? nova::INVALID_STATE : "Pool is not initialized"
 @return ? NOT_FOUND : "Task is not queued in this pool"
 @return ? nova::BUSY : "Task is already running"
 @require task != null : "Task pointer must not be null"
*>
fn void? Pool.cancel(&self, Task* task)
{
	if (!self.initialized) return nova::INVALID_STATE~;

	self.mutex.lock();
	defer self.mutex.unlock();
	uint state = @atomic_load(task.state);
	if (state == TASK_RUNNING) return nova::BUSY~;
	if (state != TASK_QUEUED) return NOT_FOUND~;
	if (task.pool != self) return NOT_FOUND~;

	if (task.prev)
	{
		task.prev.next = task.next;
	}
	else
	{
		self.head = task.next;
	}
	if (task.next)
	{
		task.next.prev = task.prev;
	}
	else
	{
		self.tail = task.prev;
	}
	self.queued_count--;
	task.next = null;
	task.prev = null;
	task.callback = null;
	task.done = null;
	task.userdata = null;
	@atomic_store(task.state, TASK_FREE);
}

<*
 Join every worker thread owned by a shutting-down pool.

 @param pool : "Initialized pool whose workers have been asked to stop"
 @require pool != null : "Pool pointer must not be null"
 @require pool.initialized : "Pool must be initialized"
*>
fn void pool_join_workers(Pool* pool) @local
{
	foreach (worker : pool.workers)
	{
		(void)worker.join();
	}
}

<*
 Remove and return the oldest queued task.

 @param pool : "Pool with its mutex already held"
 @return "Dequeued task or null when the queue is empty"
 @require pool != null : "Pool pointer must not be null"
*>
fn Task* pool_pop_task_locked(Pool* pool) @local
{
	Task* task = pool.head;
	if (!task) return null;
	pool.head = task.next;
	if (!pool.head)
	{
		pool.tail = null;
	}
	else
	{
		pool.head.prev = null;
	}
	task.next = null;
	task.prev = null;
	pool.queued_count--;
	return task;
}

<*
 Worker thread entry point.

 The worker drains queued tasks until shutdown has been requested and no queued
 task remains. Task callbacks run outside the pool mutex.

 @param raw : "Pool pointer passed to `Thread.create`"
 @return "Native thread exit code"
 @require raw != null : "Pool pointer must not be null"
*>
fn int pool_worker_main(void* raw) @local
{
	Pool* pool = (Pool*)raw;
	while (true)
	{
		pool.mutex.lock();
		while (!pool.head && !pool.stopping)
		{
			pool.notify.wait(&pool.mutex);
		}
		if (!pool.head && pool.stopping)
		{
			pool.mutex.unlock();
			return 0;
		}

		Task* task        = pool_pop_task_locked(pool);
		Callback callback = task.callback;
		Callback done     = task.done;
		@atomic_store(task.state, TASK_RUNNING);
		pool.mutex.unlock();

		callback(task);

		@atomic_store(task.state, TASK_FREE);

		if (done) done(task);
	}
}
