module nova_tests;

import std::core::test;
import std::core::mem;
import std::core::mem::allocators;
import libc;

import nova @norecurse, nova::net, nova::net::tcp, nova::framed;

<*
 Length-prefixed echo: each frame is [1-byte length N][N payload bytes]. Small
 frames are echoed in-place via reserve/commit; a frame larger than the input
 buffer streams its body through read_into into the external `body` buffer.
*>
struct EchoCtx
{
	char[256] body;
	usz big_n;
	int frames;
	int data_calls;
}

fn void echo_on_data(Loop* loop, framed::FramedConn* conn, void* ud)
{
	EchoCtx* ctx = (EchoCtx*)ud;
	ctx.data_calls++;
	for (;;)
	{
		char[] h = conn.peek(1);
		if (!h.len) break;
		usz n           = (usz)h[0];
		usz frame_total = 1 + n;

		if (frame_total > conn.input_capacity())
		{
			conn.consume(1);
			ctx.big_n = n;
			if (catch conn.read_into(loop, ctx.body[0:n], n, &echo_on_body)) return;
			return;
		}

		char[] frame = conn.peek(frame_total);
		if (!frame.len) break;

		char[] region = conn.reserve(frame_total);
		if (!region.len)
		{
			(void)conn.flush(loop);
			return;
		}
		region[0] = (char)n;
		mem::copy(&region[1], &frame[1], (sz)n);
		conn.commit(frame_total);
		conn.consume(frame_total);
		ctx.frames++;
	}
}

fn void echo_on_body(Loop* loop, framed::FramedConn* conn, void* ud)
{
	(void)loop;
	EchoCtx* ctx  = (EchoCtx*)ud;
	usz n         = ctx.big_n;
	char[] region = conn.reserve(1 + n);
	if (!region.len) return;
	region[0] = (char)n;
	mem::copy(&region[1], &ctx.body[0], (sz)n);
	conn.commit(1 + n);
	ctx.frames++;
}

fn void echo_on_error(Loop* loop, framed::FramedConn* conn, fault status, void* ud)
{
	(void)loop;
	(void)conn;
	(void)status;
	(void)ud;
}

fn sz framed_pump_recv(Loop* loop, NativeHandle client, char[] dst, sz want)
{
	sz got = 0;
	for (sz i = 0; i < 2_000_000 && got < want; i++)
	{
		(void)nova::run(loop, RunMode.NO_WAIT);
		sz r = libc::recv((Fd)(int)client, &dst[got], (usz)(want - got), TEST_MSG_DONTWAIT);
		if (r > 0) got += r;
	}
	return got;
}

fn void test_framed_frame_reassembles_zero_alloc() @test
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
	framed::FramedConn conn;
	EchoCtx ctx;
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

	conn.init(
		&accepted,
		{
			.input_capacity = 64,
			.output_capacity = 512,
			.on_data = &echo_on_data,
			.on_error = &echo_on_error,
			.userdata = &ctx,
		},
		allocator
	)!!;
	sz allocation_count = tracker.total_allocation_count();
	conn.start(&loop)!!;

	char[3] part1 = { 5, 'h', 'e' };
	char[3] part2 = { 'l', 'l', 'o' };
	test::eq((sz)3, libc::send((Fd)client, &part1[0], 3, 0));
	for (sz i = 0; i < 200; i++) nova::run(&loop, RunMode.NO_WAIT)!!;
	test::eq((sz)3, libc::send((Fd)client, &part2[0], 3, 0));

	char[8] got;
	test::eq((sz)6, framed_pump_recv(&loop, client, got[0:8], 6));
	test::@check(got[0] == 5 && got[1] == 'h' && got[5] == 'o');
	test::eq(1, ctx.frames);
	test::eq(allocation_count, tracker.total_allocation_count());

	conn.destroy();
	loop.force_destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_framed_pipelined_coalesced() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	framed::FramedConn conn;
	EchoCtx ctx;
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
			.input_capacity = 64,
			.output_capacity = 512,
			.on_data = &echo_on_data,
			.on_error = &echo_on_error,
			.userdata = &ctx,
		}
	)!!;
	conn.start(&loop)!!;

	char[9] batch = { 2, 'a', 'b', 1, 'c', 3, 'x', 'y', 'z' };
	test::eq((sz)9, libc::send((Fd)client, &batch[0], 9, 0));

	char[16] got;
	test::eq((sz)9, framed_pump_recv(&loop, client, got[0:16], 9));
	test::@check(got[0] == 2 && got[1] == 'a' && got[2] == 'b');
	test::@check(got[3] == 1 && got[4] == 'c');
	test::@check(got[5] == 3 && got[6] == 'x' && got[8] == 'z');
	test::eq(3, ctx.frames);

	conn.destroy();
	loop.force_destroy();
}

fn void test_framed_read_into_large_body() @test
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
	framed::FramedConn conn;
	EchoCtx ctx;
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

	conn.init(
		&accepted,
		{
			.input_capacity = 8,
			.output_capacity = 512,
			.on_data = &echo_on_data,
			.on_error = &echo_on_error,
			.userdata = &ctx,
		},
		allocator
	)!!;
	sz allocation_count = tracker.total_allocation_count();
	conn.start(&loop)!!;

	char[41] msg;
	msg[0] = 40;
	for (usz i = 0; i < 40; i++) msg[1 + i] = (char)('A' + (char)(i % 26));
	test::eq((sz)41, libc::send((Fd)client, &msg[0], 41, 0));

	char[64] got;
	test::eq((sz)41, framed_pump_recv(&loop, client, got[0:64], 41));
	test::@check(got[0] == 40 && got[1] == 'A' && got[40] == (char)('A' + (char)(39 % 26)));
	test::eq(1, ctx.frames);
	test::eq(allocation_count, tracker.total_allocation_count());

	conn.destroy();
	loop.force_destroy();
	test::@check(!tracker.has_leaks());
}

fn void noconsume_on_data(Loop* loop, framed::FramedConn* conn, void* ud)
{
	(void)loop;
	(void)conn;
	EchoCtx* ctx = (EchoCtx*)ud;
	ctx.data_calls++;
}

fn void test_framed_backpressure_suspends_and_resumes() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	framed::FramedConn conn;
	EchoCtx ctx;
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
			.input_capacity = 64,
			.output_capacity = 64,
			.read_high = 8,
			.on_data = &noconsume_on_data,
			.on_error = &echo_on_error,
			.userdata = &ctx,
		}
	)!!;
	conn.start(&loop)!!;

	char[32] burst;
	for (usz i = 0; i < 32; i++) burst[i] = (char)i;
	test::eq((sz)32, libc::send((Fd)client, &burst[0], 32, 0));
	for (sz i = 0; i < 5000; i++) nova::run(&loop, RunMode.NO_WAIT)!!;

	test::@check(conn.read_paused);
	test::@check(conn.available() >= (usz)8);
	usz buffered = conn.available();

	conn.consume(buffered);
	conn.resume_read(&loop)!!;
	for (sz i = 0; i < 200; i++) nova::run(&loop, RunMode.NO_WAIT)!!;
	test::@check(!conn.read_paused);

	conn.destroy();
	loop.force_destroy();
}
