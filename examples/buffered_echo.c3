<*
 Line-echo server built on `nova::buffered`.

 Demonstrates the buffered layer: each accepted connection is wrapped in a
 `buffered::StreamConn`, which turns the raw proactor read/write model into a
 batching one. The data callback frames newline-delimited lines with
 `find_byte`/`copyout`/`consume` and echoes them with `write` (coalesced into one
 vectored flush while output remains); read backpressure and write draining are
 handled by the buffered layer. SIGINT shuts the server down gracefully via
 `Loop.close_all` followed by the loop draining its cancellations, then
 `Loop.destroy` (the P0 teardown path), leaking nothing.

 Each connection's rings are reserved in `StreamConn.init` on accept and
 released in `destroy` on close, so only connection setup allocates.
*>
module nova_examples::buffered_echo;

import std::io;
import std::core::mem::alloc;
import libc;

import nova @norecurse, nova::net, nova::net::tcp, nova::buffered, nova::signal;
import nova_examples::common;

const usz SLOTS    = 64;
const usz RING_CAP = 16 * 1024;
const ushort PORT  = 9009;

<*
 Shared server state visible to every slot and the signal handler.
*>
struct Server
{
	Loop* loop;
	tcp::Listener* listener;
	Slot[] slots;
	signal::SignalOp sig_op;
	bool stopping;
}

<*
 One reusable connection slot: its accepted stream, accept op, async-close op and
 the buffered connection wrapping the stream while it is serving.
*>
struct Slot
{
	Server* server;
	tcp::Stream stream;
	tcp::AcceptOp accept_op;
	tcp::StreamCloseOp close_op;
	buffered::StreamConn conn;
	bool serving;
	bool closing;
}

<*
 Program entry point.
*>
fn int main(String[] args)
{
	(void)args;
	if (catch err = run())
	{
		(void)io::eprintfn("buffered-echo failed: %s", err.description);
		return 1;
	}
	return 0;
}

<*
 Bind the listener, arm one accept per slot, run until SIGINT, then tear down.
*>
fn void? run()
{
	Loop loop;
	tcp::Listener listener;
	Server server;

	common::init_loop(&loop, { .max_events = (sz)SLOTS + 8 })!;
	defer loop.destroy();

	Slot[] slots = alloc::new_array_try(mem, Slot, (sz)SLOTS)!;
	defer alloc::free(mem, slots.ptr);

	listener.init({ .reuse_addr = true })!;
	defer
	{
		if (listener.is_open()) (void)tcp::listener_close_now(&listener);
		listener.destroy();
	}
	tcp::bind(&listener, ipv4_any(PORT))!;
	tcp::listen(&listener)!;

	server.loop = &loop;
	server.listener = &listener;
	server.slots = slots[..];

	// Pre-init every slot's stream so accepts can reuse them across connections.
	for (usz i = 0; i < SLOTS; i++)
	{
		slots[i].server = &server;
		slots[i].stream.init()!;
	}
	defer foreach (&slot : slots)
	{
		if (slot.conn.initialized) slot.conn.destroy();
		if (slot.stream.is_open()) (void)tcp::stream_close_now(&slot.stream);
		slot.stream.destroy();
	}

	signal::start(&loop, &server.sig_op, { .signum = libc::SIGINT }, &on_signal, &server)!;
	foreach (&slot : slots) start_accept(slot);

	(void)io::printfn("buffered-echo on 0.0.0.0:%d (line echo; Ctrl-C to stop)", PORT);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

	// P0 teardown: cancel every live op, then let the loop drain the cancellations.
	(void)loop.close_all();
	(void)loop.drain();
}

<*
 IPv4 wildcard endpoint on `port`.
*>
fn Endpoint ipv4_any(ushort port) => { .family = AddressFamily.IPV4, .port = port };

<*
 Arm an accept on a free slot unless the server is shutting down.
*>
fn void start_accept(Slot* slot)
{
	if (slot.server.stopping) return;
	(void)tcp::accept(slot.server.loop, slot.server.listener, &slot.stream, &slot.accept_op, &on_accept, slot);
}

<*
 Accept completion: wrap the new stream in a buffered connection and start
 reading. A cancelled accept during shutdown simply leaves the slot idle.
*>
fn void on_accept(Loop* loop, tcp::Listener* listener, tcp::AcceptOp* op, tcp::AcceptResult* result, void* ud)
{
	(void)listener;
	(void)op;
	Slot* slot = (Slot*)ud;
	if (result.error.status)
	{
		start_accept(slot);
		return;
	}

	if (catch slot.conn.init(
		&slot.stream,
		{
			.input_capacity = RING_CAP,
			.output_capacity = RING_CAP,
			.on_data = &on_data,
			.on_error = &on_error,
			.userdata = slot,
		},
		loop.allocator
	))
	{
		(void)tcp::stream_close_now(&slot.stream);
		start_accept(slot);
		return;
	}
	slot.serving = true;
	if (catch slot.conn.start(loop))
	{
		slot.conn.destroy();
		(void)tcp::stream_close_now(&slot.stream);
		slot.serving = false;
		start_accept(slot);
	}
}

<*
 Data callback: echo every complete newline-delimited line back to the peer.
*>
fn void on_data(Loop* loop, buffered::StreamConn* conn, void* ud)
{
	(void)ud;
	for (;;)
	{
		// Locate one complete line; stop when no newline remains buffered.
		sz nl = conn.find_byte('\n');
		if (nl < 0) break;
		usz line_len = (usz)nl + 1;
		char[RING_CAP] line;
		// Copy the line out of the input ring, drop it, then echo it back.
		usz n        = conn.copyout(line[0:RING_CAP], line_len);
		conn.consume(line_len);
		if (catch conn.write(loop, line[0:n])) return;
	}
}

<*
 Error/EOF callback: close the connection. During shutdown the cancellations are
 collected by `close_all`/`drain` and the fds are reclaimed in `run`'s teardown,
 so no per-connection close is started.
*>
fn void on_error(Loop* loop, buffered::StreamConn* conn, fault status, void* ud)
{
	(void)conn;
	(void)status;
	Slot* slot = (Slot*)ud;
	slot.serving = false;
	if (slot.server.stopping || slot.closing) return;
	slot.closing = true;
	if (catch tcp::stream_close(loop, &slot.stream, &slot.close_op, { }, &on_slot_close, slot))
	{
		slot.closing = false;
		if (slot.stream.is_open()) (void)tcp::stream_close_now(&slot.stream);
		slot.conn.destroy();
		start_accept(slot);
	}
}

<*
 Async-close completion: release the buffered rings and re-arm the slot.
*>
fn void on_slot_close(Loop* loop, tcp::Stream* stream, tcp::StreamCloseOp* op, CloseResult* result, void* ud)
{
	(void)loop;
	(void)stream;
	(void)op;
	(void)result;
	Slot* slot = (Slot*)ud;
	slot.closing = false;
	slot.conn.destroy();
	start_accept(slot);
}

<*
 SIGINT handler: stop accepting and ask `run` to return. The teardown in `run`
 then calls `close_all` (which cancels the accepts, the in-flight reads/writes and
 this very signal op — all registered in `live_head`) followed by `drain`.
*>
fn void on_signal(Loop* loop, signal::SignalOp* op, signal::SignalResult* result, void* userdata)
{
	(void)op;
	Server* server = (Server*)userdata;
	if (result.error.status) return;
	(void)io::printn("\nshutting down");
	server.stopping = true;
	loop.stop();
}
