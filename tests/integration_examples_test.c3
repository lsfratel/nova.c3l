module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import libc;

import nova @norecurse, nova::buffer, nova::net, nova::net::tcp, nova::net::udp;

const String HTTP_HELLO_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world";

struct EchoExample
{
	TcpExampleSlot* slot;
	int accept_calls;
	int read_calls;
	int write_calls;
	fault status;
	sz bytes;
}

struct HttpExample
{
	TcpExampleSlot* slot;
	String response;
	int accept_calls;
	int read_calls;
	int write_calls;
	fault status;
}

struct UdpPoolExample
{
	buffer::Lease lease;
	int recv_calls;
	fault status;
	sz bytes;
	bool released;
	char first;
}

struct TcpExampleSlot
{
	tcp::Stream stream;
	tcp::ReadOp read_op;
	tcp::WriteOp write_op;
	char[] read_buffer;
}

fn void on_echo_accept(
	Loop* loop,
	tcp::Listener* listener,
	tcp::AcceptOp* op,
	tcp::AcceptResult* result,
	void* userdata
)
{
	(void)listener;
	(void)op;
	EchoExample* example = (EchoExample*)userdata;
	example.accept_calls++;
	example.status = result.error.status;
	if (!result.error.status)
	{
		TcpExampleSlot* slot = example.slot;
		tcp::read(loop, &slot.stream, slot.read_buffer, &slot.read_op, { }, &on_echo_read, example)!!;
	}
}

fn void on_echo_read(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)op;
	EchoExample* example = (EchoExample*)userdata;
	example.read_calls++;
	example.status = result.error.status;
	example.bytes = result.bytes;
	if (!result.error.status && !result.eof && result.bytes > 0)
	{
		TcpExampleSlot* slot = example.slot;
		tcp::write(loop, stream, result.buffer[0:result.bytes], &slot.write_op, { }, &on_echo_write, example)!!;
	}
}

fn void on_echo_write(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	EchoExample* example = (EchoExample*)userdata;
	example.write_calls++;
	example.status = result.error.status;
	example.bytes = result.bytes;
}

fn void on_http_accept(
	Loop* loop,
	tcp::Listener* listener,
	tcp::AcceptOp* op,
	tcp::AcceptResult* result,
	void* userdata
)
{
	(void)listener;
	(void)op;
	HttpExample* example = (HttpExample*)userdata;
	example.accept_calls++;
	example.status = result.error.status;
	if (!result.error.status)
	{
		TcpExampleSlot* slot = example.slot;
		tcp::read(loop, &slot.stream, slot.read_buffer, &slot.read_op, { }, &on_http_read, example)!!;
	}
}

fn void on_http_read(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)op;
	HttpExample* example = (HttpExample*)userdata;
	example.read_calls++;
	example.status = result.error.status;
	if (!result.error.status && !result.eof)
	{
		TcpExampleSlot* slot = example.slot;
		tcp::write(loop, stream, example.response, &slot.write_op, { }, &on_http_write, example)!!;
	}
}

fn void on_http_write(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	HttpExample* example = (HttpExample*)userdata;
	example.write_calls++;
	example.status = result.error.status;
}

fn void on_udp_pool_recv(Loop* loop, udp::Socket* socket, udp::RecvOp* op, udp::RecvResult* result, void* userdata)
{
	(void)loop;
	(void)socket;
	(void)op;
	UdpPoolExample* example = (UdpPoolExample*)userdata;
	example.recv_calls++;
	example.status = result.error.status;
	example.bytes = result.bytes;
	if (!result.error.status && result.bytes > 0) example.first = result.buffer[0];
	buffer::release(&example.lease)!!;
	example.released = true;
}

fn void test_example_tcp_echo_with_caller_owned_slot_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	tcp::Listener listener;
	TcpExampleSlot slot;
	tcp::AcceptOp accept_op;
	EchoExample example;
	NativeHandle client = (NativeHandle)-1;
	String payload      = "ping";
	char[64] read_buffer;
	char[8] received;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 8 }, allocator)!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	slot.stream.init()!!;
	slot.read_buffer = read_buffer[0:64];

	sz allocation_count = tracker.total_allocation_count();

	example.slot = &slot;
	tcp::accept(&loop, &listener, &slot.stream, &accept_op, &on_echo_accept, &example)!!;

	client = connect_loopback(listener.local.port)!!;
	test::eq((sz)payload.len, libc::send((Fd)client, payload.ptr, (usz)payload.len, 0));
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, example.accept_calls);
	test::eq(1, example.read_calls);
	test::eq(1, example.write_calls);
	test::@check(!example.status);
	test::eq((sz)payload.len, example.bytes);
	test::eq((sz)payload.len, libc::recv((Fd)client, received[0:8].ptr, (usz)received.len, 0));
	test::@check(received[0] == 'p');
	test::@check(received[1] == 'i');
	test::@check(received[2] == 'n');
	test::@check(received[3] == 'g');
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&slot.stream)!!;
	slot.stream.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_example_http_hello_world_with_caller_owned_slot_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	tcp::Listener listener;
	TcpExampleSlot slot;
	tcp::AcceptOp accept_op;
	HttpExample example = { .response = HTTP_HELLO_RESPONSE };
	NativeHandle client = (NativeHandle)-1;
	String request      = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
	char[256] read_buffer;
	char[128] received;
	defer if ((int)client >= 0) (void)libc::close((int)client);

	loop.init({ .max_events = 8 }, allocator)!!;
	listener.init({ .reuse_addr = true })!!;
	tcp::bind(&listener, ipv4_endpoint(0))!!;
	tcp::listen(&listener)!!;
	slot.stream.init()!!;
	slot.read_buffer = read_buffer[0:256];

	sz allocation_count = tracker.total_allocation_count();

	example.slot = &slot;
	tcp::accept(&loop, &listener, &slot.stream, &accept_op, &on_http_accept, &example)!!;

	client = connect_loopback(listener.local.port)!!;
	test::eq((sz)request.len, libc::send((Fd)client, request.ptr, (usz)request.len, 0));
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	sz received_bytes = libc::recv((Fd)client, received[0:128].ptr, (usz)received.len, 0);
	test::eq((sz)HTTP_HELLO_RESPONSE.len, received_bytes);
	test::eq(1, example.accept_calls);
	test::eq(1, example.read_calls);
	test::eq(1, example.write_calls);
	test::@check(!example.status);
	test::@check(received[0] == 'H');
	test::@check(received[8] == ' ');
	test::@check(received[HTTP_HELLO_RESPONSE.len - 11] == 'h');
	test::@check(received[HTTP_HELLO_RESPONSE.len - 1] == 'd');
	test::eq(allocation_count, tracker.total_allocation_count());

	tcp::stream_close_now(&slot.stream)!!;
	slot.stream.destroy();
	tcp::listener_close_now(&listener)!!;
	listener.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_example_udp_receive_with_buffer_pool_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	Loop loop;
	udp::Socket socket;
	udp::RecvOp recv_op;
	buffer::Pool buffers;
	UdpPoolExample example;
	char[5] payload     = { 'h', 'e', 'l', 'l', 'o' };

	loop.init({ .max_events = 4 }, allocator)!!;
	socket.init({ .reuse_addr = true })!!;
	udp::bind(&socket, ipv4_loopback_endpoint(0))!!;
	buffers.init(1, 16, allocator)!!;

	sz allocation_count = tracker.total_allocation_count();

	example.lease = buffer::acquire(&buffers)!!;
	udp::recv(&loop, &socket, example.lease.bytes, &recv_op, &on_udp_pool_recv, &example)!!;
	send_udp_loopback(socket.local.port, payload[0:5])!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, example.recv_calls);
	test::@check(!example.status);
	test::eq((sz)5, example.bytes);
	test::@check(example.first == 'h');
	test::@check(example.released);
	test::eq((sz)1, buffers.available());
	test::eq(allocation_count, tracker.total_allocation_count());

	buffers.destroy();
	udp::close_now(&socket)!!;
	socket.destroy();
	loop.destroy();
	test::@check(!tracker.has_leaks());
}
