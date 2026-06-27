<*
 Single-threaded HTTP server with signal-driven graceful shutdown: the
 `nova::signal` variant of `http.c3`.

 Like the base `http` example it runs one `Loop` over a preallocated slot pool and
 honors the `NOVA_HTTP_CONNECTION` env var (`close`|`keep-alive`), but it also arms two
 `signal::SignalOp`s (SIGINT and SIGTERM) on the loop. On either signal
 `begin_shutdown` stops accepting, asynchronously closes the listener
 (`tcp::listener_close`), and drains in-flight work: idle keep-alive connections are
 closed immediately while connections mid-response finish and then close, replying
 `503 Service Unavailable` to any request that arrives during the drain. Each slot
 carries an explicit `SlotPhase` state machine (FREE/ACCEPTING/READING/WRITING/
 CLOSING) and the server tracks `active_connections`; once the listener is closed
 and that count reaches zero, `maybe_stop` calls `Loop.stop` for a clean exit.
 Responses and the connection-mode / backend selection are shared with the other
 HTTP examples via `nova_examples::common`.
*>
module nova_examples::http_signal;

import std::io;
import std::os::posix;
import std::core::mem::alloc;
import libc;

import nova @norecurse, nova::net, nova::net::tcp, nova::signal;
import nova_examples::common;

const ushort DEFAULT_PORT            = 8080;
const sz DEFAULT_CONNECTION_CAPACITY = 4096;
const sz DEFAULT_ACCEPT_WINDOW       = 512;

const String RESPONSE_SHUTDOWN = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 48\r\nConnection: close\r\nRetry-After: 5\r\n\r\n<html><body><h1>shutting down</h1></body></html>";

constdef SlotPhase : inline char
{
	FREE      = 0,
	ACCEPTING = 1,
	READING   = 2,
	WRITING   = 3,
	CLOSING   = 4,
}

struct Server
{
	Loop loop;
	tcp::Listener listener;
	tcp::ListenerCloseOp listener_close_op;
	signal::SignalOp sigint_op;
	signal::SignalOp sigterm_op;
	ConnectionSlot[] slots;
	sz accept_window;
	sz active_connections;
	bool close_after_response;
	bool shutting_down;
	bool listener_closing;
}

struct ConnectionSlot
{
	Server* server;
	tcp::Stream stream;
	tcp::AcceptOp accept_op;
	tcp::ReadOp read_op;
	tcp::WriteOp write_op;
	tcp::StreamCloseOp close_op;
	char[common::READ_BUFFER_SIZE] read_buffer;
	SlotPhase phase;
	bool connected;
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

	server.listener.init({ .reuse_addr = true, .reuse_port = true, .nodelay = true })!;
	tcp::bind(&server.listener, common::ipv4_any_endpoint(DEFAULT_PORT))!;
	tcp::listen(&server.listener)!;

	// Arm SIGINT/SIGTERM as loop operations; on_signal triggers graceful shutdown.
	server.sigint_op.init();
	server.sigterm_op.init();
	signal::start(&server.loop, &server.sigint_op, { .signum = libc::SIGINT }, &on_signal, &server)!;
	signal::start(&server.loop, &server.sigterm_op, { .signum = libc::SIGTERM }, &on_signal, &server)!;

	for (sz i = 0; i < DEFAULT_CONNECTION_CAPACITY; i++)
	{
		ConnectionSlot* slot = &server.slots[i];
		slot.server = &server;
		slot.stream.init()!;
		slot.initialized = true;
	}

	String mode = server.close_after_response ? "close" : "keep-alive";
	(void)io::printfn(
		"nova http_signal listening on 0.0.0.0:%d capacity=%d accept_window=%d connection=%s",
		server.listener.local.port,
		DEFAULT_CONNECTION_CAPACITY,
		server.accept_window,
		mode
	);
	(void)io::printfn("send SIGINT or SIGTERM to stop accepting and drain active responses (pid=%d)", posix::getpid());

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
	server.sigint_op.destroy();
	server.sigterm_op.destroy();
	server.listener.destroy();
	server.loop.destroy();
}

fn void? slot_accept(ConnectionSlot* slot)
{
	Server* server = slot.server;
	if (server.shutting_down) return;
	slot.phase = SlotPhase.ACCEPTING;
	tcp::accept(&server.loop, &server.listener, &slot.stream, &slot.accept_op, &on_accept, slot)!;
}

fn void? slot_read(Loop* loop, ConnectionSlot* slot)
{
	slot.phase = SlotPhase.READING;
	tcp::read(loop, &slot.stream, slot.read_buffer[0:common::READ_BUFFER_SIZE], &slot.read_op, { }, &on_read, slot)!;
}

fn void? slot_write(Loop* loop, ConnectionSlot* slot, String response)
{
	slot.phase = SlotPhase.WRITING;
	tcp::write(loop, &slot.stream, response, &slot.write_op, { }, &on_write, slot)!;
}

fn void read_or_close(Loop* loop, ConnectionSlot* slot)
{
	if (catch slot_read(loop, slot)) close_slot_now(slot);
}

fn void write_or_close(Loop* loop, ConnectionSlot* slot, String response)
{
	if (catch slot_write(loop, slot, response)) close_slot_now(slot);
}

fn void close_idle_connection(Loop* loop, ConnectionSlot* slot)
{
	if (!slot.connected || slot.phase != SlotPhase.READING) return;
	slot.phase = SlotPhase.CLOSING;
	if (catch tcp::stream_close(loop, &slot.stream, &slot.close_op, { }, &on_stream_close, slot))
	{
		close_slot_now(slot);
	}
}

fn void close_slot_now(ConnectionSlot* slot)
{
	if (slot.stream.open) (void)tcp::stream_close_now(&slot.stream);
	if (slot.connected && slot.server.active_connections > 0) slot.server.active_connections--;
	slot.connected = false;
	slot.phase = SlotPhase.FREE;
	maybe_stop(slot.server);
}

// Stop the loop only once shutdown began, the listener finished closing, and
// every active connection has drained.
fn void maybe_stop(Server* server)
{
	if (!server.shutting_down) return;
	if (server.listener_closing) return;
	if (server.active_connections > 0) return;
	server.loop.stop();
}

fn void begin_shutdown(Loop* loop, Server* server, CInt signum)
{
	if (server.shutting_down) return;
	server.shutting_down = true;
	(void)io::printfn("received signal %d; closing listener and draining connections", signum);
	if (server.sigint_op.active()) (void)signal::stop(loop, &server.sigint_op);
	if (server.sigterm_op.active()) (void)signal::stop(loop, &server.sigterm_op);

	if (server.listener.open && !server.listener_closing)
	{
		server.listener_closing = true;
		if (catch tcp::listener_close(
			loop,
			&server.listener,
			&server.listener_close_op,
			{ },
			&on_listener_close,
			server
		))
		{
			server.listener_closing = false;
			if (server.listener.open) (void)tcp::listener_close_now(&server.listener);
		}
	}

	for (sz i = 0; i < server.slots.len; i++)
	{
		close_idle_connection(loop, &server.slots[i]);
	}
	maybe_stop(server);
}

fn void on_signal(Loop* loop, signal::SignalOp* op, signal::SignalResult* result, void* userdata)
{
	(void)op;
	Server* server = (Server*)userdata;
	if (result.error.status) return;
	begin_shutdown(loop, server, result.signum);
}

fn void on_listener_close(
	Loop* loop,
	tcp::Listener* listener,
	tcp::ListenerCloseOp* op,
	CloseResult* result,
	void* userdata
)
{
	(void)loop;
	(void)listener;
	(void)op;
	if (result.error.status) (void)io::eprintfn("listener close failed: %s", result.error.status.description);
	Server* server = (Server*)userdata;
	server.listener_closing = false;
	maybe_stop(server);
}

fn void on_accept(Loop* loop, tcp::Listener* listener, tcp::AcceptOp* op, tcp::AcceptResult* result, void* userdata)
{
	(void)listener;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (result.error.status)
	{
		slot.phase = SlotPhase.FREE;
		if (!slot.server.shutting_down) (void)slot_accept(slot);
		maybe_stop(slot.server);
		return;
	}

	slot.connected = true;
	slot.server.active_connections++;
	// A connection accepted mid-shutdown gets a 503 instead of being served.
	if (slot.server.shutting_down)
	{
		write_or_close(loop, slot, RESPONSE_SHUTDOWN);
		return;
	}
	read_or_close(loop, slot);
}

fn void on_read(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (slot.phase == SlotPhase.CLOSING) return;
	if (result.error.status || result.eof || result.bytes <= 0)
	{
		close_slot_now(slot);
		return;
	}

	String response = slot.server.shutting_down ? RESPONSE_SHUTDOWN
		: (slot.server.close_after_response ? common::RESPONSE_CLOSE : common::RESPONSE_KEEP_ALIVE);
	write_or_close(loop, slot, response);
}

fn void on_write(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (result.error.status || slot.server.shutting_down || slot.server.close_after_response)
	{
		close_slot_now(slot);
		return;
	}
	read_or_close(loop, slot);
}

fn void on_stream_close(Loop* loop, tcp::Stream* stream, tcp::StreamCloseOp* op, CloseResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	if (result.error.status) (void)io::eprintfn("stream close failed: %s", result.error.status.description);
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (slot.connected && slot.server.active_connections > 0) slot.server.active_connections--;
	slot.connected = false;
	slot.phase = SlotPhase.FREE;
	maybe_stop(slot.server);
}
