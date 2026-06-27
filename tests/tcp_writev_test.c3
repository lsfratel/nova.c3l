module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import libc;

import nova @norecurse, nova::net, nova::net::tcp;

fn void test_tcp_write_vectored_concatenates_and_zero_allocates() @test
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
	tcp::WriteOp write_op;
	WriteSeen write_seen;
	NativeHandle client = (NativeHandle)-1;
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

	char[5] s0    = { 'h', 'e', 'l', 'l', 'o' };
	char[1] s1    = { ' ' };
	char[5] s2    = { 'w', 'o', 'r', 'l', 'd' };
	char[][3] vec = { s0[..], s1[..], s2[..] };

	tcp::write_vectored(&loop, &accepted, vec[..], &write_op, { }, &on_write_seen, &write_seen)!!;
	test::@check(accepted.active_write == &write_op.header);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::eq((sz)11, write_seen.bytes);
	test::@check(accepted.active_write == null);
	test::eq(allocation_count, tracker.total_allocation_count());

	char[16] received;
	sz got = recv_native_exact(client, received[0:16], 11)!!;
	test::eq((sz)11, got);
	test::@check(received[0] == 'h' && received[5] == ' ' && received[6] == 'w' && received[10] == 'd');

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_tcp_write_vectored_large_partial_drains_fully() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::WriteOp write_op;
	WriteSeen write_seen;
	NativeHandle client = (NativeHandle)-1;
	char[65536] sink;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	sz q = TCP_STALE_HANGUP_WRITE_SIZE / 4;
	char[][4] vec = {
		tcp_stale_hangup_write_payload[0:q],
		tcp_stale_hangup_write_payload[q:q],
		tcp_stale_hangup_write_payload[q * 2:q],
		tcp_stale_hangup_write_payload[q * 3:q],
	};

	tcp::write_vectored(&loop, &accepted, vec[..], &write_op, { }, &on_write_seen, &write_seen)!!;

	sz total_received = 0;
	for (sz i = 0; i < 4_000_000 && (write_seen.calls == 0 || total_received < TCP_STALE_HANGUP_WRITE_SIZE); i++)
	{
		if (write_seen.calls == 0) nova::run(&loop, RunMode.NO_WAIT)!!;
		sz n = libc::recv((Fd)client, sink[0:sink.len].ptr, (usz)sink.len, TEST_MSG_DONTWAIT);
		if (n > 0) total_received += n;
	}

	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::eq(TCP_STALE_HANGUP_WRITE_SIZE, write_seen.bytes);
	test::@check(accepted.active_write == null);
	test::eq((sz)0, accepted.write_queue_size());
	test::eq(TCP_STALE_HANGUP_WRITE_SIZE, total_received);

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}
