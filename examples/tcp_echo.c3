<*
 In-process TCP echo round-trip built on the raw `nova::net::tcp` op layer.

 Demonstrates driving both ends of a connection from one event loop: a
 `Listener` binds a loopback port and `tcp::accept`s a single `Stream`, while a
 client `Stream` `tcp::connect`s to that port and sends a message. The server's
 `tcp::read` callback writes the bytes straight back with `tcp::write`, and the
 client's read callback prints the echo and calls `loop.stop()`. Each async
 operation pre-allocates its own `*Op` (`AcceptOp`, `ConnectOp`, `ReadOp`,
 `WriteOp`) and a shared `Ctx` carries the per-connection state and first fault
 through every callback. The loop is driven by `nova::run` in
 `RunMode.UNTIL_STOPPED`.
*>
module nova_examples::tcp_echo_example;

import std::io;

import nova @norecurse, nova::net, nova::net::tcp;
import nova_examples::common;

const String MESSAGE = "hello nova tcp";
const sz BUFFER_SIZE = 1024;

struct Ctx
{
	tcp::Stream* accepted;
	tcp::ReadOp* server_read_op;
	tcp::WriteOp* server_write_op;
	tcp::ReadOp* client_read_op;
	tcp::WriteOp* client_write_op;
	char[] server_buffer;
	char[] client_buffer;
	fault status;
}

fn int main(String[] args)
{
	(void)args;
	if (catch err = run())
	{
		(void)io::eprintfn("tcp echo failed: %s", err.description);
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
	tcp::WriteOp server_write_op;
	tcp::WriteOp client_write_op;
	tcp::ReadOp client_read_op;
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

	tcp::bind(&listener, loopback(0))!;
	tcp::listen(&listener)!;

	ctx = {
		.accepted = &accepted,
		.server_read_op = &server_read_op,
		.server_write_op = &server_write_op,
		.client_read_op = &client_read_op,
		.client_write_op = &client_write_op,
		.server_buffer = server_buffer[0:BUFFER_SIZE],
		.client_buffer = client_buffer[0:BUFFER_SIZE],
	};

	// Server accepts one connection; the client connects to the bound port.
	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept, &ctx)!;
	tcp::connect(&loop, &client, loopback(listener.local.port), &connect_op, &on_connect, &ctx)!;

	(void)io::printfn("client connecting and sending: %s", MESSAGE);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

	if (ctx.status) return ctx.status~;
}

fn Endpoint loopback(ushort port)
{
	char[4] address = { (char)127, 0, 0, 1 };
	return net::endpoint_from_ipv4(port, address[0:4]);
}

fn void on_accept(Loop* loop, Listener* listener, tcp::AcceptOp* op, tcp::AcceptResult* result, void* userdata)
{
	(void)listener;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		loop.stop();
		return;
	}

	(void)io::printn("server accepted connection");
	if (catch err = tcp::read(loop, ctx.accepted, ctx.server_buffer, ctx.server_read_op, { }, &on_server_read, ctx))
	{
		ctx.status = err;
		loop.stop();
	}
}

fn void on_server_read(Loop* loop, Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		loop.stop();
		return;
	}
	if (result.eof)
	{
		loop.stop();
		return;
	}

	String text = (String)result.buffer[0:result.bytes];
	(void)io::printfn("server read %d bytes: %s", result.bytes, text);
	if (catch err = tcp::write(
		loop,
		ctx.accepted,
		result.buffer[0:result.bytes],
		ctx.server_write_op,
		{ },
		&on_server_write,
		ctx
	))
	{
		ctx.status = err;
		loop.stop();
	}
}

fn void on_server_write(Loop* loop, Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
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
	(void)io::printfn("server echoed %d bytes", result.bytes);
}

fn void on_connect(Loop* loop, Stream* stream, tcp::ConnectOp* op, tcp::ConnectResult* result, void* userdata)
{
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		loop.stop();
		return;
	}

	if (catch err = tcp::read(loop, stream, ctx.client_buffer, ctx.client_read_op, { }, &on_client_read, ctx))
	{
		ctx.status = err;
		loop.stop();
		return;
	}
	if (catch err = tcp::write(loop, stream, (char[])MESSAGE, ctx.client_write_op, { }, &on_client_write, ctx))
	{
		ctx.status = err;
		loop.stop();
	}
}

fn void on_client_write(Loop* loop, Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status) ctx.status = result.error.status;
}

fn void on_client_read(Loop* loop, Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		loop.stop();
		return;
	}

	String text = (String)result.buffer[0:result.bytes];
	(void)io::printfn("client received echo %d bytes: %s", result.bytes, text);
	loop.stop();
}
