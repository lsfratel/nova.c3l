module nova_tests;

import std::core::test;
import std::core::mem::allocators;

import nova::op @public;
import nova @norecurse, nova::timer;

fn void on_timer_heap_test(Loop* loop, void* raw)
{
	(void)loop;
	(void)raw;
}

struct TimerOrderCtx
{
	int[3] order;
	int count;
}

struct TimerOrderSlot
{
	TimerOrderCtx* ctx;
	int id;
}

fn void on_timer_order(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	(void)result;
	TimerOrderSlot* slot = (TimerOrderSlot*)userdata;
	if (slot.ctx.count < 3) slot.ctx.order[slot.ctx.count] = slot.id;
	slot.ctx.count++;
}

struct TimerChainCtx
{
	timer::TimerOp* second;
	int first_calls;
	int second_calls;
	bool armed;
}

fn void on_timer_chain_second(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	(void)result;
	TimerChainCtx* ctx = (TimerChainCtx*)userdata;
	ctx.second_calls++;
}

fn void on_timer_chain_first(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)op;
	(void)result;
	TimerChainCtx* ctx = (TimerChainCtx*)userdata;
	ctx.first_calls++;
	if (ctx.armed) return;
	ctx.armed = true;
	timer::start(loop, ctx.second, { .delay = (Duration)1_000 }, &on_timer_chain_second, ctx)!!;
}

fn void test_timer_immediate_dispatch() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	Ref oref = timer::start(&loop, &op, { }, &on_timer, &seen)!!;
	test::@check(op.header.matches(oref));
	test::@check(op.active());

	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((ulong)1, seen.expirations);
	test::@check(!op.active());
	test::eq((ulong)0, op.result.expirations);
	test::eq((long)0, (long)op.interval);
	test::eq((uint)0, op.remaining_repeats);
	test::@check(op.callback == null);

	op.destroy();
	test::@check(op.header.timer == null);
	loop.destroy();
}
fn void test_timer_once_waits_for_deadline() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	timer::start(&loop, &op, { .delay = (Duration)1_000 }, &on_timer, &seen)!!;
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((ulong)1, seen.expirations);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
}
fn void test_until_stopped_waits_for_timer_stop() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	timer::start(&loop, &op, { .delay = (Duration)1_000 }, &on_timer_stop, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(!op.active());
	test::@check(!loop.alive());

	op.destroy();
	loop.destroy();
}
fn void test_timer_stop_dispatches_cancelled() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	timer::start(&loop, &op, { .delay = (Duration)60_000_000 }, &on_timer, &seen)!!;
	test::@check(op.active());
	test::eq((sz)1, loop.timer_count);

	timer::stop(&loop, &op)!!;
	test::eq((sz)0, loop.timer_count);
	test::@check(op.active());

	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::CANCELLED);
	test::eq((ulong)0, seen.expirations);
	test::@check(!op.active());
	test::@check(!op.result.error.status);
	test::eq((ulong)0, op.result.expirations);
	test::eq((long)0, (long)op.interval);
	test::eq((uint)0, op.remaining_repeats);
	test::@check(op.callback == null);

	op.destroy();
	loop.destroy();
}
fn void test_timer_heap_is_unbounded() @test
{
	Loop loop;
	timer::TimerOp first;
	timer::TimerOp second;
	TimerSeen seen;

	loop.init({ })!!;
	first.init();
	second.init();

	timer::start(&loop, &first, { .delay = (Duration)60_000_000 }, &on_timer, &seen)!!;
	timer::start(&loop, &second, { .delay = (Duration)60_000_000 }, &on_timer, &seen)!!;
	test::@check(first.active());
	test::@check(second.active());
	test::eq((sz)2, loop.timer_count);

	timer::stop(&loop, &first)!!;
	timer::stop(&loop, &second)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	first.destroy();
	second.destroy();
	loop.destroy();
}
fn void test_timer_heap_remove_preserves_deadline_order() @test
{
	Loop loop;
	timer::TimerOp[8] ops;
	Clock[8] deadlines = { (Clock)40, (Clock)10, (Clock)70, (Clock)20, (Clock)60, (Clock)30, (Clock)80, (Clock)50 };

	loop.init({ })!!;
	for (int i = 0; i < 8; i++)
	{
		ops[i].init();
		op::init_header(&ops[i].header, Kind.TIMER, &loop, &on_timer_heap_test, &ops[i], null);
		timer::arm(&loop, &ops[i].header, &ops[i].timeout, deadlines[i]);
	}

	timer::heap_remove(&loop, &ops[3].timeout);
	op::reset_header(&ops[3].header);

	Clock last = (Clock)0;
	while (loop.timer_count > 0)
	{
		timer::Node* next = loop.timer_min;
		test::@check(next.deadline >= last);
		last = next.deadline;
		op::Header* next_header = next.header;
		timer::heap_remove(&loop, next);
		op::reset_header(next_header);
	}

	for (int i = 0; i < 8; i++) ops[i].destroy();
	loop.destroy();
}
fn void test_timer_repeat_runs_to_completion() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	timer::start(&loop, &op, { .interval = (Duration)1_000, .repeat = 2 }, &on_timer, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::@check(seen.calls >= 1);
	test::eq((ulong)3, seen.total_expirations);
	test::@check(!seen.status);
	test::@check(!op.active());
	test::eq((ulong)0, op.result.expirations);
	test::eq((long)0, (long)op.interval);
	test::eq((uint)0, op.remaining_repeats);
	test::@check(op.callback == null);

	op.destroy();
	loop.destroy();
}
fn void test_timer_repeat_stop_inside_callback() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	timer::start(&loop, &op, { .interval = (Duration)10_000, .repeat = 3 }, &on_timer_stop_self, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::eq((ulong)1, seen.total_expirations);
	test::@check(!seen.status);
	test::@check(!op.active());
	test::eq((ulong)0, op.result.expirations);
	test::eq((long)0, (long)op.interval);
	test::eq((uint)0, op.remaining_repeats);
	test::@check(op.callback == null);

	op.destroy();
	loop.destroy();
}
fn void test_timer_repeat_options_are_validated() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	test::@error(timer::start(&loop, &op, { .repeat = 1 }, &on_timer, &seen), nova::INVALID_STATE);
	test::@error(timer::start(&loop, &op, { .interval = (Duration)-1 }, &on_timer, &seen), nova::INVALID_STATE);
	test::@error(timer::start(&loop, &op, { .delay = (Duration)-1 }, &on_timer, &seen), nova::INVALID_STATE);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
}
fn void test_timer_infinite_repeats_until_stopped() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	// interval > 0 with repeat == 0 means repeat indefinitely; the callback stops
	// it after three fires (otherwise it would keep the loop alive forever).
	timer::start(&loop, &op, { .interval = (Duration)1_000 }, &on_timer_stop_after_three, &seen)!!;
	test::@check(op.active());
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(3, seen.calls);
	test::@check(!seen.status);
	test::@check(!op.active());
	test::eq((uint)0, op.remaining_repeats);
	test::eq((long)0, (long)op.interval);

	op.destroy();
	loop.destroy();
}

fn void test_timer_expirations_due_saturates_before_overflow() @test
{
	Loop loop;
	timer::TimerOp op;

	op.init();
	loop.cached_now = (Clock)ulong::max;
	op.timeout.deadline = (Clock)0;
	op.interval = (Duration)1;
	op.remaining_repeats = uint::max;

	test::eq((ulong)uint::max + 1, timer::expirations_due(&loop, &op));

	op.destroy();
}
fn void test_timer_repeat_uses_unbounded_heap() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init()!!;
	op.init();

	timer::start(&loop, &op, { .interval = (Duration)1_000, .repeat = 1 }, &on_timer, &seen)!!;
	test::@check(op.active());
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq((ulong)2, seen.total_expirations);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
}
fn void test_zero_alloc_timer_and_wake_paths_after_loop_init() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();
	op.init();

	timer::start(&loop, &op, { .interval = (Duration)1_000, .repeat = 1 }, &on_timer, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq((ulong)2, seen.total_expirations);
	test::@check(!op.active());

	timer::start(&loop, &op, { .delay = (Duration)60_000_000 }, &on_timer, &seen)!!;
	timer::stop(&loop, &op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	loop.wake()!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(allocation_count, tracker.total_allocation_count());

	op.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
fn void test_multiple_timers_fire_in_deadline_order() @test
{
	Loop loop;
	timer::TimerOp[3] ops;
	TimerOrderCtx ctx;
	TimerOrderSlot[3] slots;
	Duration[3] delays = { (Duration)3_000, (Duration)1_000, (Duration)2_000 };

	loop.init({ })!!;
	for (int i = 0; i < 3; i++)
	{
		ops[i].init();
		slots[i] = { .ctx = &ctx, .id = i };
		timer::start(&loop, &ops[i], { .delay = delays[i] }, &on_timer_order, &slots[i])!!;
	}

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(3, ctx.count);
	test::eq(1, ctx.order[0]);
	test::eq(2, ctx.order[1]);
	test::eq(0, ctx.order[2]);

	for (int i = 0; i < 3; i++) ops[i].destroy();
	loop.destroy();
}

fn void test_timer_restart_after_stop_fires_again() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	loop.init({ })!!;
	op.init();

	timer::start(&loop, &op, { .delay = (Duration)60_000_000 }, &on_timer, &seen)!!;
	timer::stop(&loop, &op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::CANCELLED);
	test::@check(!op.active());

	timer::start(&loop, &op, { .delay = (Duration)1_000 }, &on_timer, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, seen.calls);
	test::@check(!seen.status);
	test::eq((ulong)1, seen.expirations);
	test::@check(!op.active());

	op.destroy();
	loop.destroy();
}

fn void test_timer_started_inside_callback_runs_same_loop() @test
{
	Loop loop;
	timer::TimerOp first;
	timer::TimerOp second;
	TimerChainCtx ctx = { .second = &second };

	loop.init({ })!!;
	first.init();
	second.init();

	timer::start(&loop, &first, { .delay = (Duration)1_000 }, &on_timer_chain_first, &ctx)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, ctx.first_calls);
	test::eq(1, ctx.second_calls);
	test::@check(!first.active());
	test::@check(!second.active());

	first.destroy();
	second.destroy();
	loop.destroy();
}

fn void test_timer_start_invalid_loop_leaves_op_free() @test
{
	Loop loop;
	timer::TimerOp op;
	TimerSeen seen;

	op.init();

	test::@error(timer::start(&loop, &op, { }, &on_timer, &seen), nova::INVALID_STATE);
	test::@check(!op.active());
	test::@check(op.callback == null);

	op.destroy();
}
