module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import libc;

import nova::op @public;
import nova @norecurse, nova::net, nova::net::tcp, nova::signal;

fn void test_signal_during_pending_tcp_read_shuts_down_cleanly() @test
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
	CloseSeen close_seen;
	signal::SignalOp signal_op;
	SignalSeen signal_seen;
	char[16] buffer;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 8 }, allocator)!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	signal_op.init();

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	tcp::read(&loop, &accepted, buffer[0:16], &read_op, { }, &on_read_seen, &read_seen)!!;
	signal::start(&loop, &signal_op, { .signum = libc::SIGUSR1 }, &on_signal_seen, &signal_seen)!!;
	test::@check(read_op.header.active());

	test::eq(0, libc::raise(libc::SIGUSR1));
	nova::run(&loop, RunMode.ONCE)!!;

	test::eq(1, signal_seen.calls);
	test::@check(!signal_seen.status);
	test::@check(signal_seen.owner_thread);
	test::eq(0, read_seen.calls);
	test::@check(read_op.header.active());

	signal::stop(&loop, &signal_op)!!;
	tcp::stream_close(&loop, &accepted, &close_op, { }, &on_stream_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, read_seen.calls);
	test::eq(nova::CLOSED, read_seen.status);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::eq((sz)0, loop.signal_count);
	test::eq((sz)0, loop.backend_active_count);

	accepted.destroy();
	signal_op.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
