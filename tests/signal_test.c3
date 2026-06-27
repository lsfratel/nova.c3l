module nova_tests;

import std::core::test;
import libc;

import nova::op @public;
import nova @norecurse, nova::signal;

struct SignalSeen
{
	fault status;
	CInt signum;
	ulong count;
	int calls;
	bool owner_thread;
}

fn void previous_signal_handler(CInt signum)
{
	(void)signum;
}

fn void replacement_signal_handler(CInt signum)
{
	(void)signum;
}

fn void on_signal_stop(Loop* loop, signal::SignalOp* op, signal::SignalResult* result, void* userdata)
{
	SignalSeen* seen = (SignalSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.signum = result.signum;
	seen.count = result.count;
	seen.owner_thread = loop.is_owner_thread();
	if (!result.error.status) signal::stop(loop, op)!!;
}

fn void on_signal_seen(Loop* loop, signal::SignalOp* op, signal::SignalResult* result, void* userdata)
{
	(void)op;
	SignalSeen* seen = (SignalSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.signum = result.signum;
	seen.count = result.count;
	seen.owner_thread = loop.is_owner_thread();
}

fn void on_signal_stop_after_two(Loop* loop, signal::SignalOp* op, signal::SignalResult* result, void* userdata)
{
	SignalSeen* seen = (SignalSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.signum = result.signum;
	seen.count = result.count;
	seen.owner_thread = loop.is_owner_thread();
	if (seen.calls >= 2 && !result.error.status) signal::stop(loop, op)!!;
}

fn void test_signal_dispatches_on_owner_thread() @test
{
	Loop loop;
	signal::SignalOp op;
	SignalSeen seen;

	loop.init()!!;
	op.init();

	Ref oref = signal::start(&loop, &op, { .signum = libc::SIGUSR1 }, &on_signal_stop, &seen)!!;
	test::@check(op.header.matches(oref));
	test::@check(op.active());
	test::eq((sz)1, loop.signal_count);

	test::eq(0, libc::raise(libc::SIGUSR1));
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq(libc::SIGUSR1, seen.signum);
	test::eq((ulong)1, seen.count);
	test::@check(seen.owner_thread);
	test::@check(!op.active());
	test::eq((sz)0, loop.signal_count);

	op.destroy();
	loop.destroy();
}

fn void test_signal_rearms_after_callback() @test
{
	Loop loop;
	signal::SignalOp op;
	SignalSeen seen;

	loop.init()!!;
	op.init();

	signal::start(&loop, &op, { .signum = libc::SIGUSR1 }, &on_signal_stop_after_two, &seen)!!;

	test::eq(0, libc::raise(libc::SIGUSR1));
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq(libc::SIGUSR1, seen.signum);
	test::eq((ulong)1, seen.count);
	test::@check(op.active());
	test::eq((sz)1, loop.signal_count);

	test::eq(0, libc::raise(libc::SIGUSR1));
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(2, seen.calls);
	test::@check(!seen.status);
	test::eq(libc::SIGUSR1, seen.signum);
	test::eq((ulong)1, seen.count);
	test::@check(!op.active());
	test::eq((sz)0, loop.signal_count);

	op.destroy();
	loop.destroy();
}

fn void test_signal_restores_previous_native_handler() @test
{
	libc::Sigaction original;
	libc::Sigaction previous;
	libc::Sigaction current;
	Loop loop;
	signal::SignalOp op;
	SignalSeen seen;

	previous.sa_handler = &previous_signal_handler;
	(void)libc::sigemptyset(&previous.sa_mask);
	test::eq(0, libc::sigaction(libc::SIGUSR2, &previous, &original));
	defer (void)libc::sigaction(libc::SIGUSR2, &original, null);

	loop.init()!!;
	op.init();

	signal::start(&loop, &op, { .signum = libc::SIGUSR2 }, &on_signal_seen, &seen)!!;
	signal::stop(&loop, &op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(0, libc::sigaction(libc::SIGUSR2, null, &current));
	test::@check(current.sa_handler == &previous_signal_handler);
	test::@check(!op.active());
	test::eq((sz)0, loop.signal_count);

	op.destroy();
	loop.destroy();
}

fn void test_signal_does_not_clobber_replaced_native_handler() @test
{
	libc::Sigaction original;
	libc::Sigaction previous;
	libc::Sigaction replacement;
	libc::Sigaction current;
	Loop loop;
	signal::SignalOp op;
	SignalSeen seen;

	previous.sa_handler = &previous_signal_handler;
	(void)libc::sigemptyset(&previous.sa_mask);
	test::eq(0, libc::sigaction(libc::SIGUSR2, &previous, &original));
	defer (void)libc::sigaction(libc::SIGUSR2, &original, null);

	loop.init()!!;
	op.init();

	signal::start(&loop, &op, { .signum = libc::SIGUSR2 }, &on_signal_seen, &seen)!!;

	replacement.sa_handler = &replacement_signal_handler;
	(void)libc::sigemptyset(&replacement.sa_mask);
	test::eq(0, libc::sigaction(libc::SIGUSR2, &replacement, null));

	signal::stop(&loop, &op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(0, libc::sigaction(libc::SIGUSR2, null, &current));
	test::@check(current.sa_handler == &replacement_signal_handler);
	test::@check(!op.active());
	test::eq((sz)0, loop.signal_count);

	op.destroy();
	loop.destroy();
}

fn void test_signal_oneshot_resets_after_first_delivery() @test
{
	Loop loop;
	signal::SignalOp op;
	SignalSeen seen;

	loop.init()!!;
	op.init();

	signal::start(&loop, &op, { .signum = libc::SIGUSR1, .oneshot = true }, &on_signal_seen, &seen)!!;
	test::eq((sz)1, loop.signal_count);

	test::eq(0, libc::raise(libc::SIGUSR1));
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq(libc::SIGUSR1, seen.signum);
	test::eq((ulong)1, seen.count);
	test::@check(!op.active());
	test::eq((sz)0, loop.signal_count);

	op.destroy();
	loop.destroy();
}

fn void test_signal_stop_dispatches_cancelled() @test
{
	Loop loop;
	signal::SignalOp op;
	SignalSeen seen;

	loop.init()!!;
	op.init();

	signal::start(&loop, &op, { .signum = libc::SIGUSR1 }, &on_signal_seen, &seen)!!;
	test::@check(op.active());
	test::eq((sz)1, loop.signal_count);

	signal::stop(&loop, &op)!!;
	test::eq((sz)0, loop.signal_count);
	test::@check(op.active());

	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::CANCELLED);
	test::eq((ulong)0, seen.count);
	test::@check(!op.active());
	test::@check(op.callback == null);

	op.destroy();
	loop.destroy();
}

fn void test_signal_start_rejects_invalid_signals() @test
{
	Loop loop;
	signal::SignalOp op;
	SignalSeen seen;

	loop.init()!!;
	op.init();

	test::@error(signal::start(&loop, &op, { .signum = 0 }, &on_signal_seen, &seen), nova::INVALID_STATE);
	test::@error(signal::start(&loop, &op, { .signum = libc::SIGKILL }, &on_signal_seen, &seen), nova::INVALID_STATE);
	test::@error(signal::start(&loop, &op, { .signum = libc::SIGSTOP }, &on_signal_seen, &seen), nova::INVALID_STATE);
	test::@check(!op.active());
	test::eq((sz)0, loop.signal_count);

	op.destroy();
	loop.destroy();
}
