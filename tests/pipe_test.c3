module nova_tests;

import std::core::mem::allocators;
import std::core::test;
import std::os::posix;
import libc;

import nova @norecurse, nova::op @public, nova::pipe;

const sz PARTIAL_WRITE_PAYLOAD_SIZE = 1_048_576;

char[PARTIAL_WRITE_PAYLOAD_SIZE] partial_write_payload;

struct PipeReadSeen
{
	char[] buffer;
	fault status;
	int calls;
	sz bytes;
	bool endpoint_open;
	bool eof;
	bool op_active;
}

struct PipeWriteSeen
{
	fault status;
	int calls;
	sz bytes;
	bool endpoint_open;
	bool op_active;
}

struct PipeCloseSeen
{
	fault status;
	int calls;
	bool endpoint_open;
	bool op_active;
}

fn void on_pipe_read_seen(
	Loop* loop,
	pipe::Endpoint* endpoint,
	pipe::ReadOp* op,
	pipe::ReadResult* result,
	void* userdata
)
{
	(void)loop;
	PipeReadSeen* seen = (PipeReadSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.bytes = result.bytes;
	seen.eof = result.eof;
	seen.buffer = result.buffer;
	seen.endpoint_open = endpoint.is_open();
	seen.op_active = op.header.active();
}

fn void on_pipe_write_seen(
	Loop* loop,
	pipe::Endpoint* endpoint,
	pipe::WriteOp* op,
	pipe::WriteResult* result,
	void* userdata
)
{
	(void)loop;
	PipeWriteSeen* seen = (PipeWriteSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.bytes = result.bytes;
	seen.endpoint_open = endpoint.is_open();
	seen.op_active = op.header.active();
}

fn void on_pipe_close_seen(
	Loop* loop,
	pipe::Endpoint* endpoint,
	pipe::EndpointCloseOp* op,
	CloseResult* result,
	void* userdata
)
{
	(void)loop;
	PipeCloseSeen* seen = (PipeCloseSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.endpoint_open = endpoint.is_open();
	seen.op_active = op.header.active();
}

fn void test_pipe_pair_open_close_now() @test
{
	pipe::Pair pair;

	pair.open()!!;
	test::@check(pair.read.is_open());
	test::@check(pair.write.is_open());
	test::@check(pair.read.direction == pipe::Direction.READ);
	test::@check(pair.write.direction == pipe::Direction.WRITE);

	pipe::close_now(&pair.read)!!;
	pipe::close_now(&pair.write)!!;
	test::@check(!pair.read.is_open());
	test::@check(!pair.write.is_open());
	pair.destroy();
}

fn void test_pipe_endpoint_adopt_owned_handle_close_now() @test
{
	CInt[2] fds;
	pipe::Endpoint endpoint;

	test::eq((CInt)0, posix::pipe(&fds));
	(void)libc::close(fds[1]);

	endpoint.adopt((NativeHandle)(int)fds[0], { .owns_handle = true, .direction = pipe::Direction.READ })!!;
	test::@check(endpoint.is_open());
	test::eq((NativeHandle)(int)fds[0], endpoint.borrow_native()!!);

	pipe::close_now(&endpoint)!!;
	test::@check(!endpoint.is_open());
	test::eq((CInt)-1, libc::close(fds[0]));
	endpoint.destroy();
}

fn void test_pipe_endpoint_adopt_borrowed_handle_close_now() @test
{
	CInt[2] fds;
	pipe::Endpoint endpoint;

	test::eq((CInt)0, posix::pipe(&fds));
	(void)libc::close(fds[1]);

	endpoint.adopt((NativeHandle)(int)fds[0], { .owns_handle = false, .direction = pipe::Direction.READ })!!;
	test::@check(endpoint.is_open());
	test::eq((NativeHandle)(int)fds[0], endpoint.borrow_native()!!);

	pipe::close_now(&endpoint)!!;
	test::@check(!endpoint.is_open());
	test::eq((CInt)0, libc::close(fds[0]));
	endpoint.destroy();
}

fn void test_pipe_endpoint_adopt_rejects_closed_handle() @test
{
	CInt[2] fds;
	pipe::Endpoint endpoint;

	test::eq((CInt)0, posix::pipe(&fds));
	(void)libc::close(fds[0]);
	(void)libc::close(fds[1]);

	test::@error(
		endpoint.adopt((NativeHandle)(int)fds[0], { .owns_handle = false, .direction = pipe::Direction.READ }),
		nova::INVALID_SOCKET
	);
	test::@check(!endpoint.is_open());
}

fn void test_pipe_endpoint_adopt_rejects_reserved_duplex_direction() @test
{
	CInt[2] fds;
	pipe::Endpoint endpoint;

	test::eq((CInt)0, posix::pipe(&fds));
	(void)libc::close(fds[1]);

	test::@error(
		endpoint.adopt((NativeHandle)(int)fds[0], { .owns_handle = false, .direction = pipe::Direction.DUPLEX }),
		nova::INVALID_STATE
	);
	test::@check(!endpoint.is_open());
	test::eq((CInt)0, libc::close(fds[0]));
}

fn void test_pipe_read_write_roundtrip_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	pipe::Pair pair;
	pipe::ReadOp read_op;
	pipe::WriteOp write_op;
	PipeReadSeen read_seen;
	PipeWriteSeen write_seen;
	char[8] buffer;
	char[5] payload     = { 'h', 'e', 'l', 'l', 'o' };

	pair.open()!!;
	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	pipe::read(&loop, &pair.read, buffer[0:8], &read_op, { }, &on_pipe_read_seen, &read_seen)!!;
	pipe::write(&loop, &pair.write, payload[0:5], &write_op, { }, &on_pipe_write_seen, &write_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::eq((sz)5, write_seen.bytes);
	test::@check(!write_seen.op_active);
	test::@check(write_seen.endpoint_open);
	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)5, read_seen.bytes);
	test::@check(!read_seen.eof);
	test::@check(!read_seen.op_active);
	test::@check(read_seen.endpoint_open);
	test::@check(buffer[0] == 'h');
	test::@check(buffer[1] == 'e');
	test::@check(buffer[2] == 'l');
	test::@check(buffer[3] == 'l');
	test::@check(buffer[4] == 'o');
	test::eq(allocation_count, tracker.total_allocation_count());

	pipe::close_now(&pair.read)!!;
	pipe::close_now(&pair.write)!!;
	pair.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_pipe_registered_watcher_rejects_other_loop() @test
{
	Loop loop_a;
	Loop loop_b;
	pipe::Pair pair;
	pipe::ReadOp read_op;
	pipe::ReadOp other_read_op;
	PipeReadSeen read_seen;
	PipeReadSeen other_seen;
	char[1] buffer;
	char[1] other_buffer;
	char[1] payload_storage = { 'x' };
	char[] payload          = payload_storage[0:1];

	pair.open()!!;
	loop_a.init({ .max_events = 4 })!!;
	loop_b.init({ .max_events = 4 })!!;

	pipe::read(&loop_a, &pair.read, buffer[0:1], &read_op, { }, &on_pipe_read_seen, &read_seen)!!;
	NativeHandle write_handle = pair.write.borrow_native()!!;
	test::eq((sz)1, libc::write((int)write_handle, payload.ptr, (usz)payload.len));
	nova::run(&loop_a, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)1, read_seen.bytes);
	test::@check(pair.read.is_open());

	test::@error(
		pipe::read(&loop_b, &pair.read, other_buffer[0:1], &other_read_op, { }, &on_pipe_read_seen, &other_seen),
		nova::INVALID_STATE
	);
	test::@check(!other_read_op.header.active());
	test::eq(0, other_seen.calls);

	pipe::close_now(&pair.read)!!;
	pipe::close_now(&pair.write)!!;
	pair.destroy();
	loop_b.destroy();
	loop_a.destroy();
}

fn void test_pipe_read_reports_eof_after_writer_close() @test
{
	Loop loop;
	pipe::Pair pair;
	pipe::ReadOp read_op;
	PipeReadSeen read_seen;
	char[8] buffer;

	pair.open()!!;
	loop.init({ .max_events = 4 })!!;
	pipe::close_now(&pair.write)!!;

	pipe::read(&loop, &pair.read, buffer[0:8], &read_op, { }, &on_pipe_read_seen, &read_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)0, read_seen.bytes);
	test::@check(read_seen.eof);
	test::@check(!read_op.header.active());

	pipe::close_now(&pair.read)!!;
	pair.destroy();
	loop.destroy();
}

fn void test_pipe_write_after_reader_close_reports_closed() @test
{
	Loop loop;
	pipe::Pair pair;
	pipe::WriteOp write_op;
	PipeWriteSeen write_seen;
	char[5] payload = { 'c', 'l', 'o', 's', 'e' };

	pair.open()!!;
	loop.init({ .max_events = 4 })!!;
	pipe::close_now(&pair.read)!!;

	pipe::write(&loop, &pair.write, payload[0:5], &write_op, { }, &on_pipe_write_seen, &write_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, write_seen.calls);
	test::@check(write_seen.status == nova::CLOSED);
	test::eq((sz)0, write_seen.bytes);
	test::@check(!write_op.header.active());

	pipe::close_now(&pair.write)!!;
	pair.destroy();
	loop.destroy();
}

fn void test_pipe_try_write_delivers_payload_without_operation() @test
{
	pipe::Pair pair;
	char[5] payload = { 'p', 'i', 'p', 'e', '!' };
	char[8] received;

	pair.open()!!;

	test::eq((sz)0, pair.write.write_queue_size());
	test::eq((sz)5, pair.write.try_write(payload[0:5])!!);
	test::eq((sz)0, pair.write.write_queue_size());
	test::eq((sz)5, libc::read((Fd)(int)pair.read.borrow_native()!!, received[0:8].ptr, (usz)received.len));
	test::@check(received[0] == 'p');
	test::@check(received[1] == 'i');
	test::@check(received[2] == 'p');
	test::@check(received[3] == 'e');
	test::@check(received[4] == '!');

	pipe::close_now(&pair.read)!!;
	pipe::close_now(&pair.write)!!;
	pair.destroy();
}

fn void test_pipe_partial_write_reports_backend_capacity_after_progress() @test
{
	Loop loop;
	pipe::Pair pair;
	pipe::WriteOp write_op;
	PipeWriteSeen write_seen;

	pair.open()!!;
	loop.init({ .max_events = 0 })!!;

	pipe::write(
		&loop,
		&pair.write,
		partial_write_payload[0:partial_write_payload.len],
		&write_op,
		{ },
		&on_pipe_write_seen,
		&write_seen
	)!!;
	test::@check(pair.write.write_queue_size() > 0);
	test::eq(partial_write_payload.len - write_op.written, pair.write.write_queue_size());
	test::@error(pair.write.try_write(partial_write_payload[0:1]), nova::BUSY);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, write_seen.calls);
	test::@check(write_seen.status == CAPACITY_EXCEEDED);
	test::@check(write_seen.bytes > 0);
	test::@check(write_seen.bytes < partial_write_payload.len);
	test::@check(!write_seen.op_active);
	test::@check(pair.write.active_write == null);
	test::eq((sz)0, pair.write.write_queue_size());

	pipe::close_now(&pair.read)!!;
	pipe::close_now(&pair.write)!!;
	pair.destroy();
	loop.destroy();
}

fn void test_pipe_close_cancels_active_read_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	pipe::Pair pair;
	pipe::ReadOp read_op;
	pipe::EndpointCloseOp close_op;
	PipeReadSeen read_seen;
	PipeCloseSeen close_seen;
	char[8] buffer;

	pair.open()!!;
	loop.init({ .max_events = 4 }, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	pipe::read(&loop, &pair.read, buffer[0:8], &read_op, { }, &on_pipe_read_seen, &read_seen)!!;
	pipe::close(&loop, &pair.read, &close_op, { }, &on_pipe_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, read_seen.calls);
	test::@check(read_seen.status == nova::CLOSED);
	test::@check(!read_seen.op_active);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::@check(!close_seen.endpoint_open);
	test::@check(!close_seen.op_active);
	test::@check(!pair.read.is_open());
	test::@check(pair.read.active_read == null);
	test::@check(pair.read.active_close == null);
	test::eq((sz)0, loop.timer_count);
	test::eq(allocation_count, tracker.total_allocation_count());

	pipe::close_now(&pair.write)!!;
	pair.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_pipe_close_overrides_ready_immediate_write() @test
{
	Loop loop;
	pipe::Pair pair;
	pipe::WriteOp write_op;
	pipe::EndpointCloseOp close_op;
	PipeWriteSeen write_seen;
	PipeCloseSeen close_seen;
	char[1] payload = { 'x' };

	pair.open()!!;
	loop.init({ .max_events = 4 })!!;

	pipe::write(&loop, &pair.write, payload[0:1], &write_op, { }, &on_pipe_write_seen, &write_seen)!!;
	test::@check(write_op.header.active());
	test::@check(pair.write.active_write == &write_op.header);

	pipe::close(&loop, &pair.write, &close_op, { }, &on_pipe_close_seen, &close_seen)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, write_seen.calls);
	test::@check(write_seen.status == nova::CLOSED);
	test::eq((sz)1, write_seen.bytes);
	test::@check(!write_seen.op_active);
	test::eq(1, close_seen.calls);
	test::@check(!close_seen.status);
	test::@check(!pair.write.is_open());

	pipe::close_now(&pair.read)!!;
	pair.destroy();
	loop.destroy();
}

fn void test_pipe_direction_validation() @test
{
	Loop loop;
	pipe::Pair pair;
	pipe::ReadOp read_op;
	pipe::WriteOp write_op;
	PipeReadSeen read_seen;
	PipeWriteSeen write_seen;
	char[8] buffer;
	char[1] payload = { 'x' };

	pair.open()!!;
	loop.init({ .max_events = 4 })!!;

	test::@error(
		pipe::read(&loop, &pair.write, buffer[0:8], &read_op, { }, &on_pipe_read_seen, &read_seen),
		nova::INVALID_STATE
	);
	test::@error(
		pipe::write(&loop, &pair.read, payload[0:1], &write_op, { }, &on_pipe_write_seen, &write_seen),
		nova::INVALID_STATE
	);

	pipe::close_now(&pair.read)!!;
	pipe::close_now(&pair.write)!!;
	pair.destroy();
	loop.destroy();
}
