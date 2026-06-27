module nova::net::udp;

import std::io;

import nova @norecurse;
import nova::net;
import nova::op @public;
import nova::backend @public;
import nova::timer;

<*
 Callback invoked when a receive operation reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the receive"
 @param socket : "UDP socket that owns the operation"
 @param op : "Receive operation storage"
 @param result : "Receive result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias RecvCallback = fn void(Loop* loop, Socket* socket, RecvOp* op, RecvResult* result, void* userdata);

<*
 Callback invoked when a send operation reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the send"
 @param socket : "UDP socket that owns the operation"
 @param op : "Send operation storage"
 @param result : "Send result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias SendCallback = fn void(Loop* loop, Socket* socket, SendOp* op, SendResult* result, void* userdata);

<*
 Callback invoked when UDP close reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the close"
 @param socket : "UDP socket being closed"
 @param op : "Close operation storage"
 @param result : "Close result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias SocketCloseCallback = fn void(Loop* loop, Socket* socket, SocketCloseOp* op, CloseResult* result, void* userdata);

<*
 Caller-owned UDP socket handle.

 The native descriptor is owned by this handle while `open` is true. At most one
 receive, one send and one close operation may be active at a time, but a receive
 and a send may run concurrently (full duplex) — they occupy independent slots on
 the socket's persistent backend watcher.
*>
struct Socket
{
	SocketOptions options;
	NativeHandle native_handle;
	backend::Watcher watcher;
	op::Header* active_recv;
	op::Header* active_send;
	op::Header* active_close;
	Endpoint local;
	Endpoint remote;
	bool initialized;
	bool bound;
	bool connected;
	bool open;
}

<*
 Result delivered for one UDP receive operation.

 The buffer slice aliases the caller-provided receive storage and is valid only
 during the callback that receives this result. `bytes` is capped to the
 number of bytes copied into `buffer`; `truncated` reports that the datagram
 was larger than the buffer, including zero-length buffers. `peer` is
 meaningful only when `error.status` is success. Timeout, cancellation and
 close completions report zero bytes, a zeroed peer and `truncated == false`.
*>
struct RecvResult
{
	ErrorInfo error;
	char[] buffer;
	sz bytes;
	Endpoint peer;
	bool truncated;
}

<*
 Result delivered for one UDP send operation.

 `bytes` is the number of datagram bytes accepted before the terminal status
 was reported. UDP sends complete as a single datagram; failures before native
 send acceptance report zero bytes. Timeout, cancellation and close
 completions before native send acceptance also report zero bytes.
*>
struct SendResult
{
	ErrorInfo error;
	sz bytes;
}

<*
 Caller-owned UDP receive operation storage.

 The receive buffer is borrowed from submission until the terminal callback
 starts. Internal driver fields are cleared before user code runs so the
 operation can be reposted from its callback.
*>
struct RecvOp
{
	inline op::Header header;
	backend::OpState backend;
	char[] buffer;
	net::UdpMsgHdr msghdr;
	net::UdpIoVec iov;
	net::SockAddrAny peer_addr;
	RecvCallback callback;
}

<*
 Caller-owned UDP send operation storage.

 The byte slice is borrowed from submission until the terminal callback starts.
 Explicit remote endpoints are copied into the operation so caller stack storage
 may go out of scope after submission.
*>
struct SendOp
{
	inline op::Header header;
	backend::OpState backend;
	char[] bytes;
	Endpoint remote;
	net::UdpMsgHdr msghdr;
	net::UdpIoVec iov;
	net::SockAddrAny remote_addr;
	sz sent;
	bool has_remote;
	bool completed;
	SendCallback callback;
}

<*
 Caller-owned async UDP close operation storage.

 The callback field is set by `close` and cleared before the terminal callback
 starts, so the same storage may be reused from that callback.
*>
struct SocketCloseOp
{
	inline op::Header header;
	SocketCloseCallback callback;
}

<*
 Initialize caller-owned UDP socket storage.

 This does not create a native datagram socket; `bind` or `connect` creates and
 owns it. Socket options are stored without validation until that native setup.

 @param [&inout] self : "UDP socket storage"
 @param options : "Socket options stored without validation until native setup"
 @return "Initialized socket"
 @return ? nova::INVALID_STATE : "Socket is already initialized"
 @ensure self.initialized : "Socket is initialized when init succeeds"
*>
fn Socket*? Socket.init(&self, SocketOptions options = { })
{
	if (self.initialized) return nova::INVALID_STATE~;
	*self = { };
	self.options = options;
	self.native_handle = (NativeHandle)-1;
	self.initialized = true;
	return self;
}

<*
 Destroy an initialized UDP socket.

 @param [&inout] self : "Closed socket with no active operations"
 @require self.initialized : "Socket must be initialized"
 @require !self.open : "Socket must be closed"
 @require self.active_recv == null : "Receive operation must be inactive"
 @require self.active_send == null : "Send operation must be inactive"
 @require self.active_close == null : "Close operation must be inactive"
 @ensure !self.initialized : "Socket is uninitialized after destroy"
*>
fn void Socket.destroy(&self)
{
	*self = { };
	self.native_handle = (NativeHandle)-1;
}

<*
 Report whether this UDP socket currently owns an open native handle.

 @param self : "Socket storage to inspect"
 @return "True when the socket is open"
*>
fn bool Socket.is_open(&self) => self.open;

<*
 Borrow this UDP socket's native handle without transferring ownership.

 @param self : "Socket storage to inspect"
 @return "Open native datagram handle"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
*>
fn NativeHandle? Socket.borrow_native(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return self.native_handle;
}

<*
 Return this socket's current local endpoint.

 The endpoint is queried from the native socket so kernel-assigned addresses
 and ports are reported directly.

 @param self : "Open UDP socket storage"
 @return "Current local endpoint"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "Native endpoint query failed"
*>
fn Endpoint? Socket.local_endpoint(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return net::native_udp_socket_local_endpoint(self.native_handle);
}

<*
 Return this socket's connected default peer endpoint.

 @param self : "Open UDP socket storage"
 @return "Current peer endpoint"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? NOT_FOUND : "Socket is open but has no connected default peer"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "Native endpoint query failed"
*>
fn Endpoint? Socket.peer_endpoint(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return net::native_udp_socket_peer_endpoint(self.native_handle);
}

<*
 Try to send one datagram immediately without submitting an operation.

 This preserves the ordering of async sends: when a send is active, the call
 returns `BUSY` instead of sending around queued data.

 @param self : "Open UDP socket"
 @param bytes : "Caller-owned datagram bytes"
 @param remote : "Optional explicit destination endpoint"
 @return "Datagram bytes accepted by the OS"
 @return ? nova::INVALID_STATE : "Socket is not initialized, open or lacks a default remote"
 @return ? nova::BUSY : "Socket has an active close or send operation"
 @return ? std::io::WOULD_BLOCK : "The datagram cannot be sent now"
 @return ? nova::CONNECTION_REFUSED : "Connected UDP socket received an ICMP refusal"
 @return ? nova::UNSUPPORTED : "Explicit remote endpoint family or native socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native send failed"
*>
fn sz? Socket.try_send(&self, char[] bytes, Endpoint* remote = null)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	if (self.active_close || self.active_send) return nova::BUSY~;
	if (!remote && !self.connected) return nova::INVALID_STATE~;
	return net::native_udp_send(self.native_handle, bytes, remote);
}

<*
 Return bytes still pending in this socket's active send operation.

 @param self : "Socket storage to inspect"
 @return "Pending async send bytes, or zero when no send is active"
*>
fn sz Socket.send_queue_size(&self)
{
	if (!self.active_send) return 0;
	SendOp* op = (SendOp*)self.active_send;
	if (op.sent >= op.bytes.len) return 0;
	return op.bytes.len - op.sent;
}

<*
 Bind a UDP socket to a local endpoint.

 @param socket : "Initialized closed UDP socket"
 @param local : "Local IPv4 or IPv6 endpoint"
 @return ? nova::INVALID_STATE : "Socket is not initialized, already open, closing or has invalid socket options"
 @return ? nova::UNSUPPORTED : "Endpoint family or stream-only socket option is unsupported"
 @return ? nova::ADDRESS_IN_USE : "Address is already in use"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? bind(Socket* socket, Endpoint local)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::INVALID_STATE~;
	if (socket.open || socket.bound) return nova::INVALID_STATE~;
	NativeHandle handle = net::native_udp_bind(local, socket.options)!;
	Endpoint? bound     = net::native_udp_socket_local_endpoint(handle);
	if (catch err = bound)
	{
		(void)net::native_udp_close(handle);
		return err~;
	}
	socket.native_handle = handle;
	socket.local = bound;
	socket.bound = true;
	socket.open = true;
}

<*
 Connect a UDP socket to a default remote endpoint.

 @param socket : "Initialized UDP socket"
 @param remote : "Default remote IPv4 or IPv6 endpoint"
 @return ? nova::INVALID_STATE : "Socket is not initialized, already connected or has invalid socket options"
 @return ? nova::BUSY : "Socket has an active receive, send or close operation"
 @return ? nova::UNSUPPORTED : "Endpoint family or stream-only socket option is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup or connect failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? connect(Socket* socket, Endpoint remote)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.connected) return nova::INVALID_STATE~;
	if (socket.active_recv || socket.active_send || socket.active_close) return nova::BUSY~;

	if (socket.open)
	{
		net::native_udp_connect(socket.native_handle, remote)!;
		socket.remote = remote;
		socket.connected = true;
		return;
	}

	NativeHandle handle = net::native_udp_connect_new(remote, socket.options)!;
	Endpoint? bound     = net::native_udp_socket_local_endpoint(handle);
	if (catch err = bound)
	{
		(void)net::native_udp_close(handle);
		return err~;
	}
	socket.native_handle = handle;
	socket.local = bound;
	socket.bound = true;
	socket.open = true;

	socket.remote = remote;
	socket.connected = true;
}

<*
 Submit one UDP receive operation using a caller-owned buffer.

 The buffer is borrowed until the terminal callback starts. Submission userdata
 is delivered through the callback argument, and `op.header.userdata` has been
 cleared before the callback runs. The callback starts after `op` is reusable.
 The result pointer is valid only during the callback.

 @param loop : "Loop that owns the receive operation"
 @param socket : "Open UDP socket"
 @param [out] buffer : "Caller-owned destination bytes borrowed until callback"
 @param op : "Receive operation storage"
 @param callback : "Callback invoked when receive reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, socket or receive options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Socket or operation already has a conflicting active operation"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require socket != null : "Socket pointer must not be null"
 @require op != null : "Receive operation pointer must not be null"
*>
fn Ref? recv(Loop* loop, Socket* socket, char[] buffer, RecvOp* op, RecvCallback callback, void* userdata = null)
{
	if (!loop.initialized || !socket.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open || (!socket.bound && !socket.connected)) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (socket.active_recv || op.header.active()) return nova::BUSY~;

	op.buffer = buffer;
	op.callback = callback;

	if (backend::udp_completion_recv_enabled(loop))
	{
		net::native_udp_recvmsg_init(&op.msghdr, &op.iov, &op.peer_addr, buffer);
		Ref? received = backend::udp_recvmsg_submit(
			loop,
			&op.header,
			&op.backend,
			socket.native_handle,
			(ulong)(uptr)&op.msghdr,
			(uint)net::MSG_TRUNC,
			&dispatch_recv,
			socket,
			userdata
		);
		if (catch received)
		{
			reset_recv_fields(op);
			return received;
		}
		Ref rref = received;
		socket.active_recv = &op.header;
		return rref;
	}

	Ref? submitted = backend::udp_recv_submit(
		loop,
		&op.header,
		&op.backend,
		&socket.watcher,
		socket.native_handle,
		&dispatch_recv,
		socket,
		userdata
	);
	if (catch submitted)
	{
		reset_recv_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	socket.active_recv = &op.header;
	return oref;
}

<*
 Submit one UDP send operation using caller-owned bytes.

 The byte slice is borrowed until the terminal callback starts. Explicit remote
 endpoints are copied before submission. Submission userdata is delivered
 through the callback argument, and `op.header.userdata` has been cleared before the
 callback runs. The callback starts after `op` is reusable. The result pointer
 is valid only during the callback.

 @param loop : "Loop that owns the send operation"
 @param socket : "Open UDP socket"
 @param bytes : "Caller-owned source bytes borrowed until callback"
 @param remote : "Optional explicit remote endpoint"
 @param op : "Send operation storage"
 @param callback : "Callback invoked when send reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, socket, remote endpoint or send options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Socket has an active close or active send"
 @return ? nova::UNSUPPORTED : "Explicit remote endpoint family or native socket family is unsupported"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require socket != null : "Socket pointer must not be null"
 @require op != null : "Send operation pointer must not be null"
*>
fn Ref? send(
	Loop* loop,
	Socket* socket,
	char[] bytes,
	Endpoint* remote,
	SendOp* op,
	SendCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !socket.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	if (!remote && !socket.connected) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (socket.active_send || op.header.active()) return nova::BUSY~;

	op.bytes = bytes;
	op.remote = { };
	op.sent = 0;
	op.has_remote = false;
	op.completed = false;
	if (remote)
	{
		op.remote = *remote;
		op.has_remote = true;
	}
	op.callback = callback;

	if (backend::udp_completion_send_enabled(loop))
	{
		Endpoint* completion_remote = op.has_remote ? &op.remote : null;
		if (catch e = net::native_udp_sendmsg_init(&op.msghdr, &op.iov, &op.remote_addr, completion_remote, bytes))
		{
			reset_send_fields(op);
			return e~;
		}
		Ref? sent = backend::udp_sendmsg_submit(
			loop,
			&op.header,
			&op.backend,
			socket.native_handle,
			(ulong)(uptr)&op.msghdr,
			0,
			&dispatch_send,
			socket,
			userdata
		);
		if (catch sent)
		{
			reset_send_fields(op);
			return sent;
		}
		Ref sref = sent;
		socket.active_send = &op.header;
		return sref;
	}

	Endpoint* send_remote = null;
	if (op.has_remote) send_remote = &op.remote;
	fault status;
	bool complete   = false;
	sz? sent_result = net::native_udp_send(socket.native_handle, op.bytes, send_remote);
	fault send_err  = @catch(sent_result);

	if (try sent = sent_result)
	{
		complete = true;
		op.sent = sent;
	}

	if (send_err == io::WOULD_BLOCK)
	{
		complete = false;
	}

	if (send_err && send_err != io::WOULD_BLOCK)
	{
		complete = true;
		status = send_err;
	}
	op.completed = complete;

	Ref? submitted = backend::udp_send_submit(
		loop,
		&op.header,
		&op.backend,
		&socket.watcher,
		socket.native_handle,
		complete,
		status,
		&dispatch_send,
		socket,
		userdata
	);
	if (catch submitted)
	{
		reset_send_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	socket.active_send = &op.header;
	return oref;
}

<*
 Enable or disable IPv4 broadcast sends on this UDP socket.

 @param socket : "Open UDP socket"
 @param enabled : "Broadcast socket option value"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket option setup failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? set_broadcast(Socket* socket, bool enabled)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	net::native_udp_set_broadcast(socket.native_handle, enabled)!;
}

<*
 Set the unicast IPv4 packet TTL for this UDP socket.

 @param socket : "Open UDP socket"
 @param ttl : "TTL in the inclusive range 1..255"
 @return ? nova::INVALID_STATE : "Socket is not initialized, open or TTL is out of range"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket option setup failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? set_ttl(Socket* socket, uint ttl)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	if (!ttl || ttl > 255) return nova::INVALID_STATE~;
	net::native_udp_set_ttl(socket.native_handle, ttl)!;
}

<*
 Enable or disable IPv4 multicast loopback for this UDP socket.

 @param socket : "Open UDP socket"
 @param enabled : "Multicast loopback option value"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket option setup failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? set_multicast_loop(Socket* socket, bool enabled)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	net::native_udp_set_multicast_loop(socket.native_handle, enabled)!;
}

<*
 Set the IPv4 multicast packet TTL for this UDP socket.

 @param socket : "Open UDP socket"
 @param ttl : "TTL in the inclusive range 1..255"
 @return ? nova::INVALID_STATE : "Socket is not initialized, open or TTL is out of range"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket option setup failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? set_multicast_ttl(Socket* socket, uint ttl)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	if (!ttl || ttl > 255) return nova::INVALID_STATE~;
	net::native_udp_set_multicast_ttl(socket.native_handle, ttl)!;
}

<*
 Set the multicast interface for this UDP socket.

 `interface_addr` may be `AddressFamily.UNSPEC` for the platform default
 interface, an IPv4 local interface address, or an IPv6 endpoint whose scope id
 is used as the interface index.

 @param socket : "Open UDP socket"
 @param interface_addr : "Default, IPv4 local address or IPv6 scoped interface endpoint"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::UNSUPPORTED : "Interface family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket option setup failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? set_multicast_interface(Socket* socket, Endpoint interface_addr)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	net::native_udp_set_multicast_interface(socket.native_handle, interface_addr)!;
}

<*
 Join a multicast group.

 Only endpoint address and family fields participate in membership setup; ports
 in `group` are ignored.

 @param socket : "Open UDP socket"
 @param group : "IPv4 or IPv6 multicast group and optional interface"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::UNSUPPORTED : "Multicast group or interface is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native multicast setup failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? join_multicast(Socket* socket, MulticastGroup group)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	net::native_udp_join_multicast(socket.native_handle, group)!;
}

<*
 Leave a multicast group.

 Only endpoint address and family fields participate in membership teardown;
 ports in `group` are ignored.

 @param socket : "Open UDP socket"
 @param group : "IPv4 or IPv6 multicast group and optional interface"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::UNSUPPORTED : "Multicast group or interface is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native multicast teardown failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? leave_multicast(Socket* socket, MulticastGroup group)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	net::native_udp_leave_multicast(socket.native_handle, group)!;
}

<*
 Join a source-specific multicast group.

 Only endpoint address and family fields participate in membership setup; ports
 in `group` are ignored.

 @param socket : "Open UDP socket"
 @param group : "Multicast group, optional interface and same-family source"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::UNSUPPORTED : "Source-specific multicast is unsupported or addresses are invalid"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native multicast setup failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? join_source_multicast(Socket* socket, SourceMulticastGroup group)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	net::native_udp_join_source_multicast(socket.native_handle, group)!;
}

<*
 Leave a source-specific multicast group.

 Only endpoint address and family fields participate in membership teardown;
 ports in `group` are ignored.

 @param socket : "Open UDP socket"
 @param group : "Multicast group, optional interface and same-family source"
 @return ? nova::INVALID_STATE : "Socket is not initialized or open"
 @return ? nova::BUSY : "Socket has an active close operation"
 @return ? nova::UNSUPPORTED : "Source-specific multicast is unsupported or addresses are invalid"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native multicast teardown failed"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? leave_source_multicast(Socket* socket, SourceMulticastGroup group)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	net::native_udp_leave_source_multicast(socket.native_handle, group)!;
}

<*
 Submit async UDP socket close.

 Close first completes active socket operations with `CLOSED`, then closes the
 native descriptor and queues this close operation as an immediate completion.
 `options.abortive` is ignored for UDP sockets.
 Submission userdata is delivered through the callback argument, and
 `op.header.userdata` has been cleared before the callback runs. The callback
 starts after `op` is reusable. The result pointer is valid only during the
 callback.

 @param loop : "Loop that owns the close operation"
 @param socket : "UDP socket being closed"
 @param op : "Close operation storage"
 @param options : "Close options; `abortive` is ignored for UDP sockets"
 @param callback : "Callback invoked when close reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop or socket is not ready for close"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Socket or close operation already has an active close"
 @return ? nova::BACKEND_FAILED : "Native close failed"
 @require loop != null : "Loop pointer must not be null"
 @require socket != null : "Socket pointer must not be null"
 @require op != null : "Close operation pointer must not be null"
*>
fn Ref? close(
	Loop* loop,
	Socket* socket,
	SocketCloseOp* op,
	CloseOptions options,
	SocketCloseCallback callback,
	void* userdata = null
)
{
	(void)options;
	if (!loop.initialized || !socket.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (socket.active_close || op.header.active()) return nova::BUSY~;
	if (!socket.open && !socket.active_recv && !socket.active_send) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;

	if (socket.active_recv) op::complete(loop, socket.active_recv, nova::CLOSED)!;
	if (socket.active_send) op::complete(loop, socket.active_send, nova::CLOSED)!;

	backend::watcher_close(loop, &socket.watcher);

	fault status = @catch(net::native_udp_close(socket.native_handle));

	socket.native_handle = (NativeHandle)-1;
	socket.open = false;
	socket.bound = false;
	socket.connected = false;
	socket.local = { };
	socket.remote = { };
	op.callback = callback;

	Ref? submitted = nova::submit_udp_close(loop, &op.header, &dispatch_close, socket, userdata, status);
	if (catch submitted)
	{
		reset_close_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	socket.active_close = &op.header;
	return oref;
}

<*
 Close a UDP socket synchronously when it has no active operations.

 If a previous receive or send registered the persistent watcher, `close_now`
 unregisters it on the owning loop thread before closing the descriptor.

 @param socket : "Open UDP socket with no active operations"
 @return ? nova::INVALID_STATE : "Socket is not initialized, not open or its loop is unusable"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Socket has an active receive, send or close operation"
 @require socket != null : "Socket pointer must not be null"
*>
fn void? close_now(Socket* socket)
{
	if (!socket.initialized) return nova::INVALID_STATE~;
	if (socket.active_recv) return nova::BUSY~;
	if (socket.active_send) return nova::BUSY~;
	if (socket.active_close) return nova::BUSY~;
	if (!socket.open) return nova::INVALID_STATE~;
	if (socket.watcher.registered)
	{
		Loop* loop = socket.watcher.loop;
		if (!loop || !loop.initialized) return nova::INVALID_STATE~;
		if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
		backend::watcher_close(loop, &socket.watcher);
	}
	net::native_udp_close(socket.native_handle)!;
	socket.watcher = { };
	socket.native_handle = (NativeHandle)-1;
	socket.open = false;
	socket.bound = false;
	socket.connected = false;
	socket.local = { };
	socket.remote = { };
}

<*
 Dispatch a UDP receive completion through the typed callback.

 Backend readiness is only a prompt. If a stale event produces `WOULD_BLOCK`,
 the operation is rearmed without invoking user code.

 @param loop : "Loop dispatching the receive operation"
 @param raw : "Header pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_recv(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	RecvOp* op         = (RecvOp*)raw;
	Socket* socket     = (Socket*)header.owner;

	if (header.terminal_status)
	{
		finish_recv(loop, socket, op, header.terminal_status, 0, { }, false);
		return;
	}

	if (backend::op_completion(header))
	{
		sz res = backend::op_completion_result(header);
		if (res < 0)
		{
			finish_recv(loop, socket, op, net::udp_completion_fault((int)-res), 0, { }, false);
			return;
		}
		bool truncated = (op.msghdr.msg_flags & net::MSG_TRUNC) != 0 || res > op.buffer.len;
		sz copied      = res > op.buffer.len ? op.buffer.len : res;
		Endpoint peer  = { };
		if (try parsed = net::native_endpoint_from_sockaddr_any(
			&op.peer_addr,
			(uint)op.msghdr.msg_namelen
		)) peer = parsed;
		finish_recv(loop, socket, op, { }, copied, peer, truncated);
		return;
	}

	net::NativeUdpRecvResult? recv_result = net::native_udp_recv(socket.native_handle, op.buffer);
	fault err                             = @catch(recv_result);
	if (try result = recv_result)
	{
		finish_recv(loop, socket, op, { }, result.bytes, result.peer, result.truncated);
		return;
	}

	if (err == io::WOULD_BLOCK)
	{
		backend::stream_ready_consumed(header, nova::READY_READABLE);
		if (catch rearm_err = backend::udp_recv_rearm(loop, header))
		{
			finish_recv(loop, socket, op, rearm_err, 0, { }, false);
		}
		return;
	}

	finish_recv(loop, socket, op, err, 0, { }, false);
}

<*
 Complete a receive operation with a terminal semantic result.

 @param loop : "Loop that owns the operation"
 @param socket : "UDP socket owner"
 @param op : "Receive operation storage"
 @param status : "Terminal status"
 @param bytes : "Received byte count"
 @param peer : "Peer endpoint"
 @param truncated : "Whether the datagram was truncated"
 @require loop != null : "Loop pointer must not be null"
 @require socket != null : "Socket pointer must not be null"
 @require op != null : "Receive operation pointer must not be null"
*>
fn void finish_recv(
	Loop* loop,
	Socket* socket,
	RecvOp* op,
	fault status,
	sz bytes,
	Endpoint peer,
	bool truncated
) @local
{
	RecvCallback callback = op.callback;
	void* userdata        = op.header.userdata;
	char[] buffer         = op.buffer;

	timer::deadline_done(loop, &op.header);
	RecvResult result;
	result.error.status = status;
	result.buffer = buffer;
	result.bytes = bytes;
	result.peer = peer;
	result.truncated = truncated;
	reset_recv(socket, op);
	callback(loop, socket, op, &result, userdata);
}

<*
 Release socket and operation state before a terminal receive callback starts.

 @param socket : "UDP socket owner"
 @param op : "Receive operation storage"
 @require socket != null : "Socket pointer must not be null"
 @require op != null : "Receive operation pointer must not be null"
*>
fn void reset_recv(Socket* socket, RecvOp* op) @local
{
	if (socket.active_recv == &op.header) socket.active_recv = null;
	reset_recv_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear receive-specific fields after a receive operation leaves the runtime.

 @param op : "Receive operation storage to clear"
 @require op != null : "Receive operation pointer must not be null"
*>
fn void reset_recv_fields(RecvOp* op) @local
{
	op.buffer = { };
	op.callback = null;
}

<*
 Dispatch a UDP send completion through the typed callback.

 Stale writable readiness that still produces `WOULD_BLOCK` is rearmed without
 invoking user code.

 @param loop : "Loop dispatching the send operation"
 @param raw : "Header pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_send(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	SendOp* op         = (SendOp*)raw;
	Socket* socket     = (Socket*)header.owner;

	if (header.terminal_status)
	{
		sz sent = 0;
		if (op.completed) sent = op.sent;
		finish_send(loop, socket, op, header.terminal_status, sent);
		return;
	}

	if (backend::op_completion(header))
	{
		sz res = backend::op_completion_result(header);
		if (res < 0)
		{
			finish_send(loop, socket, op, net::udp_completion_fault((int)-res), 0);
			return;
		}
		finish_send(loop, socket, op, { }, res);
		return;
	}

	if (op.completed)
	{
		finish_send(loop, socket, op, { }, op.sent);
		return;
	}

	Endpoint* remote = null;
	if (op.has_remote) remote = &op.remote;
	sz? send_result = net::native_udp_send(socket.native_handle, op.bytes, remote);
	fault err       = @catch(send_result);
	if (try sent = send_result)
	{
		finish_send(loop, socket, op, { }, sent);
		return;
	}

	if (err == io::WOULD_BLOCK)
	{
		backend::stream_ready_consumed(header, nova::READY_WRITABLE);
		if (catch rearm_err = backend::udp_send_rearm(loop, header))
		{
			finish_send(loop, socket, op, rearm_err, 0);
		}
		return;
	}

	finish_send(loop, socket, op, err, 0);
}

<*
 Complete a send operation with a terminal semantic result.

 @param loop : "Loop that owns the operation"
 @param socket : "UDP socket owner"
 @param op : "Send operation storage"
 @param status : "Terminal status"
 @param bytes : "Sent byte count"
 @require loop != null : "Loop pointer must not be null"
 @require socket != null : "Socket pointer must not be null"
 @require op != null : "Send operation pointer must not be null"
*>
fn void finish_send(Loop* loop, Socket* socket, SendOp* op, fault status, sz bytes) @local
{
	SendCallback callback = op.callback;
	void* userdata        = op.header.userdata;

	timer::deadline_done(loop, &op.header);
	SendResult result;
	result.error.status = status;
	result.bytes = bytes;
	reset_send(socket, op);
	callback(loop, socket, op, &result, userdata);
}

<*
 Release socket and operation state before a terminal send callback starts.

 @param socket : "UDP socket owner"
 @param op : "Send operation storage"
 @require socket != null : "Socket pointer must not be null"
 @require op != null : "Send operation pointer must not be null"
*>
fn void reset_send(Socket* socket, SendOp* op) @local
{
	if (socket.active_send == &op.header) socket.active_send = null;
	reset_send_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear send-specific fields after a send operation leaves the runtime.

 @param op : "Send operation storage to clear"
 @require op != null : "Send operation pointer must not be null"
*>
fn void reset_send_fields(SendOp* op) @local
{
	op.bytes = { };
	op.remote = { };
	op.sent = 0;
	op.has_remote = false;
	op.completed = false;
	op.callback = null;
}

<*
 Dispatch an async UDP close completion through the typed callback.

 @param loop : "Loop dispatching the close operation"
 @param raw : "Header pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_close(Loop* loop, void* raw)
{
	op::Header* header = (op::Header*)raw;
	SocketCloseOp* op  = (SocketCloseOp*)raw;
	Socket* socket     = (Socket*)header.owner;

	SocketCloseCallback callback = op.callback;
	void* userdata               = header.userdata;
	CloseResult result;
	result.error.status = header.terminal_status;
	reset_close(socket, op);
	callback(loop, socket, op, &result, userdata);
}

<*
 Release UDP close operation state before its callback starts.

 @param socket : "UDP socket owner"
 @param op : "Close operation storage"
 @require socket != null : "Socket pointer must not be null"
 @require op != null : "Close operation pointer must not be null"
*>
fn void reset_close(Socket* socket, SocketCloseOp* op)
{
	if (socket.active_close == &op.header) socket.active_close = null;
	reset_close_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear close-specific fields after a close operation leaves the runtime.

 @param op : "Close operation storage to clear"
 @require op != null : "Close operation pointer must not be null"
*>
fn void reset_close_fields(SocketCloseOp* op)
{
	op.callback = null;
}
