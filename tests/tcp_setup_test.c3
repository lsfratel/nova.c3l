module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import std::net::os;
import libc;

import nova::op @public;
import nova @norecurse, nova::net, nova::net::tcp;

fn void test_tcp_lifecycle() @test
{
	Endpoint local = ipv4_endpoint(0);
	Listener listener;
	Stream stream;

	test::@error(tcp::bind(&listener, local), nova::INVALID_STATE);
	test::@error(tcp::listener_close_now(&listener), nova::INVALID_STATE);
	test::@error(tcp::stream_close_now(&stream), nova::INVALID_STATE);

	listener.init({ .reuse_addr = true, .nodelay = true })!!;
	test::@error(listener.borrow_native(), nova::INVALID_STATE);
	test::@error(listener.local_endpoint(), nova::INVALID_STATE);
	test::@error(tcp::listener_close_now(&listener), nova::INVALID_STATE);
	tcp::bind(&listener, local)!!;
	test::@check(listener.is_open());
	test::@check(listener.borrow_native()!! != (NativeHandle)-1);
	Endpoint listener_local = listener.local_endpoint()!!;
	test::@check(listener_local.family == AddressFamily.IPV4);
	test::eq(listener.local.port, listener_local.port);
	test::@error(tcp::bind(&listener, local), nova::INVALID_STATE);
	test::@error(tcp::listen(&listener, 0), nova::INVALID_STATE);
	tcp::listen(&listener)!!;
	test::@check(listener.is_open());

	tcp::listener_close_now(&listener)!!;
	test::@check(!listener.is_open());
	test::@error(listener.borrow_native(), nova::INVALID_STATE);
	test::@error(listener.local_endpoint(), nova::INVALID_STATE);
	test::@check(!listener.bound);
	test::@check(!listener.listening);
	test::eq((ushort)0, listener.local.port);
	listener.destroy();
	test::@check(!listener.initialized);
	test::@check(listener.native_handle == (NativeHandle)-1);
	test::@check(!listener.options.reuse_addr);
	test::@check(!listener.options.nodelay);

	stream.init({ .reuse_addr = true, .nodelay = true })!!;
	test::@error(stream.borrow_native(), nova::INVALID_STATE);
	test::@error(stream.local_endpoint(), nova::INVALID_STATE);
	test::@error(stream.peer_endpoint(), nova::INVALID_STATE);
	test::@error(tcp::stream_close_now(&stream), nova::INVALID_STATE);
	test::@error(tcp::shutdown(&stream, (ShutdownMode)99), nova::INVALID_STATE);
	stream.open = true;
	stream.native_handle = (NativeHandle)-1;
	test::@error(tcp::shutdown(&stream, (ShutdownMode)99), nova::INVALID_STATE);
	test::@check(stream.is_open());
	tcp::stream_close_now(&stream)!!;
	test::@check(!stream.is_open());
	test::@error(stream.borrow_native(), nova::INVALID_STATE);
	stream.destroy();
	test::@check(!stream.initialized);
	test::@check(stream.native_handle == (NativeHandle)-1);
	test::@check(!stream.options.reuse_addr);
	test::@check(!stream.options.nodelay);
}
fn void test_tcp_bind_rejects_unsupported_family() @test
{
	Endpoint local;
	Listener listener;

	listener.init()!!;

	test::@error(tcp::bind(&listener, local), nova::UNSUPPORTED);
	test::@check(!listener.is_open());

	listener.destroy();
}

fn void test_tcp_bind_conflicting_port_reports_address_in_use() @test
{
	Listener first;
	Listener second;

	first.init()!!;
	tcp::bind(&first, ipv4_loopback_endpoint(0))!!;
	test::@check(first.is_open());

	second.init()!!;
	test::@error(tcp::bind(&second, ipv4_loopback_endpoint(first.local.port)), nova::ADDRESS_IN_USE);
	test::@check(!second.is_open());

	tcp::listener_close_now(&first)!!;
	first.destroy();
	second.destroy();
}

fn void test_tcp_bind_ipv6_loopback_reports_ipv6_local_endpoint() @test
{
	Listener listener;

	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv6_loopback_endpoint(0))!!;

	test::@check(listener.is_open());
	test::@check(listener.local.family == AddressFamily.IPV6);
	test::@check(listener.local.port > 0);
	test::eq((char)1, listener.local.storage[15]);

	tcp::listener_close_now(&listener)!!;
	listener.destroy();
}

fn void test_tcp_connect_accept_ipv6_loopback() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	Stream client;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ConnectOp connect_op;
	ConnectSeen connect_seen;

	loop.init({ .max_events = 8 })!!;
	listener.init({ .reuse_addr = true, .nodelay = true })!!;
	tcp::bind(&listener, ipv6_loopback_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	client.init({ .nodelay = true })!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	tcp::connect(
		&loop,
		&client,
		ipv6_loopback_endpoint(listener.local.port),
		&connect_op,
		&on_connect_seen,
		&connect_seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, accept_seen.calls);
	test::@check(!accept_seen.status);
	test::@check(accept_seen.peer_family == AddressFamily.IPV6);
	test::@check(accepted.is_open());
	test::eq(1, connect_seen.calls);
	test::@check(!connect_seen.status);
	test::@check(client.is_open());
	test::@check(!accept_op.header.active());
	test::@check(!connect_op.header.active());

	test::@check(listener.borrow_native()!! != (NativeHandle)-1);
	test::@check(client.borrow_native()!! != (NativeHandle)-1);
	test::@check(accepted.borrow_native()!! != (NativeHandle)-1);

	Endpoint listener_local = listener.local_endpoint()!!;
	Endpoint client_local   = client.local_endpoint()!!;
	Endpoint client_peer    = client.peer_endpoint()!!;
	Endpoint accepted_local = accepted.local_endpoint()!!;
	Endpoint accepted_peer  = accepted.peer_endpoint()!!;

	test::@check(listener_local.family == AddressFamily.IPV6);
	test::eq(listener.local.port, listener_local.port);
	test::@check(client_local.family == AddressFamily.IPV6);
	test::@check(client_local.port > 0);
	test::@check(client_peer.family == AddressFamily.IPV6);
	test::eq(listener.local.port, client_peer.port);
	test::@check(accepted_local.family == AddressFamily.IPV6);
	test::eq(listener.local.port, accepted_local.port);
	test::@check(accepted_peer.family == AddressFamily.IPV6);
	test::eq(client_local.port, accepted_peer.port);

	tcp::stream_close_now(&client)!!;
	client.destroy();
	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_sockets_are_close_on_exec() @test
{
	const CInt F_GETFD_LOCAL    = 1;
	const CInt FD_CLOEXEC_LOCAL = 1;
	Loop loop;
	Listener listener;
	Stream accepted;
	Stream client;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ConnectOp connect_op;
	ConnectSeen connect_seen;

	loop.init({ .max_events = 8 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	client.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	tcp::connect(
		&loop,
		&client,
		ipv4_loopback_endpoint(listener.local.port),
		&connect_op,
		&on_connect_seen,
		&connect_seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::@check(!accept_seen.status);
	test::@check(!connect_seen.status);

	os::NativeSocket listener_fd = (os::NativeSocket)listener.borrow_native()!!;
	os::NativeSocket client_fd   = (os::NativeSocket)client.borrow_native()!!;
	os::NativeSocket accepted_fd = (os::NativeSocket)accepted.borrow_native()!!;
	test::@check((os::fcntl(listener_fd, F_GETFD_LOCAL, 0) & FD_CLOEXEC_LOCAL) != 0);
	test::@check((os::fcntl(client_fd, F_GETFD_LOCAL, 0) & FD_CLOEXEC_LOCAL) != 0);
	test::@check((os::fcntl(accepted_fd, F_GETFD_LOCAL, 0) & FD_CLOEXEC_LOCAL) != 0);

	tcp::stream_close_now(&client)!!;
	client.destroy();
	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_stream_set_options_after_connect() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	Stream client;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ConnectOp connect_op;
	ConnectSeen connect_seen;

	loop.init({ .max_events = 8 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	client.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	tcp::connect(&loop, &client, ipv4_endpoint(listener.local.port), &connect_op, &on_connect_seen, &connect_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());
	test::@check(client.is_open());

	accepted.set_options({ .nodelay = true, .keepalive = true, .send_buffer_size = 16384 })!!;
	client.set_options({ .nodelay = true })!!;

	Stream closed;
	closed.init()!!;
	test::@error(closed.set_options({ .nodelay = true }), nova::INVALID_STATE);
	closed.destroy();

	tcp::stream_close_now(&client)!!;
	client.destroy();
	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_accept_async_dispatches_and_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	Listener listener;
	Stream accepted;
	Stream busy_stream;
	tcp::AcceptOp accept_op;
	AcceptSeen seen;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	listener.init({ .reuse_addr = true, .nodelay = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	test::@check(listener.local.port > 0);
	tcp::listen(&listener)!!;

	accepted.init()!!;
	busy_stream.init()!!;

	Ref oref = tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &seen)!!;
	test::@check(accept_op.header.matches(oref));
	test::@check(listener.accept_head == &accept_op);
	test::eq((sz)1, listener.accept_count);
	test::@error(tcp::accept(&loop, &listener, &busy_stream, &accept_op, &on_accept_seen, &seen), nova::BUSY);

	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.stream == &accepted);
	test::@check(seen.stream_open);
	test::@check(seen.peer_port > 0);
	test::@check(!accept_op.header.active());
	test::@check(listener.accept_head == null);
	test::eq((sz)0, listener.accept_count);
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	busy_stream.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
fn void test_tcp_accept_rejects_output_stream_with_active_connect() @test
{
	Loop loop;
	Listener listener;
	Stream stream;
	tcp::ConnectOp connect_op;
	tcp::AcceptOp accept_op;
	tcp::StreamCloseOp close_op;
	ConnectSeen connect_seen;
	AcceptSeen accept_seen;
	CloseSeen close_seen;

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	stream.init()!!;

	tcp::connect(
		&loop,
		&stream,
		ipv4_loopback_endpoint(listener.local.port),
		&connect_op,
		&on_connect_seen,
		&connect_seen
	)!!;
	test::@check(stream.active_connect == &connect_op.header);
	test::@check(!stream.is_open());

	test::@error(tcp::accept(&loop, &listener, &stream, &accept_op, &on_accept_seen, &accept_seen), nova::BUSY);
	test::@check(!accept_op.header.active());
	test::eq(0, accept_seen.calls);

	tcp::stream_close(&loop, &stream, &close_op, { }, &on_stream_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, connect_seen.calls);
	test::@check(connect_seen.status == nova::CLOSED);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::@check(!stream.is_open());
	test::@check(stream.active_connect == null);
	test::@check(stream.active_close == null);

	stream.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

struct AcceptRepostCtx
{
	tcp::Stream* second;
	tcp::Stream*[2] streams;
	fault[2] statuses;
	bool[2] op_active;
	sz calls;
}

fn void on_accept_repost_same_op(
	Loop* loop,
	tcp::Listener* listener,
	tcp::AcceptOp* op,
	tcp::AcceptResult* result,
	void* userdata
)
{
	AcceptRepostCtx* ctx = (AcceptRepostCtx*)userdata;
	sz index             = ctx.calls;
	ctx.streams[index] = result.stream;
	ctx.statuses[index] = result.error.status;
	ctx.op_active[index] = op.header.active();
	ctx.calls++;

	if (ctx.calls == 1)
	{
		tcp::accept(loop, listener, ctx.second, op, &on_accept_repost_same_op, ctx)!!;
	}
}

fn void test_tcp_accept_can_repost_same_op_inside_callback_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator  = &tracker;
	Loop loop;
	Listener listener;
	Stream first;
	Stream second;
	tcp::AcceptOp accept_op;
	AcceptRepostCtx ctx;
	NativeHandle client1 = (NativeHandle)-1;
	NativeHandle client2 = (NativeHandle)-1;
	defer if ((int)client1 >= 0) (void)libc::close((int)client1);
	defer if ((int)client2 >= 0) (void)libc::close((int)client2);

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	first.init()!!;
	second.init()!!;
	ctx.second = &second;

	tcp::accept(&loop, &listener, &first, &accept_op, &on_accept_repost_same_op, &ctx)!!;
	client1 = connect_loopback(listener.local.port)!!;
	client2 = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.calls);
	test::@check(!ctx.statuses[0]);
	test::@check(!ctx.statuses[1]);
	test::@check(!ctx.op_active[0]);
	test::@check(!ctx.op_active[1]);
	test::@check(ctx.streams[0] == &first);
	test::@check(ctx.streams[1] == &second);
	test::@check(first.is_open());
	test::@check(second.is_open());
	test::@check(!accept_op.header.active());
	test::@check(listener.accept_head == null);
	test::eq((sz)0, listener.accept_count);
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&first)!!;
	first.destroy();
	tcp::stream_close_now(&second)!!;
	second.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

struct AcceptCloseNowCtx
{
	fault status;
	fault close_status;
	bool op_active;
	bool listener_open_after_close;
	int calls;
}

fn void on_accept_close_listener_now(
	Loop* loop,
	tcp::Listener* listener,
	tcp::AcceptOp* op,
	tcp::AcceptResult* result,
	void* userdata
)
{
	(void)loop;
	AcceptCloseNowCtx* ctx = (AcceptCloseNowCtx*)userdata;
	ctx.calls++;
	ctx.status = result.error.status;
	ctx.op_active = op.header.active();
	ctx.close_status = @catch(tcp::listener_close_now(listener));
	ctx.listener_open_after_close = listener.is_open();
}

fn void test_tcp_accept_callback_can_close_listener_now() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptCloseNowCtx ctx;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_close_listener_now, &ctx)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(1, ctx.calls);
	test::@check(!ctx.status);
	test::@check(!ctx.close_status);
	test::@check(!ctx.op_active);
	test::@check(!ctx.listener_open_after_close);
	test::@check(!listener.is_open());
	test::@check(!listener.accept_driver.active());
	test::@check(!accept_op.header.active());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_connect_async_dispatches_and_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	Listener listener;
	Stream stream;
	tcp::ConnectOp connect_op;
	tcp::ConnectOp busy_op;
	ConnectSeen seen;

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;

	stream.init({ .nodelay = true })!!;
	Endpoint remote = ipv4_loopback_endpoint(listener.local.port);

	Ref oref = tcp::connect(&loop, &stream, remote, &connect_op, &on_connect_seen, &seen)!!;
	test::@check(connect_op.header.matches(oref));
	test::@check(stream.active_connect == &connect_op.header);
	test::@error(tcp::connect(&loop, &stream, remote, &busy_op, &on_connect_seen, &seen), nova::BUSY);

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.stream == &stream);
	test::@check(seen.stream_open);
	test::@check(stream.is_open());
	test::@check(!connect_op.header.active());
	test::@check(stream.active_connect == null);
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&stream)!!;
	stream.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
fn void test_tcp_connect_refused_reports_callback_error() @test
{
	Loop loop;
	Listener listener;
	Stream stream;
	tcp::ConnectOp connect_op;
	ConnectSeen seen;

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	ushort port = listener.local.port;
	tcp::listener_close_now(&listener)!!;
	listener.destroy();

	stream.init()!!;
	tcp::connect(&loop, &stream, ipv4_loopback_endpoint(port), &connect_op, &on_connect_seen, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::CONNECTION_REFUSED);
	test::@check(!seen.stream_open);
	test::@check(!stream.is_open());
	test::@check(!connect_op.header.active());
	test::@check(stream.active_connect == null);

	stream.destroy();
	loop.destroy();
}
fn void test_tcp_keepalive_tuning_options_accept_and_connect() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	Stream client;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ConnectOp connect_op;
	ConnectSeen connect_seen;
	SocketOptions options = {
		.reuse_addr = true,
		.nodelay = true,
		.keepalive = true,
		.keepalive_idle = (Duration)1_000_000,
		.keepalive_interval = (Duration)1_000_000,
		.keepalive_count = 2,
		.send_buffer_size = 4096,
		.recv_buffer_size = 4096,
	};

	loop.init({ .max_events = 8 })!!;
	listener.init(options)!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	client.init(options)!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	tcp::connect(
		&loop,
		&client,
		ipv4_loopback_endpoint(listener.local.port),
		&connect_op,
		&on_connect_seen,
		&connect_seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, accept_seen.calls);
	test::@check(!accept_seen.status);
	test::@check(accepted.is_open());
	test::eq(1, connect_seen.calls);
	test::@check(!connect_seen.status);
	test::@check(client.is_open());

	tcp::stream_close_now(&client)!!;
	client.destroy();
	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}
fn void test_tcp_invalid_keepalive_tuning_is_rejected() @test
{
	Loop loop;
	Listener listener;
	Listener invalid_count;
	Listener oversized_listener;
	Listener server;
	Stream stream;
	Stream oversized_stream;
	tcp::ConnectOp connect_op;
	tcp::ConnectOp oversized_connect_op;
	ConnectSeen seen;

	listener.init({ .keepalive = true, .keepalive_idle = (Duration)-1 })!!;
	test::@error(tcp::bind(&listener, ipv4_endpoint(0)), nova::INVALID_STATE);
	listener.destroy();

	invalid_count.init({ .keepalive = true, .keepalive_count = uint::max })!!;
	test::@error(tcp::bind(&invalid_count, ipv4_endpoint(0)), nova::INVALID_STATE);
	test::@check(!invalid_count.is_open());
	invalid_count.destroy();

	oversized_listener.init({ .send_buffer_size = uint::max })!!;
	test::@error(tcp::bind(&oversized_listener, ipv4_endpoint(0)), nova::INVALID_STATE);
	test::@check(!oversized_listener.is_open());
	oversized_listener.destroy();

	loop.init({ .max_events = 4 })!!;
	server.init({ .reuse_addr = true })!!;
	tcp::bind(&server, ipv4_endpoint(0))!!;
	tcp::listen(&server)!!;
	stream.init({ .keepalive = true, .keepalive_interval = (Duration)-1 })!!;

	test::@error(
		tcp::connect(&loop, &stream, ipv4_loopback_endpoint(server.local.port), &connect_op, &on_connect_seen, &seen),
		nova::INVALID_STATE
	);
	test::@check(!stream.is_open());
	test::@check(stream.active_connect == null);

	oversized_stream.init({ .recv_buffer_size = uint::max })!!;
	test::@error(
		tcp::connect(
			&loop,
			&oversized_stream,
			ipv4_loopback_endpoint(server.local.port),
			&oversized_connect_op,
			&on_connect_seen,
			&seen
		),
		nova::INVALID_STATE
	);
	test::@check(!oversized_stream.is_open());
	test::@check(oversized_stream.active_connect == null);

	oversized_stream.destroy();
	stream.destroy();
	tcp::listener_close_now(&server)!!;
	server.destroy();
	loop.destroy();
}
