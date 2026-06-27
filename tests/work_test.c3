module nova_tests;

import std::core::test;
import std::thread;

import nova::op @public;
import nova @norecurse, nova::work;

struct RawTaskCtx
{
	uint started;
	uint release;
	int calls;
}

struct WorkSeen
{
	uint started;
	int work_calls;
	int after_calls;
	fault status;
	bool owner_thread;
	bool op_active_in_after;
}

struct ReuseCtx
{
	int work_calls;
	int after_calls;
}

struct CancelQueueCtx
{
	uint blocker_started;
	int blocker_work_calls;
	int target_work_calls;
	int after_calls;
	int cancelled_calls;
	fault target_status;
}

struct ReadyCancelCtx
{
	uint first_started;
	uint target_started;
	int first_after_calls;
	int target_after_calls;
	fault target_status;
}

fn void raw_blocking_task(work::Task* task)
{
	RawTaskCtx* ctx = (RawTaskCtx*)task.userdata;
	@atomic_store(ctx.started, (uint)1);
	while (@atomic_load(ctx.release) == 0)
	{
		thread::sleep_ms(1);
	}
	ctx.calls++;
}

fn void raw_count_task(work::Task* task)
{
	RawTaskCtx* ctx = (RawTaskCtx*)task.userdata;
	ctx.calls++;
}

fn void? worker_success(WorkOp* op)
{
	WorkSeen* seen = (WorkSeen*)op.header.userdata;
	@atomic_store(seen.started, (uint)1);
	seen.work_calls++;
}

fn void? worker_fault(WorkOp* op)
{
	(void)op;
	return nova::UNSUPPORTED~;
}

fn void after_success(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	WorkSeen* seen = (WorkSeen*)userdata;
	seen.after_calls++;
	seen.status = status;
	seen.owner_thread = loop.is_owner_thread();
	seen.op_active_in_after = op.active();
	loop.stop();
}

fn void after_status_only(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)op;
	WorkSeen* seen = (WorkSeen*)userdata;
	seen.after_calls++;
	seen.status = status;
	loop.stop();
}

fn void? reusable_work(WorkOp* op)
{
	ReuseCtx* ctx = (ReuseCtx*)op.header.userdata;
	ctx.work_calls++;
}

fn void after_reuse(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)status;
	ReuseCtx* ctx = (ReuseCtx*)userdata;
	ctx.after_calls++;
	if (ctx.after_calls == 1)
	{
		work::queue(loop, op, &reusable_work, &after_reuse, ctx)!!;
		return;
	}
	loop.stop();
}

fn void? blocker_work(WorkOp* op)
{
	CancelQueueCtx* ctx = (CancelQueueCtx*)op.header.userdata;
	@atomic_store(ctx.blocker_started, (uint)1);
	ctx.blocker_work_calls++;
	thread::sleep_ms(80);
}

fn void? target_work(WorkOp* op)
{
	CancelQueueCtx* ctx = (CancelQueueCtx*)op.header.userdata;
	ctx.target_work_calls++;
}

fn void after_cancel_queue(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)op;
	CancelQueueCtx* ctx = (CancelQueueCtx*)userdata;
	ctx.after_calls++;
	if (status == nova::CANCELLED)
	{
		ctx.cancelled_calls++;
		ctx.target_status = status;
	}
	if (ctx.after_calls == 2) loop.stop();
}

fn void? running_work(WorkOp* op)
{
	WorkSeen* seen = (WorkSeen*)op.header.userdata;
	@atomic_store(seen.started, (uint)1);
	seen.work_calls++;
	thread::sleep_ms(50);
}

fn void after_running(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	WorkSeen* seen = (WorkSeen*)userdata;
	seen.after_calls++;
	seen.status = status;
	seen.op_active_in_after = op.active();
	loop.stop();
}

fn void? ready_cancel_first_work(WorkOp* op)
{
	ReadyCancelCtx* ctx = (ReadyCancelCtx*)op.header.userdata;
	@atomic_store(ctx.first_started, (uint)1);
}

fn void? ready_cancel_target_work(WorkOp* op)
{
	ReadyCancelCtx* ctx = (ReadyCancelCtx*)op.header.userdata;
	@atomic_store(ctx.target_started, (uint)1);
}

fn void after_ready_cancel_first(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)loop;
	(void)op;
	(void)status;
	ReadyCancelCtx* ctx = (ReadyCancelCtx*)userdata;
	ctx.first_after_calls++;
}

fn void after_ready_cancel_target(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)op;
	ReadyCancelCtx* ctx = (ReadyCancelCtx*)userdata;
	ctx.target_after_calls++;
	ctx.target_status = status;
	loop.stop();
}

struct ConcurrentCtx
{
	bool[4] worked;
	bool[4] after_owner;
	fault[4] statuses;
	int after_done;
}

struct ConcurrentSlot
{
	ConcurrentCtx* ctx;
	int id;
}

fn void? concurrent_work(WorkOp* op)
{
	ConcurrentSlot* slot = (ConcurrentSlot*)op.header.userdata;
	slot.ctx.worked[slot.id] = true;
}

fn void after_concurrent(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)op;
	ConcurrentSlot* slot = (ConcurrentSlot*)userdata;
	slot.ctx.after_owner[slot.id] = loop.is_owner_thread();
	slot.ctx.statuses[slot.id] = status;
	slot.ctx.after_done++;
	if (slot.ctx.after_done == 4) loop.stop();
}

fn void test_work_pool_runs_many_tasks_to_completion() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp[4] ops;
	ConcurrentCtx ctx;
	ConcurrentSlot[4] slots;

	pool.init({ .workers = 4, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;

	for (int i = 0; i < 4; i++)
	{
		ops[i].init();
		slots[i] = { .ctx = &ctx, .id = i };
		work::queue(&loop, &ops[i], &concurrent_work, &after_concurrent, &slots[i])!!;
	}

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(4, ctx.after_done);
	for (int i = 0; i < 4; i++)
	{
		test::@check(ctx.worked[i]);
		test::@check(ctx.after_owner[i]);
		test::@check(!ctx.statuses[i]);
		test::@check(!ops[i].active());
	}

	for (int i = 0; i < 4; i++) ops[i].destroy();
	loop.destroy();
	pool.destroy();
}

const int STRESS_REUSE_OPS    = 8;
const int STRESS_REUSE_PER_OP = 750;

struct StressReuseCtx
{
	fault status;
	bool busy_seen;
}

struct StressReuseSlot
{
	StressReuseCtx* ctx;
	WorkOp* op;
	int iterations;
}

fn void? stress_reuse_work(WorkOp* op)
{
	(void)op;
}

fn void after_stress_reuse(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)op;
	StressReuseSlot* slot = (StressReuseSlot*)userdata;
	StressReuseCtx* ctx   = slot.ctx;
	if (status) ctx.status = status;

	slot.iterations++;
	if (slot.iterations >= STRESS_REUSE_PER_OP) return;

	if (catch work::queue(loop, slot.op, &stress_reuse_work, &after_stress_reuse, slot))
	{
		ctx.busy_seen = true;
	}
}

fn void test_work_reuse_in_after_callback_never_races_task_slot() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp[STRESS_REUSE_OPS] ops;
	StressReuseSlot[STRESS_REUSE_OPS] slots;
	StressReuseCtx ctx;

	pool.init({ .workers = 4, .queue_capacity = STRESS_REUSE_OPS })!!;
	loop.init({ .blocking_pool = &pool })!!;

	for (int i = 0; i < STRESS_REUSE_OPS; i++)
	{
		ops[i].init();
		slots[i] = { .ctx = &ctx, .op = &ops[i] };
		work::queue(&loop, &ops[i], &stress_reuse_work, &after_stress_reuse, &slots[i])!!;
	}

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::@check(!ctx.busy_seen);
	test::@check(!ctx.status);
	for (int i = 0; i < STRESS_REUSE_OPS; i++)
	{
		test::eq(STRESS_REUSE_PER_OP, slots[i].iterations);
		test::@check(!ops[i].active());
	}

	for (int i = 0; i < STRESS_REUSE_OPS; i++) ops[i].destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_work_pool_reports_backpressure() @test
{
	work::Pool pool;
	work::Task blocking;
	work::Task queued;
	work::Task overflow;
	RawTaskCtx ctx;

	pool.init({ .workers = 1, .queue_capacity = 1 })!!;
	blocking.init();
	queued.init();
	overflow.init();

	pool.schedule(&blocking, &raw_blocking_task, &ctx)!!;
	while (@atomic_load(ctx.started) == 0)
	{
		thread::sleep_ms(1);
	}
	pool.schedule(&queued, &raw_count_task, &ctx)!!;
	test::@error(pool.schedule(&overflow, &raw_count_task, &ctx), nova::BACKPRESSURE);

	@atomic_store(ctx.release, (uint)1);
	pool.destroy();
	test::eq(2, ctx.calls);
	test::@check(!blocking.active());
	test::@check(!queued.active());
	test::@check(!overflow.active());
}

fn void test_work_pool_shutdown_rejects_new_tasks() @test
{
	work::Pool pool;
	work::Task task;
	RawTaskCtx ctx;

	pool.init({ .workers = 1, .queue_capacity = 1 })!!;
	task.init();
	pool.shutdown();

	test::@error(pool.schedule(&task, &raw_count_task, &ctx), nova::CLOSED);
	test::@check(!task.active());

	pool.destroy();
}

fn void test_work_queue_runs_after_callback_on_owner_thread() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp op;
	WorkSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	work::queue(&loop, &op, &worker_success, &after_success, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.work_calls);
	test::eq(1, seen.after_calls);
	test::@check(!seen.status);
	test::@check(seen.owner_thread);
	test::@check(!seen.op_active_in_after);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_work_queue_propagates_worker_fault() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp op;
	WorkSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	work::queue(&loop, &op, &worker_fault, &after_status_only, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.after_calls);
	test::@check(seen.status == nova::UNSUPPORTED);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_work_queue_can_reuse_same_op_inside_after_callback() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp op;
	ReuseCtx ctx;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	work::queue(&loop, &op, &reusable_work, &after_reuse, &ctx)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.work_calls);
	test::eq(2, ctx.after_calls);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_work_queue_requires_blocking_pool() @test
{
	Loop loop;
	WorkOp op;
	WorkSeen seen;

	loop.init()!!;
	op.init();

	test::@error(work::queue(&loop, &op, &worker_success, &after_success, &seen), nova::INVALID_STATE);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
}

fn void test_blocking_pool_does_not_enable_public_post() @test
{
	work::Pool pool;
	Loop loop;
	PostOp post;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	post.init();

	test::@error(nova::post(&loop, &post, &on_unused_post, null), nova::INVALID_STATE);
	test::@check(!post.queued());

	loop.destroy();
	pool.destroy();
}

fn void on_unused_post(Loop* loop, PostOp* op, void* userdata)
{
	(void)loop;
	(void)op;
	(void)userdata;
}

fn void test_cancel_queued_work_completes_cancelled() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp blocker;
	WorkOp target;
	CancelQueueCtx ctx;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	blocker.init();
	target.init();

	work::queue(&loop, &blocker, &blocker_work, &after_cancel_queue, &ctx)!!;
	Ref target_ref = work::queue(&loop, &target, &target_work, &after_cancel_queue, &ctx)!!;
	op::cancel_ref(&loop, target_ref)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, ctx.blocker_work_calls);
	test::eq(0, ctx.target_work_calls);
	test::eq(2, ctx.after_calls);
	test::eq(1, ctx.cancelled_calls);
	test::@check(ctx.target_status == nova::CANCELLED);
	test::@check(!blocker.active());
	test::@check(!target.active());

	blocker.destroy();
	target.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_cancel_ready_work_returns_busy_and_preserves_result() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp first;
	WorkOp target;
	ReadyCancelCtx ctx;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool, .dispatch_budget = 1 })!!;
	first.init();
	target.init();

	work::queue(&loop, &first, &ready_cancel_first_work, &after_ready_cancel_first, &ctx)!!;
	Ref target_ref = work::queue(&loop, &target, &ready_cancel_target_work, &after_ready_cancel_target, &ctx)!!;
	while (@atomic_load(ctx.target_started) == 0)
	{
		thread::sleep_ms(1);
	}

	nova::run(&loop, RunMode.NO_WAIT)!!;
	test::eq(1, ctx.first_after_calls);
	test::eq(0, ctx.target_after_calls);
	test::@check(target.active());
	test::@error(op::cancel_ref(&loop, target_ref), nova::BUSY);

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, ctx.target_after_calls);
	test::@check(!ctx.target_status);
	test::@check(!first.active());
	test::@check(!target.active());

	first.destroy();
	target.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_cancel_running_work_returns_busy() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp op;
	WorkSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	Ref ref = work::queue(&loop, &op, &running_work, &after_running, &seen)!!;
	while (@atomic_load(seen.started) == 0)
	{
		thread::sleep_ms(1);
	}
	test::@error(op::cancel_ref(&loop, ref), nova::BUSY);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.work_calls);
	test::eq(1, seen.after_calls);
	test::@check(!seen.status);
	test::@check(!seen.op_active_in_after);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
	pool.destroy();
}
