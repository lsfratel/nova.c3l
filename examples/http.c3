<*
 Single-threaded "hello world" HTTP server built on the raw `nova::net::tcp`
 proactor.

 Demonstrates the lowest-level server pattern: one `Loop` drives a pool of
 preallocated `ConnectionSlot`s, each owning its own `AcceptOp`/`ReadOp`/`WriteOp`
 and read buffer. `accept_window` slots are armed up front and every slot loops
 accept -> read -> write -> (re-accept or read-again) entirely through completion
 callbacks; all sockets and slots are allocated once at startup. The
 `NOVA_HTTP_CONNECTION` env var (`close`|`keep-alive`, default keep-alive) selects
 whether each connection is closed after the response or kept open for the next
 request, and `NOVA_BACKEND` selects the event-loop backend. Both, the responses
 and the loop setup are shared with the other examples via `nova_examples::common`.
*>
module nova_examples::http;

import std::io;
import std::core::mem::alloc;

import nova @norecurse, nova::net, nova::net::tcp;
import nova_examples::common;

const ushort DEFAULT_PORT            = 8080;
const sz DEFAULT_CONNECTION_CAPACITY = 4096;
const sz DEFAULT_ACCEPT_WINDOW       = 512;

struct Server
{
	Loop loop;
	tcp::Listener listener;
	ConnectionSlot[] slots;
	sz accept_window;
	bool close_after_response;
}

struct ConnectionSlot
{
	Server* server;
	tcp::Stream stream;
	tcp::AcceptOp accept_op;
	tcp::ReadOp read_op;
	tcp::WriteOp write_op;
	char[common::READ_BUFFER_SIZE] read_buffer;
	bool initialized;
}

fn int main(String[] args)
{
	(void)args;
	if (catch err = run_server(common::close_after_response()))
	{
		(void)io::eprintfn("server failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void? run_server(bool close_after_response)
{
	Server server;
	server.close_after_response = close_after_response;
	server.accept_window = DEFAULT_CONNECTION_CAPACITY < DEFAULT_ACCEPT_WINDOW ? DEFAULT_CONNECTION_CAPACITY
		: DEFAULT_ACCEPT_WINDOW;
	server.slots = alloc::new_array_try(mem, ConnectionSlot, DEFAULT_CONNECTION_CAPACITY)!;
	defer alloc::free(mem, server.slots.ptr);

	common::init_loop(
		&server.loop,
		{ .max_events = DEFAULT_CONNECTION_CAPACITY + 1, .dispatch_budget = 1024, .io_progress_budget = 32 }
	)!;

	// reuse_addr/reuse_port allow quick rebinds; nodelay disables Nagle for low latency.
	server.listener.init({ .reuse_addr = true, .reuse_port = true, .nodelay = true })!;
	tcp::bind(&server.listener, common::ipv4_any_endpoint(DEFAULT_PORT))!;
	tcp::listen(&server.listener)!;

	for (sz i = 0; i < DEFAULT_CONNECTION_CAPACITY; i++)
	{
		ConnectionSlot* slot = &server.slots[i];
		slot.server = &server;
		slot.stream.init()!;
		slot.initialized = true;
	}

	String mode    = server.close_after_response ? "close" : "keep-alive";
	String backend = server.loop.backend() == nova::BackendKind.IO_URING ? "io_uring" : "epoll";
	(void)io::printfn(
		"nova http listening on 0.0.0.0:%d capacity=%d accept_window=%d connection=%s backend=%s",
		server.listener.local.port,
		DEFAULT_CONNECTION_CAPACITY,
		server.accept_window,
		mode,
		backend
	);

	// Arm the initial batch of accepts; each completion re-arms its own slot.
	for (sz i = 0; i < server.accept_window; i++)
	{
		slot_accept(&server.slots[i])!;
	}

	nova::run(&server.loop, RunMode.UNTIL_STOPPED)!;

	for (sz i = 0; i < DEFAULT_CONNECTION_CAPACITY; i++)
	{
		ConnectionSlot* slot = &server.slots[i];
		if (slot.stream.open) (void)tcp::stream_close_now(&slot.stream);
		if (slot.initialized) slot.stream.destroy();
	}
	if (server.listener.open) (void)tcp::listener_close_now(&server.listener);
	server.listener.destroy();
	server.loop.destroy();
}

fn void? slot_accept(ConnectionSlot* slot)
{
	Server* server = slot.server;
	tcp::accept(&server.loop, &server.listener, &slot.stream, &slot.accept_op, &on_accept, slot)!;
}

fn void? slot_read(Loop* loop, ConnectionSlot* slot)
{
	tcp::read(loop, &slot.stream, slot.read_buffer[0:common::READ_BUFFER_SIZE], &slot.read_op, { }, &on_read, slot)!;
}

fn void? slot_write(Loop* loop, ConnectionSlot* slot, String response)
{
	tcp::write(loop, &slot.stream, response, &slot.write_op, { }, &on_write, slot)!;
}

fn void read_or_close(Loop* loop, ConnectionSlot* slot)
{
	if (catch slot_read(loop, slot)) close_and_accept(slot);
}

fn void write_or_close(Loop* loop, ConnectionSlot* slot, String response)
{
	if (catch slot_write(loop, slot, response)) close_and_accept(slot);
}

fn void on_accept(Loop* loop, tcp::Listener* listener, tcp::AcceptOp* op, tcp::AcceptResult* result, void* userdata)
{
	(void)listener;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (result.error.status)
	{
		(void)slot_accept(slot);
		return;
	}

	read_or_close(loop, slot);
}

fn void on_read(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (result.error.status || result.eof || result.bytes <= 0)
	{
		close_and_accept(slot);
		return;
	}

	String response = slot.server.close_after_response ? common::RESPONSE_CLOSE : common::RESPONSE_KEEP_ALIVE;
	write_or_close(loop, slot, response);
}

fn void on_write(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (result.error.status || slot.server.close_after_response)
	{
		close_and_accept(slot);
		return;
	}

	// keep-alive: reuse the same connection for the next request.
	read_or_close(loop, slot);
}

fn void close_and_accept(ConnectionSlot* slot)
{
	if (slot.stream.open) (void)tcp::stream_close_now(&slot.stream);
	(void)slot_accept(slot);
}
