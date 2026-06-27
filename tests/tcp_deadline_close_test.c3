module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import libc;

import nova::op @public;
import nova @norecurse, nova::net, nova::net::tcp;

fn void test_tcp_stream_close_cancels_active_read_and_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadOp read_op;
	ReadSeen read_seen;
	tcp::StreamCloseOp close_op;
	tcp::StreamCloseOp busy_close_op;
	tcp::ConnectOp connect_op;
	tcp::ReadOp late_read_op;
	tcp::WriteOp late_write_op;
	tcp::AcceptOp late_accept_op;
	CloseSeen close_seen;
	ConnectSeen connect_seen;
	NativeHandle client = (NativeHandle)-1;
	char[8] buffer;
	char[4] late_buffer;
	char[4] payload     = { 'b', 'u', 's', 'y' };
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	tcp::read(&loop, &accepted, buffer[0:8], &read_op, { }, &on_read_seen, &read_seen)!!;
	// In readiness mode the read parks on the backend until dispatched; forge it
	// into the "ready but not yet called" window this test targets. In io_uring
	// completion mode the RECV lives in the kernel (no ready-queue slot), and
	// `stream_close` cancels it asynchronously, so the forge does not apply.
	if (!loop.stream_read_completion())
	{
		read_op.header.state = State.OP_READY;
		read_op.header.ready_flags = nova::READY_READABLE;
		read_op.header.next_ready = null;
		loop.ready_head = &read_op.header;
		loop.ready_tail = &read_op.header;
		loop.ready_count = 1;
	}
	Ref close_ref = tcp::stream_close(&loop, &accepted, &close_op, { }, &on_stream_close_seen, &close_seen)!!;
	test::@check(close_op.header.matches(close_ref));
	test::@check(accepted.active_close == &close_op.header);
	test::@error(
		tcp::stream_close(&loop, &accepted, &busy_close_op, { }, &on_stream_close_seen, &close_seen),
		nova::BUSY
	);
	test::@error(tcp::stream_close_now(&accepted), nova::BUSY);
	test::@error(
		tcp::connect(
			&loop,
			&accepted,
			ipv4_loopback_endpoint(listener.local.port),
			&connect_op,
			&on_connect_seen,
			&connect_seen
		),
		nova::BUSY
	);
	test::@error(
		tcp::read(&loop, &accepted, late_buffer[0:4], &late_read_op, { }, &on_read_seen, &read_seen),
		nova::BUSY
	);
	test::@error(tcp::write(&loop, &accepted, payload[0:4], &late_write_op, { }, &on_write_seen, null), nova::BUSY);
	test::@error(tcp::shutdown(&accepted, ShutdownMode.SEND), nova::BUSY);
	test::@error(tcp::accept(&loop, &listener, &accepted, &late_accept_op, &on_accept_seen, &accept_seen), nova::BUSY);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, read_seen.calls);
	test::@check(read_seen.status == nova::CLOSED);
	test::@check(!read_seen.op_active);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::@check(!close_seen.op_active);
	test::@check(!close_seen.stream_open);
	test::@check(!accepted.is_open());
	test::@check(!read_op.header.active());
	test::@check(!close_op.header.active());
	test::@check(accepted.active_read == null);
	test::@check(accepted.active_close == null);
	test::eq(allocation_count, tracker.total_allocation_count());

	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
fn void test_tcp_stream_close_cancels_ready_connect_before_callback() @test
{
	Loop loop;
	Listener listener;
	Stream stream;
	tcp::ConnectOp connect_op;
	ConnectSeen connect_seen;
	tcp::StreamCloseOp close_op;
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

	// In readiness mode the connect parks on writable readiness; forge it into the
	// "ready but not yet called" window this test targets. In io_uring completion
	// mode the CONNECT lives in the kernel (no ready-queue slot), and `stream_close`
	// cancels it asynchronously, so the forge does not apply.
	if (!loop.tcp_connect_completion())
	{
		connect_op.header.state = State.OP_READY;
		connect_op.header.ready_flags = 0;
		connect_op.header.next_ready = null;
		loop.ready_head = &connect_op.header;
		loop.ready_tail = &connect_op.header;
		loop.ready_count = 1;
	}

	tcp::stream_close(&loop, &stream, &close_op, { }, &on_stream_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, connect_seen.calls);
	test::@check(connect_seen.status == nova::CLOSED);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::@check(!stream.is_open());
	test::@check(stream.native_handle == (NativeHandle)-1);
	test::@check(stream.active_connect == null);
	test::@check(stream.active_close == null);

	stream.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}
fn void test_tcp_listener_close_cancels_active_accept() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	Stream late_out;
	tcp::AcceptOp accept_op;
	tcp::AcceptOp late_accept_op;
	AcceptSeen accept_seen;
	tcp::ListenerCloseOp close_op;
	tcp::ListenerCloseOp busy_close_op;
	CloseSeen close_seen;

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	late_out.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	Ref close_ref = tcp::listener_close(&loop, &listener, &close_op, { }, &on_listener_close_seen, &close_seen)!!;
	test::@check(close_op.header.matches(close_ref));
	test::@check(listener.active_close == &close_op.header);
	test::@error(
		tcp::listener_close(&loop, &listener, &busy_close_op, { }, &on_listener_close_seen, &close_seen),
		nova::BUSY
	);
	test::@error(tcp::listener_close_now(&listener), nova::BUSY);
	test::@error(tcp::bind(&listener, ipv4_endpoint(0)), nova::INVALID_STATE);
	test::@error(tcp::listen(&listener), nova::BUSY);
	test::@error(tcp::accept(&loop, &listener, &late_out, &late_accept_op, &on_accept_seen, &accept_seen), nova::BUSY);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, accept_seen.calls);
	test::@check(accept_seen.status == nova::CLOSED);
	test::@check(!accept_seen.op_active);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::@check(!close_seen.op_active);
	test::@check(!close_seen.listener_open);
	test::@check(!listener.is_open());
	test::@check(!listener.bound);
	test::@check(!listener.listening);
	test::eq((ushort)0, listener.local.port);
	test::@check(!accept_op.header.active());
	test::@check(!close_op.header.active());
	test::@check(listener.accept_head == null);
	test::eq((sz)0, listener.accept_count);
	test::@check(listener.active_close == null);

	accepted.destroy();
	late_out.destroy();
	listener.destroy();
	loop.destroy();
}
