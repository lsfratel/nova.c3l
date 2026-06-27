<*
 Child-process runner built on `nova::process`, `nova::pipe` and `nova::timer`.

 Demonstrates spawning a subprocess with captured stdio: `process::make_options`
 plus `process::piped()` request piped stdout/stderr, `process::spawn` launches
 the child and reports termination through `on_process_exit` (distinguishing
 normal exit from a delivering signal). The child's `stdout`/`stderr` pipe
 endpoints are drained with self-re-arming `pipe::read` loops until EOF, streaming
 output to the parent's stdout/stderr. An optional leading `--timeout-ms=MS` arms a
 `timer::start`; on expiry it sends SIGTERM via `process::kill`. The example
 forwards the child's exit code (124 on timeout, 128+signal when killed). The
 remaining arguments are the command and its arguments.
*>
module nova_examples::process_example;

import std::io;
import libc;

import nova @norecurse, nova::pipe, nova::process, nova::timer;
import nova_examples::common;

const sz PROCESS_BUFFER_SIZE   = 4096;
const int PROCESS_TIMEOUT_EXIT = 124;
const String TIMEOUT_PREFIX    = "--timeout-ms=";

struct Config
{
	String command;
	String[] args;
	Duration timeout;
}

struct App
{
	process::Process child;
	pipe::ReadOp stdout_read;
	pipe::ReadOp stderr_read;
	timer::TimerOp timeout_timer;
	char[PROCESS_BUFFER_SIZE] stdout_buffer;
	char[PROCESS_BUFFER_SIZE] stderr_buffer;
	fault status;
	int exit_code;
	CInt term_signal;
	bool timed_out;
}

fn int main(String[] args)
{
	String program = args.len ? args[0] : "process";
	Config config;
	sz i           = 1;
	if (i < args.len && args[i].starts_with(TIMEOUT_PREFIX))
	{
		Duration? timeout = parse_timeout_ms(args[i][TIMEOUT_PREFIX.len..]);
		if (catch timeout)
		{
			print_usage(program);
			return 2;
		}
		config.timeout = timeout;
		i++;
	}
	if (i >= args.len)
	{
		(void)io::eprintn("missing command");
		print_usage(program);
		return 2;
	}
	config.command = args[i];
	config.args = args[i + 1:args.len - i - 1];

	int? exit_code = run_process(config);
	if (catch err = exit_code)
	{
		(void)io::eprintfn("process failed: %s", err.description);
		return 1;
	}
	return exit_code;
}

fn void print_usage(String program)
{
	(void)io::printfn("usage: %s [--timeout-ms=MS] command [args...]", program);
	(void)io::printfn("example: %s --timeout-ms=1000 echo hello", program);
}

fn Duration? parse_timeout_ms(String value)
{
	long parsed = value.to_long()!;
	if (parsed < 0 || parsed > long::max / 1000)
	{
		(void)io::eprintfn("invalid timeout-ms: %s", value);
		return nova::INVALID_STATE~;
	}
	return (Duration)(parsed * 1000);
}

fn int? run_process(Config config)
{
	Loop loop;
	App app;

	common::init_loop(&loop, { .max_events = 8 })!;
	defer loop.destroy();

	app.child.init();
	app.timeout_timer.init();
	defer app.child.destroy();
	defer app.timeout_timer.destroy();

	// piped() asks the child to inherit pipe endpoints we own, so the parent can
	// read its stdout/stderr; leave stdin at its default.
	process::SpawnOptions options = process::make_options(config.command);
	options.args = config.args;
	options.stdout = process::piped();
	options.stderr = process::piped();

	process::spawn(&loop, &app.child, options, &on_process_exit, &app)!;
	defer close_child_stdio(&app.child);

	if (app.child.has_stdout)
	{
		pipe::read(
			&loop,
			&app.child.stdout,
			app.stdout_buffer[0:PROCESS_BUFFER_SIZE],
			&app.stdout_read,
			{ },
			&on_stdout_read,
			&app
		)!;
	}
	if (app.child.has_stderr)
	{
		pipe::read(
			&loop,
			&app.child.stderr,
			app.stderr_buffer[0:PROCESS_BUFFER_SIZE],
			&app.stderr_read,
			{ },
			&on_stderr_read,
			&app
		)!;
	}
	if (config.timeout > (Duration)0)
	{
		timer::start(&loop, &app.timeout_timer, { .delay = config.timeout }, &on_timeout, &app)!;
	}

	nova::run(&loop, RunMode.UNTIL_STOPPED)!;
	if (app.status) return app.status~;

	if (app.timed_out)
	{
		(void)io::eprintfn("process timed out after %d ms", (long)config.timeout / 1000);
		return PROCESS_TIMEOUT_EXIT;
	}
	if (app.term_signal)
	{
		(void)io::eprintfn("process signaled: pid=%d signal=%d", app.child.get_pid(), app.term_signal);
		return 128 + (int)app.term_signal;
	}
	(void)io::eprintfn("process exited: pid=%d code=%d", app.child.get_pid(), app.exit_code);
	return app.exit_code;
}

fn void close_child_stdio(process::Process* child)
{
	if (child.has_stdin || child.has_stdout || child.has_stderr)
	{
		(void)process::close_stdio_now(child);
	}
}

fn void on_process_exit(Loop* loop, process::Process* child, process::ExitResult* result, void* userdata)
{
	App* app = (App*)userdata;
	// Child is gone, so the timeout no longer applies; cancel a still-pending timer.
	if (app.timeout_timer.active()) (void)timer::stop(loop, &app.timeout_timer);
	if (result.error.status)
	{
		app.status = result.error.status;
		return;
	}
	if (result.signaled)
	{
		app.term_signal = result.term_signal;
		return;
	}
	if (result.exited) app.exit_code = result.exit_status;
	(void)child;
}

fn void on_timeout(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	App* app = (App*)userdata;
	if (result.error.status) return;
	app.timed_out = true;
	if (app.child.is_running()) (void)process::kill(&app.child, libc::SIGTERM);
	(void)loop;
	(void)op;
}

fn void on_stdout_read(Loop* loop, pipe::Endpoint* endpoint, pipe::ReadOp* op, pipe::ReadResult* result, void* userdata)
{
	App* app = (App*)userdata;
	handle_pipe_read(loop, endpoint, op, result, app.stdout_buffer[0:PROCESS_BUFFER_SIZE], &on_stdout_read, app, false);
}

fn void on_stderr_read(Loop* loop, pipe::Endpoint* endpoint, pipe::ReadOp* op, pipe::ReadResult* result, void* userdata)
{
	App* app = (App*)userdata;
	handle_pipe_read(loop, endpoint, op, result, app.stderr_buffer[0:PROCESS_BUFFER_SIZE], &on_stderr_read, app, true);
}

fn void handle_pipe_read(
	Loop* loop,
	pipe::Endpoint* endpoint,
	pipe::ReadOp* op,
	pipe::ReadResult* result,
	char[] buffer,
	pipe::ReadCallback callback,
	App* app,
	bool stderr
)
{
	if (result.error.status)
	{
		app.status = result.error.status;
		return;
	}
	if (result.bytes > 0)
	{
		String text = (String)result.buffer[0:result.bytes];
		if (stderr)
		{
			io::eprint(text);
		}
		else
		{
			io::print(text);
		}
	}
	if (result.eof) return;
	// Not at EOF yet: re-arm the same read op to keep draining the pipe.
	if (catch err = pipe::read(loop, endpoint, buffer, op, { }, callback, app))
	{
		app.status = err;
	}
}
