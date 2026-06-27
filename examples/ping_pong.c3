<*
 A TCP request with a deadline, showing the timer-as-timeout pattern over the
 raw `nova::net::tcp` and `nova::timer` op layers.

 The client connects, arms a one-shot `timer::start` deadline, posts a
 `tcp::read` for the reply, then `tcp::write`s "ping". The server accepts the
 connection and reads the request but deliberately stays silent, so the reply
 never arrives. When the timer's `on_timeout` callback fires it cancels the
 in-flight request by closing the client stream with `tcp::stream_close`; the
 server then observes that close as EOF on its pending read. A shared `Ctx` and
 a `fail` helper record the first fault and `loop.stop()`. Durations are
 microseconds; the loop runs via `nova::run` in `RunMode.UNTIL_STOPPED`.
*>
module nova_examples::ping_pong_example;

import std::io;

import nova @norecurse, nova::net, nova::net::tcp, nova::timer;
import nova_examples::common;

const String PING      = "ping";
const Duration TIMEOUT = (Duration)300_000; // 300ms client deadline
const sz BUFFER_SIZE   = 64;

struct Ctx
{
	tcp::Stream* accepted;
	tcp::Stream* client;
	tcp::ReadOp* server_read_op;
	tcp::ReadOp* client_read_op;
	tcp::WriteOp* client_write_op;
	tcp::StreamCloseOp* client_close_op;
	timer::TimerOp* timeout_op;
	char[] server_buffer;
	char[] client_buffer;
	bool timed_out;
	fault status;
}

fn int main(String[] args)
{
	(void)args;
	if (catch err = run())
	{
		(void)io::eprintfn("timeout example failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void? run()
{
	Loop loop;
	Listener listener;
	Stream accepted;
	Stream client;
	tcp::AcceptOp accept_op;
	tcp::ConnectOp connect_op;
	tcp::ReadOp server_read_op;
	tcp::ReadOp client_read_op;
	tcp::WriteOp client_write_op;
	tcp::StreamCloseOp client_close_op;
	timer::TimerOp timeout_op;
	Ctx ctx;
	char[BUFFER_SIZE] server_buffer;
	char[BUFFER_SIZE] client_buffer;

	common::init_loop(&loop, { .max_events = 8 })!;
	defer loop.destroy();

	listener.init({ .reuse_addr = true })!;
	defer if (listener.is_open()) (void)tcp::listener_close_now(&listener);
	defer listener.destroy();

	accepted.init()!;
	defer if (accepted.is_open()) (void)tcp::stream_close_now(&accepted);
	defer accepted.destroy();

	client.init()!;
	defer if (client.is_open()) (void)tcp::stream_close_now(&client);
	defer client.destroy();

	timeout_op.init();

	tcp::bind(&listener, loopback(0))!;
	tcp::listen(&listener)!;

	ctx = {
		.accepted = &accepted,
		.client = &client,
		.server_read_op = &server_read_op,
		.client_read_op = &client_read_op,
		.client_write_op = &client_write_op,
		.client_close_op = &client_close_op,
		.timeout_op = &timeout_op,
		.server_buffer = server_buffer[0:BUFFER_SIZE],
		.client_buffer = client_buffer[0:BUFFER_SIZE],
	};

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept, &ctx)!;
	tcp::connect(&loop, &client, loopback(listener.local.port), &connect_op, &on_connect, &ctx)!;

	(void)io::printfn("client: connecting (server will sleep, %dms deadline)", (int)(TIMEOUT / 1_000));
	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

	if (ctx.status) return ctx.status~;
}

fn Endpoint loopback(ushort port)
{
	char[4] address = { (char)127, 0, 0, 1 };
	return net::endpoint_from_ipv4(port, address[0:4]);
}

// ---- server: accept, take the ping, then stay silent ----

fn void on_accept(Loop* loop, Listener* listener, tcp::AcceptOp* op, tcp::AcceptResult* result, void* userdata)
{
	(void)listener;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (fail(loop, ctx, result.error.status)) return;
	(void)io::printn("server: client connected, sleeping (will not reply)");
	read_from_client(loop, ctx);
}

fn void on_server_read(Loop* loop, Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (fail(loop, ctx, result.error.status)) return;
	if (result.eof)
	{
		(void)io::printn("server: connection closed by client");
		return;
	}
	// Got the request, but deliberately send nothing back. Keep a read pending
	// so the eventual client-side close is observed as EOF.
	(void)io::printfn("server: received \"%s\", staying silent", (String)result.buffer[0:result.bytes]);
	read_from_client(loop, ctx);
}

fn void read_from_client(Loop* loop, Ctx* ctx)
{
	if (catch err = tcp::read(loop, ctx.accepted, ctx.server_buffer, ctx.server_read_op, { }, &on_server_read, ctx))
	{
		(void)fail(loop, ctx, err);
	}
}

// ---- client: send a request, guard it with a timer ----

fn void on_connect(Loop* loop, Stream* stream, tcp::ConnectOp* op, tcp::ConnectResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (fail(loop, ctx, result.error.status)) return;

	// Arm the deadline, wait for a reply, then send the request.
	if (catch err = timer::start(loop, ctx.timeout_op, { .delay = TIMEOUT }, &on_timeout, ctx))
	{
		(void)fail(loop, ctx, err);
		return;
	}
	if (catch err = tcp::read(loop, ctx.client, ctx.client_buffer, ctx.client_read_op, { }, &on_client_read, ctx))
	{
		(void)fail(loop, ctx, err);
		return;
	}
	if (catch err = tcp::write(loop, ctx.client, (char[])PING, ctx.client_write_op, { }, &on_client_write, ctx))
	{
		(void)fail(loop, ctx, err);
	}
}

fn void on_client_write(Loop* loop, Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	(void)fail(loop, ctx, result.error.status);
}

fn void on_client_read(Loop* loop, Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	(void)userdata;
	// The reply never arrives; this only fires with CLOSED once the timeout
	// closes the request below, which is expected.
	(void)result;
}

// The deadline elapsed before any reply: cancel the request by closing it.
fn void on_timeout(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status) return;
	(void)io::printfn("client: timed out after %dms, cancelling the request", (int)(TIMEOUT / 1_000));
	ctx.timed_out = true;
	if (catch err = tcp::stream_close(loop, ctx.client, ctx.client_close_op, { }, &on_client_close, ctx))
	{
		(void)fail(loop, ctx, err);
	}
}

fn void on_client_close(Loop* loop, Stream* stream, tcp::StreamCloseOp* op, nova::CloseResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		return;
	}
	(void)io::printn("client: request cancelled, connection closed");
}

// Record the first fault and stop the loop. Returns true when a fault was seen.
fn bool fail(Loop* loop, Ctx* ctx, fault status)
{
	if (!status) return false;
	if (!ctx.status) ctx.status = status;
	loop.stop();
	return true;
}
