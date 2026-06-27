<*
 Detect a file change by stat-polling, built on `nova::fs::poll`.

 Demonstrates the `poll::Poll` watcher: `poll::start` stats `path` every
 `interval` on the loop's blocking pool and invokes `on_change` with a
 `poll::PollResult` carrying the previous/current `Stat` and a `changed` flag.
 The first callback is the baseline snapshot (so it appends to the file to force
 a change); the next change stops the watch with `poll::stop` and the loop. The
 demo file is created, modified and removed by the program itself.
*>
module nova_examples::fs_watch_example;

import std::io;
import libc;

import nova @norecurse, nova::fs::poll, nova::work;
import nova_examples::common;

const String DEFAULT_PATH    = "nova_fs_watch_demo.txt";
const Duration POLL_INTERVAL = (Duration)50_000; // 50ms (microseconds)

struct Ctx
{
	String path;
	int calls;
	fault status;
}

fn int main(String[] args)
{
	// Creates, modifies and removes its own demo file so the run is self-contained.
	String path = args.len >= 2 ? args[1] : DEFAULT_PATH;
	if (catch err = run(path))
	{
		(void)io::eprintfn("fs watch failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void? run(String path)
{
	work::Pool pool;
	Loop loop;
	poll::Poll poll_handle;
	Ctx ctx = { .path = path };

	pool.init({ .workers = 1, .queue_capacity = 4 })!;
	defer pool.destroy();

	common::init_loop(&loop, { .blocking_pool = &pool })!;
	defer loop.destroy();

	poll_handle.init();
	write_file(path, "initial\n");
	defer remove_file(path);

	(void)io::printfn("watching %s every 50ms", path);
	poll::start(&loop, &poll_handle, path, { .interval = POLL_INTERVAL }, &on_change, &ctx)!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

	if (ctx.status) return ctx.status~;
}

fn void on_change(Loop* loop, poll::Poll* poll_handle, poll::PollResult* result, void* userdata)
{
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		loop.stop();
		return;
	}

	ctx.calls++;
	// First callback is the baseline; mutate the file to provoke a change.
	if (ctx.calls == 1)
	{
		(void)io::printfn("baseline snapshot (exists=%s, size=%d)", result.current_exists, result.current.size);
		append_file(ctx.path, "appended\n");
		return;
	}

	if (result.changed)
	{
		(void)io::printfn("change detected: size %d -> %d", result.previous.size, result.current.size);
		if (catch err = poll::stop(loop, poll_handle)) ctx.status = err;
		loop.stop();
	}
}

fn void write_file(String path, String data)
{
	CFile file = libc::fopen(path.zstr_tcopy(), "w");
	if (file == null) return;
	(void)libc::fwrite(data.ptr, 1, (usz)data.len, file);
	(void)libc::fclose(file);
}

fn void append_file(String path, String data)
{
	CFile file = libc::fopen(path.zstr_tcopy(), "a");
	if (file == null) return;
	(void)libc::fwrite(data.ptr, 1, (usz)data.len, file);
	(void)libc::fclose(file);
}

fn void remove_file(String path)
{
	(void)libc::remove(path.zstr_tcopy());
}
