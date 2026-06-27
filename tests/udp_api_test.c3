module nova_tests;

import std::core::test;
import std::core::mem::allocators;

import nova::op @public;
import nova @norecurse, nova::net, nova::net::tcp, nova::net::udp;

char[70_000] udp_oversized_payload;

fn void test_udp_send_oversized_datagram_reports_error() @test
{
	Loop loop;
	udp::Socket sender;
	udp::Socket receiver;
	udp::SendOp send_op;
	UdpSendSeen seen;

	loop.init({ .max_events = 4 })!!;

	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&sender, ipv4_loopback_endpoint(0))!!;
	udp::bind(&receiver, ipv4_loopback_endpoint(0))!!;

	udp::send(&loop, &sender, udp_oversized_payload[0:70_000], &receiver.local, &send_op, &on_udp_send_seen, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::BACKEND_FAILED);
	test::eq((sz)0, seen.bytes);
	test::@check(!send_op.header.active());
	test::@check(sender.active_send == null);

	udp::close_now(&sender)!!;
	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
	loop.destroy();
}

fn void test_udp_lifecycle() @test
{
	Endpoint local  = ipv4_loopback_endpoint(0);
	Endpoint remote = ipv4_loopback_endpoint(9);
	udp::Socket socket;

	test::@error(udp::bind(&socket, local), nova::INVALID_STATE);
	test::@error(udp::close_now(&socket), nova::INVALID_STATE);

	socket.init({ .reuse_addr = true })!!;
	test::@error(socket.borrow_native(), nova::INVALID_STATE);
	test::@error(socket.local_endpoint(), nova::INVALID_STATE);
	test::@error(socket.peer_endpoint(), nova::INVALID_STATE);
	test::@error(udp::close_now(&socket), nova::INVALID_STATE);
	udp::bind(&socket, local)!!;
	test::@check(socket.is_open());
	test::@check(socket.bound);
	test::@check(socket.local.port > 0);
	test::@check(socket.borrow_native()!! != (NativeHandle)-1);
	Endpoint bound = socket.local_endpoint()!!;
	test::@check(bound.family == AddressFamily.IPV4);
	test::eq(socket.local.port, bound.port);
	test::@error(socket.peer_endpoint(), NOT_FOUND);
	test::@error(udp::bind(&socket, local), nova::INVALID_STATE);

	udp::connect(&socket, remote)!!;
	test::@check(socket.connected);
	Endpoint peer = socket.peer_endpoint()!!;
	test::@check(peer.family == AddressFamily.IPV4);
	test::eq(remote.port, peer.port);

	udp::close_now(&socket)!!;
	test::@check(!socket.is_open());
	test::@error(socket.borrow_native(), nova::INVALID_STATE);
	test::@error(socket.local_endpoint(), nova::INVALID_STATE);
	test::@error(socket.peer_endpoint(), nova::INVALID_STATE);
	test::@check(!socket.bound);
	test::@check(!socket.connected);
	test::eq((ushort)0, socket.local.port);
	test::eq((ushort)0, socket.remote.port);
	socket.destroy();
	test::@check(!socket.initialized);
	test::@check(socket.native_handle == (NativeHandle)-1);
	test::@check(!socket.options.reuse_addr);
}
fn void test_udp_connect_without_explicit_bind_opens_socket() @test
{
	udp::Socket socket;

	socket.init()!!;
	udp::connect(&socket, ipv4_loopback_endpoint(9))!!;

	test::@check(socket.is_open());
	test::@check(socket.bound);
	test::@check(socket.connected);
	test::@check(socket.local.port > 0);
	Endpoint local = socket.local_endpoint()!!;
	Endpoint peer  = socket.peer_endpoint()!!;
	test::@check(local.family == AddressFamily.IPV4);
	test::eq(socket.local.port, local.port);
	test::@check(peer.family == AddressFamily.IPV4);
	test::eq((ushort)9, peer.port);

	udp::close_now(&socket)!!;
	socket.destroy();
}

fn void test_udp_bind_ipv6_loopback_reports_ipv6_local_endpoint() @test
{
	udp::Socket socket;

	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv6_loopback_endpoint(0))!!;

	test::@check(socket.is_open());
	test::@check(socket.bound);
	test::@check(socket.local.family == AddressFamily.IPV6);
	test::@check(socket.local.port > 0);
	test::eq((char)1, socket.local.storage[15]);
	Endpoint local = socket.local_endpoint()!!;
	test::@check(local.family == AddressFamily.IPV6);
	test::eq(socket.local.port, local.port);
	test::eq((char)1, local.storage[15]);

	udp::close_now(&socket)!!;
	socket.destroy();
}

fn void test_udp_send_recv_ipv6_loopback_explicit_remote() @test
{
	Loop loop;
	udp::Socket sender;
	udp::Socket receiver;
	udp::RecvOp recv_op;
	udp::SendOp send_op;
	UdpRecvSeen recv_seen;
	UdpSendSeen send_seen;
	char[6] payload = { 'i', 'p', 'v', '6', '!', '!' };
	char[8] buffer;

	loop.init({ .max_events = 4 })!!;
	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&sender, ipv6_loopback_endpoint(0))!!;
	udp::bind(&receiver, ipv6_loopback_endpoint(0))!!;

	udp::recv(&loop, &receiver, buffer[0:8], &recv_op, &on_udp_recv_seen, &recv_seen)!!;
	udp::send(&loop, &sender, payload[0:6], &receiver.local, &send_op, &on_udp_send_seen, &send_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, send_seen.calls);
	test::@check(!send_seen.status);
	test::eq((sz)6, send_seen.bytes);
	test::eq(1, recv_seen.calls);
	test::@check(!recv_seen.status);
	test::eq((sz)6, recv_seen.bytes);
	test::@check(recv_seen.peer_family == AddressFamily.IPV6);
	test::@check(recv_seen.peer_port > 0);
	test::@check(!recv_seen.truncated);
	test::@check(buffer[0] == 'i');
	test::@check(buffer[1] == 'p');
	test::@check(buffer[2] == 'v');
	test::@check(buffer[3] == '6');
	test::@check(buffer[4] == '!');
	test::@check(buffer[5] == '!');

	udp::close_now(&sender)!!;
	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
	loop.destroy();
}

fn void test_udp_connected_send_uses_ipv6_default_remote() @test
{
	Loop loop;
	udp::Socket sender;
	udp::Socket receiver;
	udp::SendOp send_op;
	UdpSendSeen seen;
	char[4] payload = { 'd', 'n', 's', '6' };
	char[8] received;

	loop.init({ .max_events = 4 })!!;
	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&receiver, ipv6_loopback_endpoint(0))!!;
	udp::connect(&sender, receiver.local)!!;

	test::@check(sender.local.family == AddressFamily.IPV6);
	test::@check(sender.remote.family == AddressFamily.IPV6);

	udp::send(&loop, &sender, payload[0:4], null, &send_op, &on_udp_send_seen, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((sz)4, seen.bytes);
	test::eq((sz)4, recv_udp_now(receiver.native_handle, received[0:8])!!);
	test::@check(received[0] == 'd');
	test::@check(received[1] == 'n');
	test::@check(received[2] == 's');
	test::@check(received[3] == '6');

	udp::close_now(&sender)!!;
	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
	loop.destroy();
}

fn void test_udp_bind_and_connect_reject_unsupported_family() @test
{
	Endpoint endpoint;
	udp::Socket socket;
	udp::Socket oversized;
	udp::Socket invalid_keepalive;
	udp::Socket invalid_keepalive_count;

	socket.init()!!;

	test::@error(udp::bind(&socket, endpoint), nova::UNSUPPORTED);
	test::@check(!socket.is_open());
	test::@error(udp::connect(&socket, endpoint), nova::UNSUPPORTED);
	test::@check(!socket.is_open());

	socket.destroy();

	oversized.init({ .send_buffer_size = uint::max })!!;
	test::@error(udp::bind(&oversized, ipv4_loopback_endpoint(0)), nova::INVALID_STATE);
	test::@check(!oversized.is_open());
	oversized.destroy();

	invalid_keepalive.init({ .keepalive = true, .keepalive_idle = (Duration)-1 })!!;
	test::@error(udp::bind(&invalid_keepalive, ipv4_loopback_endpoint(0)), nova::INVALID_STATE);
	test::@check(!invalid_keepalive.is_open());
	invalid_keepalive.destroy();

	invalid_keepalive_count.init({ .keepalive_count = uint::max })!!;
	test::@error(udp::bind(&invalid_keepalive_count, ipv4_loopback_endpoint(0)), nova::INVALID_STATE);
	test::@check(!invalid_keepalive_count.is_open());
	invalid_keepalive_count.destroy();
}
fn void test_submission_stubs_return_not_implemented() @test
{
	Loop loop;
	Listener listener;
	Stream stream;
	Stream accepted;
	tcp::AcceptOp accept_op;
	tcp::ReadOp read_op;
	tcp::WriteOp write_op;
	tcp::StreamCloseOp stream_close_op;
	tcp::ListenerCloseOp listener_close_op;
	udp::Socket socket;
	udp::RecvOp recv_op;
	udp::SendOp send_op;
	udp::SocketCloseOp udp_close_op;
	char[16] storage;

	loop.init()!!;
	listener.init()!!;
	stream.init()!!;
	accepted.init()!!;
	socket.init()!!;

	test::@error(tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept), nova::INVALID_STATE);
	test::@error(tcp::read(&loop, &stream, storage[0:16], &read_op, { }, &on_read), nova::INVALID_STATE);
	test::@error(tcp::write(&loop, &stream, storage[0:5], &write_op, { }, &on_write), nova::INVALID_STATE);
	test::@error(tcp::stream_close(&loop, &stream, &stream_close_op, { }, &on_stream_close), nova::INVALID_STATE);
	test::@error(
		tcp::listener_close(&loop, &listener, &listener_close_op, { }, &on_listener_close),
		nova::INVALID_STATE
	);
	test::@error(udp::recv(&loop, &socket, storage[0:16], &recv_op, &on_udp_recv), nova::INVALID_STATE);
	test::@error(udp::send(&loop, &socket, storage[0:5], null, &send_op, &on_udp_send), nova::INVALID_STATE);
	test::@error(udp::close(&loop, &socket, &udp_close_op, { }, &on_udp_close), nova::INVALID_STATE);

	loop.destroy();
}
fn void test_udp_recv_async_dispatches_datagram_and_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	udp::Socket socket;
	udp::RecvOp recv_op;
	udp::RecvOp busy_op;
	UdpRecvSeen seen;
	char[16] buffer;
	char[5] payload     = { 'h', 'e', 'l', 'l', 'o' };

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv4_loopback_endpoint(0))!!;

	Ref oref = udp::recv(&loop, &socket, buffer[0:16], &recv_op, &on_udp_recv_seen, &seen)!!;
	test::@check(recv_op.header.matches(oref));
	test::@check(socket.active_recv == &recv_op.header);
	test::@error(udp::recv(&loop, &socket, buffer[0:16], &busy_op, &on_udp_recv_seen, &seen), nova::BUSY);

	send_udp_loopback(socket.local.port, payload[0:5])!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.socket_open);
	test::@check(seen.buffer.ptr == buffer[0:16].ptr);
	test::eq((sz)16, seen.buffer.len);
	test::eq((sz)5, seen.bytes);
	test::@check(seen.peer_port > 0);
	test::@check(!seen.truncated);
	test::@check(buffer[0] == 'h');
	test::@check(buffer[1] == 'e');
	test::@check(buffer[2] == 'l');
	test::@check(buffer[3] == 'l');
	test::@check(buffer[4] == 'o');
	test::@check(!recv_op.header.active());
	test::@check(socket.active_recv == null);
	test::eq(allocation_count, tracker.total_allocation_count());

	udp::close_now(&socket)!!;
	socket.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

struct UdpRecvRepostCtx
{
	char[] buffer;
	Ref repost_ref;
	fault repost_status;
	fault[2] statuses;
	bool[2] op_active;
	bool[2] userdata_cleared;
	int calls;
}

fn void on_udp_recv_repost_same_op(
	Loop* loop,
	udp::Socket* socket,
	udp::RecvOp* op,
	udp::RecvResult* result,
	void* userdata
)
{
	UdpRecvRepostCtx* ctx = (UdpRecvRepostCtx*)userdata;
	int index             = ctx.calls;
	if (index < 2)
	{
		ctx.statuses[index] = result.error.status;
		ctx.op_active[index] = op.header.active();
		ctx.userdata_cleared[index] = op.header.userdata == null;
	}
	ctx.calls++;

	if (ctx.calls == 1)
	{
		Ref? reposted = udp::recv(loop, socket, ctx.buffer, op, &on_udp_recv_repost_same_op, ctx);
		ctx.repost_status = @catch(reposted);
		if (try repost_ref = reposted) ctx.repost_ref = repost_ref;
	}
}

fn void test_udp_recv_can_repost_same_op_inside_callback() @test
{
	Loop loop;
	udp::Socket socket;
	udp::RecvOp recv_op;
	UdpRecvRepostCtx ctx;
	char[8] first_buffer;
	char[8] second_buffer;
	char[5] payload = { 'r', 'e', 'p', 'o', 's' };

	loop.init({ .max_events = 4 })!!;
	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv4_loopback_endpoint(0))!!;
	ctx.buffer = second_buffer[0:8];

	udp::recv(&loop, &socket, first_buffer[0:8], &recv_op, &on_udp_recv_repost_same_op, &ctx)!!;
	send_udp_loopback(socket.local.port, payload[0:5])!!;
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(1, ctx.calls);
	test::@check(!ctx.statuses[0]);
	test::@check(!ctx.op_active[0]);
	test::@check(ctx.userdata_cleared[0]);
	test::@check(!ctx.repost_status);
	test::@check(recv_op.header.matches(ctx.repost_ref));
	test::@check(recv_op.header.active());
	test::@check(socket.active_recv == &recv_op.header);

	op::cancel_ref(&loop, ctx.repost_ref)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(2, ctx.calls);
	test::@check(ctx.statuses[1] == nova::CANCELLED);
	test::@check(!ctx.op_active[1]);
	test::@check(ctx.userdata_cleared[1]);
	test::@check(!recv_op.header.active());
	test::@check(socket.active_recv == null);

	udp::close_now(&socket)!!;
	socket.destroy();
	loop.destroy();
}

fn void test_udp_recv_succeeds_with_active_send() @test
{
	Loop loop;
	udp::Socket socket;
	udp::RecvOp recv_op;
	udp::SendOp send_op;
	UdpRecvSeen seen;
	char[8] buffer;

	loop.init({ .max_events = 4 })!!;
	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv4_loopback_endpoint(0))!!;

	// The persistent watcher gives recv and send independent read/write slots, so a
	// receive may be armed while a send is in flight (full duplex). connect, which
	// rebinds the descriptor, is still rejected while any I/O is active.
	send_op.header.state = State.OP_ACTIVE;
	socket.active_send = &send_op.header;
	Ref recv_ref = udp::recv(&loop, &socket, buffer[0:8], &recv_op, &on_udp_recv_seen, &seen)!!;
	test::@check(recv_op.header.active());
	test::@check(socket.active_recv == &recv_op.header);
	test::@error(udp::connect(&socket, ipv4_loopback_endpoint(9)), nova::BUSY);

	op::cancel_ref(&loop, recv_ref)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;
	test::@check(!recv_op.header.active());
	test::@check(socket.active_recv == null);

	socket.active_send = null;
	send_op.header = { };
	udp::close_now(&socket)!!;
	socket.destroy();
	loop.destroy();
}

fn void test_udp_full_duplex_recv_and_send_concurrent() @test
{
	Loop loop;
	udp::Socket a;
	udp::Socket b;
	udp::RecvOp a_recv;
	udp::SendOp a_send;
	udp::SendOp b_send;
	UdpRecvSeen a_recv_seen;
	UdpSendSeen a_send_seen;
	UdpSendSeen b_send_seen;
	char[8] a_buf;
	char[4] ping = { 'p', 'i', 'n', 'g' };
	char[4] pong = { 'p', 'o', 'n', 'g' };

	loop.init({ .max_events = 8 })!!;
	a.init({ .reuse_addr = true })!!;
	b.init({ .reuse_addr = true })!!;
	udp::bind(&a, ipv4_loopback_endpoint(0))!!;
	udp::bind(&b, ipv4_loopback_endpoint(0))!!;

	// Socket a runs a receive and a send at the same time over its single persistent
	// watcher (read and write slots are independent) — the pre-watcher design rejected
	// this with BUSY.
	udp::recv(&loop, &a, a_buf[0:8], &a_recv, &on_udp_recv_seen, &a_recv_seen)!!;
	udp::send(&loop, &a, ping[0:4], &b.local, &a_send, &on_udp_send_seen, &a_send_seen)!!;
	test::@check(a.active_recv != null);
	test::@check(a.active_send != null);

	// b answers so a's receive completes.
	udp::send(&loop, &b, pong[0:4], &a.local, &b_send, &on_udp_send_seen, &b_send_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, a_send_seen.calls);
	test::@check(!a_send_seen.status);
	test::eq((sz)4, a_send_seen.bytes);
	test::eq(1, a_recv_seen.calls);
	test::@check(!a_recv_seen.status);
	test::eq((sz)4, a_recv_seen.bytes);
	test::@check(a_buf[0] == 'p' && a_buf[1] == 'o' && a_buf[2] == 'n' && a_buf[3] == 'g');

	udp::close_now(&a)!!;
	a.destroy();
	udp::close_now(&b)!!;
	b.destroy();
	loop.destroy();
}

fn void test_udp_try_send_delivers_datagram_without_operation() @test
{
	udp::Socket sender;
	udp::Socket receiver;
	char[5] payload = { 't', 'r', 'y', 'u', 'd' };
	char[8] received;

	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&sender, ipv4_loopback_endpoint(0))!!;
	udp::bind(&receiver, ipv4_loopback_endpoint(0))!!;

	test::eq((sz)0, sender.send_queue_size());
	test::eq((sz)5, sender.try_send(payload[0:5], &receiver.local)!!);
	test::eq((sz)0, sender.send_queue_size());
	test::eq((sz)5, recv_udp_now(receiver.native_handle, received[0:8])!!);
	test::@check(received[0] == 't');
	test::@check(received[1] == 'r');
	test::@check(received[2] == 'y');
	test::@check(received[3] == 'u');
	test::@check(received[4] == 'd');

	udp::close_now(&sender)!!;
	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
}

fn void test_udp_send_async_dispatches_datagram_and_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	udp::Socket sender;
	udp::Socket receiver;
	udp::SendOp send_op;
	udp::SendOp busy_op;
	UdpSendSeen seen;
	char[5] payload     = { 'h', 'e', 'l', 'l', 'o' };
	char[8] received;

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&sender, ipv4_loopback_endpoint(0))!!;
	udp::bind(&receiver, ipv4_loopback_endpoint(0))!!;

	Ref oref = udp::send(&loop, &sender, payload[0:5], &receiver.local, &send_op, &on_udp_send_seen, &seen)!!;
	test::@check(send_op.header.matches(oref));
	test::@check(sender.active_send == &send_op.header);
	if (loop.udp_send_completion())
	{
		test::eq((sz)5, sender.send_queue_size());
	}
	else
	{
		test::eq((sz)0, sender.send_queue_size());
	}
	test::@error(sender.try_send(payload[0:5], &receiver.local), nova::BUSY);
	test::@error(
		udp::send(&loop, &sender, payload[0:5], &receiver.local, &busy_op, &on_udp_send_seen, &seen),
		nova::BUSY
	);

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.socket_open);
	test::eq((sz)5, seen.bytes);
	test::@check(!send_op.header.active());
	test::@check(sender.active_send == null);
	test::eq((sz)0, sender.send_queue_size());

	test::eq((sz)5, recv_udp_now(receiver.native_handle, received[0:8])!!);
	test::@check(received[0] == 'h');
	test::@check(received[1] == 'e');
	test::@check(received[2] == 'l');
	test::@check(received[3] == 'l');
	test::@check(received[4] == 'o');
	test::eq(allocation_count, tracker.total_allocation_count());

	udp::close_now(&sender)!!;
	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

struct UdpSendRepostCtx
{
	Endpoint remote;
	char[] payload;
	Ref repost_ref;
	fault repost_status;
	fault[2] statuses;
	bool[2] op_active;
	bool[2] userdata_cleared;
	sz[2] bytes;
	int calls;
}

fn void on_udp_send_repost_same_op(
	Loop* loop,
	udp::Socket* socket,
	udp::SendOp* op,
	udp::SendResult* result,
	void* userdata
)
{
	UdpSendRepostCtx* ctx = (UdpSendRepostCtx*)userdata;
	int index             = ctx.calls;
	if (index < 2)
	{
		ctx.statuses[index] = result.error.status;
		ctx.op_active[index] = op.header.active();
		ctx.userdata_cleared[index] = op.header.userdata == null;
		ctx.bytes[index] = result.bytes;
	}
	ctx.calls++;

	if (ctx.calls == 1)
	{
		Ref? reposted = udp::send(loop, socket, ctx.payload, &ctx.remote, op, &on_udp_send_repost_same_op, ctx);
		ctx.repost_status = @catch(reposted);
		if (try repost_ref = reposted) ctx.repost_ref = repost_ref;
	}
}

fn void test_udp_send_can_repost_same_op_inside_callback() @test
{
	Loop loop;
	udp::Socket sender;
	udp::Socket receiver;
	udp::SendOp send_op;
	UdpSendRepostCtx ctx;
	char[4] payload = { 's', 'e', 'n', 'd' };

	loop.init({ .max_events = 4 })!!;
	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&sender, ipv4_loopback_endpoint(0))!!;
	udp::bind(&receiver, ipv4_loopback_endpoint(0))!!;
	ctx.remote = receiver.local;
	ctx.payload = payload[0:4];

	udp::send(&loop, &sender, payload[0:4], &receiver.local, &send_op, &on_udp_send_repost_same_op, &ctx)!!;
	// Readiness sends complete inline and re-queue synchronously, so both the send
	// and its in-callback repost finish in one NO_WAIT tick. A completion SENDMSG
	// needs a kernel round-trip per send, so the reposted send finishes on a later
	// tick; run until idle to observe both.
	if (loop.udp_send_completion())
	{
		nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	}
	else
	{
		nova::run(&loop, RunMode.NO_WAIT)!!;
	}

	test::eq(2, ctx.calls);
	test::@check(!ctx.statuses[0]);
	test::@check(!ctx.statuses[1]);
	test::@check(!ctx.op_active[0]);
	test::@check(!ctx.op_active[1]);
	test::@check(ctx.userdata_cleared[0]);
	test::@check(ctx.userdata_cleared[1]);
	test::eq((sz)4, ctx.bytes[0]);
	test::eq((sz)4, ctx.bytes[1]);
	test::@check(!ctx.repost_status);
	test::@check(!send_op.header.active());
	test::@check(sender.active_send == null);

	udp::close_now(&sender)!!;
	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
	loop.destroy();
}

fn void test_udp_connected_send_uses_default_remote() @test
{
	Loop loop;
	udp::Socket sender;
	udp::Socket receiver;
	udp::SendOp send_op;
	UdpSendSeen seen;
	char[3] payload = { 'o', 'k', '!' };
	char[8] received;

	loop.init({ .max_events = 4 })!!;
	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&receiver, ipv4_loopback_endpoint(0))!!;
	udp::connect(&sender, receiver.local)!!;

	udp::send(&loop, &sender, payload[0:3], null, &send_op, &on_udp_send_seen, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((sz)3, seen.bytes);
	test::eq((sz)3, recv_udp_now(receiver.native_handle, received[0:8])!!);
	test::@check(received[0] == 'o');
	test::@check(received[1] == 'k');
	test::@check(received[2] == '!');

	udp::close_now(&sender)!!;
	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
	loop.destroy();
}
fn void test_udp_recv_reports_truncated_datagram_and_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	udp::Socket socket;
	udp::RecvOp recv_op;
	UdpRecvSeen seen;
	char[4] buffer;
	char[10] payload    = { 't', 'r', 'u', 'n', 'c', 'a', 't', 'e', 'd', '!' };

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv4_loopback_endpoint(0))!!;

	udp::recv(&loop, &socket, buffer[0:4], &recv_op, &on_udp_recv_seen, &seen)!!;
	send_udp_loopback(socket.local.port, payload[0:10])!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((sz)4, seen.bytes);
	test::@check(seen.truncated);
	test::@check(buffer[0] == 't');
	test::@check(buffer[1] == 'r');
	test::@check(buffer[2] == 'u');
	test::@check(buffer[3] == 'n');
	test::eq(allocation_count, tracker.total_allocation_count());

	udp::close_now(&socket)!!;
	socket.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
fn void test_udp_recv_empty_buffer_consumes_truncated_datagram() @test
{
	Loop loop;
	udp::Socket socket;
	udp::RecvOp recv_op;
	UdpRecvSeen seen;
	char[1] empty;
	char[3] payload = { 'a', 'b', 'c' };

	loop.init({ .max_events = 4 })!!;
	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv4_loopback_endpoint(0))!!;

	udp::recv(&loop, &socket, empty[0:0], &recv_op, &on_udp_recv_seen, &seen)!!;
	send_udp_loopback(socket.local.port, payload[0:3])!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((sz)0, seen.bytes);
	test::@check(seen.truncated);

	udp::close_now(&socket)!!;
	socket.destroy();
	loop.destroy();
}
fn void test_udp_zero_length_datagram_send_recv() @test
{
	Loop loop;
	udp::Socket sender;
	udp::Socket receiver;
	udp::RecvOp recv_op;
	udp::SendOp send_op;
	UdpRecvSeen recv_seen;
	UdpSendSeen send_seen;
	char[1] empty;
	char[1] buffer = { 'x' };

	loop.init({ .max_events = 4 })!!;
	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&sender, ipv4_loopback_endpoint(0))!!;
	udp::bind(&receiver, ipv4_loopback_endpoint(0))!!;

	udp::recv(&loop, &receiver, buffer[0:1], &recv_op, &on_udp_recv_seen, &recv_seen)!!;
	udp::send(&loop, &sender, empty[0:0], &receiver.local, &send_op, &on_udp_send_seen, &send_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, send_seen.calls);
	test::@check(!send_seen.status);
	test::eq((sz)0, send_seen.bytes);
	test::eq(1, recv_seen.calls);
	test::@check(!recv_seen.status);
	test::eq((sz)0, recv_seen.bytes);
	test::@check(!recv_seen.truncated);
	test::@check(buffer[0] == 'x');

	udp::close_now(&sender)!!;
	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
	loop.destroy();
}
fn void test_udp_multicast_join_leave_and_validation() @test
{
	udp::Socket socket;
	MulticastGroup group         = { .group = ipv4_multicast_endpoint(0) };
	MulticastGroup invalid_group = { .group = ipv4_loopback_endpoint(0) };
	MulticastGroup ipv6_group    = { .group = ipv6_multicast_endpoint(0) };

	test::@error(udp::join_multicast(&socket, group), nova::INVALID_STATE);

	socket.init({ .reuse_addr = true, .reuse_port = true })!!;
	test::@error(udp::join_multicast(&socket, group), nova::INVALID_STATE);

	udp::bind(&socket, ipv4_any_endpoint(0))!!;
	test::@error(udp::join_multicast(&socket, invalid_group), nova::UNSUPPORTED);
	test::@error(udp::join_multicast(&socket, ipv6_group), nova::UNSUPPORTED);

	udp::join_multicast(&socket, group)!!;
	udp::leave_multicast(&socket, group)!!;

	udp::close_now(&socket)!!;
	socket.destroy();
}

fn void test_udp_socket_options_and_source_multicast_validation() @test
{
	udp::Socket socket;
	Endpoint ipv6_interface = ipv6_loopback_endpoint(0);
	SourceMulticastGroup source_group = {
		.group = ipv4_multicast_endpoint(0),
		.interface_addr = ipv4_loopback_endpoint(0),
		.source = ipv4_loopback_endpoint(0),
	};
	SourceMulticastGroup invalid_group  = source_group;
	SourceMulticastGroup invalid_source = source_group;
	invalid_group.group = ipv4_loopback_endpoint(0);
	invalid_source.source = ipv4_multicast_endpoint(0);

	test::@error(udp::set_broadcast(&socket, true), nova::INVALID_STATE);
	test::@error(udp::set_ttl(&socket, 64), nova::INVALID_STATE);
	test::@error(udp::set_multicast_loop(&socket, true), nova::INVALID_STATE);
	test::@error(udp::set_multicast_ttl(&socket, 1), nova::INVALID_STATE);
	test::@error(udp::set_multicast_interface(&socket, ipv4_loopback_endpoint(0)), nova::INVALID_STATE);
	test::@error(udp::join_source_multicast(&socket, source_group), nova::INVALID_STATE);
	test::@error(udp::leave_source_multicast(&socket, source_group), nova::INVALID_STATE);

	socket.init({ .reuse_addr = true, .reuse_port = true })!!;
	test::@error(udp::set_broadcast(&socket, true), nova::INVALID_STATE);
	test::@error(udp::set_ttl(&socket, 64), nova::INVALID_STATE);
	test::@error(udp::set_multicast_loop(&socket, true), nova::INVALID_STATE);
	test::@error(udp::set_multicast_ttl(&socket, 1), nova::INVALID_STATE);
	test::@error(udp::set_multicast_interface(&socket, ipv4_loopback_endpoint(0)), nova::INVALID_STATE);
	test::@error(udp::join_source_multicast(&socket, source_group), nova::INVALID_STATE);
	test::@error(udp::leave_source_multicast(&socket, source_group), nova::INVALID_STATE);

	udp::bind(&socket, ipv4_any_endpoint(0))!!;

	udp::set_broadcast(&socket, true)!!;
	udp::set_broadcast(&socket, false)!!;
	test::@error(udp::set_ttl(&socket, 0), nova::INVALID_STATE);
	test::@error(udp::set_ttl(&socket, 256), nova::INVALID_STATE);
	udp::set_ttl(&socket, 1)!!;
	udp::set_ttl(&socket, 64)!!;
	udp::set_multicast_loop(&socket, true)!!;
	udp::set_multicast_loop(&socket, false)!!;
	test::@error(udp::set_multicast_ttl(&socket, 0), nova::INVALID_STATE);
	test::@error(udp::set_multicast_ttl(&socket, 256), nova::INVALID_STATE);
	udp::set_multicast_ttl(&socket, 1)!!;
	udp::set_multicast_interface(&socket, { })!!;
	test::@error(udp::set_multicast_interface(&socket, ipv6_interface), nova::UNSUPPORTED);
	test::@error(udp::join_source_multicast(&socket, invalid_group), nova::UNSUPPORTED);
	test::@error(udp::join_source_multicast(&socket, invalid_source), nova::UNSUPPORTED);

	$if env::LINUX:
		udp::join_source_multicast(&socket, source_group)!!;
		udp::leave_source_multicast(&socket, source_group)!!;
	$else
		(void)udp::join_source_multicast(&socket, source_group);
		(void)udp::leave_source_multicast(&socket, source_group);
	$endif

	udp::close_now(&socket)!!;
	socket.destroy();
}

fn void test_udp_ipv6_multicast_interface_scope_metadata() @test
{
	udp::Socket socket;
	char[16] any_address;
	char[16] loopback_address;
	loopback_address[15] = 1;
	Endpoint default_ipv6_interface = net::endpoint_from_ipv6_scoped(0, any_address[0:16], 0);
	Endpoint scoped_loopback        = net::endpoint_from_ipv6_scoped(0, loopback_address[0:16], 1);
	Endpoint unscoped_loopback      = net::endpoint_from_ipv6(0, loopback_address[0:16]);

	test::eq((uint)0, default_ipv6_interface.ipv6_scope_id());
	test::eq((uint)1, scoped_loopback.ipv6_scope_id());

	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv6_loopback_endpoint(0))!!;

	udp::set_multicast_interface(&socket, default_ipv6_interface)!!;
	test::@error(udp::set_multicast_interface(&socket, unscoped_loopback), nova::UNSUPPORTED);

	udp::close_now(&socket)!!;
	socket.destroy();
}

fn void test_udp_close_cancels_active_recv_and_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator  = &tracker;
	Loop loop;
	udp::Socket socket;
	udp::RecvOp recv_op;
	udp::RecvOp late_recv_op;
	udp::SendOp late_send_op;
	UdpRecvSeen recv_seen;
	udp::SocketCloseOp close_op;
	udp::SocketCloseOp busy_close_op;
	UdpCloseSeen close_seen;
	char[8] buffer;
	char[4] late_buffer;
	char[4] payload      = { 'b', 'u', 's', 'y' };
	MulticastGroup group = { .group = ipv4_multicast_endpoint(0) };
	SourceMulticastGroup source_group = {
		.group = ipv4_multicast_endpoint(0),
		.interface_addr = ipv4_loopback_endpoint(0),
		.source = ipv4_loopback_endpoint(0),
	};

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv4_loopback_endpoint(0))!!;

	udp::recv(&loop, &socket, buffer[0:8], &recv_op, &on_udp_recv_seen, &recv_seen)!!;
	Ref close_ref = udp::close(&loop, &socket, &close_op, { }, &on_udp_close_seen, &close_seen)!!;
	test::@check(close_op.header.matches(close_ref));
	test::@check(socket.active_close == &close_op.header);
	test::@error(udp::close(&loop, &socket, &busy_close_op, { }, &on_udp_close_seen, &close_seen), nova::BUSY);
	test::@error(udp::close_now(&socket), nova::BUSY);
	test::@error(udp::bind(&socket, ipv4_loopback_endpoint(0)), nova::INVALID_STATE);
	test::@error(udp::connect(&socket, ipv4_loopback_endpoint(9)), nova::BUSY);
	test::@error(udp::recv(&loop, &socket, late_buffer[0:4], &late_recv_op, &on_udp_recv_seen, &recv_seen), nova::BUSY);
	test::@error(
		udp::send(&loop, &socket, payload[0:4], &socket.local, &late_send_op, &on_udp_send_seen, null),
		nova::BUSY
	);
	test::@error(udp::join_multicast(&socket, group), nova::BUSY);
	test::@error(udp::leave_multicast(&socket, group), nova::BUSY);
	test::@error(udp::set_broadcast(&socket, true), nova::BUSY);
	test::@error(udp::set_ttl(&socket, 64), nova::BUSY);
	test::@error(udp::set_multicast_loop(&socket, true), nova::BUSY);
	test::@error(udp::set_multicast_ttl(&socket, 1), nova::BUSY);
	test::@error(udp::set_multicast_interface(&socket, { }), nova::BUSY);
	test::@error(udp::join_source_multicast(&socket, source_group), nova::BUSY);
	test::@error(udp::leave_source_multicast(&socket, source_group), nova::BUSY);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, recv_seen.calls);
	test::@check(recv_seen.status == nova::CLOSED);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::@check(!close_seen.socket_open);
	test::@check(!close_seen.op_active);
	test::@check(!socket.is_open());
	test::@check(!socket.bound);
	test::@check(!socket.connected);
	test::eq((ushort)0, socket.local.port);
	test::eq((ushort)0, socket.remote.port);
	test::@check(!recv_op.header.active());
	test::@check(!close_op.header.active());
	test::@check(socket.active_recv == null);
	test::@check(socket.active_close == null);
	test::eq((sz)0, loop.timer_count);
	test::eq(allocation_count, tracker.total_allocation_count());

	socket.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
fn void test_udp_close_preserves_ready_send_result() @test
{
	Loop loop;
	udp::Socket sender;
	udp::Socket receiver;
	udp::SendOp send_op;
	UdpSendSeen send_seen;
	udp::SocketCloseOp close_op;
	UdpCloseSeen close_seen;
	char[5] payload = { 'c', 'l', 'o', 's', 'e' };

	loop.init({ .max_events = 4 })!!;
	sender.init({ .reuse_addr = true })!!;
	receiver.init({ .reuse_addr = true })!!;
	udp::bind(&sender, ipv4_loopback_endpoint(0))!!;
	udp::bind(&receiver, ipv4_loopback_endpoint(0))!!;

	udp::send(&loop, &sender, payload[0:5], &receiver.local, &send_op, &on_udp_send_seen, &send_seen)!!;
	udp::close(&loop, &sender, &close_op, { }, &on_udp_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, send_seen.calls);
	// A readiness send completes inline before the close, so its success result is
	// preserved. A completion SENDMSG is in flight when the close runs, so the close
	// asynchronously cancels it and the send reports CLOSED.
	if (loop.udp_send_completion())
	{
		test::@check(send_seen.status == nova::CLOSED);
		test::eq((sz)0, send_seen.bytes);
	}
	else
	{
		test::@check(!send_seen.status);
		test::eq((sz)5, send_seen.bytes);
	}
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::@check(!close_seen.op_active);
	test::@check(!sender.is_open());
	test::@check(!sender.bound);
	test::@check(!sender.connected);
	test::eq((ushort)0, sender.local.port);
	test::eq((ushort)0, sender.remote.port);
	test::@check(!send_op.header.active());
	test::@check(!close_op.header.active());
	test::@check(sender.active_send == null);
	test::@check(sender.active_close == null);

	sender.destroy();
	udp::close_now(&receiver)!!;
	receiver.destroy();
	loop.destroy();
}
