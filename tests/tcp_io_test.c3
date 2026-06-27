module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import libc;

import nova::op @public;
import nova @norecurse, nova::net, nova::net::tcp;

const sz TCP_STALE_HANGUP_WRITE_SIZE = 16 * 1024 * 1024;

char[TCP_STALE_HANGUP_WRITE_SIZE] tcp_stale_hangup_write_payload;

const CInt TEST_MSG_DONTWAIT = env::LINUX ? 0x40 : 0x80;

struct TcpReadStartSeen
{
	int calls;
	int stop_after;
	fault[4] statuses;
	sz[4] bytes;
	bool[4] eof;
	bool[4] reader_active;
	bool[4] op_active;
	char[4] first_byte;
}

fn tcp::ReadAction on_tcp_read_start_seen(
	Loop* loop,
	Stream* stream,
	tcp::ReadStarter* reader,
	tcp::ReadResult* result,
	void* userdata
)
{
	(void)stream;
	TcpReadStartSeen* seen = (TcpReadStartSeen*)userdata;
	int index              = seen.calls;
	if (index < 4)
	{
		seen.statuses[index] = result.error.status;
		seen.bytes[index] = result.bytes;
		seen.eof[index] = result.eof;
		seen.reader_active[index] = reader.active;
		seen.op_active[index] = reader.op.header.active();
		if (result.bytes > 0) seen.first_byte[index] = result.buffer[0];
	}
	seen.calls++;

	if (result.error.status || result.eof || seen.calls >= seen.stop_after)
	{
		loop.stop();
		return tcp::ReadAction.STOP;
	}
	return tcp::ReadAction.CONTINUE;
}

fn void test_tcp_read_async_dispatches_payload_and_zero_allocates() @test
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
	tcp::ReadOp busy_op;
	ReadSeen read_seen;
	NativeHandle client = (NativeHandle)-1;
	char[16] buffer;
	char[5] payload     = { 'h', 'e', 'l', 'l', 'o' };
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

	Ref oref = tcp::read(&loop, &accepted, buffer[0:16], &read_op, { }, &on_read_seen, &read_seen)!!;
	test::@check(read_op.header.matches(oref));
	test::@check(accepted.active_read == &read_op.header);
	test::@error(tcp::read(&loop, &accepted, buffer[0:16], &busy_op, { }, &on_read_seen, &read_seen), nova::BUSY);

	test::eq((sz)5, libc::send((Fd)client, payload[0:5].ptr, (usz)payload.len, 0));
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::@check(read_seen.stream_open);
	test::@check(read_seen.buffer.ptr == buffer[0:16].ptr);
	test::eq((sz)16, read_seen.buffer.len);
	test::eq((sz)5, read_seen.bytes);
	test::@check(!read_seen.eof);
	test::@check(buffer[0] == 'h');
	test::@check(buffer[1] == 'e');
	test::@check(buffer[2] == 'l');
	test::@check(buffer[3] == 'l');
	test::@check(buffer[4] == 'o');
	test::@check(!read_op.header.active());
	test::@check(accepted.active_read == null);
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
fn void test_tcp_sequential_writes_arrive_in_order() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::WriteOp write_op;
	WriteSeen write_seen;
	NativeHandle client = (NativeHandle)-1;
	char[2] first       = { 'A', 'B' };
	char[2] second      = { 'C', 'D' };
	char[8] received;
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

	tcp::write(&loop, &accepted, first[0:2], &write_op, { }, &on_write_seen, &write_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::eq((sz)2, write_seen.bytes);
	test::@check(!write_op.header.active());

	tcp::write(&loop, &accepted, second[0:2], &write_op, { }, &on_write_seen, &write_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(2, write_seen.calls);
	test::@check(!write_seen.status);
	test::eq((sz)2, write_seen.bytes);
	test::@check(!write_op.header.active());

	test::eq((sz)4, recv_native_exact(client, received[0:8], 4)!!);
	test::@check(received[0] == 'A');
	test::@check(received[1] == 'B');
	test::@check(received[2] == 'C');
	test::@check(received[3] == 'D');

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}
fn void test_tcp_read_reports_eof() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadOp read_op;
	ReadSeen read_seen;
	NativeHandle client = (NativeHandle)-1;
	char[8] buffer;

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	(void)libc::close((int)client);
	client = (NativeHandle)-1;

	wait_native_readable(accepted.native_handle);
	tcp::read(&loop, &accepted, buffer[0:8], &read_op, { }, &on_read_seen, &read_seen)!!;
	test::@check(read_op.header.active());
	test::@check(accepted.active_read == &read_op.header);
	if (loop.stream_read_completion())
	{
		test::eq((sz)0, loop.ready_count);
		test::eq((sz)1, loop.backend_active_count);
	}
	else
	{
		test::eq((sz)1, loop.ready_count);
		test::eq((sz)0, loop.backend_active_count);
	}
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)0, read_seen.bytes);
	test::@check(read_seen.eof);
	test::@check(accepted.is_open());
	test::@check(!read_op.header.active());
	test::@check(accepted.active_read == null);

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_read_immediate_buffered_payload_zero_allocates() @test
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
	NativeHandle client = (NativeHandle)-1;
	char[8] buffer;
	char[5] payload     = { 'r', 'e', 'a', 'd', 'y' };
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

	test::eq((sz)5, libc::send((Fd)client, payload[0:5].ptr, (usz)payload.len, 0));
	wait_native_readable(accepted.native_handle);
	Ref oref = tcp::read(&loop, &accepted, buffer[0:8], &read_op, { }, &on_read_seen, &read_seen)!!;
	test::@check(read_op.header.matches(oref));
	test::@check(read_op.header.active());
	test::@check(accepted.active_read == &read_op.header);
	if (loop.stream_read_completion())
	{
		test::eq((sz)0, loop.ready_count);
		test::eq((sz)1, loop.backend_active_count);
	}
	else
	{
		test::eq((sz)1, loop.ready_count);
		test::eq((sz)0, loop.backend_active_count);
	}

	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)5, read_seen.bytes);
	test::@check(!read_seen.eof);
	test::@check(buffer[0] == 'r');
	test::@check(buffer[1] == 'e');
	test::@check(buffer[2] == 'a');
	test::@check(buffer[3] == 'd');
	test::@check(buffer[4] == 'y');
	test::@check(!read_op.header.active());
	test::@check(accepted.active_read == null);
	test::eq((sz)0, loop.ready_count);
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_tcp_read_start_receives_multiple_chunks_without_manual_repost() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadStarter reader;
	TcpReadStartSeen seen = { .stop_after = 2 };
	NativeHandle client   = (NativeHandle)-1;
	char[3] buffer;
	char[6] payload       = { 'a', 'b', 'c', 'd', 'e', 'f' };
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	reader.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	tcp::read_start(&loop, &accepted, &reader, buffer[0:3], &on_tcp_read_start_seen, { }, &seen)!!;
	test::@check(reader.active);
	test::@check(reader.op.header.active());
	test::eq((sz)6, libc::send((Fd)client, payload[0:6].ptr, (usz)payload.len, 0));
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, seen.calls);
	test::@check(!seen.statuses[0]);
	test::@check(!seen.statuses[1]);
	test::eq((sz)3, seen.bytes[0]);
	test::eq((sz)3, seen.bytes[1]);
	test::@check(seen.first_byte[0] == 'a');
	test::@check(seen.first_byte[1] == 'd');
	test::@check(seen.reader_active[0]);
	test::@check(seen.reader_active[1]);
	test::@check(!seen.op_active[0]);
	test::@check(!seen.op_active[1]);
	test::@check(!reader.active);
	test::@check(!reader.op.header.active());
	test::@check(accepted.active_read == null);

	reader.destroy();
	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_read_stop_cancels_reader_without_user_callback() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadStarter reader;
	TcpReadStartSeen seen = { .stop_after = 1 };
	NativeHandle client   = (NativeHandle)-1;
	char[8] buffer;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	reader.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	tcp::read_start(&loop, &accepted, &reader, buffer[0:8], &on_tcp_read_start_seen, { }, &seen)!!;
	tcp::read_stop(&loop, &accepted, &reader)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(0, seen.calls);
	test::@check(!reader.active);
	test::@check(!reader.op.header.active());
	test::@check(accepted.active_read == null);

	reader.destroy();
	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_read_start_reports_eof_and_stops() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadStarter reader;
	TcpReadStartSeen seen = { .stop_after = 4 };
	NativeHandle client   = (NativeHandle)-1;
	char[8] buffer;

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	reader.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	(void)libc::close((int)client);
	client = (NativeHandle)-1;
	tcp::read_start(&loop, &accepted, &reader, buffer[0:8], &on_tcp_read_start_seen, { }, &seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.statuses[0]);
	test::eq((sz)0, seen.bytes[0]);
	test::@check(seen.eof[0]);
	test::@check(!reader.active);
	test::@check(!reader.op.header.active());
	test::@check(accepted.active_read == null);

	reader.destroy();
	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_write_after_peer_read_eof_waits_for_writable_not_stale_hangup() @test @if(env::LINUX)
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadOp read_op;
	ReadSeen read_seen;
	tcp::WriteOp write_op;
	WriteSeen write_seen;
	tcp::StreamCloseOp close_op;
	CloseSeen close_seen;
	NativeHandle client = (NativeHandle)-1;
	char[1] buffer;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4, .dispatch_budget = 1 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	test::eq((CInt)0, libc::shutdown((Fd)client, libc::SHUT_WR));
	tcp::read(&loop, &accepted, buffer[0:1], &read_op, { }, &on_read_seen, &read_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, read_seen.calls);
	test::@check(read_seen.eof);

	tcp::write(
		&loop,
		&accepted,
		tcp_stale_hangup_write_payload[0:TCP_STALE_HANGUP_WRITE_SIZE],
		&write_op,
		{ },
		&on_write_seen,
		&write_seen
	)!!;
	nova::run(&loop, RunMode.NO_WAIT)!!;

	test::eq(0, write_seen.calls);
	test::@check(write_op.written > 0);
	test::@check(write_op.written < TCP_STALE_HANGUP_WRITE_SIZE);
	test::@check(write_op.header.active());
	test::@check(accepted.active_write == &write_op.header);
	test::eq(TCP_STALE_HANGUP_WRITE_SIZE - write_op.written, accepted.write_queue_size());
	test::@error(accepted.try_write(tcp_stale_hangup_write_payload[0:1]), nova::BUSY);
	test::eq((sz)0, loop.ready_count);
	test::eq((sz)1, loop.backend_active_count);

	tcp::stream_close(&loop, &accepted, &close_op, { }, &on_stream_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, write_seen.calls);
	test::eq(nova::CLOSED, write_seen.status);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_shutdown_send_rejects_active_write() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::WriteOp write_op;
	WriteSeen write_seen;
	tcp::StreamCloseOp close_op;
	CloseSeen close_seen;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4, .dispatch_budget = 1 })!!;
	listener.init({ .reuse_addr = true, .send_buffer_size = 4096 })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	tcp::write(
		&loop,
		&accepted,
		tcp_stale_hangup_write_payload[0:TCP_STALE_HANGUP_WRITE_SIZE],
		&write_op,
		{ },
		&on_write_seen,
		&write_seen
	)!!;

	test::@check(write_op.header.active());
	test::@error(tcp::shutdown(&accepted, ShutdownMode.SEND), nova::BUSY);
	test::@error(tcp::shutdown(&accepted, ShutdownMode.BOTH), nova::BUSY);

	tcp::stream_close(&loop, &accepted, &close_op, { }, &on_stream_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, write_seen.calls);
	test::eq(nova::CLOSED, write_seen.status);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_shutdown_recv_rejects_active_read() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadOp read_op;
	ReadSeen read_seen;
	tcp::StreamCloseOp close_op;
	CloseSeen close_seen;
	NativeHandle client = (NativeHandle)-1;
	char[4] buffer;
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

	tcp::read(&loop, &accepted, buffer[0:buffer.len], &read_op, { }, &on_read_seen, &read_seen)!!;

	test::@check(read_op.header.active());
	test::@error(tcp::shutdown(&accepted, ShutdownMode.RECV), nova::BUSY);
	test::@error(tcp::shutdown(&accepted, ShutdownMode.BOTH), nova::BUSY);

	tcp::stream_close(&loop, &accepted, &close_op, { }, &on_stream_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, read_seen.calls);
	test::eq(nova::CLOSED, read_seen.status);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_read_min_bytes_waits_for_threshold() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadOp read_op;
	ReadSeen read_seen;
	NativeHandle client = (NativeHandle)-1;
	char[8] buffer;
	char[2] first       = { 'o', 'k' };
	char[3] second      = { '!', '!', '!' };
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	tcp::read(&loop, &accepted, buffer[0:8], &read_op, { .min_bytes = 5 }, &on_read_seen, &read_seen)!!;
	test::eq((sz)2, libc::send((Fd)client, first[0:2].ptr, (usz)first.len, 0));
	wait_native_readable(accepted.native_handle);
	nova::run(&loop, RunMode.ONCE)!!;
	test::eq(0, read_seen.calls);
	test::@check(read_op.header.active());
	test::eq((sz)2, read_op.filled);

	test::eq((sz)3, libc::send((Fd)client, second[0:3].ptr, (usz)second.len, 0));
	wait_native_readable(accepted.native_handle);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)5, read_seen.bytes);
	test::@check(buffer[0] == 'o');
	test::@check(buffer[1] == 'k');
	test::@check(buffer[2] == '!');
	test::@check(buffer[3] == '!');
	test::@check(buffer[4] == '!');
	test::@check(!read_op.header.active());
	test::@check(accepted.active_read == null);

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

struct ReadReuseCtx
{
	tcp::ReadOp* op;
	char[] next_buffer;
	Ref stale_ref;
	Ref reused_ref;
	fault stale_cancel_status;
	int calls;
	sz[2] bytes;
	bool[2] op_active;
	char[2] first_byte;
	bool stale_cancel_succeeded;
}

fn void on_read_reuse_same_op(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	ReadReuseCtx* ctx = (ReadReuseCtx*)userdata;
	int index         = ctx.calls;
	ctx.bytes[index] = result.bytes;
	ctx.op_active[index] = op.header.active();
	if (result.bytes > 0) ctx.first_byte[index] = result.buffer[0];
	ctx.calls++;

	if (ctx.calls == 1)
	{
		ctx.reused_ref = tcp::read(loop, stream, ctx.next_buffer, ctx.op, { }, &on_read_reuse_same_op, ctx)!!;
		fault err = @catch(op::cancel_ref(loop, ctx.stale_ref));
		if (err)
		{
			ctx.stale_cancel_status = err;
			return;
		}
		ctx.stale_cancel_succeeded = true;
	}
}

fn void test_tcp_read_callback_can_reuse_same_op_zero_allocates() @test
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
	ReadReuseCtx ctx    = { .op = &read_op };
	NativeHandle client = (NativeHandle)-1;
	char[5] first_buffer;
	char[5] second_buffer;
	char[10] payload    = { 'h', 'e', 'l', 'l', 'o', 'w', 'o', 'r', 'l', 'd' };
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;
	ctx.next_buffer = second_buffer[0:5];

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	ctx.stale_ref = tcp::read(&loop, &accepted, first_buffer[0:5], &read_op, { }, &on_read_reuse_same_op, &ctx)!!;
	test::eq((sz)10, libc::send((Fd)client, payload[0:10].ptr, (usz)payload.len, 0));
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.calls);
	test::eq((sz)5, ctx.bytes[0]);
	test::eq((sz)5, ctx.bytes[1]);
	test::@check(!ctx.op_active[0]);
	test::@check(!ctx.op_active[1]);
	test::@check(ctx.stale_cancel_status == NOT_FOUND);
	test::@check(!ctx.stale_cancel_succeeded);
	test::@check(!read_op.header.matches(ctx.stale_ref));
	test::@check(read_op.header.matches(ctx.reused_ref));
	test::@error(op::cancel_ref(&loop, ctx.reused_ref), NOT_FOUND);
	test::@check(ctx.first_byte[0] == 'h');
	test::@check(ctx.first_byte[1] == 'w');
	test::@check(!read_op.header.active());
	test::@check(accepted.active_read == null);
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
fn void test_tcp_read_rejects_min_bytes_larger_than_buffer() @test
{
	Loop loop;
	Stream stream;
	tcp::ReadOp read_op;
	ReadSeen seen;
	char[4] buffer;

	loop.init({ .max_events = 4 })!!;
	stream.init()!!;
	stream.open = true;

	test::@error(
		tcp::read(&loop, &stream, buffer[0:4], &read_op, { .min_bytes = 5 }, &on_read_seen, &seen),
		nova::INVALID_STATE
	);
	test::@check(!read_op.header.active());
	test::@check(stream.active_read == null);

	tcp::stream_close_now(&stream)!!;
	stream.destroy();
	loop.destroy();
}

fn void test_tcp_try_write_delivers_payload_without_operation() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	NativeHandle client = (NativeHandle)-1;
	char[5] payload     = { 't', 'r', 'y', '!', '!' };
	char[8] received;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq((sz)0, accepted.write_queue_size());
	test::eq((sz)5, accepted.try_write(payload[0:5])!!);
	test::eq((sz)0, accepted.write_queue_size());
	test::eq((sz)5, libc::recv((Fd)client, received[0:8].ptr, (usz)received.len, 0));
	test::@check(received[0] == 't');
	test::@check(received[1] == 'r');
	test::@check(received[2] == 'y');
	test::@check(received[3] == '!');
	test::@check(received[4] == '!');

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_write_async_dispatches_payload_and_zero_allocates() @test
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
	tcp::WriteOp busy_op;
	WriteSeen write_seen;
	NativeHandle client = (NativeHandle)-1;
	char[5] payload     = { 'h', 'e', 'l', 'l', 'o' };
	char[8] received;
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

	Ref oref = tcp::write(&loop, &accepted, payload[0:5], &write_op, { }, &on_write_seen, &write_seen)!!;
	test::@check(write_op.header.matches(oref));
	test::@check(accepted.active_write == &write_op.header);
	if (loop.stream_write_completion())
	{
		test::eq((sz)5, accepted.write_queue_size());
	}
	else
	{
		test::eq((sz)0, accepted.write_queue_size());
	}
	test::@error(accepted.try_write(payload[0:5]), nova::BUSY);
	test::@error(tcp::write(&loop, &accepted, payload[0:5], &busy_op, { }, &on_write_seen, &write_seen), nova::BUSY);

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::@check(write_seen.stream_open);
	test::eq((sz)5, write_seen.bytes);
	test::@check(!write_op.header.active());
	test::@check(accepted.active_write == null);
	test::eq(allocation_count, tracker.total_allocation_count());

	test::eq((sz)5, libc::recv((Fd)client, received[0:8].ptr, (usz)received.len, 0));
	test::@check(received[0] == 'h');
	test::@check(received[1] == 'e');
	test::@check(received[2] == 'l');
	test::@check(received[3] == 'l');
	test::@check(received[4] == 'o');

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_tcp_large_write_drains_fully_with_single_completion() @test
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

	tcp::write(
		&loop,
		&accepted,
		tcp_stale_hangup_write_payload[0:TCP_STALE_HANGUP_WRITE_SIZE],
		&write_op,
		{ },
		&on_write_seen,
		&write_seen
	)!!;

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
	test::@check(!write_op.header.active());
	test::@check(accepted.active_write == null);
	test::eq((sz)0, accepted.write_queue_size());
	test::eq(TCP_STALE_HANGUP_WRITE_SIZE, total_received);

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_write_callback_can_close_now_zero_allocates() @test
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
	char[5] payload     = { 'h', 'e', 'l', 'l', 'o' };
	char[8] received;
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

	Ref oref = tcp::write(&loop, &accepted, payload[0:5], &write_op, { }, &on_write_close_now, &write_seen)!!;
	test::@check(write_op.header.matches(oref));
	test::@check(accepted.active_write == &write_op.header);

	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::@check(write_seen.stream_open);
	test::@check(!write_seen.op_active);
	test::eq((sz)5, write_seen.bytes);
	test::@check(!write_op.header.active());
	test::@check(accepted.active_write == null);
	test::@check(!accepted.is_open());
	test::eq(allocation_count, tracker.total_allocation_count());

	test::eq((sz)5, libc::recv((Fd)client, received[0:8].ptr, (usz)received.len, 0));
	test::@check(received[0] == 'h');
	test::@check(received[1] == 'e');
	test::@check(received[2] == 'l');
	test::@check(received[3] == 'l');
	test::@check(received[4] == 'o');

	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

struct WriteCloseAcceptCtx
{
	tcp::Listener* listener;
	tcp::Stream* stream;
	tcp::AcceptOp* accept_op;
	AcceptSeen* accept_seen;
	bool write_op_active;
	bool accept_submitted;
	fault accept_submit_status;
}

fn void on_write_close_and_accept_same_slot(
	Loop* loop,
	tcp::Stream* stream,
	tcp::WriteOp* op,
	tcp::WriteResult* result,
	void* userdata
)
{
	(void)result;
	WriteCloseAcceptCtx* ctx = (WriteCloseAcceptCtx*)userdata;
	ctx.write_op_active = op.header.active();
	tcp::stream_close_now(stream)!!;
	fault err = @catch(tcp::accept(loop, ctx.listener, ctx.stream, ctx.accept_op, &on_accept_seen, ctx.accept_seen));
	if (err)
	{
		ctx.accept_submit_status = err;
		return;
	}
	ctx.accept_submitted = true;
}

fn void test_tcp_write_callback_can_close_and_reaccept_same_slot_zero_allocates() @test
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
	WriteCloseAcceptCtx ctx = {
		.listener = &listener,
		.stream = &accepted,
		.accept_op = &accept_op,
		.accept_seen = &accept_seen,
	};
	NativeHandle client1 = (NativeHandle)-1;
	NativeHandle client2 = (NativeHandle)-1;
	char[5] payload      = { 'h', 'e', 'l', 'l', 'o' };
	defer if ((int)client1 >= 0) (void)libc::close((int)client1);
	defer if ((int)client2 >= 0) (void)libc::close((int)client2);

	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client1 = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, accept_seen.calls);
	test::@check(accepted.is_open());

	tcp::write(&loop, &accepted, payload[0:5], &write_op, { }, &on_write_close_and_accept_same_slot, &ctx)!!;
	nova::run(&loop, RunMode.ONCE)!!;
	test::@check(!ctx.write_op_active);
	test::@check(ctx.accept_submitted);
	test::@check(!ctx.accept_submit_status);
	test::@check(!accepted.is_open());
	test::@check(!write_op.header.active());
	test::@check(accept_op.header.active());

	client2 = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(2, accept_seen.calls);
	test::@check(accepted.is_open());
	test::@check(!accept_op.header.active());
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_tcp_shutdown_send_reports_eof_to_peer() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	NativeHandle client = (NativeHandle)-1;
	char[1] byte;
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

	tcp::shutdown(&accepted, ShutdownMode.SEND)!!;
	test::eq((sz)0, libc::recv((Fd)client, byte[0:1].ptr, (usz)byte.len, 0));
	test::@check(accepted.is_open());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_write_after_shutdown_send_is_rejected() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::WriteOp write_op;
	NativeHandle client = (NativeHandle)-1;
	char[4] payload     = { 'p', 'i', 'n', 'g' };
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

	tcp::shutdown(&accepted, ShutdownMode.SEND)!!;
	test::@check(accepted.send_shutdown);
	tcp::shutdown(&accepted, ShutdownMode.SEND)!!;
	test::@error(
		tcp::write(&loop, &accepted, payload[0:payload.len], &write_op, { }, &on_write_seen, null),
		nova::CONNECTION_RESET
	);
	test::@check(!write_op.header.active());
	test::@check(accepted.active_write == null);
	test::@check(accepted.is_open());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_read_after_shutdown_recv_is_rejected() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadOp read_op;
	NativeHandle client = (NativeHandle)-1;
	char[4] buffer;
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

	tcp::shutdown(&accepted, ShutdownMode.RECV)!!;
	test::@check(accepted.recv_shutdown);
	tcp::shutdown(&accepted, ShutdownMode.RECV)!!;
	test::@error(
		tcp::read(&loop, &accepted, buffer[0:buffer.len], &read_op, { }, &on_read_seen, null),
		nova::CONNECTION_RESET
	);
	test::@check(!read_op.header.active());
	test::@check(accepted.active_read == null);
	test::@check(accepted.is_open());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_shutdown_send_then_recv_marks_both_halves() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
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
	test::@check(accepted.is_open());

	tcp::shutdown(&accepted, ShutdownMode.SEND)!!;
	test::@check(accepted.send_shutdown);
	test::@check(!accepted.recv_shutdown);

	tcp::shutdown(&accepted, ShutdownMode.RECV)!!;
	test::@check(accepted.send_shutdown);
	test::@check(accepted.recv_shutdown);
	test::@check(accepted.is_open());

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

bool tcp_sigpipe_was_delivered;

fn void tcp_record_sigpipe(CInt signum)
{
	(void)signum;
	tcp_sigpipe_was_delivered = true;
}

fn void test_tcp_write_to_closed_peer_does_not_raise_sigpipe() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::WriteOp write_op;
	WriteSeen write_seen;
	NativeHandle client = (NativeHandle)-1;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	tcp_sigpipe_was_delivered = false;
	SignalFunction previous = libc::signal(libc::SIGPIPE, &tcp_record_sigpipe);
	defer (void)libc::signal(libc::SIGPIPE, previous);

	loop.init({ .max_events = 4 })!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	accepted.init()!!;

	tcp::accept(&loop, &listener, &accepted, &accept_op, &on_accept_seen, &accept_seen)!!;
	client = connect_loopback(listener.local.port)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::@check(accepted.is_open());

	(void)libc::close((int)client);
	client = (NativeHandle)-1;

	tcp::write(
		&loop,
		&accepted,
		tcp_stale_hangup_write_payload[0:TCP_STALE_HANGUP_WRITE_SIZE],
		&write_op,
		{ },
		&on_write_seen,
		&write_seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, write_seen.calls);
	test::@check(write_op.written < TCP_STALE_HANGUP_WRITE_SIZE);
	test::@check(!tcp_sigpipe_was_delivered);

	if (catch tcp::stream_close_now(&accepted))
	{
	}
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}

fn void test_tcp_write_succeeds_after_peer_half_close_eof() @test
{
	Loop loop;
	Listener listener;
	Stream accepted;
	tcp::AcceptOp accept_op;
	AcceptSeen accept_seen;
	tcp::ReadOp read_op;
	ReadSeen read_seen;
	tcp::WriteOp write_op;
	WriteSeen write_seen;
	char[16] rbuf;
	char[5] payload     = { 'h', 'e', 'l', 'l', 'o' };
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
	test::@check(accepted.is_open());

	test::eq((CInt)0, libc::shutdown((Fd)client, libc::SHUT_WR));
	tcp::read(&loop, &accepted, rbuf[0:16], &read_op, { }, &on_read_seen, &read_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, read_seen.calls);
	test::@check(read_seen.eof);

	tcp::write(&loop, &accepted, payload[0:5], &write_op, { }, &on_write_seen, &write_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::eq((sz)5, write_seen.bytes);

	tcp::stream_close_now(&accepted)!!;
	accepted.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
}
