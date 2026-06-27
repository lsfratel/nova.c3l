module nova_tests;

import std::core::test;
import std::thread;
import std::io, std::os::posix;
import libc;

import nova @norecurse, nova::fs, nova::fs::poll, nova::work;

struct FsPollSeen
{
	int calls;
	fault status;
	bool changed;
	bool previous_exists;
	bool current_exists;
	fs::Stat previous;
	fs::Stat current;
	bool owner_thread;
	bool poll_active;
}

struct FsPollChangeCtx
{
	FsPollSeen seen;
	String path;
	int mode;
}

struct FsPollCancelCtx
{
	uint blocker_started;
	int blocker_calls;
	int poll_calls;
	int after_calls;
	fault poll_status;
}

struct FsPollStopTimerCtx
{
	int calls;
	fault status;
}

fn void fs_poll_append(String path, String data)
{
	CFile file = libc::fopen(path.zstr_tcopy(), "a");
	test::@check(file != null);
	test::eq((usz)data.len, libc::fwrite(data.ptr, 1, (usz)data.len, file));
	test::eq((CInt)0, libc::fclose(file));
}

fn void fs_poll_record(Loop* loop, poll::Poll* poll_handle, poll::PollResult* result, FsPollSeen* seen)
{
	seen.calls++;
	seen.status = result.error.status;
	seen.changed = result.changed;
	seen.previous_exists = result.previous_exists;
	seen.current_exists = result.current_exists;
	seen.previous = result.previous;
	seen.current = result.current;
	seen.owner_thread = loop.is_owner_thread();
	seen.poll_active = poll_handle.active();
}

fn void on_fs_poll_creation(Loop* loop, poll::Poll* poll_handle, poll::PollResult* result, void* userdata)
{
	FsPollChangeCtx* ctx = (FsPollChangeCtx*)userdata;
	fs_poll_record(loop, poll_handle, result, &ctx.seen);
	if (ctx.seen.calls == 1)
	{
		test::@check(!result.changed);
		test::@check(!result.current_exists);
		fs_touch_file(ctx.path);
		return;
	}
	test::@check(result.changed);
	test::@check(!result.previous_exists);
	test::@check(result.current_exists);
	poll::stop(loop, poll_handle)!!;
	loop.stop();
}

fn void on_fs_poll_modification(Loop* loop, poll::Poll* poll_handle, poll::PollResult* result, void* userdata)
{
	FsPollChangeCtx* ctx = (FsPollChangeCtx*)userdata;
	fs_poll_record(loop, poll_handle, result, &ctx.seen);
	if (ctx.seen.calls == 1)
	{
		test::@check(!result.changed);
		test::@check(result.current_exists);
		fs_poll_append(ctx.path, "more");
		return;
	}
	test::@check(result.changed);
	test::@check(result.previous_exists);
	test::@check(result.current_exists);
	test::@check(result.current.size > result.previous.size);
	poll::stop(loop, poll_handle)!!;
	loop.stop();
}

fn void on_fs_poll_unlink(Loop* loop, poll::Poll* poll_handle, poll::PollResult* result, void* userdata)
{
	FsPollChangeCtx* ctx = (FsPollChangeCtx*)userdata;
	fs_poll_record(loop, poll_handle, result, &ctx.seen);
	if (ctx.seen.calls == 1)
	{
		test::@check(!result.changed);
		test::@check(result.current_exists);
		fs_cleanup_path(ctx.path);
		return;
	}
	test::@check(result.changed);
	test::@check(result.previous_exists);
	test::@check(!result.current_exists);
	poll::stop(loop, poll_handle)!!;
	loop.stop();
}

fn void? fs_poll_blocker(work::WorkOp* op)
{
	FsPollCancelCtx* ctx = (FsPollCancelCtx*)op.header.userdata;
	@atomic_store(ctx.blocker_started, (uint)1);
	ctx.blocker_calls++;
	thread::sleep_ms(80);
}

fn void after_fs_poll_blocker(Loop* loop, work::WorkOp* op, fault status, void* userdata)
{
	(void)op;
	(void)status;
	FsPollCancelCtx* ctx = (FsPollCancelCtx*)userdata;
	ctx.after_calls++;
	if (ctx.after_calls == 2) loop.stop();
}

fn void on_fs_poll_cancelled(Loop* loop, poll::Poll* poll_handle, poll::PollResult* result, void* userdata)
{
	(void)poll_handle;
	FsPollCancelCtx* ctx = (FsPollCancelCtx*)userdata;
	ctx.poll_calls++;
	ctx.after_calls++;
	ctx.poll_status = result.error.status;
	if (ctx.after_calls == 2) loop.stop();
}

fn void on_fs_poll_stop_timer(Loop* loop, poll::Poll* poll_handle, poll::PollResult* result, void* userdata)
{
	(void)poll_handle;
	FsPollStopTimerCtx* ctx = (FsPollStopTimerCtx*)userdata;
	ctx.calls++;
	ctx.status = result.error.status;
	loop.stop();
}

fn void test_fs_poll_detects_creation_after_missing_path() @test
{
	work::Pool pool;
	Loop loop;
	poll::Poll poll_handle;
	FsPollChangeCtx ctx;
	char[128] storage;
	String path = fs_temp_path(storage[0:128], 32);

	fs_cleanup_path(path);
	ctx.path = path;
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	poll_handle.init();

	poll::start(&loop, &poll_handle, path, { .interval = (Duration)1_000 }, &on_fs_poll_creation, &ctx)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.seen.calls);
	test::@check(!poll_handle.active());
	test::@check(ctx.seen.owner_thread);

	fs_cleanup_path(path);
	poll_handle.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_poll_detects_file_modification() @test
{
	work::Pool pool;
	Loop loop;
	poll::Poll poll_handle;
	FsPollChangeCtx ctx;
	char[128] storage;
	String path = fs_temp_path(storage[0:128], 33);

	fs_cleanup_path(path);
	fs_poll_append(path, "base");
	ctx.path = path;
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	poll_handle.init();

	poll::start(&loop, &poll_handle, path, { .interval = (Duration)1_000 }, &on_fs_poll_modification, &ctx)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.seen.calls);
	test::@check(!poll_handle.active());

	fs_cleanup_path(path);
	poll_handle.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_poll_detects_unlink() @test
{
	work::Pool pool;
	Loop loop;
	poll::Poll poll_handle;
	FsPollChangeCtx ctx;
	char[128] storage;
	String path = fs_temp_path(storage[0:128], 34);

	fs_cleanup_path(path);
	fs_touch_file(path);
	ctx.path = path;
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	poll_handle.init();

	poll::start(&loop, &poll_handle, path, { .interval = (Duration)1_000 }, &on_fs_poll_unlink, &ctx)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.seen.calls);
	test::@check(!poll_handle.active());

	fs_cleanup_path(path);
	poll_handle.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_poll_stop_before_initial_worker_runs_reports_cancelled() @test
{
	work::Pool pool;
	work::WorkOp blocker;
	Loop loop;
	poll::Poll poll_handle;
	FsPollCancelCtx ctx;
	char[128] storage;
	String path = fs_temp_path(storage[0:128], 35);

	fs_cleanup_path(path);
	fs_touch_file(path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	blocker.init();
	poll_handle.init();

	work::queue(&loop, &blocker, &fs_poll_blocker, &after_fs_poll_blocker, &ctx)!!;
	while (@atomic_load(ctx.blocker_started) == 0)
	{
		thread::sleep_ms(1);
	}
	poll::start(&loop, &poll_handle, path, { .interval = (Duration)1_000 }, &on_fs_poll_cancelled, &ctx)!!;
	poll::stop(&loop, &poll_handle)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, ctx.blocker_calls);
	test::eq(1, ctx.poll_calls);
	test::eq(nova::CANCELLED, ctx.poll_status);
	test::@check(!poll_handle.active());

	fs_cleanup_path(path);
	poll_handle.destroy();
	blocker.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_poll_stop_while_timer_pending_reports_cancelled() @test
{
	work::Pool pool;
	Loop loop;
	poll::Poll poll_handle;
	FsPollStopTimerCtx ctx;
	char[128] storage;
	String path = fs_temp_path(storage[0:128], 36);

	fs_cleanup_path(path);
	fs_touch_file(path);
	pool.init({ .workers = 1, .queue_capacity = 2 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	poll_handle.init();

	poll::start(&loop, &poll_handle, path, { .interval = (Duration)1_000_000_000 }, &on_fs_poll_stop_timer, &ctx)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, ctx.calls);
	test::@check(!ctx.status);
	test::@check(poll_handle.active());

	poll::stop(&loop, &poll_handle)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(2, ctx.calls);
	test::eq(nova::CANCELLED, ctx.status);
	test::@check(!poll_handle.active());

	fs_cleanup_path(path);
	poll_handle.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_poll_requires_blocking_pool() @test
{
	Loop loop;
	poll::Poll poll_handle;
	FsPollChangeCtx ctx;
	char[128] storage;
	String path = fs_temp_path(storage[0:128], 37);

	loop.init()!!;
	poll_handle.init();

	test::@error(
		poll::start(&loop, &poll_handle, path, { .interval = (Duration)1_000 }, &on_fs_poll_creation, &ctx),
		nova::INVALID_STATE
	);
	test::@error(
		poll::start(&loop, &poll_handle, path, { .interval = (Duration)0 }, &on_fs_poll_creation, &ctx),
		nova::INVALID_STATE
	);
	test::@check(!poll_handle.active());

	poll_handle.destroy();
	loop.destroy();
}
