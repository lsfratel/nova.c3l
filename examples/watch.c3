<*
 Watch a raw file descriptor for readiness with `nova::watch`.

 `nova::watch` registers any borrowed native handle on the loop and reports when
 it becomes readable/writable. It is the building block for bringing a foreign
 fd (an eventfd, an inotify fd, a socket you manage yourself, ...) into a nova
 loop. Here we watch the read end of a pipe. Each watch is one-shot, so the
 callback re-arms it to keep observing.
*>
module nova_examples::watch_example;

import std::io;
import std::os::posix;
import libc;

import nova @norecurse, nova::watch;
import nova_examples::common;

const int MESSAGES = 3;

struct App
{
	CInt read_fd;
	CInt write_fd;
	int seen;
	fault status;
}

fn int main(String[] args)
{
	(void)args;
	Loop loop;
	watch::Watch w;
	watch::WatchOp op;
	App app;

	if (catch err = run(&loop, &w, &op, &app))
	{
		(void)io::eprintfn("watch example failed: %s", err.description);
		return 1;
	}
	if (app.status) return 1;
	return 0;
}

fn void? run(Loop* loop, watch::Watch* w, watch::WatchOp* op, App* app)
{
	CInt[2] fds;
	if (posix::pipe(&fds) != 0) return nova::BACKEND_FAILED~;
	app.read_fd = fds[0];
	app.write_fd = fds[1];
	defer (void)libc::close(app.read_fd);
	defer (void)libc::close(app.write_fd);

	common::init_loop(loop, { .max_events = 4 })!;
	defer loop.destroy();

	// The native handle is borrowed: nova watches it but never closes it.
	w.init((NativeHandle)app.read_fd, watch::Interest.READABLE)!;
	op.init();

	(void)io::printfn("watching a pipe read fd for readability (%d messages)", MESSAGES);
	watch::start(loop, w, op, &on_readable, app)!;
	send(app, "hello");

	nova::run(loop, RunMode.UNTIL_STOPPED)!;
}

fn void on_readable(Loop* loop, watch::Watch* w, watch::WatchOp* op, watch::WatchResult* result, void* userdata)
{
	App* app = (App*)userdata;

	if (result.error.status)
	{
		app.status = result.error.status;
		loop.stop();
		return;
	}
	if (!result.events.readable) return;

	// The watch fired because the handle is readable, so this read does not
	// block. (With non-blocking fds you would instead drain until EAGAIN.)
	char[64] buf;
	sz n = libc::read(app.read_fd, &buf, buf.len);
	app.seen++;
	if (n > 0) (void)io::printfn("message %d readable: %s", app.seen, (String)buf[0:n]);

	if (app.seen >= MESSAGES)
	{
		loop.stop();
		return;
	}

	// A watch is one-shot: re-arm it for the next readiness, then push more data.
	if (catch err = watch::start(loop, w, op, &on_readable, app))
	{
		app.status = err;
		loop.stop();
		return;
	}
	send(app, "tick");
}

fn void send(App* app, String msg)
{
	(void)libc::write(app.write_fd, msg.ptr, (usz)msg.len);
}
