module nova_tests;

import std::core::test;
import std::thread;

import nova::op @public;
import nova @norecurse, nova::timer;

struct StopThreadCtx
{
	Loop* loop;
	fault status;
}

struct RunThreadCtx
{
	Loop* loop;
	fault status;
}

struct TimerStartThreadCtx
{
	Loop* loop;
	timer::TimerOp op;
	TimerSeen seen;
	fault status;
}

struct PostThreadCtx
{
	Loop* loop;
	PostOp post_op;
	fault status;
	int calls;
	bool owner_thread;
}

struct CancelThreadCtx
{
	Loop* loop;
	Ref target;
	CancelOp cancel_op;
	fault submit_status;
	fault cancel_status;
	int cancel_calls;
	TimerSeen timer_seen;
}

struct ConcurrentCancelArg
{
	Loop* loop;
	CancelOp* op;
	Ref target;
	CancelThreadCtx* ctx;
	fault status;
}

fn int request_stop_thread(void* raw)
{
	StopThreadCtx* ctx = (StopThreadCtx*)raw;
	ctx.status = @catch(ctx.loop.request_stop());
	return ctx.status ? 1 : 0;
}

fn int run_thread(void* raw)
{
	RunThreadCtx* ctx = (RunThreadCtx*)raw;
	ctx.status = @catch(nova::run(ctx.loop, RunMode.NO_WAIT));
	return ctx.status ? 1 : 0;
}

fn int timer_start_thread(void* raw)
{
	TimerStartThreadCtx* ctx = (TimerStartThreadCtx*)raw;
	ctx.status = @catch(timer::start(ctx.loop, &ctx.op, { .delay = (Duration)1 }, &on_timer, &ctx.seen));
	return ctx.status ? 1 : 0;
}

fn int post_thread(void* raw)
{
	PostThreadCtx* ctx = (PostThreadCtx*)raw;
	ctx.status = @catch(nova::post(ctx.loop, &ctx.post_op, &on_thread_post, ctx));
	return ctx.status ? 1 : 0;
}

fn int cancel_thread(void* raw)
{
	CancelThreadCtx* ctx = (CancelThreadCtx*)raw;
	ctx.submit_status = @catch(op::cancel_ref_async(ctx.loop, &ctx.cancel_op, ctx.target, &on_cancel_async, ctx));
	return ctx.submit_status ? 1 : 0;
}

fn int concurrent_cancel_thread(void* raw)
{
	ConcurrentCancelArg* arg = (ConcurrentCancelArg*)raw;
	arg.status = @catch(op::cancel_ref_async(arg.loop, arg.op, arg.target, &on_cancel_async, arg.ctx));
	return arg.status ? 1 : 0;
}

fn void on_thread_post(Loop* loop, PostOp* op, void* userdata)
{
	(void)op;
	PostThreadCtx* ctx = (PostThreadCtx*)userdata;
	ctx.calls++;
	ctx.owner_thread = loop.is_owner_thread();
	loop.stop();
}

fn void on_count_post(Loop* loop, PostOp* op, void* userdata)
{
	(void)loop;
	(void)op;
	PostThreadCtx* ctx = (PostThreadCtx*)userdata;
	ctx.calls++;
}

fn void on_cancel_async(Loop* loop, CancelOp* op, fault status, void* userdata)
{
	(void)loop;
	(void)op;
	CancelThreadCtx* ctx = (CancelThreadCtx*)userdata;
	ctx.cancel_calls++;
	ctx.cancel_status = status;
}

fn void on_cancelled_timer_stop(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	on_timer(loop, op, result, userdata);
	loop.stop();
}

fn void test_request_stop_from_thread_unblocks_until_stopped() @test
{
	Loop loop;
	StopThreadCtx ctx = { .loop = &loop };
	thread::Thread worker;

	loop.init({ .enable_thread_submit = true })!!;
	worker.create(&request_stop_thread, &ctx)!!;

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	int result = worker.join()!!;

	test::eq(0, result);
	test::@check(!ctx.status);
	test::@check(!loop.alive());

	loop.destroy();
}

fn void test_run_from_non_owner_thread_is_rejected() @test
{
	Loop loop;
	RunThreadCtx ctx = { .loop = &loop };
	thread::Thread worker;

	loop.init({ .enable_thread_submit = true })!!;
	worker.create(&run_thread, &ctx)!!;
	int result = worker.join()!!;

	test::eq(1, result);
	test::@check(ctx.status == nova::NOT_OWNER);
	test::@check(loop.is_owner_thread());

	loop.destroy();
}

fn void test_timer_start_from_non_owner_thread_is_rejected() @test
{
	Loop loop;
	TimerStartThreadCtx ctx = { .loop = &loop };
	thread::Thread worker;

	loop.init({ .enable_thread_submit = true })!!;
	ctx.op.init();
	worker.create(&timer_start_thread, &ctx)!!;
	int result = worker.join()!!;

	test::eq(1, result);
	test::@check(ctx.status == nova::NOT_OWNER);
	test::@check(!ctx.op.active());
	test::eq(0, ctx.seen.calls);

	ctx.op.destroy();
	loop.destroy();
}

fn void test_post_from_thread_runs_on_owner_thread() @test
{
	Loop loop;
	PostThreadCtx ctx = { .loop = &loop };
	thread::Thread worker;

	ctx.post_op.init();
	loop.init({ .enable_thread_submit = true })!!;
	worker.create(&post_thread, &ctx)!!;

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	int result = worker.join()!!;

	test::eq(0, result);
	test::@check(!ctx.status);
	test::eq(1, ctx.calls);
	test::@check(ctx.owner_thread);
	test::@check(!ctx.post_op.queued());

	loop.destroy();
}

fn void test_post_rejects_reuse_while_queued() @test
{
	Loop loop;
	PostThreadCtx ctx = { .loop = &loop };

	ctx.post_op.init();
	loop.init({ .enable_thread_submit = true })!!;

	nova::post(&loop, &ctx.post_op, &on_count_post, &ctx)!!;
	test::@error(nova::post(&loop, &ctx.post_op, &on_count_post, &ctx), nova::BUSY);
	test::@check(ctx.post_op.queued());

	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, ctx.calls);
	test::@check(!ctx.post_op.queued());

	loop.destroy();
}

fn void test_cancel_ref_async_from_thread_cancels_timer_on_owner_thread() @test
{
	Loop loop;
	timer::TimerOp timer_op;
	CancelThreadCtx ctx = { .loop = &loop };
	thread::Thread worker;

	loop.init({ .enable_thread_submit = true })!!;
	timer_op.init();
	ctx.cancel_op.init();

	ctx.target = timer::start(
		&loop,
		&timer_op,
		{ .delay = (Duration)60_000_000 },
		&on_cancelled_timer_stop,
		&ctx.timer_seen
	)!!;

	worker.create(&cancel_thread, &ctx)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	int result = worker.join()!!;

	test::eq(0, result);
	test::@check(!ctx.submit_status);
	test::eq(1, ctx.cancel_calls);
	test::@check(!ctx.cancel_status);
	test::eq(1, ctx.timer_seen.calls);
	test::@check(ctx.timer_seen.status == nova::CANCELLED);
	test::@check(!timer_op.active());
	test::@check(!ctx.cancel_op.post.queued());

	timer_op.destroy();
	loop.destroy();
}

fn void test_cancel_ref_async_rejects_reuse_without_retargeting() @test
{
	Loop loop;
	timer::TimerOp first_timer;
	timer::TimerOp second_timer;
	CancelThreadCtx ctx = { .loop = &loop };
	TimerSeen first_seen;
	TimerSeen second_seen;

	loop.init({ .enable_thread_submit = true })!!;
	first_timer.init();
	second_timer.init();
	ctx.cancel_op.init();

	Ref first_ref  = timer::start(&loop, &first_timer, { .delay = (Duration)60_000_000 }, &on_timer, &first_seen)!!;
	Ref second_ref = timer::start(&loop, &second_timer, { .delay = (Duration)60_000_000 }, &on_timer, &second_seen)!!;

	op::cancel_ref_async(&loop, &ctx.cancel_op, first_ref, &on_cancel_async, &ctx)!!;
	test::@error(op::cancel_ref_async(&loop, &ctx.cancel_op, second_ref, &on_cancel_async, &ctx), nova::BUSY);

	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, ctx.cancel_calls);
	test::@check(!ctx.cancel_status);
	test::eq(1, first_seen.calls);
	test::@check(first_seen.status == nova::CANCELLED);
	test::@check(!first_timer.active());
	test::eq(0, second_seen.calls);
	test::@check(second_timer.active());
	test::@check(!ctx.cancel_op.post.queued());

	timer::stop(&loop, &second_timer)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, second_seen.calls);
	test::@check(second_seen.status == nova::CANCELLED);
	test::@check(!second_timer.active());

	first_timer.destroy();
	second_timer.destroy();
	loop.destroy();
}

fn void test_cancel_ref_async_concurrent_reuse_cancels_only_winner() @test
{
	Loop loop;
	timer::TimerOp first_timer;
	timer::TimerOp second_timer;
	CancelThreadCtx ctx            = { .loop = &loop };
	TimerSeen first_seen;
	TimerSeen second_seen;
	ConcurrentCancelArg first_arg  = { .loop = &loop, .op = &ctx.cancel_op, .ctx = &ctx };
	ConcurrentCancelArg second_arg = { .loop = &loop, .op = &ctx.cancel_op, .ctx = &ctx };
	thread::Thread first_thread;
	thread::Thread second_thread;

	loop.init({ .enable_thread_submit = true })!!;
	first_timer.init();
	second_timer.init();
	ctx.cancel_op.init();

	first_arg.target = timer::start(&loop, &first_timer, { .delay = (Duration)60_000_000 }, &on_timer, &first_seen)!!;
	second_arg.target = timer::start(
		&loop,
		&second_timer,
		{ .delay = (Duration)60_000_000 },
		&on_timer,
		&second_seen
	)!!;

	first_thread.create(&concurrent_cancel_thread, &first_arg)!!;
	second_thread.create(&concurrent_cancel_thread, &second_arg)!!;
	(void)first_thread.join()!!;
	(void)second_thread.join()!!;

	bool first_won  = !first_arg.status && second_arg.status == nova::BUSY;
	bool second_won = !second_arg.status && first_arg.status == nova::BUSY;
	test::@check(first_won || second_won);

	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, ctx.cancel_calls);
	test::@check(!ctx.cancel_status);
	if (!first_arg.status)
	{
		test::eq(1, first_seen.calls);
		test::@check(first_seen.status == nova::CANCELLED);
		test::@check(!first_timer.active());
		test::eq(0, second_seen.calls);
		test::@check(second_timer.active());
		timer::stop(&loop, &second_timer)!!;
	}
	else
	{
		test::eq(1, second_seen.calls);
		test::@check(second_seen.status == nova::CANCELLED);
		test::@check(!second_timer.active());
		test::eq(0, first_seen.calls);
		test::@check(first_timer.active());
		timer::stop(&loop, &first_timer)!!;
	}

	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::@check(!first_timer.active());
	test::@check(!second_timer.active());
	test::@check(!ctx.cancel_op.post.queued());

	first_timer.destroy();
	second_timer.destroy();
	loop.destroy();
}
