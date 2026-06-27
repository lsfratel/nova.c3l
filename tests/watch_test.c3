module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import std::os::posix;
import std::net::os;
import libc;

import nova::op @public;
import nova @norecurse, nova::backend @public, nova::timer, nova::watch;

fn void test_zero_alloc_watch_path_after_loop_init() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	WatchSeen seen;
	CInt[2] fds;
	char[1] bytes       = { 'x' };
	char[] payload      = bytes[0:1];

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();
	w.init((NativeHandle)fds[0], watch::Interest.READABLE)!!;
	op.init();

	watch::start(&loop, &w, &op, &on_watch_seen, &seen)!!;
	test::eq((sz)1, libc::write(fds[1], payload.ptr, (usz)payload.len));
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(seen.readable);
	test::eq(allocation_count, tracker.total_allocation_count());

	op.destroy();
	test::@check(op.header.timer == null);
	w.destroy();
	test::@check(w.handle == (NativeHandle)-1);
	loop.destroy();
	test::@check(!tracker.has_leaks());
	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);
}
fn void test_watch_readable_dispatch() @test
{
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	WatchSeen seen;
	CInt[2] fds;
	char[1] bytes  = { 'x' };
	char[] payload = bytes[0:1];

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 4 })!!;
	w.init((NativeHandle)fds[0], watch::Interest.READABLE)!!;
	op.init();

	Ref oref = watch::start(&loop, &w, &op, &on_watch_seen, &seen)!!;
	test::@check(op.header.matches(oref));
	test::@check(op.active());
	test::@check(w.active());

	test::eq((sz)1, libc::write(fds[1], payload.ptr, (usz)payload.len));
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.readable);
	test::@check(!seen.writable);
	test::@check(!op.active());
	test::@check(!w.active());

	op.destroy();
	w.destroy();
	loop.destroy();
	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);
}

struct WatchRepostCtx
{
	Ref repost_ref;
	fault repost_status;
	fault[2] statuses;
	bool[2] op_active;
	bool[2] watch_active;
	int calls;
}

fn void on_watch_repost_same_op(
	Loop* loop,
	watch::Watch* w,
	watch::WatchOp* op,
	watch::WatchResult* result,
	void* userdata
)
{
	WatchRepostCtx* ctx = (WatchRepostCtx*)userdata;
	int index           = ctx.calls;
	if (index < 2)
	{
		ctx.statuses[index] = result.error.status;
		ctx.op_active[index] = op.header.active();
		ctx.watch_active[index] = w.active();
	}
	ctx.calls++;

	if (ctx.calls == 1)
	{
		Ref? reposted = watch::start(loop, w, op, &on_watch_repost_same_op, ctx);
		ctx.repost_status = @catch(reposted);
		if (try repost_ref = reposted) ctx.repost_ref = repost_ref;
	}
}

fn void test_watch_can_repost_same_op_inside_callback() @test
{
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	WatchRepostCtx ctx;
	CInt[2] fds;
	char[1] bytes  = { 'x' };
	char[] payload = bytes[0:1];

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 4 })!!;
	w.init((NativeHandle)fds[0], watch::Interest.READABLE)!!;
	op.init();

	watch::start(&loop, &w, &op, &on_watch_repost_same_op, &ctx)!!;
	test::eq((sz)1, libc::write(fds[1], payload.ptr, (usz)payload.len));
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, ctx.calls);
	test::@check(!ctx.statuses[0]);
	test::@check(!ctx.op_active[0]);
	test::@check(!ctx.watch_active[0]);
	test::@check(!ctx.repost_status);
	test::@check(op.header.matches(ctx.repost_ref));
	test::@check(op.active());
	test::@check(w.active());

	watch::stop(&loop, &w, &op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(2, ctx.calls);
	test::@check(ctx.statuses[1] == nova::CANCELLED);
	test::@check(!ctx.op_active[1]);
	test::@check(!ctx.watch_active[1]);
	test::@check(!op.active());
	test::@check(!w.active());

	op.destroy();
	w.destroy();
	loop.destroy();
	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);
}

fn void test_watch_writable_dispatch() @test
{
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	WatchSeen seen;
	CInt[2] fds;

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 4 })!!;
	w.init((NativeHandle)fds[1], watch::Interest.WRITABLE)!!;
	op.init();

	watch::start(&loop, &w, &op, &on_watch_seen, &seen)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.writable);
	test::@check(!seen.readable);
	test::@check(!op.active());

	op.destroy();
	w.destroy();
	loop.destroy();
	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);
}

fn void test_watch_both_directions_report_each_event() @test
{
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	WatchSeen seen;
	os::NativeSocket[2] sp;
	char[1] bytes  = { 'x' };
	char[] payload = bytes[0:1];

	test::@check(os::socketpair(os::AF_UNIX, os::SOCK_STREAM, (os::AIProtocol)0, &sp).is_valid());

	loop.init({ .max_events = 4 })!!;
	w.init((NativeHandle)(int)sp[0], watch::Interest.READABLE | watch::Interest.WRITABLE)!!;
	op.init();

	watch::start(&loop, &w, &op, &on_watch_seen, &seen)!!;
	test::eq((sz)1, libc::write((Fd)(int)sp[1], payload.ptr, (usz)payload.len));
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.readable);
	test::@check(seen.writable);
	test::@check(!op.active());

	op.destroy();
	w.destroy();
	loop.destroy();
	(void)sp[0].close();
	(void)sp[1].close();
}

fn void test_watch_reports_hangup_after_peer_close() @test
{
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	WatchSeen seen;
	CInt[2] fds;

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 4 })!!;
	w.init((NativeHandle)fds[0], watch::Interest.READABLE)!!;
	op.init();

	watch::start(&loop, &w, &op, &on_watch_seen, &seen)!!;
	(void)libc::close(fds[1]);
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.hangup);
	test::@check(!op.active());

	op.destroy();
	w.destroy();
	loop.destroy();
	(void)libc::close(fds[0]);
}

fn void test_watch_multiple_fds_dispatch_independently() @test
{
	Loop loop;
	watch::Watch wa;
	watch::Watch wb;
	watch::WatchOp opa;
	watch::WatchOp opb;
	WatchSeen seen_a;
	WatchSeen seen_b;
	CInt[2] fds_a;
	CInt[2] fds_b;
	char[1] bytes  = { 'x' };
	char[] payload = bytes[0:1];

	test::eq(0, posix::pipe(&fds_a));
	test::eq(0, posix::pipe(&fds_b));

	loop.init({ .max_events = 8 })!!;
	wa.init((NativeHandle)fds_a[0], watch::Interest.READABLE)!!;
	wb.init((NativeHandle)fds_b[0], watch::Interest.READABLE)!!;
	opa.init();
	opb.init();

	watch::start(&loop, &wa, &opa, &on_watch_seen, &seen_a)!!;
	watch::start(&loop, &wb, &opb, &on_watch_seen, &seen_b)!!;
	test::eq((sz)2, loop.backend_active_count);

	test::eq((sz)1, libc::write(fds_a[1], payload.ptr, (usz)payload.len));
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen_a.calls);
	test::@check(seen_a.readable);
	test::eq(0, seen_b.calls);
	test::@check(!opa.active());
	test::@check(opb.active());
	test::eq((sz)1, loop.backend_active_count);

	watch::stop(&loop, &wb, &opb)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;
	test::@check(seen_b.status == nova::CANCELLED);
	test::@check(!opb.active());

	opa.destroy();
	opb.destroy();
	wa.destroy();
	wb.destroy();
	loop.destroy();
	(void)libc::close(fds_a[0]);
	(void)libc::close(fds_a[1]);
	(void)libc::close(fds_b[0]);
	(void)libc::close(fds_b[1]);
}

fn void test_watch_start_rejects_empty_interest() @test
{
	Loop loop;
	watch::Watch w;
	watch::Watch invalid;
	watch::WatchOp op;
	CInt[2] fds;

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 4 })!!;
	w.init((NativeHandle)fds[0], (watch::Interest)0)!!;
	op.init();

	test::@error(watch::start(&loop, &w, &op, &on_watch), nova::INVALID_STATE);
	test::@check(!op.active());
	test::@check(!w.active());

	invalid.init((NativeHandle)fds[0], (watch::Interest)5)!!;
	test::@error(watch::start(&loop, &invalid, &op, &on_watch), nova::INVALID_STATE);
	test::@check(!op.active());
	test::@check(!invalid.active());

	op.destroy();
	w.destroy();
	invalid.destroy();
	loop.destroy();
	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);
}

fn void test_watch_stop_dispatches_cancelled() @test
{
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	WatchSeen seen;
	CInt[2] fds;

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 4 })!!;
	w.init((NativeHandle)fds[0], watch::Interest.READABLE)!!;
	op.init();

	watch::start(&loop, &w, &op, &on_watch_seen, &seen)!!;
	test::@check(op.backend.counted);
	watch::stop(&loop, &w, &op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::CANCELLED);
	test::@check(!seen.readable);
	test::@check(!op.active());
	test::@check(!w.active());

	op.destroy();
	w.destroy();
	loop.destroy();
	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);
}

fn void test_watch_start_clears_stale_backend_watcher_before_cancel() @test
{
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	WatchSeen seen;
	backend::Watcher stale_watcher;
	CInt[2] fds;

	test::eq(0, posix::pipe(&fds));

	loop.init({ .max_events = 4 })!!;
	w.init((NativeHandle)fds[0], watch::Interest.READABLE)!!;
	op.init();
	op.header.backend = &op.backend;
	op.backend.watcher = &stale_watcher;
	op.backend.interest = nova::READY_READABLE;
	op.backend.counted = true;

	watch::start(&loop, &w, &op, &on_watch_seen, &seen)!!;
	watch::stop(&loop, &w, &op)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::CANCELLED);
	test::eq((sz)0, loop.backend_active_count);
	test::@check(op.header.backend == null);
	test::@check(op.backend.watcher == null);
	test::eq((uint)0, op.backend.interest);
	test::@check(!op.backend.counted);

	op.destroy();
	w.destroy();
	loop.destroy();
	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);
}
