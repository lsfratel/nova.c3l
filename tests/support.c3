module nova_tests;

import std::net::os;
import std::os::linux;
import std::thread;
import libc;

import nova @norecurse, nova::net, nova::net::tcp, nova::net::udp, nova::timer, nova::watch;

<*
 Native `pollfd` and `poll` binding used by readiness wait helpers.

 macOS loopback delivery is not synchronous: data written into one socket is not
 guaranteed to be readable from its peer the instant `send`/`close` returns. Test
 helpers poll for readiness so assertions about inline readiness are deterministic
 instead of racing loopback delivery.
*>
struct TestPollFd
{
	CInt fd;
	CShort events;
	CShort revents;
}

const CShort TEST_POLLIN  = (CShort)0x0001;
const CShort TEST_POLLHUP = (CShort)0x0010;

extern fn CInt poll(TestPollFd* fds, usz nfds, CInt timeout);

const os::AIProtocol TEST_IPPROTO_TCP = (os::AIProtocol)6;
const os::AIProtocol TEST_IPPROTO_UDP = (os::AIProtocol)17;

extern fn sz sendto(
	Fd socket,
	void* buffer,
	usz length,
	CInt flags,
	os::SockAddrPtr address,
	os::Socklen_t address_len
);

struct TestSockAddrIn
{
	ushort family;
	ushort port;
	char[4] address;
	char[8] zero;
}

fn ushort test_htons(ushort port)
{
	$if env::LINUX:
		return linux::htons(port);
	$else
		return net::htons(port);
	$endif
}

fn void on_accept(Loop* loop, tcp::Listener* listener, tcp::AcceptOp* op, tcp::AcceptResult* result, void* userdata)
{
	(void)loop;
	(void)listener;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_accept_seen(
	Loop* loop,
	tcp::Listener* listener,
	tcp::AcceptOp* op,
	tcp::AcceptResult* result,
	void* userdata
)
{
	(void)loop;
	(void)listener;
	AcceptSeen* seen = (AcceptSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.op_active = op.header.active();
	seen.stream = result.stream;
	seen.stream_open = result.stream != null && result.stream.is_open();
	seen.peer_family = result.peer.family;
	seen.peer_port = result.peer.port;
}

fn void on_connect(Loop* loop, tcp::Stream* stream, tcp::ConnectOp* op, tcp::ConnectResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_connect_seen(Loop* loop, tcp::Stream* stream, tcp::ConnectOp* op, tcp::ConnectResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	ConnectSeen* seen = (ConnectSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.op_active = op.header.active();
	seen.stream = result.stream;
	seen.stream_open = result.stream != null && result.stream.is_open();
}

fn void on_read(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_read_seen(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)loop;
	ReadSeen* seen = (ReadSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.op_active = op.header.active();
	seen.stream_open = stream.is_open();
	seen.buffer = result.buffer;
	seen.bytes = result.bytes;
	seen.eof = result.eof;
}

fn void on_write(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_write_seen(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)loop;
	WriteSeen* seen = (WriteSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.stream_open = stream.is_open();
	seen.bytes = result.bytes;
	seen.op_active = op.header.active();
}

fn void on_write_close_now(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	on_write_seen(loop, stream, op, result, userdata);
	tcp::stream_close_now(stream)!!;
}

fn void on_stream_close(Loop* loop, tcp::Stream* stream, tcp::StreamCloseOp* op, CloseResult* result, void* userdata)
{
	(void)loop;
	(void)stream;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_stream_close_seen(
	Loop* loop,
	tcp::Stream* stream,
	tcp::StreamCloseOp* op,
	CloseResult* result,
	void* userdata
)
{
	(void)loop;
	CloseSeen* seen = (CloseSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.op_active = op.header.active();
	seen.stream_open = stream.is_open();
}

fn void on_listener_close(
	Loop* loop,
	tcp::Listener* listener,
	tcp::ListenerCloseOp* op,
	CloseResult* result,
	void* userdata
)
{
	(void)loop;
	(void)listener;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_listener_close_seen(
	Loop* loop,
	tcp::Listener* listener,
	tcp::ListenerCloseOp* op,
	CloseResult* result,
	void* userdata
)
{
	(void)loop;
	CloseSeen* seen = (CloseSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.op_active = op.header.active();
	seen.listener_open = listener.is_open();
}

fn void on_udp_recv(Loop* loop, udp::Socket* socket, udp::RecvOp* op, udp::RecvResult* result, void* userdata)
{
	(void)loop;
	(void)socket;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_udp_recv_seen(Loop* loop, udp::Socket* socket, udp::RecvOp* op, udp::RecvResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	UdpRecvSeen* seen = (UdpRecvSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.socket_open = socket.is_open();
	seen.buffer = result.buffer;
	seen.bytes = result.bytes;
	seen.peer_family = result.peer.family;
	seen.peer_port = result.peer.port;
	seen.truncated = result.truncated;
}

fn void on_udp_send(Loop* loop, udp::Socket* socket, udp::SendOp* op, udp::SendResult* result, void* userdata)
{
	(void)loop;
	(void)socket;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_udp_send_seen(Loop* loop, udp::Socket* socket, udp::SendOp* op, udp::SendResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	UdpSendSeen* seen = (UdpSendSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.socket_open = socket.is_open();
	seen.bytes = result.bytes;
}

fn void on_udp_close(Loop* loop, udp::Socket* socket, udp::SocketCloseOp* op, CloseResult* result, void* userdata)
{
	(void)loop;
	(void)socket;
	(void)op;
	(void)result;
	(void)userdata;
}

fn void on_udp_close_seen(Loop* loop, udp::Socket* socket, udp::SocketCloseOp* op, CloseResult* result, void* userdata)
{
	(void)loop;
	UdpCloseSeen* seen = (UdpCloseSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.socket_open = socket.is_open();
	seen.op_active = op.header.active();
}

fn void on_timer(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	TimerSeen* seen = (TimerSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.expirations = result.expirations;
	seen.total_expirations += result.expirations;
}

fn void on_timer_stop(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	on_timer(loop, op, result, userdata);
	loop.stop();
}

fn void on_timer_stop_self(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	on_timer(loop, op, result, userdata);
	timer::stop(loop, op)!!;
}

fn void on_timer_stop_after_three(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	on_timer(loop, op, result, userdata);
	TimerSeen* seen = (TimerSeen*)userdata;
	if (seen.calls >= 3) timer::stop(loop, op)!!;
}

fn void on_watch(Loop* loop, watch::Watch* w, watch::WatchOp* op, watch::WatchResult* result, void* userdata)
{
	(void)loop;
	(void)w;
	(void)op;
	(void)result;
}

fn void on_watch_seen(Loop* loop, watch::Watch* w, watch::WatchOp* op, watch::WatchResult* result, void* userdata)
{
	(void)loop;
	(void)w;
	(void)op;
	WatchSeen* seen = (WatchSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.readable = result.events.readable;
	seen.writable = result.events.writable;
	seen.error = result.events.error;
	seen.hangup = result.events.hangup;
}

fn Endpoint ipv4_endpoint(ushort port)
{
	char[4] address;
	return net::endpoint_from_ipv4(port, address[0:4]);
}

fn Endpoint ipv4_loopback_endpoint(ushort port)
{
	char[4] address = { (char)127, 0, 0, 1 };
	return net::endpoint_from_ipv4(port, address[0:4]);
}

fn Endpoint ipv4_any_endpoint(ushort port)
{
	return ipv4_endpoint(port);
}

fn Endpoint ipv6_loopback_endpoint(ushort port)
{
	char[16] address;
	address[15] = 1;
	return net::endpoint_from_ipv6(port, address[0:16]);
}

fn Endpoint ipv4_multicast_endpoint(ushort port)
{
	char[4] address = { (char)239, (char)255, 0, 1 };
	return net::endpoint_from_ipv4(port, address[0:4]);
}

fn Endpoint ipv6_multicast_endpoint(ushort port)
{
	char[16] address;
	address[0] = (char)0xff;
	address[15] = 1;
	return net::endpoint_from_ipv6(port, address[0:16]);
}

fn NativeHandle? connect_loopback(ushort port)
{
	os::NativeSocket fd = os::socket(os::AF_INET, os::SOCK_STREAM, TEST_IPPROTO_TCP);
	if (!fd.is_valid()) return nova::BACKEND_FAILED~;

	bool retained = false;
	defer if (!retained) (void)fd.close();

	TestSockAddrIn address = {
		.family = (ushort)os::AF_INET,
		.port = test_htons(port),
		.address = { (char)127, 0, 0, 1 },
		.zero = { },
	};
	if (os::connect(
		fd,
		(os::SockAddrPtr)&address,
		(os::Socklen_t)TestSockAddrIn::size
	) != 0) return nova::BACKEND_FAILED~;

	retained = true;
	return (NativeHandle)(int)fd;
}

fn void? send_udp_loopback(ushort port, char[] payload)
{
	os::NativeSocket fd = os::socket(os::AF_INET, os::SOCK_DGRAM, TEST_IPPROTO_UDP);
	if (!fd.is_valid()) return nova::BACKEND_FAILED~;
	defer (void)fd.close();

	TestSockAddrIn address = {
		.family = (ushort)os::AF_INET,
		.port = test_htons(port),
		.address = { (char)127, 0, 0, 1 },
		.zero = { },
	};

	bool done = false;
	while (!done)
	{
		sz sent = sendto(
			(Fd)fd,
			payload.ptr,
			(usz)payload.len,
			0,
			(os::SockAddrPtr)&address,
			(os::Socklen_t)TestSockAddrIn::size
		);
		if (sent == (sz)payload.len)
		{
			done = true;
			continue;
		}
		if (sent < 0 && libc::errno() == EINTR) continue;
		return nova::BACKEND_FAILED~;
	}
}

fn sz? recv_udp_now(NativeHandle handle, char[] buffer)
{
	for (int attempt = 0; attempt < 1000; attempt++)
	{
		sz received = libc::recv((Fd)handle, buffer.ptr, (usz)buffer.len, 0);
		if (received >= 0) return received;
		Errno err = libc::errno();
		if (err == EINTR) continue;
		if (err == EAGAIN || err == EWOULDBLOCK)
		{
			(void)thread::sleep_ms(1);
			continue;
		}
		return nova::BACKEND_FAILED~;
	}
	return nova::BACKEND_FAILED~;
}

<*
 Block until a native descriptor is readable, or a bounded retry budget elapses.

 Used after writing into a socket's peer so subsequent inline-read assertions see
 buffered data instead of racing loopback delivery on platforms where it is async.

 @param handle : "Native descriptor to poll for readability"
*>
fn void wait_native_readable(NativeHandle handle)
{
	TestPollFd pfd = { .fd = (CInt)(int)handle, .events = TEST_POLLIN };
	for (int attempt = 0; attempt < 1000; attempt++)
	{
		pfd.revents = 0;
		CInt ready = poll(&pfd, 1, 0);
		if (ready > 0 && (pfd.revents & (TEST_POLLIN | TEST_POLLHUP)) != 0) return;
		(void)thread::sleep_ms(1);
	}
}

<*
 Read exactly `count` bytes from a blocking native descriptor, or stop at EOF.

 TCP delivers a byte stream, so separate peer writes can arrive as separate
 segments; a single `recv` may return fewer bytes than were written. This drains
 until the requested count is read so ordering assertions are deterministic.

 @param handle : "Blocking native descriptor"
 @param [out] buffer : "Destination bytes, at least `count` long"
 @param count : "Number of bytes to read"
 @return "Bytes read, which is `count` unless EOF arrives first"
 @return ? nova::BACKEND_FAILED : "recv failed"
*>
fn sz? recv_native_exact(NativeHandle handle, char[] buffer, sz count)
{
	sz total = 0;
	while (total < count)
	{
		sz received = libc::recv((Fd)handle, buffer.ptr + total, (usz)(count - total), 0);
		if (received > 0)
		{
			total += received;
			continue;
		}
		if (received == 0) return total;
		if (libc::errno() == EINTR) continue;
		return nova::BACKEND_FAILED~;
	}
	return total;
}

struct TimerSeen
{
	int calls;
	fault status;
	ulong expirations;
	ulong total_expirations;
}

struct WatchSeen
{
	int calls;
	fault status;
	bool readable;
	bool writable;
	bool error;
	bool hangup;
}

struct AcceptSeen
{
	int calls;
	fault status;
	bool op_active;
	bool stream_open;
	tcp::Stream* stream;
	AddressFamily peer_family;
	ushort peer_port;
}

struct ConnectSeen
{
	int calls;
	fault status;
	bool op_active;
	bool stream_open;
	tcp::Stream* stream;
}

struct ReadSeen
{
	int calls;
	fault status;
	bool op_active;
	bool stream_open;
	char[] buffer;
	sz bytes;
	bool eof;
}

struct WriteSeen
{
	int calls;
	fault status;
	bool stream_open;
	bool op_active;
	sz bytes;
}

struct CloseSeen
{
	int calls;
	fault status;
	bool op_active;
	bool stream_open;
	bool listener_open;
}

struct UdpRecvSeen
{
	int calls;
	fault status;
	bool socket_open;
	char[] buffer;
	sz bytes;
	AddressFamily peer_family;
	ushort peer_port;
	bool truncated;
}

struct UdpSendSeen
{
	int calls;
	fault status;
	bool socket_open;
	sz bytes;
}

struct UdpCloseSeen
{
	int calls;
	fault status;
	bool socket_open;
	bool op_active;
}
