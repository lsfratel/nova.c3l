module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import libc;

import nova @norecurse, nova::net, nova::net::tcp, nova::buffered;

struct BufEchoCtx
{
	bool error_seen;
}

fn void on_buf_echo_data(Loop* loop, buffered::StreamConn* conn, void* ud)
{
	for (;;)
	{
		sz nl = conn.find_byte('\n');
		if (nl < 0) break;
		usz line_len = (usz)nl + 1;
		char[256] line;
		usz n        = conn.copyout(line[0:256], line_len);
		conn.consume(line_len);
		if (catch conn.write(loop, line[0:n]))
		{
			return;
		}
	}
}

fn void on_buf_echo_error(Loop* loop, buffered::StreamConn* conn, fault status, void* ud)
{
	(void)loop;
	(void)conn;
	(void)status;
	BufEchoCtx* ctx = (BufEchoCtx*)ud;
	ctx.error_seen = true;
}

fn void test_buffered_line_echo_zero_allocates() @test
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
	buffered::StreamConn conn;
	BufEchoCtx ctx;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 8 }, allocator)!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	conn.init(
		&accepted,
		{
			.input_capacity = 4096,
			.output_capacity = 4096,
			.on_data = &on_buf_echo_data,
			.on_error = &on_buf_echo_error,
			.userdata = &ctx,
		},
		allocator
	)!!;
	sz allocation_count = tracker.total_allocation_count();
	conn.start(&loop)!!;

	String msg = "hello\nworld\n";
	test::eq((sz)msg.len, libc::send((Fd)client, msg.ptr, (usz)msg.len, 0));

	char[32] received;
	sz got = 0;
	for (sz i = 0; i < 4_000_000 && got < msg.len; i++)
	{
		nova::run(&loop, RunMode.NO_WAIT)!!;
		sz n = libc::recv((Fd)client, &received[got], (usz)(received.len - got), TEST_MSG_DONTWAIT);
		if (n > 0) got += n;
	}

	test::eq((sz)msg.len, got);
	test::@check(received[0] == 'h' && received[4] == 'o' && received[5] == '\n');
	test::@check(received[6] == 'w' && received[10] == 'd' && received[11] == '\n');
	test::eq(allocation_count, tracker.total_allocation_count());

	conn.destroy();
	loop.force_destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_buffered_partial_frame_reassembles() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	buffered::StreamConn conn;
	BufEchoCtx ctx;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 8 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	conn.init(
		&accepted,
		{
			.input_capacity = 4096,
			.output_capacity = 4096,
			.on_data = &on_buf_echo_data,
			.on_error = &on_buf_echo_error,
			.userdata = &ctx,
		}
	)!!;
	conn.start(&loop)!!;

	String part1 = "par";
	String part2 = "tial\n";
	test::eq((sz)part1.len, libc::send((Fd)client, part1.ptr, (usz)part1.len, 0));
	for (sz i = 0; i < 100; i++) nova::run(&loop, RunMode.NO_WAIT)!!;
	test::eq((sz)part2.len, libc::send((Fd)client, part2.ptr, (usz)part2.len, 0));

	char[16] received;
	sz got = 0;
	for (sz i = 0; i < 4_000_000 && got < 8; i++)
	{
		nova::run(&loop, RunMode.NO_WAIT)!!;
		sz n = libc::recv((Fd)client, &received[got], (usz)(received.len - got), TEST_MSG_DONTWAIT);
		if (n > 0) got += n;
	}

	test::eq((sz)8, got);
	test::@check(received[0] == 'p' && received[6] == 'l' && received[7] == '\n');

	conn.destroy();
	loop.force_destroy();
}

fn void test_ring_find_byte_across_wrap() @test
{
	buffered::RingBuffer ring;
	ring.init(8)!!;
	defer ring.destroy(mem);

	ring.append((char[])"ABCDEF")!!;
	ring.drain(4);
	ring.append((char[])"GHIJ")!!;

	test::eq((sz)0, ring.find_byte('E'));
	test::eq((sz)2, ring.find_byte('G'));
	test::eq((sz)4, ring.find_byte('I'));
	test::eq((sz)5, ring.find_byte('J'));
	test::eq((sz)-1, ring.find_byte('Z'));

	test::eq((sz)4, ring.find_byte_from('I', 3));
	test::eq((sz)-1, ring.find_byte_from('E', 1));
}
