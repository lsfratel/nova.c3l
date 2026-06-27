module nova::net @if(env::LINUX);

import std::io, std::net::os, std::os::linux;
import libc;

import nova @norecurse;
import nova::posix_errno @public;

<*
 Linux protocol constants used when creating TCP and UDP sockets.
*>
const os::AIProtocol IPPROTO_TCP = (os::AIProtocol)6;
const os::AIProtocol IPPROTO_UDP = (os::AIProtocol)17;

<*
 Linux TCP socket option identifiers used by stream setup.
*>
const CInt TCP_NODELAY   = 1;
const CInt TCP_KEEPIDLE  = 4;
const CInt TCP_KEEPINTVL = 5;
const CInt TCP_KEEPCNT   = 6;

<*
 Linux message flags used by TCP send, UDP send and UDP receive paths.
*>
const CInt MSG_NOSIGNAL = 0x4000;
const CInt MSG_TRUNC    = 0x20;

<*
 Max iovec segments per vectored write syscall; the driver re-invokes for the
 rest, so partial coverage of a larger vector list is fine.
*>
const usz MAX_WRITE_IOV = 64;
const usz MAX_READ_IOV  = MAX_WRITE_IOV;

<*
 Linux IPv4 packet and multicast socket option identifiers.
*>
const CInt IPPROTO_IP                = 0;
const CInt IP_TTL                    = 2;
const CInt IP_MULTICAST_IF           = 32;
const CInt IP_MULTICAST_TTL          = 33;
const CInt IP_MULTICAST_LOOP         = 34;
const CInt IP_ADD_MEMBERSHIP         = 35;
const CInt IP_DROP_MEMBERSHIP        = 36;
const CInt IP_ADD_SOURCE_MEMBERSHIP  = 39;
const CInt IP_DROP_SOURCE_MEMBERSHIP = 40;

<*
 Linux IPv6 multicast socket option identifiers.
*>
const CInt IPPROTO_IPV6             = 41;
const CInt IPV6_MULTICAST_IF        = 17;
const CInt IPV6_JOIN_GROUP          = 20;
const CInt IPV6_LEAVE_GROUP         = 21;
const CInt MCAST_JOIN_SOURCE_GROUP  = 46;
const CInt MCAST_LEAVE_SOURCE_GROUP = 47;

<*
 Linux errno values not exposed by the active C3 libc enum.
*>
const Errno LINUX_EPROTONOSUPPORT = (Errno)93;
const Errno LINUX_EAFNOSUPPORT    = (Errno)97;

<*
 Linux socket creation flags used for nonblocking close-on-exec sockets.
*>
const int SOCK_NONBLOCK = 0o4000;
const int SOCK_CLOEXEC  = 0o2000000;

<*
 Accept a TCP connection while setting native socket flags atomically.
*>
extern fn os::NativeSocket accept4(
	os::NativeSocket socket,
	os::SockAddrPtr address,
	os::Socklen_t* address_len,
	int flags
);

<*
 Query a native socket's local address.
*>
extern fn CInt getsockname(os::NativeSocket socket, os::SockAddrPtr address, os::Socklen_t* address_len);

<*
 Query a native socket's connected peer address.
*>
extern fn CInt getpeername(os::NativeSocket socket, os::SockAddrPtr address, os::Socklen_t* address_len);

<*
 Receive a datagram with metadata needed for truncation and peer reporting.
*>
extern fn sz recvmsg(os::NativeSocket socket, UdpMsgHdr* message, CInt flags);

<*
 Send the iovec segments of a message; used for vectored (scatter-gather) TCP
 writes via `MSG_NOSIGNAL`.
*>
extern fn sz sendmsg(os::NativeSocket socket, UdpMsgHdr* message, CInt flags);

<*
 Send a datagram to an optional explicit peer address.
*>
extern fn sz sendto(
	os::NativeSocket socket,
	void* buffer,
	usz length,
	CInt flags,
	os::SockAddrPtr address,
	os::Socklen_t address_len
);

<*
 Linux IPv4 `sockaddr_in` used by TCP and UDP socket operations.
*>
struct SockAddrIn
{
	ushort family;
	ushort port;
	uint address;
	char[8] zero;
}

<*
 Linux IPv6 `sockaddr_in6` used by TCP and UDP socket operations.
*>
struct SockAddrIn6
{
	ushort family;
	ushort port;
	uint flowinfo;
	char[16] address;
	uint scope_id;
}

<*
 Linux socket address storage large enough for IPv4 and IPv6 addresses.
*>
union SockAddrAny
{
	SockAddrIn ipv4;
	SockAddrIn6 ipv6;
	char[128] storage;
}

<*
 Linux `iovec` used by `recvmsg` for UDP truncation detection.
*>
struct UdpIoVec
{
	void* iov_base;
	usz iov_len;
}

<*
 Linux `msghdr` used by `recvmsg`.

 This mirrors the native fields touched by UDP receive code and is kept local
 to avoid exposing platform-specific message layout through the public API.
*>
struct UdpMsgHdr
{
	void* msg_name;
	os::Socklen_t msg_namelen;
	UdpIoVec* msg_iov;
	usz msg_iovlen;
	void* msg_control;
	usz msg_controllen;
	CInt msg_flags;
}

<*
 Linux IPv4 multicast membership request.

 This is the local `ip_mreq` layout used only when configuring UDP multicast
 membership through `setsockopt`.
*>
struct UdpIpMreq
{
	uint imr_multiaddr;
	uint imr_interface;
}

<*
 Linux IPv4 source-specific multicast membership request.

 This mirrors the native `ip_mreq_source` layout used by
 `IP_ADD_SOURCE_MEMBERSHIP` and `IP_DROP_SOURCE_MEMBERSHIP`.
*>
struct UdpIpMreqSource
{
	uint imr_multiaddr;
	uint imr_interface;
	uint imr_sourceaddr;
}

<*
 Linux IPv6 multicast membership request.
*>
struct UdpIpv6Mreq
{
	char[16] ipv6mr_multiaddr;
	uint ipv6mr_interface;
}

<*
 Linux `sockaddr_storage` used by RFC 3678 group-source membership requests.
*>
struct UdpSockAddrStorage @align(8)
{
	char[128] storage;
}

<*
 Linux RFC 3678 `group_source_req` source-specific multicast membership request.
*>
struct UdpGroupSourceReq
{
	uint gsr_interface;
	UdpSockAddrStorage gsr_group;
	UdpSockAddrStorage gsr_source;
}

<*
 Linux `linger` socket option payload.

 This mirrors the native linger payload used to request abortive TCP close
 behavior through `setsockopt`.
*>
struct TcpLinger
{
	CInt onoff;
	CInt linger;
}

<*
 Create, configure and bind a non-blocking TCP listener socket.

 @param local : "IPv4 or IPv6 endpoint used for bind"
 @param options : "Socket options applied before bind"
 @return "Open native listener handle"
 @return ? nova::UNSUPPORTED : "Endpoint family or socket option is unsupported"
 @return ? nova::INVALID_STATE : "Socket option value is invalid"
 @return ? nova::ADDRESS_IN_USE : "Address is already in use"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup failed"
*>
fn NativeHandle? native_tcp_listener_bind(Endpoint local, SocketOptions options)
{
	os::AIFamily family = socket_family_from_endpoint(local)!;

	os::NativeSocket fd = os::socket(family, os::SOCK_STREAM | (os::AISockType)SOCK_CLOEXEC, IPPROTO_TCP);
	if (!fd.is_valid()) return tcp_platform_fault()~;

	bool retained = false;
	defer if (!retained) (void)fd.close();

	if (catch fd.set_non_blocking(true)) return nova::BACKEND_FAILED~;
	if (options.reuse_addr) tcp_set_bool_option(fd, os::SO_REUSEADDR, true)!;
	if (options.reuse_port) tcp_set_bool_option(fd, os::SO_REUSEPORT, true)!;
	tcp_apply_keepalive_options(fd, options)!;
	if (options.send_buffer_size) tcp_set_uint_option(fd, os::SO_SNDBUF, options.send_buffer_size)!;
	if (options.recv_buffer_size) tcp_set_uint_option(fd, os::SO_RCVBUF, options.recv_buffer_size)!;

	SockAddrAny address;
	os::Socklen_t address_len;
	native_sockaddr_from_endpoint(local, &address, &address_len)!;
	if (os::bind(fd, (os::SockAddrPtr)&address, address_len) != 0) return tcp_platform_fault()~;

	retained = true;
	return (NativeHandle)(int)fd;
}

<*
 Return the current local endpoint for a native TCP socket.

 This is used after binding to port `0` so caller-visible listener state stores
 the kernel-assigned port without name resolution or allocation.

 @param handle : "Native TCP socket descriptor"
 @return "Local endpoint"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "getsockname failed"
*>
fn Endpoint? native_tcp_socket_local_endpoint(NativeHandle handle)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	SockAddrAny address;
	os::Socklen_t len = (os::Socklen_t)SockAddrAny::size;
	if (getsockname(fd, (os::SockAddrPtr)&address, &len) != 0) return tcp_platform_fault()~;

	return native_endpoint_from_sockaddr((os::SockAddrPtr)&address, len);
}

<*
 Return the connected peer endpoint for a native TCP socket.

 @param handle : "Native TCP socket descriptor"
 @return "Peer endpoint"
 @return ? nova::CONNECTION_RESET : "The socket is not connected"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "getpeername failed"
*>
fn Endpoint? native_tcp_socket_peer_endpoint(NativeHandle handle)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	SockAddrAny address;
	os::Socklen_t len = (os::Socklen_t)SockAddrAny::size;
	if (getpeername(fd, (os::SockAddrPtr)&address, &len) != 0) return tcp_platform_fault()~;

	return native_endpoint_from_sockaddr((os::SockAddrPtr)&address, len);
}

<*
 Start listening on an already-bound TCP listener handle.

 @param handle : "Native TCP listener descriptor"
 @param backlog : "Requested native listen backlog"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "listen failed"
*>
fn void? native_tcp_listener_listen(NativeHandle handle, int backlog)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;
	if (os::listen(fd, (CInt)backlog) != 0) return tcp_platform_fault()~;
}

<*
 Accept one TCP stream without blocking.

 Accepted descriptors are created non-blocking and close-on-exec. Socket options
 that belong to connected streams are applied before ownership is returned.

 @param listener_handle : "Native listener descriptor"
 @param options : "Options inherited by the accepted stream"
 @param [out] peer : "Peer endpoint written on success"
 @return "Accepted native stream handle"
 @return ? std::io::WOULD_BLOCK : "No connection is ready now"
 @return ? nova::INVALID_STATE : "Socket option value is invalid"
 @return ? nova::INVALID_SOCKET : "Native listener handle is invalid"
 @return ? nova::BACKEND_FAILED : "accept or stream setup failed"
 @require peer != null : "Peer endpoint output pointer must not be null"
*>
fn NativeHandle? native_tcp_accept(NativeHandle listener_handle, SocketOptions options, Endpoint* peer)
{
	os::NativeSocket fd = (os::NativeSocket)(int)listener_handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	SockAddrAny address;
	os::Socklen_t len = (os::Socklen_t)SockAddrAny::size;
	os::NativeSocket accepted;
	do
	{
		accepted = accept4(fd, (os::SockAddrPtr)&address, &len, SOCK_NONBLOCK | SOCK_CLOEXEC);
	} while (!accepted.is_valid() && (libc::errno() == EINTR || libc::errno() == posix_errno::E_CONNABORTED));
	if (!accepted.is_valid())
	{
		Errno err = libc::errno();
		if (err == EAGAIN || err == EWOULDBLOCK) return io::WOULD_BLOCK~;
		return tcp_platform_fault()~;
	}

	bool retained = false;
	defer if (!retained) (void)accepted.close();

	if (options.nodelay) tcp_set_tcp_bool_option(accepted, TCP_NODELAY, true)!;
	tcp_apply_keepalive_options(accepted, options)!;
	if (options.send_buffer_size) tcp_set_uint_option(accepted, os::SO_SNDBUF, options.send_buffer_size)!;
	if (options.recv_buffer_size) tcp_set_uint_option(accepted, os::SO_RCVBUF, options.recv_buffer_size)!;

	Endpoint accepted_peer = native_endpoint_from_sockaddr((os::SockAddrPtr)&address, len)!;
	*peer = accepted_peer;
	retained = true;
	return (NativeHandle)(int)accepted;
}

<*
 Apply connected-stream socket options to a descriptor the kernel already accepted
 (io_uring `IORING_OP_ACCEPT`). The accept SQE sets `SOCK_NONBLOCK|SOCK_CLOEXEC`,
 so only the remaining stream options are applied here, matching the readiness
 `native_tcp_accept` path.

 @param handle : "Accepted native stream descriptor"
 @param options : "Options inherited by the accepted stream"
 @return ? nova::INVALID_STATE : "Socket option value is invalid"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "Setting a socket option failed"
*>
fn void? native_tcp_apply_accept_options(NativeHandle handle, SocketOptions options)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	if (options.nodelay) tcp_set_tcp_bool_option(fd, TCP_NODELAY, true)!;
	tcp_apply_keepalive_options(fd, options)!;
	if (options.send_buffer_size) tcp_set_uint_option(fd, os::SO_SNDBUF, options.send_buffer_size)!;
	if (options.recv_buffer_size) tcp_set_uint_option(fd, os::SO_RCVBUF, options.recv_buffer_size)!;
}

<*
 Create a non-blocking stream socket and start connecting.

 Delayed connect is returned as an incomplete start. Immediate connect failure is
 reported as a completed operation with a semantic status so public proactor
 behavior still delivers the network result through the callback.

 @param remote : "Remote IPv4 or IPv6 endpoint"
 @param options : "Socket options applied before connect"
 @return "Started connect descriptor"
 @return ? nova::UNSUPPORTED : "Endpoint family or socket option is unsupported"
 @return ? nova::INVALID_STATE : "Socket option value is invalid"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup failed"
*>
fn NativeTcpConnectStart? native_tcp_connect_start(Endpoint remote, SocketOptions options)
{
	os::AIFamily family = socket_family_from_endpoint(remote)!;

	os::NativeSocket fd = os::socket(family, os::SOCK_STREAM | (os::AISockType)SOCK_CLOEXEC, IPPROTO_TCP);
	if (!fd.is_valid()) return tcp_platform_fault()~;

	bool retained = false;
	defer if (!retained) (void)fd.close();

	if (catch fd.set_non_blocking(true)) return nova::BACKEND_FAILED~;
	if (options.reuse_addr) tcp_set_bool_option(fd, os::SO_REUSEADDR, true)!;
	if (options.reuse_port) tcp_set_bool_option(fd, os::SO_REUSEPORT, true)!;
	if (options.nodelay) tcp_set_tcp_bool_option(fd, TCP_NODELAY, true)!;
	tcp_apply_keepalive_options(fd, options)!;
	if (options.send_buffer_size) tcp_set_uint_option(fd, os::SO_SNDBUF, options.send_buffer_size)!;
	if (options.recv_buffer_size) tcp_set_uint_option(fd, os::SO_RCVBUF, options.recv_buffer_size)!;

	SockAddrAny address;
	os::Socklen_t address_len;
	native_sockaddr_from_endpoint(remote, &address, &address_len)!;
	int result;
	do
	{
		result = os::connect(fd, (os::SockAddrPtr)&address, address_len);
	} while (result != 0 && libc::errno() == EINTR);
	NativeTcpConnectStart start = { .handle = (NativeHandle)(int)fd };
	if (result == 0)
	{
		start.complete = true;
		retained = true;
		return start;
	}

	Errno err = libc::errno();
	if (tcp_connect_is_delayed(err))
	{
		start.complete = false;
		retained = true;
		return start;
	}

	start.complete = true;
	start.status = tcp_fault_from_errno(err);
	retained = true;
	return start;
}

<*
 Create a non-blocking TCP stream socket, apply connect options, and serialize the
 remote endpoint into `out_addr`/`out_len`, without starting the connect. Used by
 the io_uring completion path, which submits the connect as `IORING_OP_CONNECT`
 against the returned descriptor.

 @param remote : "Remote IPv4 or IPv6 endpoint (selects the address family)"
 @param options : "Socket options applied before connect"
 @param [out] out_addr : "Caller storage filled with the remote sockaddr"
 @param [out] out_len : "Caller storage filled with the remote sockaddr length"
 @return "Created native stream descriptor"
 @return ? nova::UNSUPPORTED : "Endpoint family or socket option is unsupported"
 @return ? nova::INVALID_STATE : "Socket option value is invalid"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup failed"
 @require out_addr != null : "Address output pointer must not be null"
 @require out_len != null : "Length output pointer must not be null"
*>
fn NativeHandle? native_tcp_connect_socket(Endpoint remote, SocketOptions options, SockAddrAny* out_addr, uint* out_len)
{
	os::AIFamily family = socket_family_from_endpoint(remote)!;

	os::NativeSocket fd = os::socket(family, os::SOCK_STREAM | (os::AISockType)SOCK_CLOEXEC, IPPROTO_TCP);
	if (!fd.is_valid()) return tcp_platform_fault()~;

	bool retained = false;
	defer if (!retained) (void)fd.close();

	if (catch fd.set_non_blocking(true)) return nova::BACKEND_FAILED~;
	if (options.reuse_addr) tcp_set_bool_option(fd, os::SO_REUSEADDR, true)!;
	if (options.reuse_port) tcp_set_bool_option(fd, os::SO_REUSEPORT, true)!;
	if (options.nodelay) tcp_set_tcp_bool_option(fd, TCP_NODELAY, true)!;
	tcp_apply_keepalive_options(fd, options)!;
	if (options.send_buffer_size) tcp_set_uint_option(fd, os::SO_SNDBUF, options.send_buffer_size)!;
	if (options.recv_buffer_size) tcp_set_uint_option(fd, os::SO_RCVBUF, options.recv_buffer_size)!;

	os::Socklen_t address_len;
	native_sockaddr_from_endpoint(remote, out_addr, &address_len)!;
	*out_len = (uint)address_len;

	retained = true;
	return (NativeHandle)(int)fd;
}

<*
 Finish a TCP connect by checking `SO_ERROR`.

 @param handle : "Native TCP stream descriptor"
 @return ? nova::CONNECTION_REFUSED : "Remote refused the connection"
 @return ? nova::CONNECTION_RESET : "Connection was reset"
 @return ? nova::CONNECTION_TIMED_OUT : "Connect timed out"
 @return ? nova::NETWORK_UNREACHABLE : "Remote network is unreachable"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "SO_ERROR query failed"
*>
fn void? native_tcp_connect_finish(NativeHandle handle)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	CInt value;
	os::Socklen_t len = (os::Socklen_t)CInt::size;
	if (os::getsockopt(fd, os::SOL_SOCKET, os::SO_ERROR, &value, &len) != 0) return tcp_platform_fault()~;
	if (value != 0) return tcp_fault_from_errno((Errno)value)~;
}

<*
 Read from a non-blocking TCP stream into caller-owned storage.

 A zero-byte success is an orderly peer EOF. Transient would-block is reported
 separately so the TCP driver can rearm readiness without invoking user code.

 @param handle : "Native stream descriptor"
 @param [out] buffer : "Caller-owned destination bytes"
 @return "Bytes read, or zero for EOF"
 @return ? std::io::WOULD_BLOCK : "No bytes are ready now"
 @return ? nova::CONNECTION_RESET : "Connection was reset"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "recv failed"
*>
fn sz? native_tcp_read(NativeHandle handle, char[] buffer)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	while (true)
	{
		sz received = libc::recv(fd, buffer.ptr, (usz)buffer.len, 0);
		if (received >= 0) return received;

		Errno err = libc::errno();
		if (err == EINTR) continue;
		if (err == EAGAIN || err == EWOULDBLOCK) return io::WOULD_BLOCK~;
		return tcp_fault_from_errno(err)~;
	}
}

<*
 Vectored read into caller-owned slices from a non-blocking TCP stream.

 `first_offset` skips already-filled bytes at the start of `vectors[0]`
 (partial-read resume). At most `MAX_READ_IOV` segments are read per call.

 @param handle : "Native stream descriptor"
 @param vectors : "Caller-owned destination slices"
 @param first_offset : "Bytes to skip at the start of vectors[0]"
 @return "Bytes read this call (zero means EOF)"
 @return ? std::io::WOULD_BLOCK : "No bytes can be read now"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "recvmsg failed"
*>
fn sz? native_tcp_readv(NativeHandle handle, char[][] vectors, usz first_offset)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	UdpIoVec[MAX_READ_IOV] iov;
	usz n = 0;
	for (usz i = 0; i < vectors.len && n < MAX_READ_IOV; i++)
	{
		char[] v = vectors[i];
		usz off  = i == 0 ? first_offset : 0;
		if (off >= v.len) continue;
		iov[n].iov_base = (void*)&v[off];
		iov[n].iov_len = v.len - off;
		n++;
	}
	if (!n) return 0;

	UdpMsgHdr message = { .msg_iov = &iov[0], .msg_iovlen = n };
	while (true)
	{
		sz received = recvmsg(fd, &message, 0);
		if (received >= 0) return received;

		Errno err = libc::errno();
		if (err == EINTR) continue;
		if (err == EAGAIN || err == EWOULDBLOCK) return io::WOULD_BLOCK~;
		return tcp_fault_from_errno(err)~;
	}
}

<*
 Write caller-owned bytes to a non-blocking TCP stream.

 `MSG_NOSIGNAL` prevents Linux from raising SIGPIPE when the peer has already
 closed. Transient would-block is reported separately so the TCP driver can
 rearm readiness while keeping partial progress in the caller-owned operation.

 @param handle : "Native stream descriptor"
 @param bytes : "Caller-owned source bytes"
 @return "Bytes accepted by the OS"
 @return ? std::io::WOULD_BLOCK : "No bytes can be written now"
 @return ? nova::CONNECTION_RESET : "Connection was reset or closed for writing"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "send failed"
*>
fn sz? native_tcp_write(NativeHandle handle, char[] bytes)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	while (true)
	{
		sz sent = libc::send(fd, bytes.ptr, (usz)bytes.len, MSG_NOSIGNAL);
		if (sent >= 0) return sent;

		Errno err = libc::errno();
		if (err == EINTR) continue;
		if (err == EAGAIN || err == EWOULDBLOCK) return io::WOULD_BLOCK~;
		return tcp_fault_from_errno(err)~;
	}
}

<*
 Write caller-owned vectored bytes to a non-blocking TCP stream via `sendmsg`.

 `first_offset` skips already-written bytes at the start of `vectors[0]`
 (partial-write resume). Empty/consumed segments are skipped; at most
 `MAX_WRITE_IOV` segments are sent per call. `MSG_NOSIGNAL` suppresses SIGPIPE.

 @param handle : "Native stream descriptor"
 @param vectors : "Caller-owned source slices"
 @param first_offset : "Bytes to skip at the start of vectors[0]"
 @return "Bytes accepted by the OS this call"
 @return ? std::io::WOULD_BLOCK : "No bytes can be written now"
 @return ? nova::CONNECTION_RESET : "Connection was reset or closed for writing"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "sendmsg failed"
*>
fn sz? native_tcp_writev(NativeHandle handle, char[][] vectors, usz first_offset)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	UdpIoVec[MAX_WRITE_IOV] iov;
	usz n = 0;
	for (usz i = 0; i < vectors.len && n < MAX_WRITE_IOV; i++)
	{
		char[] v = vectors[i];
		usz off  = i == 0 ? first_offset : 0;
		if (off >= v.len) continue;
		iov[n].iov_base = (void*)&v[off];
		iov[n].iov_len = v.len - off;
		n++;
	}
	if (!n) return 0;

	UdpMsgHdr message = { .msg_iov = &iov[0], .msg_iovlen = n };
	while (true)
	{
		sz sent = sendmsg(fd, &message, MSG_NOSIGNAL);
		if (sent >= 0) return sent;

		Errno err = libc::errno();
		if (err == EINTR) continue;
		if (err == EAGAIN || err == EWOULDBLOCK) return io::WOULD_BLOCK~;
		return tcp_fault_from_errno(err)~;
	}
}

<*
 Create, configure and bind a non-blocking UDP socket.

 @param local : "Local IPv4 or IPv6 endpoint"
 @param options : "Socket options applied before bind"
 @return "Open native datagram handle"
 @return ? nova::UNSUPPORTED : "Endpoint family or stream-only socket option is unsupported"
 @return ? nova::INVALID_STATE : "Socket option value is invalid"
 @return ? nova::ADDRESS_IN_USE : "Address is already in use"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup failed"
*>
fn NativeHandle? native_udp_bind(Endpoint local, SocketOptions options)
{
	os::AIFamily family = socket_family_from_endpoint(local)!;

	os::NativeSocket fd = udp_create_socket(family, options)!;
	bool retained       = false;
	defer if (!retained) (void)fd.close();

	SockAddrAny address;
	os::Socklen_t address_len;
	native_sockaddr_from_endpoint(local, &address, &address_len)!;
	if (os::bind(fd, (os::SockAddrPtr)&address, address_len) != 0) return udp_platform_fault()~;

	retained = true;
	return (NativeHandle)(int)fd;
}

<*
 Create, configure and connect a non-blocking UDP socket.

 UDP connect only records the default peer in the kernel; no packet is sent.

 @param remote : "Remote IPv4 or IPv6 endpoint"
 @param options : "Socket options applied before connect"
 @return "Open native datagram handle"
 @return ? nova::UNSUPPORTED : "Endpoint family or stream-only socket option is unsupported"
 @return ? nova::INVALID_STATE : "Socket option value is invalid"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup or connect failed"
*>
fn NativeHandle? native_udp_connect_new(Endpoint remote, SocketOptions options)
{
	os::AIFamily family = socket_family_from_endpoint(remote)!;

	os::NativeSocket fd = udp_create_socket(family, options)!;
	bool retained       = false;
	defer if (!retained) (void)fd.close();

	SockAddrAny address;
	os::Socklen_t address_len;
	native_sockaddr_from_endpoint(remote, &address, &address_len)!;
	int result;
	do
	{
		result = os::connect(fd, (os::SockAddrPtr)&address, address_len);
	} while (result != 0 && libc::errno() == EINTR);
	if (result != 0) return udp_platform_fault()~;

	retained = true;
	return (NativeHandle)(int)fd;
}

<*
 Connect an already-open UDP socket to a default remote endpoint.

 @param handle : "Native datagram descriptor"
 @param remote : "Remote IPv4 or IPv6 endpoint"
 @return ? nova::UNSUPPORTED : "Endpoint family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native connect failed"
*>
fn void? native_udp_connect(NativeHandle handle, Endpoint remote)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	SockAddrAny address;
	os::Socklen_t address_len;
	native_sockaddr_from_endpoint(remote, &address, &address_len)!;
	int result;
	do
	{
		result = os::connect(fd, (os::SockAddrPtr)&address, address_len);
	} while (result != 0 && libc::errno() == EINTR);
	if (result != 0) return udp_platform_fault()~;
}

<*
 Return the current local endpoint for a native UDP socket.

 @param handle : "Native datagram descriptor"
 @return "Local endpoint"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "getsockname failed"
*>
fn Endpoint? native_udp_socket_local_endpoint(NativeHandle handle)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	SockAddrAny address;
	os::Socklen_t len = (os::Socklen_t)SockAddrAny::size;
	if (getsockname(fd, (os::SockAddrPtr)&address, &len) != 0) return udp_platform_fault()~;

	return native_endpoint_from_sockaddr((os::SockAddrPtr)&address, len);
}

<*
 Return the connected default peer endpoint for a native UDP socket.

 @param handle : "Native datagram descriptor"
 @return "Peer endpoint"
 @return ? NOT_FOUND : "Socket has no connected default peer"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "getpeername failed"
*>
fn Endpoint? native_udp_socket_peer_endpoint(NativeHandle handle)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	SockAddrAny address;
	os::Socklen_t len = (os::Socklen_t)SockAddrAny::size;
	if (getpeername(fd, (os::SockAddrPtr)&address, &len) != 0)
	{
		Errno err = libc::errno();
		if (err == posix_errno::E_NOTCONN) return NOT_FOUND~;
		return udp_fault_from_errno(err)~;
	}

	return native_endpoint_from_sockaddr((os::SockAddrPtr)&address, len);
}

<*
 Receive one datagram from a non-blocking UDP socket.

 The caller-owned buffer receives at most one datagram. Linux `recvmsg` reports
 truncation through `MSG_TRUNC`; `bytes` is capped to bytes copied into the
 caller buffer so result metadata never exceeds the writable slice length.

 @param handle : "Native datagram descriptor"
 @param [out] buffer : "Caller-owned destination bytes"
 @return "Received datagram metadata"
 @return ? std::io::WOULD_BLOCK : "No datagram is ready now"
 @return ? nova::CONNECTION_REFUSED : "Connected UDP socket received an ICMP refusal"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "recvmsg failed"
*>
fn NativeUdpRecvResult? native_udp_recv(NativeHandle handle, char[] buffer)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	while (true)
	{
		SockAddrAny peer;
		UdpIoVec iov = { .iov_base = buffer.ptr, .iov_len = (usz)buffer.len, };
		UdpMsgHdr message = {
			.msg_name = &peer,
			.msg_namelen = (os::Socklen_t)SockAddrAny::size,
			.msg_iov = &iov,
			.msg_iovlen = 1,
			.msg_control = null,
			.msg_controllen = 0,
			.msg_flags = 0,
		};
		sz received = recvmsg(fd, &message, MSG_TRUNC);
		if (received >= 0)
		{
			bool truncated = (message.msg_flags & MSG_TRUNC) != 0 || received > buffer.len;
			sz copied      = received;
			if (copied > buffer.len) copied = buffer.len;
			Endpoint endpoint = native_endpoint_from_sockaddr((os::SockAddrPtr)&peer, message.msg_namelen)!;
			return { .bytes = copied, .peer = endpoint, .truncated = truncated, };
		}

		Errno err = libc::errno();
		if (err == EINTR) continue;
		if (err == EAGAIN || err == EWOULDBLOCK) return io::WOULD_BLOCK~;
		return udp_fault_from_errno(err)~;
	}
}

<*
 Fill a caller `msghdr`/`iovec` for an io_uring `IORING_OP_RECVMSG` UDP receive:
 a single iovec over `buffer` and `msg_name` pointing at `peer` storage so the
 kernel writes the source address. Keeps the `os::` message layout in the platform
 layer.

 @param msg : "Caller msghdr storage"
 @param iov : "Caller iovec storage"
 @param peer : "Caller peer sockaddr storage written by the kernel"
 @param buffer : "Caller destination bytes"
 @require msg != null : "msghdr pointer must not be null"
 @require iov != null : "iovec pointer must not be null"
 @require peer != null : "peer pointer must not be null"
*>
fn void native_udp_recvmsg_init(UdpMsgHdr* msg, UdpIoVec* iov, SockAddrAny* peer, char[] buffer)
{
	*iov = { .iov_base = buffer.ptr, .iov_len = (usz)buffer.len };
	*msg = {
		.msg_name = peer,
		.msg_namelen = (os::Socklen_t)SockAddrAny::size,
		.msg_iov = iov,
		.msg_iovlen = 1,
		.msg_control = null,
		.msg_controllen = 0,
		.msg_flags = 0,
	};
}

<*
 Fill a caller `msghdr`/`iovec` for an io_uring `IORING_OP_SENDMSG` UDP send: a
 single iovec over `bytes` and, when `remote` is set, `msg_name` serialized into
 `remote_store`. A connected socket passes a null `remote`.

 @param msg : "Caller msghdr storage"
 @param iov : "Caller iovec storage"
 @param remote_store : "Caller sockaddr storage for an explicit destination"
 @param remote : "Explicit destination endpoint, or null for a connected socket"
 @param bytes : "Caller source bytes"
 @return ? nova::UNSUPPORTED : "Remote endpoint family is unsupported"
 @require msg != null : "msghdr pointer must not be null"
 @require iov != null : "iovec pointer must not be null"
 @require remote_store != null : "remote storage pointer must not be null"
*>
fn void? native_udp_sendmsg_init(
	UdpMsgHdr* msg,
	UdpIoVec* iov,
	SockAddrAny* remote_store,
	Endpoint* remote,
	char[] bytes
)
{
	*iov = { .iov_base = bytes.ptr, .iov_len = (usz)bytes.len };

	void* name            = null;
	os::Socklen_t namelen = 0;
	if (remote)
	{
		native_sockaddr_from_endpoint(*remote, remote_store, &namelen)!;
		name = remote_store;
	}

	*msg = {
		.msg_name = name,
		.msg_namelen = namelen,
		.msg_iov = iov,
		.msg_iovlen = 1,
		.msg_control = null,
		.msg_controllen = 0,
		.msg_flags = 0,
	};
}

<*
 Map an io_uring completion `-errno` (negated CQE result) to the UDP terminal
 fault, matching what `native_udp_recv`/`native_udp_send` produce for the same
 errno.

 @param err : "Negated CQE result (positive POSIX errno)"
 @return "Mapped nova fault"
*>
fn fault udp_completion_fault(int err) => udp_fault_from_errno((Errno)err);

<*
 Join one IPv4 multicast group on a native UDP socket.

 Only endpoint address and family fields participate in membership setup;
 ports in `group` are ignored.

 @param handle : "Native datagram descriptor"
 @param group : "IPv4 multicast group and optional local interface address"
 @return ? nova::UNSUPPORTED : "Group or interface address is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_join_multicast(NativeHandle handle, MulticastGroup group)
{
	udp_set_multicast_membership(handle, group, IP_ADD_MEMBERSHIP)!;
}

<*
 Leave one IPv4 multicast group on a native UDP socket.

 Only endpoint address and family fields participate in membership teardown;
 ports in `group` are ignored.

 @param handle : "Native datagram descriptor"
 @param group : "IPv4 multicast group and optional local interface address"
 @return ? nova::UNSUPPORTED : "Group or interface address is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_leave_multicast(NativeHandle handle, MulticastGroup group)
{
	udp_set_multicast_membership(handle, group, IP_DROP_MEMBERSHIP)!;
}

<*
 Enable or disable IPv4 broadcast sends on a native UDP socket.

 @param handle : "Native datagram descriptor"
 @param enabled : "Broadcast socket option value"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_set_broadcast(NativeHandle handle, bool enabled)
{
	udp_set_socket_bool_option(handle, os::SO_BROADCAST, enabled)!;
}

<*
 Set the IPv4 unicast packet TTL on a native UDP socket.

 @param handle : "Native datagram descriptor"
 @param ttl : "TTL in the inclusive range 1..255"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_set_ttl(NativeHandle handle, uint ttl)
{
	udp_set_ip_int_option(handle, IP_TTL, (int)ttl)!;
}

<*
 Enable or disable IPv4 multicast loopback on a native UDP socket.

 @param handle : "Native datagram descriptor"
 @param enabled : "Multicast loopback option value"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_set_multicast_loop(NativeHandle handle, bool enabled)
{
	CInt loop_value = 0;
	if (enabled) loop_value = 1;
	udp_set_ip_int_option(handle, IP_MULTICAST_LOOP, loop_value)!;
}

<*
 Set the IPv4 multicast packet TTL on a native UDP socket.

 @param handle : "Native datagram descriptor"
 @param ttl : "TTL in the inclusive range 1..255"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_set_multicast_ttl(NativeHandle handle, uint ttl)
{
	udp_set_ip_int_option(handle, IP_MULTICAST_TTL, (int)ttl)!;
}

<*
 Set the IPv4 or IPv6 multicast interface on a native UDP socket.

 @param handle : "Native datagram descriptor"
 @param interface_addr : "Default, IPv4 local interface address, or IPv6 endpoint carrying an interface scope id"
 @return ? nova::UNSUPPORTED : "Interface family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_set_multicast_interface(NativeHandle handle, Endpoint interface_addr)
{
	if (interface_addr.family == AddressFamily.IPV6)
	{
		os::NativeSocket fd = (os::NativeSocket)(int)handle;
		if (!fd.is_valid()) return nova::INVALID_SOCKET~;
		if (udp_socket_family(fd)! != AddressFamily.IPV6) return nova::UNSUPPORTED~;
		udp_set_ipv6_uint_option(handle, IPV6_MULTICAST_IF, udp_ipv6_interface_scope(interface_addr)!)!;
		return;
	}
	if (interface_addr.family != AddressFamily.UNSPEC
		&& interface_addr.family != AddressFamily.IPV4) return nova::UNSUPPORTED~;

	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;
	if (interface_addr.family == AddressFamily.UNSPEC && udp_socket_family(fd)! == AddressFamily.IPV6)
	{
		udp_set_ipv6_uint_option(handle, IPV6_MULTICAST_IF, 0)!;
		return;
	}

	uint address = 0;
	if (interface_addr.family == AddressFamily.IPV4) address = udp_ipv4_raw_address(interface_addr);
	udp_set_ip_addr_option(handle, IP_MULTICAST_IF, address)!;
}

<*
 Join one IPv4 source-specific multicast group on a native UDP socket.

 @param handle : "Native datagram descriptor"
 @param group : "IPv4 multicast group, optional interface and IPv4 source"
 @return ? nova::UNSUPPORTED : "Addresses or source-specific multicast are unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_join_source_multicast(NativeHandle handle, SourceMulticastGroup group)
{
	udp_set_source_multicast_membership(handle, group, IP_ADD_SOURCE_MEMBERSHIP)!;
}

<*
 Leave one IPv4 source-specific multicast group on a native UDP socket.

 @param handle : "Native datagram descriptor"
 @param group : "IPv4 multicast group, optional interface and IPv4 source"
 @return ? nova::UNSUPPORTED : "Addresses or source-specific multicast are unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_udp_leave_source_multicast(NativeHandle handle, SourceMulticastGroup group)
{
	udp_set_source_multicast_membership(handle, group, IP_DROP_SOURCE_MEMBERSHIP)!;
}

<*
 Send one datagram from a non-blocking UDP socket.

 When `remote` is null, the socket must already be connected to a default peer.
 `MSG_NOSIGNAL` suppresses Linux SIGPIPE behavior on connected sockets.

 @param handle : "Native datagram descriptor"
 @param bytes : "Caller-owned source bytes"
 @param remote : "Optional explicit destination endpoint"
 @return "Bytes accepted by the OS"
 @return ? std::io::WOULD_BLOCK : "The datagram cannot be sent now"
 @return ? nova::CONNECTION_REFUSED : "Connected UDP socket received an ICMP refusal"
 @return ? nova::UNSUPPORTED : "Explicit remote endpoint family or native socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "send/sendto failed"
*>
fn sz? native_udp_send(NativeHandle handle, char[] bytes, Endpoint* remote)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	SockAddrAny address;
	os::SockAddrPtr address_ptr = (os::SockAddrPtr)null;
	os::Socklen_t address_len   = 0;
	if (remote)
	{
		native_sockaddr_from_endpoint(*remote, &address, &address_len)!;
		address_ptr = (os::SockAddrPtr)&address;
	}

	while (true)
	{
		sz sent;
		if (remote)
		{
			sent = sendto(fd, bytes.ptr, (usz)bytes.len, MSG_NOSIGNAL, address_ptr, address_len);
		}
		else
		{
			sent = libc::send(fd, bytes.ptr, (usz)bytes.len, MSG_NOSIGNAL);
		}
		if (sent >= 0) return sent;

		Errno err = libc::errno();
		if (err == EINTR) continue;
		if (err == EAGAIN || err == EWOULDBLOCK) return io::WOULD_BLOCK~;
		return udp_fault_from_errno(err)~;
	}
}

<*
 Close a native UDP handle.

 @param handle : "Native datagram descriptor, or negative sentinel"
 @return ? nova::BACKEND_FAILED : "close failed"
*>
fn void? native_udp_close(NativeHandle handle)
{
	if ((int)handle >= 0)
	{
		close_socket_fd((os::NativeSocket)(int)handle)!;
	}
}

<*
 Shut down one or both halves of a TCP stream.

 @param handle : "Native TCP stream descriptor"
 @param mode : "Native shutdown direction"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::CONNECTION_RESET : "Connection was reset"
 @return ? nova::BACKEND_FAILED : "shutdown failed"
*>
fn void? native_tcp_shutdown(NativeHandle handle, ShutdownMode mode)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	CInt how = libc::SHUT_WR;
	if (mode == ShutdownMode.RECV) how = libc::SHUT_RD;
	if (mode == ShutdownMode.BOTH) how = libc::SHUT_RDWR;
	if (libc::shutdown(fd, how) != 0) return tcp_platform_fault()~;
}

<*
 Configure abortive TCP close using `SO_LINGER { 1, 0 }`.

 @param handle : "Native TCP stream descriptor"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_tcp_set_abortive_close(NativeHandle handle)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	TcpLinger linger = { .onoff = 1, .linger = 0 };
	if (os::setsockopt(
		fd,
		os::SOL_SOCKET,
		os::SO_LINGER,
		&linger,
		(os::Socklen_t)TcpLinger::size
	) != 0) return tcp_platform_fault()~;
}

<*
 Apply tunable TCP socket options to an already-connected descriptor.

 Mirrors the setup-time application: `nodelay` and non-zero buffer sizes and
 keepalive fields are applied; zero/false values leave the native default
 unchanged. This lets callers tune a stream after connect/accept.

 @param handle : "Native TCP stream descriptor"
 @param options : "Socket options to apply"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::INVALID_STATE : "A socket option value is invalid"
 @return ? nova::UNSUPPORTED : "A socket option is unsupported"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? native_tcp_apply_options(NativeHandle handle, SocketOptions options)
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;

	if (options.nodelay) tcp_set_tcp_bool_option(fd, TCP_NODELAY, true)!;
	tcp_apply_keepalive_options(fd, options)!;
	if (options.send_buffer_size) tcp_set_uint_option(fd, os::SO_SNDBUF, options.send_buffer_size)!;
	if (options.recv_buffer_size) tcp_set_uint_option(fd, os::SO_RCVBUF, options.recv_buffer_size)!;
}

<*
 Close a native TCP handle.

 @param handle : "Native TCP descriptor, or negative sentinel"
 @return ? nova::BACKEND_FAILED : "close failed"
*>
fn void? native_tcp_close(NativeHandle handle)
{
	if ((int)handle >= 0)
	{
		close_socket_fd((os::NativeSocket)(int)handle)!;
	}
}

<*
 Close a native socket descriptor and map expected close faults.

 @param fd : "Native socket descriptor"
 @return ? nova::INVALID_SOCKET : "Descriptor was already invalid"
 @return ? nova::BACKEND_FAILED : "Unexpected close failure"
*>
fn void? close_socket_fd(os::NativeSocket fd) @private
{
	if (libc::close(fd) != 0)
	{
		Errno err = libc::errno();
		if (err == EBADF) return nova::INVALID_SOCKET~;
		if (err == EINTR || err == EINPROGRESS) return;
		return nova::BACKEND_FAILED~;
	}
}

<*
 Set a boolean SOL_SOCKET option.

 @param fd : "Native socket descriptor"
 @param option : "SOL_SOCKET option id"
 @param enabled : "Boolean option value"
 @return ? nova::ADDRESS_IN_USE : "Socket option reports address conflict"
 @return ? nova::UNSUPPORTED : "Socket option is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? tcp_set_bool_option(os::NativeSocket fd, CInt option, bool enabled) @private
{
	CInt value = (CInt)enabled;
	if (os::setsockopt(
		fd,
		os::SOL_SOCKET,
		option,
		&value,
		(os::Socklen_t)CInt::size
	) != 0) return tcp_platform_fault()~;
}

<*
 Set an integer SOL_SOCKET option.

 @param fd : "Native socket descriptor"
 @param option : "SOL_SOCKET option id"
 @param value : "Integer option value"
 @return ? nova::ADDRESS_IN_USE : "Socket option reports address conflict"
 @return ? nova::UNSUPPORTED : "Socket option is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? tcp_set_int_option(os::NativeSocket fd, CInt option, int value) @private
{
	CInt native_value = (CInt)value;
	if (os::setsockopt(
		fd,
		os::SOL_SOCKET,
		option,
		&native_value,
		(os::Socklen_t)CInt::size
	) != 0) return tcp_platform_fault()~;
}

<*
 Set an unsigned SOL_SOCKET option after validating it fits the native signed
 integer ABI.

 @param fd : "Native socket descriptor"
 @param option : "SOL_SOCKET option id"
 @param value : "Unsigned option value"
 @return ? nova::INVALID_STATE : "Socket option value is too large"
 @return ? nova::ADDRESS_IN_USE : "Socket option reports address conflict"
 @return ? nova::UNSUPPORTED : "Socket option is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? tcp_set_uint_option(os::NativeSocket fd, CInt option, uint value) @private
{
	if (value > (uint)CInt::max) return nova::INVALID_STATE~;
	tcp_set_int_option(fd, option, (int)value)!;
}

<*
 Set a boolean IPPROTO_TCP option.

 @param fd : "Native TCP socket descriptor"
 @param option : "IPPROTO_TCP option id"
 @param enabled : "Boolean option value"
 @return ? nova::UNSUPPORTED : "Socket option is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? tcp_set_tcp_bool_option(os::NativeSocket fd, CInt option, bool enabled) @private
{
	CInt value = (CInt)enabled;
	if (os::setsockopt(
		fd,
		(CInt)IPPROTO_TCP,
		option,
		&value,
		(os::Socklen_t)CInt::size
	) != 0) return tcp_platform_fault()~;
}

<*
 Apply TCP keepalive options.

 Linux keepalive idle and interval values are seconds. C3 public options are
 microseconds, rounded up so any positive duration enables at least one second.
 Any non-zero keepalive tuning field also enables `SO_KEEPALIVE`.

 @param fd : "Native TCP socket descriptor"
 @param options : "TCP socket options"
 @return ? nova::INVALID_STATE : "Keepalive duration or count is invalid"
 @return ? nova::UNSUPPORTED : "Socket option is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? tcp_apply_keepalive_options(os::NativeSocket fd, SocketOptions options) @private
{
	if ((long)options.keepalive_idle < 0) return nova::INVALID_STATE~;
	if ((long)options.keepalive_interval < 0) return nova::INVALID_STATE~;
	if (options.keepalive || (long)options.keepalive_idle || (long)options.keepalive_interval
		|| options.keepalive_count)
	{
		tcp_set_bool_option(fd, os::SO_KEEPALIVE, true)!;
		if ((long)options.keepalive_idle)
		{
			tcp_set_tcp_int_option(fd, TCP_KEEPIDLE, tcp_duration_to_keepalive_seconds(options.keepalive_idle)!)!;
		}
		if ((long)options.keepalive_interval)
		{
			tcp_set_tcp_int_option(fd, TCP_KEEPINTVL, tcp_duration_to_keepalive_seconds(options.keepalive_interval)!)!;
		}
		if (options.keepalive_count)
		{
			if (options.keepalive_count > (uint)CInt::max) return nova::INVALID_STATE~;
			tcp_set_tcp_int_option(fd, TCP_KEEPCNT, (int)options.keepalive_count)!;
		}
	}
}

<*
 Set an integer IPPROTO_TCP option.

 @param fd : "Native TCP socket descriptor"
 @param option : "IPPROTO_TCP option id"
 @param value : "Integer option value"
 @return ? nova::UNSUPPORTED : "Socket option is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? tcp_set_tcp_int_option(os::NativeSocket fd, CInt option, int value) @private
{
	CInt native_value = (CInt)value;
	if (os::setsockopt(
		fd,
		(CInt)IPPROTO_TCP,
		option,
		&native_value,
		(os::Socklen_t)CInt::size
	) != 0) return tcp_platform_fault()~;
}

<*
 Convert a positive microsecond keepalive duration to Linux seconds.

 @param duration : "Positive keepalive duration in microseconds"
 @return "Seconds rounded up"
 @return ? nova::INVALID_STATE : "Duration does not fit a native int"
*>
fn int? tcp_duration_to_keepalive_seconds(Duration duration) @private
{
	if ((long)duration < 0) return nova::INVALID_STATE~;
	ulong micros  = (ulong)((long)duration);
	ulong seconds = (micros + 999_999) / 1_000_000;
	if (!seconds) seconds = 1;
	if (seconds > (ulong)CInt::max) return nova::INVALID_STATE~;
	return (int)seconds;
}

<*
 Return the native socket family for a concrete endpoint.

 @param endpoint : "Endpoint to encode"
 @return "Native address family"
 @return ? nova::UNSUPPORTED : "Endpoint family is not supported"
*>
fn os::AIFamily? socket_family_from_endpoint(Endpoint endpoint) @private
{
	if (endpoint.family == AddressFamily.IPV4) return os::AF_INET;
	if (endpoint.family == AddressFamily.IPV6) return os::AF_INET6;
	return nova::UNSUPPORTED~;
}

<*
 Convert a nova endpoint into Linux socket address storage.

 @param endpoint : "IPv4 or IPv6 endpoint"
 @param [out] out : "Native socket address storage"
 @param [out] len : "Native socket address length"
 @return ? nova::UNSUPPORTED : "Endpoint family is not supported"
 @require out != null : "Output address pointer must not be null"
 @require len != null : "Output length pointer must not be null"
*>
fn void? native_sockaddr_from_endpoint(Endpoint endpoint, SockAddrAny* out, os::Socklen_t* len)
{
	if (endpoint.family == AddressFamily.IPV4)
	{
		out.ipv4 = { };
		out.ipv4.family = (ushort)os::AF_INET;
		out.ipv4.port = linux::htons(endpoint.port);
		mem::copy(&out.ipv4.address, &endpoint.storage, uint::size);
		*len = (os::Socklen_t)SockAddrIn::size;
		return;
	}
	if (endpoint.family == AddressFamily.IPV6)
	{
		out.ipv6 = { };
		out.ipv6.family = (ushort)os::AF_INET6;
		out.ipv6.port = linux::htons(endpoint.port);
		mem::copy(&out.ipv6.address, &endpoint.storage, 16);
		out.ipv6.scope_id = endpoint.ipv6_scope_id();
		*len = (os::Socklen_t)SockAddrIn6::size;
		return;
	}
	return nova::UNSUPPORTED~;
}

<*
 Decode a `SockAddrAny` storage (filled by io_uring `IORING_OP_ACCEPT`) into a nova
 endpoint. Keeps the `os::` socket types inside the platform layer so the
 cross-platform TCP accept dispatcher can parse a peer with a plain `uint` length.

 @param addr : "Caller socket address storage"
 @param len : "Caller socket address length"
 @return "Decoded endpoint"
 @return ? nova::UNSUPPORTED : "Native address family is not supported"
 @return ? nova::BACKEND_FAILED : "Native address length is invalid"
 @require addr != null : "Address pointer must not be null"
*>
fn Endpoint? native_endpoint_from_sockaddr_any(
	SockAddrAny* addr,
	uint len
) => native_endpoint_from_sockaddr((os::SockAddrPtr)addr, (os::Socklen_t)len);

<*
 Convert Linux socket address storage into a nova endpoint.

 @param address : "Native socket address storage"
 @param len : "Native socket address length"
 @return "Decoded endpoint"
 @return ? nova::UNSUPPORTED : "Native address family is not supported"
 @return ? nova::BACKEND_FAILED : "Native address length is invalid"
 @require (void*)address != null : "Native address pointer must not be null"
*>
fn Endpoint? native_endpoint_from_sockaddr(os::SockAddrPtr address, os::Socklen_t len)
{
	SockAddrAny* storage = (SockAddrAny*)address;
	if ((os::AIFamily)storage.ipv4.family == os::AF_INET)
	{
		if (len < (os::Socklen_t)SockAddrIn::size) return nova::BACKEND_FAILED~;
		Endpoint endpoint = { .family = AddressFamily.IPV4, .port = linux::ntohs(storage.ipv4.port), };
		mem::copy(&endpoint.storage, &storage.ipv4.address, uint::size);
		return endpoint;
	}
	if ((os::AIFamily)storage.ipv6.family == os::AF_INET6)
	{
		if (len < (os::Socklen_t)SockAddrIn6::size) return nova::BACKEND_FAILED~;
		Endpoint endpoint = { .family = AddressFamily.IPV6, .port = linux::ntohs(storage.ipv6.port), };
		mem::copy(&endpoint.storage, &storage.ipv6.address, 16);
		endpoint.set_ipv6_scope_id(storage.ipv6.scope_id);
		return endpoint;
	}
	return nova::UNSUPPORTED~;
}

<*
 Create a configured non-blocking UDP socket.

 Stream-only options are rejected explicitly so UDP option behavior is not
 silently ignored.

 @param family : "Native IPv4 or IPv6 socket family"
 @param options : "Datagram socket options"
 @return "Open native datagram socket"
 @return ? nova::UNSUPPORTED : "A stream-only option was requested"
 @return ? nova::INVALID_STATE : "Socket option value is invalid"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup failed"
*>
fn os::NativeSocket? udp_create_socket(os::AIFamily family, SocketOptions options) @private
{
	if ((long)options.keepalive_idle < 0) return nova::INVALID_STATE~;
	if ((long)options.keepalive_interval < 0) return nova::INVALID_STATE~;
	if (options.keepalive_count > (uint)CInt::max) return nova::INVALID_STATE~;
	if (options.nodelay) return nova::UNSUPPORTED~;
	if (options.keepalive) return nova::UNSUPPORTED~;
	if ((long)options.keepalive_idle || (long)options.keepalive_interval
		|| options.keepalive_count) return nova::UNSUPPORTED~;

	os::NativeSocket fd = os::socket(family, os::SOCK_DGRAM | (os::AISockType)SOCK_CLOEXEC, IPPROTO_UDP);
	if (!fd.is_valid()) return udp_platform_fault()~;

	bool retained = false;
	defer if (!retained) (void)fd.close();

	if (catch fd.set_non_blocking(true)) return nova::BACKEND_FAILED~;
	if (options.reuse_addr) tcp_set_bool_option(fd, os::SO_REUSEADDR, true)!;
	if (options.reuse_port) tcp_set_bool_option(fd, os::SO_REUSEPORT, true)!;
	if (options.send_buffer_size) tcp_set_uint_option(fd, os::SO_SNDBUF, options.send_buffer_size)!;
	if (options.recv_buffer_size) tcp_set_uint_option(fd, os::SO_RCVBUF, options.recv_buffer_size)!;

	retained = true;
	return fd;
}

<*
 Apply one IPv4 multicast membership socket option.

 Only endpoint address and family fields are encoded in the native request;
 ports in `group` are ignored.

 @param handle : "Native datagram descriptor"
 @param group : "IPv4 multicast group and optional interface"
 @param option : "Multicast membership option id"
 @return ? nova::UNSUPPORTED : "Group or interface address is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? udp_set_multicast_membership(NativeHandle handle, MulticastGroup group, CInt option) @private
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;
	if (udp_socket_family(fd)! != group.group.family) return nova::UNSUPPORTED~;
	if (group.group.family == AddressFamily.IPV6)
	{
		CInt membership = IPV6_LEAVE_GROUP;
		if (option == IP_ADD_MEMBERSHIP) membership = IPV6_JOIN_GROUP;
		udp_set_ipv6_multicast_membership(fd, group, membership)!;
		return;
	}
	if (!udp_endpoint_is_ipv4_multicast(group.group)) return nova::UNSUPPORTED~;
	if (group.interface_addr.family != AddressFamily.UNSPEC
		&& group.interface_addr.family != AddressFamily.IPV4) return nova::UNSUPPORTED~;

	uint imr_interface = 0;
	if (group.interface_addr.family == AddressFamily.IPV4) imr_interface = udp_ipv4_raw_address(group.interface_addr);
	UdpIpMreq request = { .imr_multiaddr = udp_ipv4_raw_address(group.group), .imr_interface = imr_interface, };
	if (os::setsockopt(
		fd,
		IPPROTO_IP,
		option,
		&request,
		(os::Socklen_t)UdpIpMreq::size
	) != 0) return udp_platform_fault()~;
}

<*
 Apply one IPv6 multicast membership socket option.

 @param fd : "Native datagram descriptor"
 @param group : "IPv6 multicast group and optional interface scope id"
 @param option : "IPv6 multicast membership option id"
 @return ? nova::UNSUPPORTED : "Group or interface address is unsupported"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? udp_set_ipv6_multicast_membership(os::NativeSocket fd, MulticastGroup group, CInt option) @private
{
	if (!udp_endpoint_is_ipv6_multicast(group.group)) return nova::UNSUPPORTED~;

	UdpIpv6Mreq request;
	request.ipv6mr_interface = udp_ipv6_interface_scope(group.interface_addr)!;
	mem::copy(&request.ipv6mr_multiaddr, &group.group.storage, 16);
	if (os::setsockopt(
		fd,
		IPPROTO_IPV6,
		option,
		&request,
		(os::Socklen_t)UdpIpv6Mreq::size
	) != 0) return udp_platform_fault()~;
}

<*
 Apply one IPv4 source-specific multicast membership socket option.

 @param handle : "Native datagram descriptor"
 @param group : "IPv4 multicast group, optional interface and IPv4 source"
 @param option : "Source-specific multicast membership option id"
 @return ? nova::UNSUPPORTED : "Group, interface or source address is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? udp_set_source_multicast_membership(NativeHandle handle, SourceMulticastGroup group, CInt option) @private
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;
	if (udp_socket_family(fd)! != group.group.family) return nova::UNSUPPORTED~;
	if (group.group.family == AddressFamily.IPV6)
	{
		CInt source_membership = MCAST_LEAVE_SOURCE_GROUP;
		if (option == IP_ADD_SOURCE_MEMBERSHIP) source_membership = MCAST_JOIN_SOURCE_GROUP;
		udp_set_ipv6_source_multicast_membership(fd, group, source_membership)!;
		return;
	}
	if (!udp_endpoint_is_ipv4_multicast(group.group)) return nova::UNSUPPORTED~;
	if (group.source.family != AddressFamily.IPV4) return nova::UNSUPPORTED~;
	if (udp_endpoint_is_ipv4_multicast(group.source)) return nova::UNSUPPORTED~;
	if (group.interface_addr.family != AddressFamily.UNSPEC
		&& group.interface_addr.family != AddressFamily.IPV4) return nova::UNSUPPORTED~;

	uint imr_interface = 0;
	if (group.interface_addr.family == AddressFamily.IPV4) imr_interface = udp_ipv4_raw_address(group.interface_addr);
	UdpIpMreqSource request = {
		.imr_multiaddr = udp_ipv4_raw_address(group.group),
		.imr_interface = imr_interface,
		.imr_sourceaddr = udp_ipv4_raw_address(group.source),
	};
	if (os::setsockopt(
		fd,
		IPPROTO_IP,
		option,
		&request,
		(os::Socklen_t)UdpIpMreqSource::size
	) != 0) return udp_platform_fault()~;
}

<*
 Apply one IPv6 source-specific multicast socket option.

 @param fd : "Native datagram descriptor"
 @param group : "IPv6 multicast group, optional interface scope id and IPv6 source"
 @param option : "RFC 3678 membership option id"
 @return ? nova::UNSUPPORTED : "Group, interface or source address is unsupported"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? udp_set_ipv6_source_multicast_membership(os::NativeSocket fd, SourceMulticastGroup group, CInt option) @private
{
	if (!udp_endpoint_is_ipv6_multicast(group.group)) return nova::UNSUPPORTED~;
	if (group.source.family != AddressFamily.IPV6) return nova::UNSUPPORTED~;
	if (udp_endpoint_is_ipv6_multicast(group.source)) return nova::UNSUPPORTED~;

	UdpGroupSourceReq request;
	request.gsr_interface = udp_ipv6_interface_scope(group.interface_addr)!;
	SockAddrAny group_address;
	SockAddrAny source_address;
	os::Socklen_t group_len;
	os::Socklen_t source_len;
	native_sockaddr_from_endpoint(group.group, &group_address, &group_len)!;
	native_sockaddr_from_endpoint(group.source, &source_address, &source_len)!;
	mem::copy(&request.gsr_group, &group_address, SockAddrAny::size);
	mem::copy(&request.gsr_source, &source_address, SockAddrAny::size);
	if (os::setsockopt(
		fd,
		IPPROTO_IPV6,
		option,
		&request,
		(os::Socklen_t)UdpGroupSourceReq::size
	) != 0) return udp_platform_fault()~;
}

<*
 Set an unsigned IPPROTO_IPV6 option using UDP fault mapping.

 @param handle : "Native datagram descriptor"
 @param option : "IPPROTO_IPV6 option id"
 @param value : "Unsigned option value"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? udp_set_ipv6_uint_option(NativeHandle handle, CInt option, uint value) @private
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;
	if (os::setsockopt(fd, IPPROTO_IPV6, option, &value, (os::Socklen_t)uint::size) != 0) return udp_platform_fault()~;
}

<*
 Set a boolean SOL_SOCKET option using UDP fault mapping.

 @param handle : "Native datagram descriptor"
 @param option : "SOL_SOCKET option id"
 @param enabled : "Boolean option value"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? udp_set_socket_bool_option(NativeHandle handle, CInt option, bool enabled) @private
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;
	CInt value = (CInt)enabled;
	if (os::setsockopt(
		fd,
		os::SOL_SOCKET,
		option,
		&value,
		(os::Socklen_t)CInt::size
	) != 0) return udp_platform_fault()~;
}

<*
 Set an integer IPPROTO_IP option using UDP fault mapping.

 @param handle : "Native datagram descriptor"
 @param option : "IPPROTO_IP option id"
 @param value : "Integer option value"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? udp_set_ip_int_option(NativeHandle handle, CInt option, int value) @private
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;
	CInt native_value = (CInt)value;
	if (os::setsockopt(
		fd,
		IPPROTO_IP,
		option,
		&native_value,
		(os::Socklen_t)CInt::size
	) != 0) return udp_platform_fault()~;
}

<*
 Set an IPv4 address IPPROTO_IP option using UDP fault mapping.

 @param handle : "Native datagram descriptor"
 @param option : "IPPROTO_IP option id"
 @param address : "Network-order IPv4 address bytes, or zero for default"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "setsockopt failed"
*>
fn void? udp_set_ip_addr_option(NativeHandle handle, CInt option, uint address) @private
{
	os::NativeSocket fd = (os::NativeSocket)(int)handle;
	if (!fd.is_valid()) return nova::INVALID_SOCKET~;
	if (os::setsockopt(fd, IPPROTO_IP, option, &address, (os::Socklen_t)uint::size) != 0) return udp_platform_fault()~;
}

<*
 Report whether an endpoint is an IPv4 multicast group address.

 @param endpoint : "Endpoint to inspect"
 @return "True when the IPv4 address is in 224.0.0.0/4"
*>
fn bool udp_endpoint_is_ipv4_multicast(Endpoint endpoint) @private
{
	if (endpoint.family != AddressFamily.IPV4) return false;
	uint first = (uint)endpoint.storage[0];
	return first >= 224 && first <= 239;
}

<*
 Report whether an endpoint is an IPv6 multicast group address.

 @param endpoint : "Endpoint to inspect"
 @return "True when the IPv6 address starts with 0xff"
*>
fn bool udp_endpoint_is_ipv6_multicast(Endpoint endpoint) @private
{
	return endpoint.family == AddressFamily.IPV6 && endpoint.storage[0] == (char)0xff;
}

<*
 Report whether an IPv6 endpoint stores the unspecified address.

 @param endpoint : "Endpoint to inspect"
 @return "True when all IPv6 address bytes are zero"
*>
fn bool udp_endpoint_is_ipv6_unspecified(Endpoint endpoint) @private
{
	if (endpoint.family != AddressFamily.IPV6) return false;
	foreach (c : endpoint.storage[0:16])
	{
		if (c != 0) return false;
	}
	return true;
}

<*
 Return the IPv6 multicast interface index encoded in an endpoint.

 @param interface_addr : "UNSPEC, IPv6 unspecified or IPv6 endpoint carrying a scope id"
 @return "Native interface index, or zero for the platform default"
 @return ? nova::UNSUPPORTED : "Interface endpoint cannot represent an interface index"
*>
fn uint? udp_ipv6_interface_scope(Endpoint interface_addr) @private
{
	if (interface_addr.family == AddressFamily.UNSPEC) return 0;
	if (interface_addr.family != AddressFamily.IPV6) return nova::UNSUPPORTED~;
	uint scope_id = interface_addr.ipv6_scope_id();
	if (!scope_id && !udp_endpoint_is_ipv6_unspecified(interface_addr)) return nova::UNSUPPORTED~;
	return scope_id;
}

<*
 Return the address family of a native UDP socket.

 @param fd : "Native datagram descriptor"
 @return "Current socket address family"
 @return ? nova::UNSUPPORTED : "Native address family is unsupported"
 @return ? nova::BACKEND_FAILED : "getsockname failed"
*>
fn AddressFamily? udp_socket_family(os::NativeSocket fd) @private
{
	SockAddrAny address;
	os::Socklen_t len = (os::Socklen_t)SockAddrAny::size;
	if (getsockname(fd, (os::SockAddrPtr)&address, &len) != 0) return udp_platform_fault()~;
	if ((os::AIFamily)address.ipv4.family == os::AF_INET) return AddressFamily.IPV4;
	if ((os::AIFamily)address.ipv6.family == os::AF_INET6) return AddressFamily.IPV6;
	return nova::UNSUPPORTED~;
}

<*
 Return the raw network-order IPv4 bytes stored in an endpoint.

 @param endpoint : "IPv4 endpoint"
 @return "Network-order IPv4 address bytes"
*>
fn uint udp_ipv4_raw_address(Endpoint endpoint) @private
{
	uint address;
	mem::copy(&address, &endpoint.storage, uint::size);
	return address;
}

<*
 Translate the current POSIX errno into nova's UDP setup faults.

 @return "Mapped nova UDP fault"
*>
fn fault udp_platform_fault() @private
{
	return udp_fault_from_errno(libc::errno());
}

<*
 Translate a POSIX errno into nova's semantic UDP faults.

 @param err : "POSIX errno value"
 @return "Mapped nova fault"
*>
fn fault udp_fault_from_errno(Errno err) @private
{
	if (err == EADDRINUSE) return nova::ADDRESS_IN_USE;
	if (err == ECONNREFUSED) return nova::CONNECTION_REFUSED;
	if (err == ECONNRESET) return nova::CONNECTION_RESET;
	if (err == ETIMEDOUT) return nova::CONNECTION_TIMED_OUT;
	if (err == ENETUNREACH) return nova::NETWORK_UNREACHABLE;
	if (err == EADDRNOTAVAIL || err == EINVAL || err == ENODEV || err == EOPNOTSUPP || err == LINUX_EAFNOSUPPORT
		|| err == LINUX_EPROTONOSUPPORT) return nova::UNSUPPORTED;
	if (err == EBADF || err == ENOTSOCK) return nova::INVALID_SOCKET;
	return nova::BACKEND_FAILED;
}

<*
 Report whether `connect` is still in progress on a non-blocking socket.

 @param err : "POSIX errno value"
 @return "True when connect should complete asynchronously"
*>
fn bool tcp_connect_is_delayed(Errno err) @private
{
	return err == EINPROGRESS || err == EAGAIN || err == EWOULDBLOCK;
}

<*
 Translate the current POSIX errno into nova's synchronous setup faults.

 @return "Mapped nova TCP fault"
*>
fn fault tcp_platform_fault() @private
{
	return tcp_fault_from_errno(libc::errno());
}

<*
 Translate a POSIX errno into nova's semantic TCP faults.

 @param err : "POSIX errno value"
 @return "Mapped nova fault"
*>
fn fault tcp_fault_from_errno(Errno err) @private
{
	if (err == EADDRINUSE) return nova::ADDRESS_IN_USE;
	if (err == ECONNREFUSED) return nova::CONNECTION_REFUSED;
	if (err == ECONNRESET) return nova::CONNECTION_RESET;
	if (err == EPIPE) return nova::CONNECTION_RESET;
	if (err == posix_errno::E_NOTCONN || err == posix_errno::E_SHUTDOWN) return nova::CONNECTION_RESET;
	if (err == ETIMEDOUT) return nova::CONNECTION_TIMED_OUT;
	if (err == ENETUNREACH) return nova::NETWORK_UNREACHABLE;
	if (err == EADDRNOTAVAIL || err == EOPNOTSUPP || err == LINUX_EAFNOSUPPORT
		|| err == LINUX_EPROTONOSUPPORT) return nova::UNSUPPORTED;
	if (err == EBADF || err == ENOTSOCK) return nova::INVALID_SOCKET;
	return nova::BACKEND_FAILED;
}

<*
 Map an io_uring completion `-errno` (negated CQE result) to the TCP terminal
 fault, matching what `native_tcp_read`/`native_tcp_write` produce for the same
 errno. Passed to the shared stream submit as the completion fault mapper.

 @param err : "Negated CQE result (positive POSIX errno)"
 @return "Mapped nova fault"
*>
fn fault tcp_completion_fault(int err) => tcp_fault_from_errno((Errno)err);
