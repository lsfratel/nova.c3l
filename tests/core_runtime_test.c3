module nova_tests;

import std::core::test;

import nova::op @public;
import nova @norecurse, nova::timer;

fn void on_generation_wrap(Loop* loop, void* raw)
{
	(void)loop;
	op::reset_header((Header*)raw);
}

struct ReadyCancelSeen
{
	fault status;
	int calls;
}

fn void on_ready_cancel_seen(Loop* loop, void* raw)
{
	(void)loop;
	Header* op            = (Header*)raw;
	ReadyCancelSeen* seen = (ReadyCancelSeen*)op.userdata;
	seen.calls++;
	seen.status = op.terminal_status;
	op::reset_header(op);
}

fn void test_loop_lifecycle() @test
{
	Loop loop;

	loop.init()!!;
	test::@check(loop.is_initialized());
	test::@check(loop.alive());
	test::@check(loop.is_owner_thread());
	test::@error(nova::run(&loop, (RunMode)99), nova::INVALID_STATE);

	loop.wake()!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	loop.stop();
	test::@check(!loop.alive());

	loop.destroy();
	test::@check(!loop.is_initialized());
	test::@check(loop.backend_handle == (NativeHandle)-1);
	test::@check(loop.wake_handle == (NativeHandle)-1);
	test::@check(loop.wake_write_handle == (NativeHandle)-1);
}

fn void test_loop_rejects_max_event_capacity_overflow() @test
{
	Loop loop;

	test::@error(loop.init({ .max_events = sz::max }), nova::INVALID_STATE);
	test::@error(loop.init({ .max_events = (sz)int::max }), nova::INVALID_STATE);
	test::@check(!loop.is_initialized());
}
fn void test_loop_rejects_negative_capacities_and_budgets() @test
{
	Loop loop;

	test::@error(loop.init({ .max_events = (sz)-1 }), nova::INVALID_STATE);
	test::@error(loop.init({ .dispatch_budget = (sz)-1 }), nova::INVALID_STATE);
	test::@error(loop.init({ .io_progress_budget = (sz)-1 }), nova::INVALID_STATE);
	test::@check(!loop.is_initialized());
}

fn void test_operation_ref_and_cancel() @test
{
	Loop loop;
	Header op;

	loop.init()!!;
	op.loop = &loop;
	op.state = State.OP_ACTIVE;
	op.generation = (Generation)7;

	Ref oref = op.to_ref();
	test::@check(op.active());
	test::@check(op.matches(oref));

	op::cancel_ref(&loop, oref)!!;
	test::@check(op.state == State.OP_CANCELLING);

	op.state = State.OP_FREE;
	test::@error(op::cancel_ref(&loop, oref), NOT_FOUND);

	loop.destroy();
}

fn void test_operation_generation_wrap_skips_zero() @test
{
	Loop loop;
	Header op;
	fault status;

	loop.init()!!;
	op.generation = (Generation)uint::max;

	Ref oref = nova::submit_immediate(&loop, &op, Kind.NONE, &on_generation_wrap, null, null, status)!!;
	test::eq((uint)1, (uint)oref.generation);
	test::eq((uint)1, (uint)op.generation);

	nova::run(&loop, RunMode.NO_WAIT)!!;
	loop.destroy();
}

fn void test_cancel_ready_operation_updates_callback_status() @test
{
	Loop loop;
	Header op;
	ReadyCancelSeen seen;
	fault status;

	loop.init()!!;
	Ref oref = nova::submit_immediate(&loop, &op, Kind.NONE, &on_ready_cancel_seen, null, &seen, status)!!;

	op::cancel_ref(&loop, oref)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::CANCELLED);
	test::@check(!op.active());

	loop.destroy();
}

fn void test_wake_unblocks_once() @test
{
	Loop loop;

	loop.init()!!;
	loop.wake()!!;
	nova::run(&loop, RunMode.ONCE)!!;
	loop.destroy();
}
fn void test_once_without_work_returns() @test
{
	Loop loop;

	loop.init()!!;
	nova::run(&loop, RunMode.ONCE)!!;
	loop.destroy();
}

fn void test_has_work_tracks_pending_timer() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init()!!;
	op.init();
	test::@check(!nova::has_work(&loop));

	timer::start(&loop, &op, { .delay = (Duration)60_000_000 }, &on_timer, &seen)!!;
	test::@check(nova::has_work(&loop));
	test::eq((sz)1, loop.timer_count);

	timer::stop(&loop, &op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;
	test::@check(!nova::has_work(&loop));
	test::eq((sz)0, loop.timer_count);

	op.destroy();
	loop.destroy();
}

fn void test_run_once_dispatches_pending_timer() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init()!!;
	op.init();

	timer::start(&loop, &op, { .delay = (Duration)1_000 }, &on_timer, &seen)!!;
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
}

fn void test_multiple_wakes_coalesce_and_drain_in_one_tick() @test
{
	Loop loop;

	loop.init()!!;
	loop.wake()!!;
	loop.wake()!!;
	loop.wake()!!;

	nova::run(&loop, RunMode.NO_WAIT)!!;
	test::@check(!nova::has_work(&loop));

	nova::run(&loop, RunMode.ONCE)!!;
	loop.destroy();
}

fn void test_no_wait_ticks_once_after_stop() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init()!!;
	op.init();

	loop.stop();
	test::@check(!loop.alive());

	timer::start(&loop, &op, { }, &on_timer, &seen)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
}
