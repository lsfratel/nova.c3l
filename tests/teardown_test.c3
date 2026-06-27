module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import std::os::posix;
import libc;

import nova::op @public;
import nova @norecurse, nova::timer, nova::signal, nova::watch;

struct TeardownCounts
{
	int timer;
	int signal;
	int watch;
}

fn void teardown_timer_cb(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	(void)result;
	TeardownCounts* counts = (TeardownCounts*)userdata;
	counts.timer++;
}

fn void teardown_signal_cb(Loop* loop, signal::SignalOp* op, signal::SignalResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	(void)result;
	TeardownCounts* counts = (TeardownCounts*)userdata;
	counts.signal++;
}

fn void teardown_watch_cb(
	Loop* loop,
	watch::Watch* watch,
	watch::WatchOp* op,
	watch::WatchResult* result,
	void* userdata
)
{
	(void)loop;
	(void)watch;
	(void)op;
	(void)result;
	TeardownCounts* counts = (TeardownCounts*)userdata;
	counts.watch++;
}

fn void test_clean_shutdown_with_timer_signal_and_watch_active() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	timer::TimerOp timer_op;
	signal::SignalOp signal_op;
	watch::Watch watcher;
	watch::WatchOp watch_op;
	TeardownCounts counts;
	CInt[2] fds;

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 8 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();
	timer_op.init();
	signal_op.init();
	watcher.init((NativeHandle)fds[0], watch::Interest.READABLE)!!;
	watch_op.init();

	timer::start(&loop, &timer_op, { .delay = (Duration)60_000_000 }, &teardown_timer_cb, &counts)!!;
	signal::start(&loop, &signal_op, { .signum = libc::SIGUSR1 }, &teardown_signal_cb, &counts)!!;
	watch::start(&loop, &watcher, &watch_op, &teardown_watch_cb, &counts)!!;

	test::eq((sz)1, loop.timer_count);
	test::eq((sz)1, loop.signal_count);
	test::eq((sz)1, loop.backend_active_count);
	test::@check(timer_op.active());
	test::@check(signal_op.active());
	test::@check(watch_op.active());
	test::eq(allocation_count, tracker.total_allocation_count());

	timer::stop(&loop, &timer_op)!!;
	signal::stop(&loop, &signal_op)!!;
	watch::stop(&loop, &watcher, &watch_op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq((sz)0, loop.timer_count);
	test::eq((sz)0, loop.signal_count);
	test::eq((sz)0, loop.backend_active_count);
	test::@check(!timer_op.active());
	test::@check(!signal_op.active());
	test::@check(!watch_op.active());

	timer_op.destroy();
	signal_op.destroy();
	watch_op.destroy();
	watcher.destroy();
	loop.destroy();

	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);

	test::@check(!tracker.has_leaks());
}
