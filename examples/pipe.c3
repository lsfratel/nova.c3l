<*
 Anonymous pipe round-trip built on `nova::pipe`.

 Demonstrates the pipe layer: `pipe::Pair.open` creates a connected read/write
 endpoint pair, then `pipe::read` and `pipe::write` are armed on the loop and
 complete asynchronously through `on_read`/`on_write` callbacks. One message is
 written through the write end and read back from the read end; the read result
 reports byte count and EOF. Both endpoints are closed on teardown via
 `pipe::close_now`. An optional first argument overrides the message.
*>
module nova_examples::pipe_example;

import std::io;

import nova @norecurse, nova::pipe;
import nova_examples::common;

const String DEFAULT_MESSAGE = "hello from nova pipe";
const sz READ_BUFFER_SIZE    = 1024;

struct App
{
	fault status;
}

fn int main(String[] args)
{
	String message = args.len > 1 ? args[1] : DEFAULT_MESSAGE;
	if (catch err = run_pipe(message))
	{
		(void)io::eprintfn("pipe failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void? run_pipe(String message)
{
	Loop loop;
	pipe::Pair pair;
	pipe::ReadOp read_op;
	pipe::WriteOp write_op;
	App app;
	char[READ_BUFFER_SIZE] buffer;

	if (message.len > READ_BUFFER_SIZE)
	{
		(void)io::eprintfn("message is too large: %d bytes (max %d)", message.len, READ_BUFFER_SIZE);
		return nova::INVALID_STATE~;
	}

	common::init_loop(&loop, { .max_events = 4 })!;
	defer loop.destroy();

	pair.open()!;
	defer pair.destroy();
	defer if (pair.write.is_open()) (void)pipe::close_now(&pair.write);
	defer if (pair.read.is_open()) (void)pipe::close_now(&pair.read);

	// Arm both ends before running the loop; the write completes and the read
	// receives the bytes within the same run.
	pipe::read(&loop, &pair.read, buffer[0:READ_BUFFER_SIZE], &read_op, { }, &on_read, &app)!;
	pipe::write(&loop, &pair.write, message, &write_op, { }, &on_write, &app)!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

	if (app.status) return app.status~;
}

fn void on_read(Loop* loop, pipe::Endpoint* endpoint, pipe::ReadOp* op, pipe::ReadResult* result, void* userdata)
{
	(void)loop;
	(void)endpoint;
	(void)op;
	App* app = (App*)userdata;
	if (result.error.status)
	{
		app.status = result.error.status;
		(void)io::eprintfn("pipe read failed: %s", result.error.status.description);
		return;
	}
	if (result.eof)
	{
		(void)io::printn("pipe read EOF");
		return;
	}

	(void)io::printfn("pipe read %d bytes", result.bytes);
	String text = (String)result.buffer[0:result.bytes];
	(void)io::print("message: ");
	(void)io::print(text);
	(void)io::printn();
}

fn void on_write(Loop* loop, pipe::Endpoint* endpoint, pipe::WriteOp* op, pipe::WriteResult* result, void* userdata)
{
	(void)loop;
	(void)endpoint;
	(void)op;
	App* app = (App*)userdata;
	if (result.error.status)
	{
		app.status = result.error.status;
		(void)io::eprintfn("pipe write failed: %s", result.error.status.description);
		return;
	}

	(void)io::printfn("pipe wrote %d bytes", result.bytes);
}
