module nova_tests @if(env::LINUX);

import std::core::test;
import std::net::os;
import libc;

import nova @norecurse, nova::timer, nova::watch;
import nova::backend::uring;

struct UringTimerSeen
{
	int calls;
}

fn void on_uring_timer(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	(void)result;
	UringTimerSeen* seen = (UringTimerSeen*)userdata;
	seen.calls++;
}

<*
 Run a real loop on the io_uring backend: select it explicitly, signal the wake
 source, then drive a one-shot timer to completion. This exercises the io_uring
 lifecycle end to end — ring init/destroy, the eventfd wake path, and the
 `io_uring_enter` EXT_ARG timeout that bounds a blocking poll.
*>
fn void test_uring_loop_timer_and_wake() @test
{
	if (!uring::probe_capabilities().usable()) return;

	Loop loop;
	loop.init({ .backend = nova::BACKEND_IO_URING })!!;
	defer loop.destroy();
	test::@check(loop.backend() == BackendKind.IO_URING);

	loop.wake()!!;

	UringTimerSeen seen;
	timer::TimerOp op;
	op.init();
	defer op.destroy();

	timer::start(&loop, &op, { .delay = (Duration)1_000 }, &on_uring_timer, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(seen.calls == 1);
}

struct LoadCounter
{
	int fired;
}

fn void on_load_watch(Loop* loop, watch::Watch* w, watch::WatchOp* op, watch::WatchResult* result, void* userdata)
{
	(void)loop;
	(void)w;
	(void)op;
	(void)result;
	LoadCounter* counter = (LoadCounter*)userdata;
	counter.fired++;
}

<*
 Stress the ring and the §3.9 memory barriers: arm 64 watches in one batch
 (64 staged POLL_ADDs flushed in a single io_uring_enter), make all 64 fds
 readable, and confirm one poll drains all 64 completions correctly.
*>
fn void test_uring_load_many_watches() @test
{
	if (!uring::probe_capabilities().usable()) return;

	const usz N = 64;
	Loop loop;
	loop.init({ .backend = nova::BACKEND_IO_URING, .max_events = 256 })!!;
	defer loop.destroy();

	watch::Watch[N] w;
	watch::WatchOp[N] op;
	os::NativeSocket[2][N] sp;
	LoadCounter counter;

	for (usz i = 0; i < N; i++)
	{
		if (!os::socketpair(os::AF_UNIX, os::SOCK_STREAM, (os::AIProtocol)0, &sp[i]).is_valid()) return;
		w[i].init((NativeHandle)(int)sp[i][0], watch::Interest.READABLE)!!;
		op[i].init();
		watch::start(&loop, &w[i], &op[i], &on_load_watch, &counter)!!;
		char x = 'x';
		(void)libc::write((Fd)(int)sp[i][1], &x, 1);
	}

	nova::run(&loop, RunMode.NO_WAIT)!!;
	test::eq((int)N, counter.fired);

	for (usz i = 0; i < N; i++)
	{
		op[i].destroy();
		w[i].destroy();
		(void)sp[i][0].close();
		(void)sp[i][1].close();
	}
}
