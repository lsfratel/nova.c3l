<*
 Length-prefixed message server built on `nova::framed`.

 Demonstrates the framed layer for a message/frame protocol: each frame is a
 4-byte big-endian length `N` followed by `N` payload bytes. Each accepted
 connection is wrapped in a `framed::FramedConn`, which gives contiguous framing
 and in-place, zero-copy response building:

   - small frames (fitting the input buffer) are framed with `peek`, echoed in
     place into a `reserve`d output region, then `commit`/`consume`d;
   - a frame larger than the input buffer streams its body straight into a
     per-slot buffer with `read_into` (zero-copy, without buffering it in the
     framing buffer) and is answered with a small ack frame carrying the byte
     count received.

 SIGINT shuts the server down gracefully via `Loop.close_all` + drain. Each
 connection's framing buffers are reserved on accept and released on close, so
 only connection setup allocates.
*>
module nova_examples::framed_echo;

import std::io;
import std::core::mem;
import std::core::mem::alloc;
import std::core::bitorder;
import libc;

import nova @norecurse, nova::net, nova::net::tcp, nova::framed, nova::signal;
import nova_examples::common;

const usz SLOTS    = 16;
const usz IN_CAP   = 4 * 1024;
const usz OUT_CAP  = 4 * 1024;
const usz MAX_BODY = 256 * 1024;
const usz HEADER   = 4;
const ushort PORT  = 9010;

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
 One reusable connection slot: the accepted stream, its accept/async-close ops,
 the framed connection, and a buffer that receives large message bodies.
*>
struct Slot
{
	Server* server;
	tcp::Stream stream;
	tcp::AcceptOp accept_op;
	tcp::StreamCloseOp close_op;
	framed::FramedConn conn;
	char[MAX_BODY] body;
	usz body_len;
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
		(void)io::eprintfn("framed-echo failed: %s", err.description);
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

	(void)io::printfn("framed-echo on 0.0.0.0:%d ([4B len][payload] frames; Ctrl-C to stop)", PORT);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

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
	if (catch tcp::accept(slot.server.loop, slot.server.listener, &slot.stream, &slot.accept_op, &on_accept, slot))
	{
	}
}

<*
 Accept completion: wrap the new stream in a framed connection and start framing.
 A cancelled accept during shutdown simply leaves the slot idle.
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
			.input_capacity = IN_CAP,
			.output_capacity = OUT_CAP,
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
 Data callback: frame and echo each complete message. A message whose frame does
 not fit the input buffer is streamed into the slot's `body` buffer via
 `read_into` and answered separately in `on_body`.
*>
fn void on_data(Loop* loop, framed::FramedConn* conn, void* ud)
{
	Slot* slot = (Slot*)ud;
	for (;;)
	{
		// Wait until the 4-byte length prefix is fully buffered.
		char[] hdr = conn.peek(HEADER);
		if (!hdr.len) break;
		uint n          = bitorder::load_be((uint*)&hdr[0]);
		usz frame_total = HEADER + n;

		// Body too big for the input buffer: stream it past the framing layer.
		if (frame_total > conn.input_capacity())
		{
			if (n > MAX_BODY)
			{
				begin_close(loop, slot);
				return;
			}
			conn.consume(HEADER);
			slot.body_len = n;
			if (catch conn.read_into(loop, slot.body[0:n], n, &on_body)) begin_close(loop, slot);
			return;
		}

		// Small frame: wait for the whole frame, then echo it in place.
		char[] frame = conn.peek(frame_total);
		if (!frame.len) break;

		char[] region = conn.reserve(frame_total);
		if (!region.len) return;
		mem::copy(region.ptr, frame.ptr, (sz)frame_total);
		conn.commit(frame_total);
		conn.consume(frame_total);
	}
}

<*
 Large-body completion: the body is now in `slot.body`. Reply with a small ack
 frame whose payload is the number of bytes received.
*>
fn void on_body(Loop* loop, framed::FramedConn* conn, void* ud)
{
	(void)loop;
	Slot* slot    = (Slot*)ud;
	// Ack frame: 4-byte length 4, then the received byte count as payload.
	char[] region = conn.reserve(HEADER + 4);
	if (!region.len) return;
	bitorder::store_be(&region[0], (uint)4);
	bitorder::store_be(&region[HEADER], (uint)slot.body_len);
	conn.commit(HEADER + 4);
}

<*
 Error/EOF (or an oversized/`read_into`-failed message): close the connection.
*>
fn void on_error(Loop* loop, framed::FramedConn* conn, fault status, void* ud)
{
	(void)conn;
	(void)status;
	begin_close(loop, (Slot*)ud);
}

<*
 Mark the framed connection closed and async-close the stream so any in-flight op
 is cancelled first; the close completion re-arms the slot. During shutdown the
 cancellations are collected by `close_all`/`drain` instead.
*>
fn void begin_close(Loop* loop, Slot* slot)
{
	slot.conn.mark_closed();
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
 Async-close completion: release the framing buffers and re-arm the slot.
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
 SIGINT handler: stop accepting and ask `run` to return; the teardown there calls
 `close_all` + `drain`.
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
