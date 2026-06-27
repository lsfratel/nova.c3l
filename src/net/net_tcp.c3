module nova::net::tcp;

import std::io;

import nova @norecurse;
import nova::net;
import nova::op @public;
import nova::backend @public;
import nova::stream @public;
import nova::timer;

<*
 Short alias for the generic stream module used by TCP read/write operations.
*>
alias evstream = module nova::stream;

<*
 Callback invoked when an accept operation reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the accept"
 @param listener : "Listener that owns the accept queue"
 @param op : "Accept operation storage"
 @param result : "Accept result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias AcceptCallback = fn void(Loop* loop, Listener* listener, AcceptOp* op, AcceptResult* result, void* userdata);

<*
 Result delivered for TCP read completion.

 The buffer slice aliases the caller-provided read storage and is valid only
 during the callback that receives this result. `bytes` is the total copied
 into `buffer` before `min_bytes`, an error, or EOF completed the operation.
 Timeout, cancellation and close completions preserve bytes already copied and
 report `eof == false`. `eof` reports peer shutdown and may be true with
 partial bytes.
*>
alias ReadResult = evstream::ReadResult;

<*
 Result delivered for TCP write completion.

 `bytes` is the number of bytes accepted before the terminal status was
 reported. On error, timeout, cancellation or close, this may be less than the
 submitted byte slice length, including zero when no bytes were accepted.
*>
alias WriteResult = evstream::WriteResult;

<*
 Caller-owned TCP read operation storage.

 The read buffer is borrowed from submission until the terminal callback
 starts. Progress fields are runtime-owned while the operation is active.
*>
alias ReadOp = evstream::ReadOp;

<*
 Caller-owned TCP write operation storage.

 The byte slice is borrowed from submission until the terminal callback starts.
 Progress fields are runtime-owned while the operation is active.
*>
alias WriteOp = evstream::WriteOp;

<*
 Callback invoked for each persistent read completion.

 Returning `CONTINUE` reposts the next one-shot read unless the result is
 terminal. Returning `STOP` leaves the reader inactive after this callback.
*>
alias ReadStartCallback = fn ReadAction(
	Loop* loop,
	Stream* stream,
	ReadStarter* reader,
	ReadResult* result,
	void* userdata
);

<*
 Callback invoked when a connect operation reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the connect"
 @param stream : "TCP stream being connected"
 @param op : "Connect operation storage"
 @param result : "Connect result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias ConnectCallback = fn void(Loop* loop, Stream* stream, ConnectOp* op, ConnectResult* result, void* userdata);

<*
 Callback invoked when a read operation reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the read"
 @param stream : "TCP stream that owns the read"
 @param op : "Read operation storage"
 @param result : "Read result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias ReadCallback = fn void(Loop* loop, Stream* stream, ReadOp* op, ReadResult* result, void* userdata);

<*
 Callback invoked when a write operation reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the write"
 @param stream : "TCP stream that owns the write"
 @param op : "Write operation storage"
 @param result : "Write result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias WriteCallback = fn void(Loop* loop, Stream* stream, WriteOp* op, WriteResult* result, void* userdata);

<*
 Callback invoked when stream close reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the close"
 @param stream : "TCP stream being closed"
 @param op : "Stream close operation storage"
 @param result : "Close result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias StreamCloseCallback = fn void(Loop* loop, Stream* stream, StreamCloseOp* op, CloseResult* result, void* userdata);

<*
 Callback invoked when listener close reaches a terminal result.

 Submission userdata is delivered through the `userdata` argument;
 `op.header.userdata` has been cleared before this callback runs.

 @param loop : "Loop dispatching the close"
 @param listener : "TCP listener being closed"
 @param op : "Listener close operation storage"
 @param result : "Close result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias ListenerCloseCallback = fn void(
	Loop* loop,
	Listener* listener,
	ListenerCloseOp* op,
	CloseResult* result,
	void* userdata
);

<*
 Default TCP listen backlog for `listen`.
*>
const int DEFAULT_BACKLOG = 128;

<*
 Persistent read callback action.

 `CONTINUE` reposts the embedded read operation. `STOP` marks the starter
 inactive after the current callback returns.
*>
constdef ReadAction : inline char
{
	CONTINUE = 0,
	STOP     = 1,
}

<*
 Caller-owned TCP listener handle.

 The native descriptor and accept watcher are owned by this handle while
 `open` is true. Accept operations are kept in a caller-owned FIFO and a close
 operation excludes new accepts and listen state changes.
*>
struct Listener
{
	SocketOptions options;
	NativeHandle native_handle;
	backend::Watcher watcher;
	op::Header accept_driver;
	backend::OpState accept_backend;
	AcceptOp* accept_head;
	AcceptOp* accept_tail;
	sz accept_count;
	op::Header* active_close;
	Endpoint local;
	bool initialized;
	bool bound;
	bool listening;
	bool open;
}

<*
 Caller-owned TCP stream handle.

 The native descriptor and backend watcher are owned by this handle while
 `open` is true. At most one connect, read, write and close operation may be
 active on a stream at a time.
*>
struct Stream
{
	SocketOptions options;
	NativeHandle native_handle;
	backend::Watcher watcher;
	op::Header* active_connect;
	op::Header* active_read;
	op::Header* active_write;
	op::Header* active_close;
	bool initialized;
	bool open;
	bool send_shutdown;
	bool recv_shutdown;
}

<*
 Result delivered for an accepted TCP stream.

 Terminal TCP callbacks receive submission `userdata` as a direct argument.
 The result pointer is valid only for the duration of that callback and does
 not alias reusable operation result storage. When a terminal callback starts,
 the completed operation has already been detached from its stream or listener
 and marked `OP_FREE`, so callback code may immediately reuse the same
 operation storage. User code must not read public state from
 `op.header.userdata`; the runtime clears operation internals before invoking the
 callback. `stream` is set only when `error.status` is success; failed,
 cancelled or timed-out accepts report a null stream. `peer` is meaningful
 only when `stream` is non-null.
*>
struct AcceptResult
{
	ErrorInfo error;
	Stream* stream;
	Endpoint peer;
}

<*
 Result delivered for TCP connect completion.

 The stream pointer aliases the submitted stream and is valid only during the
 callback that receives this result. It is set only on successful connect; on
 failure the result carries a null stream and the native handle has been
 closed.
*>
struct ConnectResult
{
	ErrorInfo error;
	Stream* stream;
}

<*
 Caller-owned TCP accept operation storage.

 `out` and `callback` are internal driver fields set by `accept` and cleared
 before the terminal callback starts.
*>
struct AcceptOp
{
	inline op::Header header;
	backend::OpState backend;
	Stream* out;
	AcceptOp* next_accept;
	net::SockAddrAny peer_addr;
	uint peer_len;
	AcceptCallback callback;
}

<*
 Caller-owned TCP connect operation storage.

 The callback field is set by `connect` and cleared before the terminal
 callback starts, so the same storage may be reused from that callback.
*>
struct ConnectOp
{
	inline op::Header header;
	backend::OpState backend;
	net::SockAddrAny remote_addr;
	uint remote_len;
	ConnectCallback callback;
}

<*
 Caller-owned persistent TCP read helper.

 This helper owns no buffers and performs no allocation. It wraps one embedded
 `ReadOp` and reposts it after successful callbacks while active.
*>
struct ReadStarter
{
	ReadOp op;
	Stream* stream;
	char[] buffer;
	ReadOptions options;
	ReadStartCallback callback;
	void* userdata;
	Ref active_ref;
	bool initialized;
	bool active;
	bool stopping;
}

<*
 Caller-owned async stream close operation storage.

 The callback field is set by `stream_close` and cleared before the terminal
 callback starts, so the same storage may be reused from that callback.
*>
struct StreamCloseOp
{
	inline op::Header header;
	StreamCloseCallback callback;
}

<*
 Caller-owned async listener close operation storage.

 The callback field is set by `listener_close` and cleared before the terminal
 callback starts, so the same storage may be reused from that callback.
*>
struct ListenerCloseOp
{
	inline op::Header header;
	ListenerCloseCallback callback;
}

<*
 Initialize caller-owned listener storage.

 This does not create a native listener socket; `bind` creates and owns it.
 Socket options are stored without validation until that native setup.

 @param [&inout] self : "Listener storage"
 @return "Initialized listener"
 @return ? nova::INVALID_STATE : "Listener is already initialized"
 @ensure self.initialized : "Listener is initialized when init succeeds"
*>
fn Listener*? Listener.init(&self, SocketOptions options = { })
{
	if (self.initialized) return nova::INVALID_STATE~;
	*self = { };
	self.options = options;
	self.native_handle = (NativeHandle)-1;
	self.initialized = true;
	return self;
}

<*
 Destroy an initialized listener.

 @param [&inout] self : "Closed listener with no active operations"
 @require self.initialized : "Listener must be initialized"
 @require !self.open : "Listener must be closed"
 @require self.active_close == null : "Listener close operation must be inactive"
 @require self.accept_count == 0 : "Listener accept queue must be empty"
 @require !self.accept_driver.active() : "Listener accept driver must be inactive"
 @ensure !self.initialized : "Listener is uninitialized after destroy"
*>
fn void Listener.destroy(&self)
{
	*self = { };
	self.native_handle = (NativeHandle)-1;
}

<*
 Report whether this listener currently owns an open native handle.

 @param self : "Listener storage to inspect"
 @return "True when the listener is open"
*>
fn bool Listener.is_open(&self) => self.open;

<*
 Borrow this listener's native socket handle without transferring ownership.

 @param self : "Listener storage to inspect"
 @return "Open native listener handle"
 @return ? nova::INVALID_STATE : "Listener is not initialized or open"
*>
fn NativeHandle? Listener.borrow_native(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return self.native_handle;
}

<*
 Return this listener's current local endpoint.

 The endpoint is queried from the native socket so kernel-assigned addresses
 and ports are reported directly.

 @param self : "Open listener storage"
 @return "Current local endpoint"
 @return ? nova::INVALID_STATE : "Listener is not initialized or open"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "Native endpoint query failed"
*>
fn Endpoint? Listener.local_endpoint(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return net::native_tcp_socket_local_endpoint(self.native_handle);
}

<*
 Initialize caller-owned stream storage.

 This does not create a native stream socket; `connect` or `accept` creates and
 attaches one. Socket options are stored without validation until that native
 setup.

 @param [&inout] self : "Stream storage"
 @return "Initialized stream"
 @return ? nova::INVALID_STATE : "Stream is already initialized"
 @ensure self.initialized : "Stream is initialized when init succeeds"
*>
fn Stream*? Stream.init(&self, SocketOptions options = { })
{
	if (self.initialized) return nova::INVALID_STATE~;
	*self = { };
	self.options = options;
	self.native_handle = (NativeHandle)-1;
	self.initialized = true;
	return self;
}

<*
 Initialize caller-owned persistent read helper storage.

 @param [&inout] self : "Read starter storage"
 @return "Initialized read starter"
 @return ? nova::INVALID_STATE : "Read starter is already initialized"
 @ensure self.initialized : "Read starter is initialized when init succeeds"
*>
fn ReadStarter*? ReadStarter.init(&self)
{
	if (self.initialized) return nova::INVALID_STATE~;
	*self = { };
	self.initialized = true;
	return self;
}

<*
 Destroy inactive persistent read helper storage.

 @param [&inout] self : "Inactive read starter"
 @require self.initialized : "Read starter must be initialized"
 @require !self.active : "Read starter must not be active"
 @require !self.op.header.active() : "Embedded read operation must be inactive"
 @ensure !self.initialized : "Read starter is uninitialized after destroy"
*>
fn void ReadStarter.destroy(&self)
{
	*self = { };
}

<*
 Destroy an initialized stream.

 @param [&inout] self : "Closed stream with no active operations"
 @require self.initialized : "Stream must be initialized"
 @require !self.open : "Stream must be closed"
 @require self.active_connect == null : "Stream connect operation must be inactive"
 @require self.active_read == null : "Stream read operation must be inactive"
 @require self.active_write == null : "Stream write operation must be inactive"
 @require self.active_close == null : "Stream close operation must be inactive"
 @ensure !self.initialized : "Stream is uninitialized after destroy"
*>
fn void Stream.destroy(&self)
{
	*self = { };
	self.native_handle = (NativeHandle)-1;
}

<*
 Report whether this stream currently owns an open native handle.

 @param self : "Stream storage to inspect"
 @return "True when the stream is open"
*>
fn bool Stream.is_open(&self) => self.open;

<*
 Borrow this stream's native socket handle without transferring ownership.

 @param self : "Stream storage to inspect"
 @return "Open native stream handle"
 @return ? nova::INVALID_STATE : "Stream is not initialized or open"
*>
fn NativeHandle? Stream.borrow_native(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return self.native_handle;
}

<*
 Apply tunable TCP socket options to this open stream after connect/accept.

 Setup-time `SocketOptions` only run during connect/accept; this lets callers
 tune a live stream. `nodelay`, keepalive fields and non-zero buffer sizes are
 applied; zero/false values leave the native default unchanged. `reuse_addr` and
 `reuse_port` apply only at bind and are ignored here.

 @param self : "Open stream storage"
 @param options : "Socket options to apply"
 @return ? nova::INVALID_STATE : "Stream is not open or an option value is invalid"
 @return ? nova::UNSUPPORTED : "A socket option is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket option update failed"
 @require self != null : "Stream pointer must not be null"
*>
fn void? Stream.set_options(&self, SocketOptions options)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return net::native_tcp_apply_options(self.native_handle, options);
}

<*
 Return this stream's current local endpoint.

 @param self : "Open stream storage"
 @return "Current local endpoint"
 @return ? nova::INVALID_STATE : "Stream is not initialized or open"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "Native endpoint query failed"
*>
fn Endpoint? Stream.local_endpoint(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return net::native_tcp_socket_local_endpoint(self.native_handle);
}

<*
 Return this stream's connected peer endpoint.

 @param self : "Open connected stream storage"
 @return "Current peer endpoint"
 @return ? nova::INVALID_STATE : "Stream is not initialized or open"
 @return ? nova::CONNECTION_RESET : "The native socket no longer has a peer"
 @return ? nova::UNSUPPORTED : "The socket family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native handle is invalid"
 @return ? nova::BACKEND_FAILED : "Native endpoint query failed"
*>
fn Endpoint? Stream.peer_endpoint(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return net::native_tcp_socket_peer_endpoint(self.native_handle);
}

<*
 Try to write bytes to this stream immediately without submitting an operation.

 This preserves the ordering of async writes: when a write is active, the call
 returns `BUSY` instead of writing around queued data.

 @param self : "Open stream storage"
 @param bytes : "Caller-owned source bytes"
 @return "Bytes accepted by the OS"
 @return ? nova::INVALID_STATE : "Stream is not initialized, open or bytes are empty"
 @return ? nova::BUSY : "Stream has an active close or write operation"
 @return ? nova::CONNECTION_RESET : "The stream send side is shut down or reset"
 @return ? std::io::WOULD_BLOCK : "No bytes can be written now"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native send failed"
*>
fn sz? Stream.try_write(&self, char[] bytes)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	if (self.active_close || self.active_write) return nova::BUSY~;
	if (self.send_shutdown) return nova::CONNECTION_RESET~;
	if (!bytes.len) return nova::INVALID_STATE~;
	return net::native_tcp_write(self.native_handle, bytes);
}

<*
 Return bytes still pending in this stream's active write operation.

 @param self : "Stream storage to inspect"
 @return "Pending async write bytes, or zero when no write is active"
*>
fn sz Stream.write_queue_size(&self) => evstream::pending_write_bytes(self.active_write);

<*
 Bind a listener to a local endpoint.

 TCP listeners bind to IPv4 or IPv6 endpoints. `local.port` selects the port,
 including `0` for a kernel-assigned port.

 @param listener : "Initialized closed listener"
 @param local : "IPv4 or IPv6 endpoint used for the listener bind"
 @return ? nova::INVALID_STATE : "Listener is not initialized, already open, closing or has invalid socket options"
 @return ? nova::UNSUPPORTED : "Endpoint family or socket option is unsupported"
 @return ? nova::ADDRESS_IN_USE : "Address is already in use"
 @return ? nova::INVALID_SOCKET : "Native listener handle is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup failed"
 @require listener != null : "Listener pointer must not be null"
*>
fn void? bind(Listener* listener, Endpoint local)
{
	if (!listener.initialized) return nova::INVALID_STATE~;
	if (listener.active_close) return nova::INVALID_STATE~;
	if (listener.open || listener.bound) return nova::INVALID_STATE~;
	NativeHandle handle = net::native_tcp_listener_bind(local, listener.options)!;
	Endpoint? bound     = net::native_tcp_socket_local_endpoint(handle);
	if (catch err = bound)
	{
		(void)net::native_tcp_close(handle);
		return err~;
	}
	listener.native_handle = handle;
	listener.local = bound;
	listener.bound = true;
	listener.open = true;
}

<*
 Start listening for incoming TCP connections.

 @param listener : "Bound open listener"
 @param backlog : "Requested native listen backlog"
 @return ? nova::INVALID_STATE : "Listener is not initialized, is not bound or backlog is invalid"
 @return ? nova::BUSY : "Listener has an active close operation"
 @return ? nova::INVALID_SOCKET : "Native listener handle is invalid"
 @return ? nova::BACKEND_FAILED : "listen failed"
 @require listener != null : "Listener pointer must not be null"
*>
fn void? listen(Listener* listener, int backlog = DEFAULT_BACKLOG)
{
	if (!listener.initialized) return nova::INVALID_STATE~;
	if (listener.active_close) return nova::BUSY~;
	if (!listener.bound) return nova::INVALID_STATE~;
	if (backlog <= 0) return nova::INVALID_STATE~;
	net::native_tcp_listener_listen(listener.native_handle, backlog)!;
	listener.listening = true;
}

<*
 Submit one TCP accept operation.

 Multiple accept operations may be active on the same listener. The listener
 keeps one internal backend driver operation and delivers at most one public
 accept callback per driver dispatch so it never touches listener or operation
 storage after a user callback begins.
 Submission userdata is delivered through the callback argument, and
 `op.header.userdata` has been cleared before the callback runs. The callback
 starts after `op` is reusable. The result pointer is valid only during the
 callback.

 @param loop : "Loop that owns the accept operation"
 @param listener : "Listening TCP listener"
 @param out : "Closed stream storage filled by a successful accept"
 @param op : "Accept operation storage"
 @param callback : "Callback invoked when accept reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, listener, output stream or accept options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Listener, output stream or operation has an active conflicting operation"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
 @require out != null : "Output stream pointer must not be null"
 @require op != null : "Accept operation pointer must not be null"
*>
fn Ref? accept(
	Loop* loop,
	Listener* listener,
	Stream* out,
	AcceptOp* op,
	AcceptCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !listener.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (listener.active_close) return nova::BUSY~;
	if (!listener.listening || !listener.open) return nova::INVALID_STATE~;
	if (!out.initialized) return nova::INVALID_STATE~;
	if (out.active_connect || out.active_read || out.active_write || out.active_close) return nova::BUSY~;
	if (out.open) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (op.header.active()) return nova::BUSY~;

	op.out = out;
	op.next_accept = null;
	op.callback = callback;

	if (backend::tcp_completion_accept_enabled(loop))
	{
		op.peer_len = (uint)net::SockAddrAny::size;
		Ref? accepted = backend::tcp_accept_submit(
			loop,
			&op.header,
			&op.backend,
			listener.native_handle,
			(ulong)(uptr)&op.peer_addr,
			(ulong)(uptr)&op.peer_len,
			&dispatch_accept_completion,
			listener,
			userdata
		);
		if (catch accepted)
		{
			reset_accept_fields(op);
			return accepted;
		}
		accept_queue_push(listener, op);
		return accepted;
	}

	Ref? submitted = nova::submit_tcp_accept_prepare(
		loop,
		&op.header,
		listener.native_handle,
		&dispatch_accept_result,
		listener,
		userdata
	);
	if (catch submitted)
	{
		reset_accept_fields(op);
		return submitted;
	}

	accept_queue_push(listener, op);
	if (catch err = ensure_accept_driver(loop, listener))
	{
		accept_queue_remove(listener, op);
		timer::deadline_done(loop, &op.header);
		reset_accept(op);
		return err~;
	}

	Ref oref = submitted;
	return oref;
}

<*
 Submit one TCP connect operation.

 Submission userdata is delivered through the callback argument, and
 `op.header.userdata` has been cleared before the callback runs. The callback
 starts after `op` is reusable. The result pointer is valid only during the
 callback.

 @param loop : "Loop that owns the connect operation"
 @param stream : "Closed stream storage to connect"
 @param remote : "Remote IPv4 or IPv6 endpoint"
 @param op : "Connect operation storage"
 @param callback : "Callback invoked when connect reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, stream or connect options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Stream or operation already has an active connect or close"
 @return ? nova::UNSUPPORTED : "Endpoint family is unsupported"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native socket setup or backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Connect operation pointer must not be null"
*>
fn Ref? connect(
	Loop* loop,
	Stream* stream,
	Endpoint remote,
	ConnectOp* op,
	ConnectCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !stream.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!callback) return nova::INVALID_STATE~;
	if (stream.active_close) return nova::BUSY~;
	if (stream.open) return nova::INVALID_STATE~;
	if (stream.active_connect || op.header.active()) return nova::BUSY~;

	if (backend::tcp_completion_connect_enabled(loop))
	{
		NativeHandle handle = net::native_tcp_connect_socket(remote, stream.options, &op.remote_addr, &op.remote_len)!;
		stream.native_handle = handle;
		stream.send_shutdown = false;
		stream.recv_shutdown = false;
		op.callback = callback;

		Ref? connected = backend::tcp_connect_complete_submit(
			loop,
			&op.header,
			&op.backend,
			handle,
			(ulong)(uptr)&op.remote_addr,
			(ulong)op.remote_len,
			&dispatch_connect,
			stream,
			userdata
		);
		if (catch connected)
		{
			(void)net::native_tcp_close(handle);
			stream.native_handle = (NativeHandle)-1;
			reset_connect_fields(op);
			return connected;
		}

		Ref cref = connected;
		stream.active_connect = &op.header;
		return cref;
	}

	net::NativeTcpConnectStart start = net::native_tcp_connect_start(remote, stream.options)!;
	stream.native_handle = start.handle;
	stream.send_shutdown = false;
	stream.recv_shutdown = false;
	op.callback = callback;

	Ref? submitted = backend::tcp_connect_submit(
		loop,
		&op.header,
		&op.backend,
		&stream.watcher,
		stream.native_handle,
		start.complete,
		start.status,
		&dispatch_connect,
		stream,
		userdata
	);
	if (catch submitted)
	{
		(void)net::native_tcp_close(stream.native_handle);
		stream.native_handle = (NativeHandle)-1;
		reset_connect_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	stream.active_connect = &op.header;
	return oref;
}

<*
 Borrow TCP stream state for the shared stream read/write driver.

 @param stream : "TCP stream handle whose state will back one operation"
 @return "Shared stream handle state pointing into the TCP stream"
 @require stream != null : "Stream pointer must not be null"
*>
fn evstream::HandleState stream_handle_state(Stream* stream) @local
{
	return {
		.handle = &stream.native_handle,
		.watcher = &stream.watcher,
		.active_read = &stream.active_read,
		.active_write = &stream.active_write,
	};
}

<*
 Submit one TCP read operation using a caller-owned buffer.

 The buffer is borrowed until the terminal callback starts. Submission userdata
 is delivered through the callback argument, and `op.header.userdata` has been
 cleared before the callback runs. The callback starts after `op` is reusable.
 The result pointer is valid only during the callback.

 @param loop : "Loop that owns the read operation"
 @param stream : "Open TCP stream"
 @param [out] buffer : "Caller-owned destination bytes borrowed until callback"
 @param op : "Read operation storage"
 @param callback : "Callback invoked when read reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, stream, buffer or read options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Stream or operation already has an active read or close"
 @return ? nova::CONNECTION_RESET : "The stream receive side is shut down"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
*>
fn Ref? read(
	Loop* loop,
	Stream* stream,
	char[] buffer,
	ReadOp* op,
	ReadOptions options,
	ReadCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !stream.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (stream.active_close) return nova::BUSY~;
	if (!stream.open) return nova::INVALID_STATE~;
	if (stream.recv_shutdown) return nova::CONNECTION_RESET~;
	if (!buffer.len || options.min_bytes < 0) return nova::INVALID_STATE~;
	if (options.min_bytes > buffer.len) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (stream.active_read || op.header.active()) return nova::BUSY~;

	sz min_bytes = 1;
	if (options.min_bytes > 0) min_bytes = options.min_bytes;
	return evstream::submit_read(
		loop,
		stream_handle_state(stream),
		stream,
		buffer,
		min_bytes,
		op,
		&net::native_tcp_read,
		(evstream::ReadCallback)callback,
		userdata,
		!options.wait_readiness,
		&net::tcp_completion_fault
	);
}

<*
 Submit a vectored (scatter-gather) read filling `vectors` in order.

 Receives into the slices with a single `recvmsg`/iovec per syscall (re-issued
 across partial reads). The slices are borrowed until the callback and are not
 mutated. Equivalent to `read` but fills several destination segments (e.g. the
 ≤2 free segments of a ring buffer) in one call.

 @param loop : "Loop that owns the read operation"
 @param stream : "Open, readable TCP stream"
 @param vectors : "Caller-owned destination slices, borrowed until the callback"
 @param op : "Read operation storage"
 @param options : "Read submission options"
 @param callback : "Terminal read callback"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop or stream not ready, or vectors empty"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::CONNECTION_RESET : "Stream recv side already shut down"
 @return ? nova::BUSY : "Stream already has an active read or close"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
*>
fn Ref? read_vectored(
	Loop* loop,
	Stream* stream,
	char[][] vectors,
	ReadOp* op,
	ReadOptions options,
	ReadCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !stream.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (stream.active_close) return nova::BUSY~;
	if (!stream.open) return nova::INVALID_STATE~;
	if (stream.recv_shutdown) return nova::CONNECTION_RESET~;
	if (!vectors.len || options.min_bytes < 0) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (stream.active_read || op.header.active()) return nova::BUSY~;

	usz total = 0;
	foreach (v : vectors) total += v.len;
	sz min_bytes = 1;
	if (options.min_bytes > 0) min_bytes = options.min_bytes;
	if (!total || (usz)min_bytes > total) return nova::INVALID_STATE~;

	return evstream::submit_read_vectored(
		loop,
		stream_handle_state(stream),
		stream,
		vectors,
		min_bytes,
		op,
		&net::native_tcp_readv,
		(evstream::ReadCallback)callback,
		userdata,
		!options.wait_readiness,
		&net::tcp_completion_fault
	);
}

<*
 Start a persistent TCP reader backed by one embedded `ReadOp`.

 The buffer is borrowed until `read_stop`, a terminal read result, or a callback
 returning `STOP` makes the reader inactive.

 @param loop : "Loop that owns the read operations"
 @param stream : "Open TCP stream"
 @param reader : "Initialized inactive persistent read helper"
 @param [out] buffer : "Caller-owned destination bytes borrowed while active"
 @param callback : "Callback invoked for each read completion"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Reference for the first embedded read operation"
 @return ? nova::INVALID_STATE : "Loop, stream, reader, buffer or options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Stream or reader already has an active read"
 @return ? nova::CONNECTION_RESET : "The stream receive side is shut down"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require reader != null : "Read starter pointer must not be null"
*>
fn Ref? read_start(
	Loop* loop,
	Stream* stream,
	ReadStarter* reader,
	char[] buffer,
	ReadStartCallback callback,
	ReadOptions options = { },
	void* userdata = null
)
{
	if (!loop || !stream || !reader || !callback) return nova::INVALID_STATE~;
	if (!reader.initialized || reader.active || reader.op.header.active()) return nova::INVALID_STATE~;

	reader.stream = stream;
	reader.buffer = buffer;
	reader.options = options;
	reader.callback = callback;
	reader.userdata = userdata;
	reader.active_ref = { };
	reader.active = true;
	reader.stopping = false;

	Ref? submitted = read(loop, stream, buffer, &reader.op, options, &dispatch_read_start, reader);
	if (catch submitted)
	{
		read_starter_reset(reader);
		return submitted;
	}

	Ref oref = submitted;
	reader.active_ref = oref;
	return oref;
}

<*
 Stop a persistent TCP reader.

 If the embedded read operation is active, it is cancelled and the cancellation
 callback is consumed internally. If called from inside the reader callback, the
 reader is made inactive immediately and no repost happens.

 @param loop : "Loop that owns the reader"
 @param stream : "Stream associated with the reader"
 @param reader : "Initialized read starter"
 @return ? nova::INVALID_STATE : "Loop, stream or reader state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? NOT_FOUND : "The active read reference is stale"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require reader != null : "Read starter pointer must not be null"
*>
fn void? read_stop(Loop* loop, Stream* stream, ReadStarter* reader)
{
	if (!loop || !stream || !reader) return nova::INVALID_STATE~;
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!reader.initialized) return nova::INVALID_STATE~;
	if (!reader.active) return;
	if (reader.stream != stream) return nova::INVALID_STATE~;

	reader.stopping = true;
	if (reader.op.header.active())
	{
		op::cancel_ref(loop, reader.active_ref)!;
		return;
	}

	read_starter_reset(reader);
}

<*
 Submit one TCP write operation using caller-owned bytes.

 The driver first attempts bounded non-blocking progress when no explicit
 timeout was requested. Writes that complete immediately are queued as normal
 proactor completions without registering backend writable readiness.
 Submission userdata is delivered through the callback argument, and
 `op.header.userdata` has been cleared before the callback runs. The callback
 starts after `op` is reusable. The result pointer is valid only during the
 callback.

 @param loop : "Loop that owns the write operation"
 @param stream : "Open TCP stream"
 @param bytes : "Caller-owned source bytes borrowed until callback"
 @param op : "Write operation storage"
 @param callback : "Callback invoked when write reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, stream, bytes or write options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Stream or operation already has an active write or close"
 @return ? nova::CONNECTION_RESET : "The stream send side is shut down"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn Ref? write(
	Loop* loop,
	Stream* stream,
	char[] bytes,
	WriteOp* op,
	WriteOptions options,
	WriteCallback callback,
	void* userdata = null
)
{
	return write_with_policy(loop, stream, bytes, op, options, callback, userdata);
}

<*
 Submit a TCP write with immediate progress before backend readiness when safe.

 @param loop : "Loop that owns the operation"
 @param stream : "Open TCP stream"
 @param bytes : "Caller-owned source bytes borrowed until callback"
 @param op : "Write operation storage"
 @param callback : "Typed write callback"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, stream, bytes or timeout are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Stream or operation already has an active write or close"
 @return ? nova::CONNECTION_RESET : "The stream send side is shut down"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
*>
fn Ref? write_with_policy(
	Loop* loop,
	Stream* stream,
	char[] bytes,
	WriteOp* op,
	WriteOptions options,
	WriteCallback callback,
	void* userdata
) @local
{
	if (!loop.initialized || !stream.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (stream.active_close) return nova::BUSY~;
	if (!stream.open) return nova::INVALID_STATE~;
	if (stream.send_shutdown) return nova::CONNECTION_RESET~;
	if (!bytes.len) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (stream.active_write || op.header.active()) return nova::BUSY~;

	return evstream::submit_write(
		loop,
		stream_handle_state(stream),
		stream,
		bytes,
		op,
		!options.wait_readiness,
		&net::native_tcp_write,
		(evstream::WriteCallback)callback,
		userdata,
		&net::tcp_completion_fault
	);
}

<*
 Submit a vectored (scatter-gather) stream write.

 Sends `vectors` in order with a single `sendmsg`/iovec per syscall (re-issued
 across partial writes). The slices are borrowed until the callback and are not
 mutated. Equivalent to `write` but avoids concatenating the source buffers.

 @param loop : "Loop that owns the write operation"
 @param stream : "Open, writable TCP stream"
 @param vectors : "Caller-owned source slices, borrowed until the callback"
 @param op : "Write operation storage"
 @param options : "Write submission options"
 @param callback : "Terminal write callback"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop or stream not ready, or vectors empty"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::CONNECTION_RESET : "Stream send side already shut down"
 @return ? nova::BUSY : "Stream already has an active write or close"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn Ref? write_vectored(
	Loop* loop,
	Stream* stream,
	char[][] vectors,
	WriteOp* op,
	WriteOptions options,
	WriteCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !stream.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (stream.active_close) return nova::BUSY~;
	if (!stream.open) return nova::INVALID_STATE~;
	if (stream.send_shutdown) return nova::CONNECTION_RESET~;
	if (!vectors.len) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (stream.active_write || op.header.active()) return nova::BUSY~;

	return evstream::submit_write_vectored(
		loop,
		stream_handle_state(stream),
		stream,
		vectors,
		op,
		!options.wait_readiness,
		&net::native_tcp_writev,
		(evstream::WriteCallback)callback,
		userdata,
		&net::tcp_completion_fault
	);
}

<*
 Submit async stream close.

 Close first completes any active stream operations with `CLOSED`, unregisters
 backend readiness, then closes the native descriptor and queues this close
 operation as an immediate completion.
 `options.abortive` requests `SO_LINGER { 1, 0 }` before closing the native
 stream descriptor.
 Submission userdata is delivered through the callback argument, and
 `op.header.userdata` has been cleared before the callback runs. The callback
 starts after `op` is reusable. The result pointer is valid only during the
 callback.

 @param loop : "Loop that owns the close operation"
 @param stream : "TCP stream being closed"
 @param op : "Stream close operation storage"
 @param callback : "Callback invoked when stream close reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop or stream is not ready for close"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Stream or close operation already has an active close"
 @return ? nova::BACKEND_FAILED : "Native close failed"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Stream close operation pointer must not be null"
*>
fn Ref? stream_close(
	Loop* loop,
	Stream* stream,
	StreamCloseOp* op,
	CloseOptions options,
	StreamCloseCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !stream.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!callback) return nova::INVALID_STATE~;
	if (stream.active_close || op.header.active()) return nova::BUSY~;
	if (!stream.open && !stream.active_connect && !stream.active_read
		&& !stream.active_write) return nova::INVALID_STATE~;

	if (stream.active_connect)
	{
		op::complete(loop, stream.active_connect, nova::CLOSED)!;
		if (stream.active_connect.state == State.OP_READY) stream.active_connect.terminal_status = nova::CLOSED;
	}
	if (stream.active_read) op::complete(loop, stream.active_read, nova::CLOSED)!;
	if (stream.active_write) op::complete(loop, stream.active_write, nova::CLOSED)!;

	backend::watcher_close(loop, &stream.watcher);

	fault status;
	if (options.abortive)
	{
		status = @catch(net::native_tcp_set_abortive_close(stream.native_handle));
	}
	fault close_status = @catch(net::native_tcp_close(stream.native_handle));
	if (!status) status = close_status;

	stream.native_handle = (NativeHandle)-1;
	stream.open = false;
	stream.send_shutdown = false;
	stream.recv_shutdown = false;
	op.callback = callback;

	Ref? submitted = nova::submit_tcp_close(loop, &op.header, &dispatch_stream_close, stream, userdata, status);
	if (catch submitted)
	{
		reset_stream_close_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	stream.active_close = &op.header;
	return oref;
}

<*
 Submit async listener close.

 Close first completes an active accept with `CLOSED`, unregisters backend
 readiness, then closes the native listener descriptor and queues this close
 operation as an immediate completion.
 `options.abortive` is ignored for listeners.
 Submission userdata is delivered through the callback argument, and
 `op.header.userdata` has been cleared before the callback runs. The callback
 starts after `op` is reusable. The result pointer is valid only during the
 callback.

 @param loop : "Loop that owns the close operation"
 @param listener : "TCP listener being closed"
 @param op : "Listener close operation storage"
 @param callback : "Callback invoked when listener close reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop or listener is not ready for close"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Listener or close operation already has an active close"
 @return ? nova::BACKEND_FAILED : "Native close failed"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
 @require op != null : "Listener close operation pointer must not be null"
*>
fn Ref? listener_close(
	Loop* loop,
	Listener* listener,
	ListenerCloseOp* op,
	CloseOptions options,
	ListenerCloseCallback callback,
	void* userdata = null
)
{
	(void)options;
	if (!loop.initialized || !listener.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!callback) return nova::INVALID_STATE~;
	if (listener.active_close || op.header.active()) return nova::BUSY~;
	if (!listener.open) return nova::INVALID_STATE~;

	complete_pending_accepts(loop, listener, nova::CLOSED);
	stop_accept_driver(loop, listener);

	backend::watcher_close(loop, &listener.watcher);
	fault status = @catch(net::native_tcp_close(listener.native_handle));

	listener.native_handle = (NativeHandle)-1;
	listener.open = false;
	listener.bound = false;
	listener.listening = false;
	listener.local = { };
	op.callback = callback;

	Ref? submitted = nova::submit_tcp_close(loop, &op.header, &dispatch_listener_close, listener, userdata, status);
	if (catch submitted)
	{
		reset_listener_close_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	listener.active_close = &op.header;
	return oref;
}

<*
 Request stream shutdown.

 @param stream : "Open TCP stream"
 @param mode : "Native shutdown direction"
 @return ? nova::INVALID_STATE : "Stream is not initialized or open"
 @return ? nova::BUSY : "Stream has an active close or conflicting stream operation"
 @return ? nova::CONNECTION_RESET : "Native shutdown reported a reset or disconnected stream"
 @return ? nova::INVALID_SOCKET : "Native socket is invalid"
 @return ? nova::BACKEND_FAILED : "Native shutdown failed"
 @require stream != null : "Stream pointer must not be null"
*>
fn void? shutdown(Stream* stream, ShutdownMode mode = ShutdownMode.SEND)
{
	if (!stream.initialized) return nova::INVALID_STATE~;
	if (stream.active_close) return nova::BUSY~;
	if (!stream.open) return nova::INVALID_STATE~;
	if (mode != ShutdownMode.SEND && mode != ShutdownMode.RECV
		&& mode != ShutdownMode.BOTH) return nova::INVALID_STATE~;
	if ((mode == ShutdownMode.SEND || mode == ShutdownMode.BOTH) && stream.active_write) return nova::BUSY~;
	if ((mode == ShutdownMode.RECV || mode == ShutdownMode.BOTH) && stream.active_read) return nova::BUSY~;

	bool want_send = mode == ShutdownMode.SEND || mode == ShutdownMode.BOTH;
	bool want_recv = mode == ShutdownMode.RECV || mode == ShutdownMode.BOTH;
	bool need_send = want_send && !stream.send_shutdown;
	bool need_recv = want_recv && !stream.recv_shutdown;
	if (need_send || need_recv)
	{
		ShutdownMode effective = ShutdownMode.RECV;
		if (need_send && need_recv)
		{
			effective = ShutdownMode.BOTH;
		}
		else if (need_send)
		{
			effective = ShutdownMode.SEND;
		}
		net::native_tcp_shutdown(stream.native_handle, effective)!;
	}
	if (want_send) stream.send_shutdown = true;
	if (want_recv) stream.recv_shutdown = true;
}

<*
 Close a stream synchronously when it has no active operations.

 If previous read or write operations registered the persistent watcher,
 `stream_close_now` unregisters it on the owning loop thread before closing the
 native descriptor.

 For a graceful close while a read/write/connect is still in flight, use the
 async `stream_close`, which first completes those operations with `CLOSED`; this
 sync variant intentionally returns `BUSY` instead. To tear down a whole loop's
 outstanding operations at once, see `Loop.close_all` + `Loop.drain`.

 @param stream : "Open TCP stream with no active operations"
 @return ? nova::INVALID_STATE : "Stream is not initialized, not open or not owned by the current thread"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Stream has an active connect, read, write or close operation"
 @return ? nova::BACKEND_FAILED : "Native close failed"
 @require stream != null : "Stream pointer must not be null"
*>
fn void? stream_close_now(Stream* stream)
{
	if (!stream.initialized) return nova::INVALID_STATE~;
	if (stream.active_connect) return nova::BUSY~;
	if (stream.active_read) return nova::BUSY~;
	if (stream.active_write) return nova::BUSY~;
	if (stream.active_close) return nova::BUSY~;
	if (!stream.open) return nova::INVALID_STATE~;
	if (stream.watcher.registered)
	{
		Loop* loop = stream.watcher.loop;
		if (!loop || !loop.initialized) return nova::INVALID_STATE~;
		if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
		backend::watcher_close(loop, &stream.watcher);
	}
	net::native_tcp_close(stream.native_handle)!;
	stream.watcher = { };
	stream.native_handle = (NativeHandle)-1;
	stream.open = false;
	stream.send_shutdown = false;
	stream.recv_shutdown = false;
}

<*
 Close a listener synchronously when it has no active operations.

 If previous accept operations registered the persistent watcher,
 `listener_close_now` unregisters it on the owning loop thread before closing
 the native descriptor.

 For a graceful close while accepts are still pending, use the async
 `listener_close`, which first completes pending accepts with `CLOSED`; this sync
 variant intentionally returns `BUSY` instead. To tear down a whole loop's
 outstanding operations at once, see `Loop.close_all` + `Loop.drain`.

 @param listener : "Open TCP listener with no active operations"
 @return ? nova::INVALID_STATE : "Listener is not initialized, not open or not owned by the current thread"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Listener has an active accept or close operation"
 @return ? nova::BACKEND_FAILED : "Native close failed"
 @require listener != null : "Listener pointer must not be null"
*>
fn void? listener_close_now(Listener* listener)
{
	if (!listener.initialized) return nova::INVALID_STATE~;
	if (listener.accept_count || listener.accept_driver.active()) return nova::BUSY~;
	if (listener.active_close) return nova::BUSY~;
	if (!listener.open) return nova::INVALID_STATE~;
	if (listener.watcher.registered)
	{
		Loop* loop = listener.watcher.loop;
		if (!loop || !loop.initialized) return nova::INVALID_STATE~;
		if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
		backend::watcher_close(loop, &listener.watcher);
	}
	net::native_tcp_close(listener.native_handle)!;
	listener.watcher = { };
	listener.native_handle = (NativeHandle)-1;
	listener.open = false;
	listener.bound = false;
	listener.listening = false;
	listener.local = { };
}

<*
 Append an accept operation to the listener queue.

 @param listener : "Listener that owns the accept queue"
 @param op : "Accept operation to append"
 @require listener != null : "Listener pointer must not be null"
 @require op != null : "Accept operation pointer must not be null"
*>
fn void accept_queue_push(Listener* listener, AcceptOp* op) @local
{
	op.next_accept = null;
	AcceptOp* tail = listener.accept_tail;
	if (!tail)
	{
		listener.accept_head = op;
	}

	if (tail)
	{
		tail.next_accept = op;
	}

	listener.accept_tail = op;
	listener.accept_count++;
}

<*
 Remove an accept operation from the listener queue.

 @param listener : "Listener that owns the accept queue"
 @param target : "Accept operation to remove"
 @return "True when the operation was queued"
 @require listener != null : "Listener pointer must not be null"
*>
fn bool accept_queue_remove(Listener* listener, AcceptOp* target) @local
{
	AcceptOp* previous = null;
	AcceptOp* current  = listener.accept_head;
	while (current)
	{
		if (current == target)
		{
			if (!previous)
			{
				listener.accept_head = current.next_accept;
			}

			if (previous)
			{
				previous.next_accept = current.next_accept;
			}

			if (listener.accept_tail == current) listener.accept_tail = previous;
			current.next_accept = null;
			if (listener.accept_count) listener.accept_count--;
			return true;
		}
		previous = current;
		current = current.next_accept;
	}
	return false;
}

<*
 Return the first still-active queued accept, dropping stale queue links left by
 cancellation or timeout callbacks.

 @param listener : "Listener that owns the accept queue"
 @return "First active accept operation, or null"
 @require listener != null : "Listener pointer must not be null"
*>
fn AcceptOp* accept_queue_first_active(Listener* listener) @local
{
	while (listener.accept_head && listener.accept_head.header.state != State.OP_ACTIVE)
	{
		AcceptOp* stale = listener.accept_head;
		(void)accept_queue_remove(listener, stale);
	}
	return listener.accept_head;
}

<*
 Ensure the listener-owned accept driver is waiting for readiness.

 @param loop : "Loop that owns the listener"
 @param listener : "Listener with queued accept operations"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Accept driver operation is already active"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
*>
fn void? ensure_accept_driver(Loop* loop, Listener* listener) @local
{
	if (!listener.accept_count) return;
	if (listener.accept_driver.active()) return;
	backend::tcp_accept_driver_submit(
		loop,
		&listener.accept_driver,
		&listener.accept_backend,
		&listener.watcher,
		listener.native_handle,
		&dispatch_accept_driver,
		listener
	)!;
}

<*
 Stop an idle accept driver without closing the listener watcher.

 @param loop : "Loop that owns the listener"
 @param listener : "Listener whose driver is stopped"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
*>
fn void stop_accept_driver(Loop* loop, Listener* listener) @local
{
	if (listener.accept_driver.state == State.OP_ACTIVE)
	{
		backend::detach_interest(loop, &listener.accept_driver);
		reset_accept_driver(listener);
	}
}

<*
 Reset the listener-owned accept driver operation.

 @param listener : "Listener whose driver is reset"
 @require listener != null : "Listener pointer must not be null"
*>
fn void reset_accept_driver(Listener* listener) @local
{
	op::reset_header(&listener.accept_driver);
}

<*
 Rearm the accept driver when accepts remain, otherwise return it to free state.

 @param loop : "Loop that owns the listener"
 @param listener : "Listener with queued accept operations"
 @param driver : "Listener-owned accept driver operation"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
 @require driver != null : "Driver operation pointer must not be null"
*>
fn void rearm_or_reset_accept_driver(Loop* loop, Listener* listener, op::Header* driver) @local
{
	if (!listener.accept_count)
	{
		reset_accept_driver(listener);
		return;
	}

	if (catch err = backend::tcp_accept_rearm(loop, driver))
	{
		complete_pending_accepts(loop, listener, err);
		reset_accept_driver(listener);
	}
}

<*
 Complete every queued accept with the same terminal status.

 @param loop : "Loop that owns the listener"
 @param listener : "Listener with queued accept operations"
 @param status : "Terminal status for each queued accept"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
*>
fn void complete_pending_accepts(Loop* loop, Listener* listener, fault status) @local
{
	AcceptOp* current = listener.accept_head;
	listener.accept_head = null;
	listener.accept_tail = null;
	listener.accept_count = 0;
	while (current)
	{
		AcceptOp* next = current.next_accept;
		current.next_accept = null;
		if (current.header.active()) (void)op::complete(loop, &current.header, status);
		current = next;
	}
}

<*
 Dispatch listener readiness and complete queued accept operations.

 The listener driver owns readiness. Public accept operations own result
 callbacks and can be reposted from inside their own callback because
 `finish_accept` releases the operation before invoking user code.

 @param loop : "Loop dispatching listener readiness"
 @param raw : "Listener-owned driver operation pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_accept_driver(Loop* loop, void* raw) @local
{
	op::Header* driver = (op::Header*)raw;
	Listener* listener = (Listener*)driver.owner;

	if (!listener.open || driver.terminal_status)
	{
		reset_accept_driver(listener);
		return;
	}

	AcceptOp* op = accept_queue_first_active(listener);

	if (op)
	{
		Endpoint peer;
		NativeHandle? accepted = net::native_tcp_accept(listener.native_handle, listener.options, &peer);
		fault err              = @catch(accepted);
		if (err == io::WOULD_BLOCK)
		{
			backend::stream_ready_consumed(driver, nova::READY_READABLE);
		}
		if (err && err != io::WOULD_BLOCK)
		{
			finish_accept_from_driver(loop, listener, driver, op, err, { });
			return;
		}
		if (try accepted_handle = accepted)
		{
			Stream* out = op.out;
			out.native_handle = accepted_handle;
			out.open = true;
			out.send_shutdown = false;
			out.recv_shutdown = false;
			finish_accept_from_driver(loop, listener, driver, op, { }, peer);
			return;
		}
	}

	rearm_or_reset_accept_driver(loop, listener, driver);
}

<*
 Dispatch timeout, cancellation or close completion for one public accept op.

 @param loop : "Loop dispatching the accept operation"
 @param raw : "Accept operation storage pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_accept_result(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	AcceptOp* op       = (AcceptOp*)raw;
	Listener* listener = (Listener*)header.owner;
	finish_accept(loop, listener, op, header.terminal_status, { });
}

<*
 Dispatch an io_uring completion-mode accept (`IORING_OP_ACCEPT`).

 The CQE result is the accepted descriptor (or `-errno`). The kernel applied
 `SOCK_NONBLOCK|SOCK_CLOEXEC`; the remaining stream options are applied here, the
 peer is parsed from the caller sockaddr storage, and the output stream is opened.
 A descriptor that the kernel accepted just before a cancel/close is closed so it
 cannot leak.

 @param loop : "Loop dispatching the accept operation"
 @param raw : "Accept operation storage pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_accept_completion(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	AcceptOp* op       = (AcceptOp*)raw;
	Listener* listener = (Listener*)header.owner;

	sz res = backend::op_completion_result(header);

	if (header.terminal_status)
	{
		if (res >= 0) (void)net::native_tcp_close((NativeHandle)(int)res);
		finish_accept_completion(loop, listener, op, header.terminal_status, { });
		return;
	}

	if (res < 0)
	{
		finish_accept_completion(loop, listener, op, net::tcp_completion_fault((int)-res), { });
		return;
	}

	NativeHandle accepted = (NativeHandle)(int)res;
	if (catch err = net::native_tcp_apply_accept_options(accepted, listener.options))
	{
		(void)net::native_tcp_close(accepted);
		finish_accept_completion(loop, listener, op, err, { });
		return;
	}

	Endpoint peer = { };
	if (try parsed = net::native_endpoint_from_sockaddr_any(&op.peer_addr, op.peer_len)) peer = parsed;

	Stream* out = op.out;
	out.native_handle = accepted;
	out.open = true;
	out.send_shutdown = false;
	out.recv_shutdown = false;
	finish_accept_completion(loop, listener, op, { }, peer);
}

<*
 Complete an io_uring completion-mode accept.

 Unlike the readiness `finish_accept`, there is no driver to stop: the operation is
 only dequeued (it stays queued purely so a listener close can find and cancel it)
 before the terminal callback starts.

 @param loop : "Loop that owns the listener"
 @param listener : "Listener that owns the accept queue"
 @param op : "Accept operation storage"
 @param status : "Terminal status"
 @param peer : "Accepted peer endpoint"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
 @require op != null : "Accept operation pointer must not be null"
*>
fn void finish_accept_completion(Loop* loop, Listener* listener, AcceptOp* op, fault status, Endpoint peer) @local
{
	(void)accept_queue_remove(listener, op);

	AcceptCallback callback = op.callback;
	void* userdata          = op.header.userdata;
	Stream* out             = op.out;

	timer::deadline_done(loop, &op.header);
	AcceptResult result;
	result.error.status = status;
	result.stream = status ? null : out;
	result.peer = peer;

	reset_accept(op);
	if (callback) callback(loop, listener, op, &result, userdata);
}

<*
 Complete an accept operation with a terminal semantic status.

 @param loop : "Loop that owns the listener"
 @param listener : "Listener that owns the accept queue"
 @param op : "Accept operation storage"
 @param status : "Terminal status"
 @param peer : "Accepted peer endpoint"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
 @require op != null : "Accept operation pointer must not be null"
*>
fn void finish_accept(Loop* loop, Listener* listener, AcceptOp* op, fault status, Endpoint peer) @local
{
	(void)accept_queue_remove(listener, op);

	AcceptCallback callback = op.callback;
	void* userdata          = op.header.userdata;
	Stream* out             = op.out;

	timer::deadline_done(loop, &op.header);
	if (!listener.accept_count) stop_accept_driver(loop, listener);
	AcceptResult result;
	result.error.status = status;
	result.stream = out;
	if (status) result.stream = null;
	result.peer = peer;

	reset_accept(op);
	if (callback) callback(loop, listener, op, &result, userdata);
}

<*
 Complete an accept from the listener driver.

 The listener-owned driver is rearmed or reset before user code starts. After
 the callback begins this path does not read or write listener, stream or
 operation storage again.

 @param loop : "Loop that owns the listener"
 @param listener : "Listener that owns the accept queue"
 @param driver : "Listener-owned accept driver operation"
 @param op : "Accept operation storage"
 @param status : "Terminal status"
 @param peer : "Accepted peer endpoint"
 @require loop != null : "Loop pointer must not be null"
 @require listener != null : "Listener pointer must not be null"
 @require driver != null : "Driver operation pointer must not be null"
 @require op != null : "Accept operation pointer must not be null"
*>
fn void finish_accept_from_driver(
	Loop* loop,
	Listener* listener,
	op::Header* driver,
	AcceptOp* op,
	fault status,
	Endpoint peer
) @local
{
	(void)accept_queue_remove(listener, op);

	AcceptCallback callback = op.callback;
	void* userdata          = op.header.userdata;
	Stream* out             = op.out;

	timer::deadline_done(loop, &op.header);
	AcceptResult result;
	result.error.status = status;
	result.stream = out;
	if (status) result.stream = null;
	result.peer = peer;

	rearm_or_reset_accept_driver(loop, listener, driver);

	reset_accept(op);
	if (callback) callback(loop, listener, op, &result, userdata);
}

<*
 Release listener and operation state before a terminal accept callback starts.

 @param op : "Accept operation storage"
 @require op != null : "Accept operation pointer must not be null"
*>
fn void reset_accept(AcceptOp* op) @local
{
	reset_accept_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear accept-specific fields after an accept operation leaves the runtime.

 @param op : "Accept operation storage to clear"
 @require op != null : "Accept operation pointer must not be null"
*>
fn void reset_accept_fields(AcceptOp* op) @local
{
	op.out = null;
	op.next_accept = null;
	op.callback = null;
}

<*
 Dispatch a TCP connect completion through the typed callback.

 Backend writability is only readiness. Successful completion is confirmed
 through the platform `SO_ERROR` check before the stream becomes open.

 @param loop : "Loop dispatching the connect operation"
 @param raw : "Connect operation storage pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_connect(Loop* loop, void* raw) @local
{
	op::Header* header       = (op::Header*)raw;
	ConnectOp* op            = (ConnectOp*)raw;
	Stream* stream           = (Stream*)header.owner;
	ConnectCallback callback = op.callback;
	void* userdata           = header.userdata;
	fault status             = header.terminal_status;

	if (!status && backend::op_completion(header))
	{
		sz res = backend::op_completion_result(header);
		if (res < 0) status = net::tcp_completion_fault((int)-res);
	}
	else if (!status)
	{
		status = @catch(net::native_tcp_connect_finish(stream.native_handle));
	}

	ConnectResult result;
	result.error.status = status;

	if (status)
	{
		backend::watcher_close(loop, &stream.watcher);
		(void)net::native_tcp_close(stream.native_handle);
		stream.native_handle = (NativeHandle)-1;
		stream.open = false;
	}
	if (!status)
	{
		stream.open = true;
		stream.send_shutdown = false;
		stream.recv_shutdown = false;
		result.stream = stream;
	}

	timer::deadline_done(loop, header);
	reset_connect(stream, op);
	callback(loop, stream, op, &result, userdata);
}

<*
 Release stream and operation state before a terminal connect callback starts.

 @param stream : "TCP stream owner"
 @param op : "Connect operation storage"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Connect operation pointer must not be null"
*>
fn void reset_connect(Stream* stream, ConnectOp* op) @local
{
	if (stream.active_connect == &op.header) stream.active_connect = null;
	reset_connect_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear connect-specific fields after a connect operation leaves the runtime.

 @param op : "Connect operation storage to clear"
 @require op != null : "Connect operation pointer must not be null"
*>
fn void reset_connect_fields(ConnectOp* op) @local
{
	op.callback = null;
}

<*
 Dispatch one embedded read completion for a persistent read starter.

 @param loop : "Loop dispatching the read operation"
 @param stream : "Stream being read"
 @param op : "Embedded read operation"
 @param result : "One-shot read result"
 @param userdata : "ReadStarter pointer"
 @require loop != null : "Loop pointer must not be null"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
 @require userdata != null : "Read starter pointer must not be null"
*>
fn void dispatch_read_start(Loop* loop, Stream* stream, ReadOp* op, ReadResult* result, void* userdata) @local
{
	(void)op;
	ReadStarter* reader = (ReadStarter*)userdata;
	if (!reader.active) return;

	reader.active_ref = { };
	if (reader.stopping && result.error.status == nova::CANCELLED)
	{
		read_starter_reset(reader);
		return;
	}

	ReadStartCallback callback = reader.callback;
	void* callback_userdata    = reader.userdata;
	ReadAction action          = callback(loop, stream, reader, result, callback_userdata);
	if (!reader.active) return;

	if (reader.stopping || action == ReadAction.STOP || result.error.status || result.eof)
	{
		read_starter_reset(reader);
		return;
	}

	Ref? submitted = read(loop, stream, reader.buffer, &reader.op, reader.options, &dispatch_read_start, reader);
	if (catch err = submitted)
	{
		ReadResult failure;
		failure.error.status = err;
		failure.buffer = reader.buffer;
		callback = reader.callback;
		callback_userdata = reader.userdata;
		read_starter_reset(reader);
		callback(loop, stream, reader, &failure, callback_userdata);
		return;
	}

	Ref oref = submitted;
	reader.active_ref = oref;
}

<*
 Clear persistent read helper runtime fields while preserving initialization.

 @param reader : "Read starter to reset"
 @require reader != null : "Read starter pointer must not be null"
*>
fn void read_starter_reset(ReadStarter* reader) @local
{
	bool initialized = reader.initialized;
	reader.stream = null;
	reader.buffer = { };
	reader.options = { };
	reader.callback = null;
	reader.userdata = null;
	reader.active_ref = { };
	reader.active = false;
	reader.stopping = false;
	reader.initialized = initialized;
}

<*
 Dispatch an async stream close completion through the typed callback.

 @param loop : "Loop dispatching the close operation"
 @param raw : "Stream close operation storage pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_stream_close(Loop* loop, void* raw) @local
{
	op::Header* header           = (op::Header*)raw;
	StreamCloseOp* op            = (StreamCloseOp*)raw;
	Stream* stream               = (Stream*)header.owner;
	StreamCloseCallback callback = op.callback;
	void* userdata               = header.userdata;

	CloseResult result;
	result.error.status = header.terminal_status;
	reset_stream_close(stream, op);
	callback(loop, stream, op, &result, userdata);
}

<*
 Release stream close operation state before its callback starts.

 @param stream : "TCP stream owner"
 @param op : "Stream close operation storage"
 @require stream != null : "Stream pointer must not be null"
 @require op != null : "Stream close operation pointer must not be null"
*>
fn void reset_stream_close(Stream* stream, StreamCloseOp* op) @local
{
	if (stream.active_close == &op.header) stream.active_close = null;
	reset_stream_close_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear stream-close-specific fields after a close operation leaves the runtime.

 @param op : "Stream close operation storage to clear"
 @require op != null : "Stream close operation pointer must not be null"
*>
fn void reset_stream_close_fields(StreamCloseOp* op) @local
{
	op.callback = null;
}

<*
 Dispatch an async listener close completion through the typed callback.

 @param loop : "Loop dispatching the close operation"
 @param raw : "Listener close operation storage pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_listener_close(Loop* loop, void* raw) @local
{
	op::Header* header             = (op::Header*)raw;
	ListenerCloseOp* op            = (ListenerCloseOp*)raw;
	Listener* listener             = (Listener*)header.owner;
	ListenerCloseCallback callback = op.callback;
	void* userdata                 = header.userdata;

	CloseResult result;
	result.error.status = header.terminal_status;
	reset_listener_close(listener, op);
	callback(loop, listener, op, &result, userdata);
}

<*
 Release listener close operation state before its callback starts.

 @param listener : "TCP listener owner"
 @param op : "Listener close operation storage"
 @require listener != null : "Listener pointer must not be null"
 @require op != null : "Listener close operation pointer must not be null"
*>
fn void reset_listener_close(Listener* listener, ListenerCloseOp* op) @local
{
	if (listener.active_close == &op.header) listener.active_close = null;
	reset_listener_close_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear listener-close-specific fields after a close operation leaves the runtime.

 @param op : "Listener close operation storage to clear"
 @require op != null : "Listener close operation pointer must not be null"
*>
fn void reset_listener_close_fields(ListenerCloseOp* op) @local
{
	op.callback = null;
}
