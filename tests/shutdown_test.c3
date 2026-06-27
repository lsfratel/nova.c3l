module nova_tests;

import std::core::test;

import nova::op @public;
import nova @norecurse, nova::timer;

struct ShutdownCtx
{
	int calls;
	fault last_status;
}

fn void on_shutdown_timer(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	ShutdownCtx* ctx = (ShutdownCtx*)userdata;
	ctx.calls++;
	ctx.last_status = result.error.status;
}

fn void test_close_all_drain_destroy() @test
{
	Loop loop;
	loop.init()!!;

	timer::TimerOp op;
	op.init();
	ShutdownCtx ctx;
	timer::start(&loop, &op, { .delay = (Duration)10_000_000 }, &on_shutdown_timer, &ctx)!!;

	test::@check(loop.timer_count == 1);
	test::@check(loop.live_head != null);

	loop.close_all()!!;
	loop.drain()!!;

	test::@check(loop.timer_count == 0);
	test::@check(loop.live_head == null);

	op.destroy();
	loop.destroy();
}

fn void test_force_destroy_active() @test
{
	Loop loop;
	loop.init()!!;

	timer::TimerOp op;
	op.init();
	ShutdownCtx ctx;
	timer::start(&loop, &op, { .delay = (Duration)10_000_000 }, &on_shutdown_timer, &ctx)!!;
	test::@check(loop.timer_count == 1);

	loop.force_destroy();
	test::@check(!loop.is_initialized());
}

fn void test_default_max_events() @test
{
	Loop loop;
	loop.init()!!;
	test::@check(loop.options.max_events == nova::DEFAULT_MAX_EVENTS);
	test::@check(loop.options.max_events > 0);
	loop.destroy();

	Loop wake_only;
	wake_only.init({ .max_events = 0 })!!;
	test::@check(wake_only.options.max_events == 0);
	wake_only.destroy();
}

fn void test_close_all_empty() @test
{
	Loop loop;
	loop.init()!!;
	loop.close_all()!!;
	loop.drain()!!;
	test::@check(loop.live_head == null);
	loop.destroy();
}
