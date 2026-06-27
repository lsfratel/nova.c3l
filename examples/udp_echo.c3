<*
 In-process UDP echo round-trip built on the raw `nova::net::udp` op layer.

 Demonstrates datagram messaging from a single event loop: a server and client
 `udp::Socket` each `udp::bind` a loopback port, the client `udp::send`s a
 datagram to the server's local address, and the server's `udp::recv` callback
 echoes the bytes back to the sender. Because the peer `Endpoint` reported by
 `RecvResult` is only valid for the duration of that callback, it is copied into
 the shared `Ctx` before the asynchronous `udp::send` echo references it. Uses
 `RecvOp`/`SendOp` per operation and `nova::run` in `RunMode.UNTIL_STOPPED`.
*>
module nova_examples::udp_echo_example;

import std::io;

import nova @norecurse, nova::net, nova::net::udp;
import nova_examples::common;

const String MESSAGE      = "hello nova udp";
const sz RECV_BUFFER_SIZE = 1024;

struct Ctx
{
	udp::Socket* server;
	udp::SendOp* server_send;
	char[] server_recv_buffer;
	Endpoint peer;
	bool peer_known;
	fault status;
}

fn int main(String[] args)
{
	(void)args;
	if (catch err = run())
	{
		(void)io::eprintfn("udp echo failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void? run()
{
	Loop loop;
	udp::Socket server;
	udp::Socket client;
	udp::RecvOp server_recv_op;
	udp::SendOp server_send_op;
	udp::SendOp client_send_op;
	udp::RecvOp client_recv_op;
	Ctx ctx;
	char[RECV_BUFFER_SIZE] server_buffer;
	char[RECV_BUFFER_SIZE] client_buffer;

	common::init_loop(&loop, { .max_events = 8 })!;
	defer loop.destroy();

	server.init({ .reuse_addr = true })!;
	defer if (server.is_open()) (void)udp::close_now(&server);
	client.init({ .reuse_addr = true })!;
	defer if (client.is_open()) (void)udp::close_now(&client);

	udp::bind(&server, loopback(0))!;
	udp::bind(&client, loopback(0))!;

	ctx.server = &server;
	ctx.server_send = &server_send_op;
	ctx.server_recv_buffer = server_buffer[0:RECV_BUFFER_SIZE];

	// Server waits for a datagram; client posts its receive then fires the request.
	udp::recv(&loop, &server, server_buffer[0:RECV_BUFFER_SIZE], &server_recv_op, &on_server_recv, &ctx)!;
	udp::recv(&loop, &client, client_buffer[0:RECV_BUFFER_SIZE], &client_recv_op, &on_client_recv, &ctx)!;
	udp::send(&loop, &client, (char[])MESSAGE, &server.local, &client_send_op, &on_client_send, &ctx)!;

	(void)io::printfn("client -> server: %s", MESSAGE);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

	if (ctx.status) return ctx.status~;
}

fn Endpoint loopback(ushort port)
{
	char[4] address = { (char)127, 0, 0, 1 };
	return net::endpoint_from_ipv4(port, address[0:4]);
}

fn void on_server_recv(Loop* loop, udp::Socket* socket, udp::RecvOp* op, udp::RecvResult* result, void* userdata)
{
	(void)socket;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		loop.stop();
		return;
	}

	String text = (String)result.buffer[0:result.bytes];
	(void)io::printfn("server received %d bytes: %s", result.bytes, text);

	// The peer endpoint is only valid during this callback, so copy it before the
	// asynchronous echo send that references it.
	ctx.peer = result.peer;
	ctx.peer_known = true;
	if (catch err = udp::send(
		loop,
		ctx.server,
		result.buffer[0:result.bytes],
		&ctx.peer,
		ctx.server_send,
		&on_server_send,
		ctx
	))
	{
		ctx.status = err;
		loop.stop();
	}
}

fn void on_server_send(Loop* loop, udp::Socket* socket, udp::SendOp* op, udp::SendResult* result, void* userdata)
{
	(void)loop;
	(void)socket;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status)
	{
		ctx.status = result.error.status;
		return;
	}
	(void)io::printfn("server echoed %d bytes back to client", result.bytes);
}

fn void on_client_send(Loop* loop, udp::Socket* socket, udp::SendOp* op, udp::SendResult* result, void* userdata)
{
	(void)loop;
	(void)socket;
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	if (result.error.status) ctx.status = result.error.status;
}

fn void on_client_recv(Loop* loop, udp::Socket* socket, udp::RecvOp* op, udp::RecvResult* result, void* userdata)
{
	(void)socket;
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
