module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import libc;

import nova @norecurse, nova::net, nova::net::tcp;

struct ReadvSeen
{
	int calls;
	fault status;
	sz bytes;
	bool eof;
}

fn void on_readv_seen(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* ud)
{
	(void)loop;
	(void)stream;
	(void)op;
	ReadvSeen* s = (ReadvSeen*)ud;
	s.calls++;
	s.status = result.error.status;
	s.bytes = result.bytes;
	s.eof = result.eof;
}

fn void test_tcp_read_vectored_scatters_into_two_segments() @test
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
	ReadvSeen seen;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 }, allocator)!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	char[5] b0;
	char[16] b1;
	char[][2] vec = { b0[..], b1[..] };
	tcp::read_vectored(&loop, &accepted, vec[..], &read_op, { }, &on_readv_seen, &seen)!!;

	sz allocation_count = tracker.total_allocation_count();
	String msg          = "hello world";
	test::eq((sz)msg.len, libc::send((Fd)client, msg.ptr, (usz)msg.len, 0));
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((sz)11, seen.bytes);
	test::@check(b0[0] == 'h' && b0[4] == 'o');
	test::@check(b1[0] == ' ' && b1[5] == 'd');
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_tcp_read_vectored_min_bytes_resumes_across_segments() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadOp read_op;
	ReadvSeen seen;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	char[4] b0;
	char[4] b1;
	char[][2] vec = { b0[..], b1[..] };
	tcp::read_vectored(&loop, &accepted, vec[..], &read_op, { .min_bytes = 6 }, &on_readv_seen, &seen)!!;

	String p1 = "ABC";
	test::eq((sz)3, libc::send((Fd)client, p1.ptr, (usz)p1.len, 0));
	for (sz i = 0; i < 200 && seen.calls == 0; i++) nova::run(&loop, RunMode.NO_WAIT)!!;
	test::eq(0, seen.calls);

	String p2 = "DEF";
	test::eq((sz)3, libc::send((Fd)client, p2.ptr, (usz)p2.len, 0));
	for (sz i = 0; i < 4_000_000 && seen.calls == 0; i++) nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((sz)6, seen.bytes);
	test::@check(b0[0] == 'A' && b0[3] == 'D');
	test::@check(b1[0] == 'E' && b1[1] == 'F');

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}
