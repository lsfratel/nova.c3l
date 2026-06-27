<*
 Stream a file to stdout, built on `nova::fs`.

 Demonstrates async filesystem IO: a single-worker `work::Pool` backs the loop's
 blocking pool, and one reusable `fs::Op` drives an `fs::open` -> repeated
 `fs::read` (at `fs::CURRENT_OFFSET`) -> `fs::close` chain, each step resumed by
 its completion callback. Every read chunk is printed until EOF, then the file is
 closed and the loop stopped; any fault is carried on `Ctx.status` and surfaced
 by `run`.
*>
module nova_examples::fs_cat_example;

import std::io;

import nova @norecurse, nova::fs, nova::work;
import nova_examples::common;

const sz CHUNK_SIZE = 4096;

struct Ctx
{
	fs::Op* op;
	fs::File file;
	char[] buffer;
	fault status;
}

fn int main(String[] args)
{
	if (args.len < 2)
	{
		(void)io::eprintfn("usage: %s <path>", args[0]);
		return 2;
	}

	if (catch err = run(args[1]))
	{
		(void)io::eprintfn("fs cat failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void? run(String path)
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	Ctx ctx;
	char[CHUNK_SIZE] buffer;

	// Filesystem operations run on the blocking pool and complete on the loop.
	pool.init({ .workers = 1, .queue_capacity = 4 })!;
	defer pool.destroy();

	common::init_loop(&loop, { .blocking_pool = &pool })!;
	defer loop.destroy();

	// One op is reused for the whole open/read/close chain.
	op.init();
	ctx = { .op = &op, .buffer = buffer[0:CHUNK_SIZE] };

	fs::open(&loop, &op, path, { .access = fs::OpenAccess.READ }, &on_open, &ctx)!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

	if (ctx.status) return ctx.status~;
}

fn void on_open(Loop* loop, fs::Op* op, fs::Result* result, void* userdata)
{
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		loop.stop();
		return;
	}

	ctx.file = result.file;
	read_next(loop, ctx);
}

fn void on_read(Loop* loop, fs::Op* op, fs::Result* result, void* userdata)
{
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		close(loop, ctx);
		return;
	}
	if (result.eof || result.bytes == 0)
	{
		close(loop, ctx);
		return;
	}

	// Print exactly the bytes read, then queue the next read.
	(void)io::print((String)ctx.buffer[0:result.bytes]);
	read_next(loop, ctx);
}

fn void on_close(Loop* loop, fs::Op* op, fs::Result* result, void* userdata)
{
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status && !ctx.status) ctx.status = result.error.status;
	loop.stop();
}

// Sequential read from the file position via CURRENT_OFFSET, reusing the op.
fn void read_next(Loop* loop, Ctx* ctx)
{
	if (catch err = fs::read(loop, ctx.op, ctx.file, ctx.buffer, fs::CURRENT_OFFSET, &on_read, ctx))
	{
		ctx.status = err;
		close(loop, ctx);
	}
}

fn void close(Loop* loop, Ctx* ctx)
{
	if (!ctx.file.valid())
	{
		loop.stop();
		return;
	}
	if (catch err = fs::close(loop, ctx.op, &ctx.file, &on_close, ctx))
	{
		if (!ctx.status) ctx.status = err;
		loop.stop();
	}
}
