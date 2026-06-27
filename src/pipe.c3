module nova::pipe;

import std::io, std::net::os, std::os::posix;
import libc;

import nova @norecurse;
import nova::backend @public;
import nova::op @public;
import nova::posix_errno @public;
import nova::stream @public;

<*
 Short alias for the generic stream module used by pipe read/write operations.
*>
alias evstream = module nova::stream;

<*
 Result delivered for pipe read completion.
*>
alias ReadResult = evstream::ReadResult;

<*
 Result delivered for pipe write completion.
*>
alias WriteResult = evstream::WriteResult;

<*
 Caller-owned pipe read operation storage.
*>
alias ReadOp = evstream::ReadOp;

<*
 Caller-owned pipe write operation storage.
*>
alias WriteOp = evstream::WriteOp;

<*
 Callback invoked when a pipe read reaches a terminal result.

 @param loop : "Loop dispatching the read"
 @param endpoint : "Pipe endpoint used by the read"
 @param op : "Read operation storage"
 @param result : "Read result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias ReadCallback = fn void(Loop* loop, Endpoint* endpoint, ReadOp* op, ReadResult* result, void* userdata);

<*
 Callback invoked when a pipe write reaches a terminal result.

 @param loop : "Loop dispatching the write"
 @param endpoint : "Pipe endpoint used by the write"
 @param op : "Write operation storage"
 @param result : "Write result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias WriteCallback = fn void(Loop* loop, Endpoint* endpoint, WriteOp* op, WriteResult* result, void* userdata);

<*
 Callback invoked when pipe endpoint close reaches a terminal result.

 @param loop : "Loop dispatching the close"
 @param endpoint : "Pipe endpoint being closed"
 @param op : "Close operation storage"
 @param result : "Close result valid only during the callback"
 @param userdata : "Submission userdata"
*>
alias EndpointCloseCallback = fn void(
	Loop* loop,
	Endpoint* endpoint,
	EndpointCloseOp* op,
	CloseResult* result,
	void* userdata
);

<*
 POSIX file descriptor flags used for close-on-exec setup.
*>
const int F_GETFD          = 1;
const int F_SETFD          = 2;
const int FD_CLOEXEC       = 1;
const CInt PIPE_O_NONBLOCK = env::LINUX ? 0o4000 : 0x0004;
const CInt PIPE_O_CLOEXEC  = env::LINUX ? 0o2000000 : 0x01000000;

<*
 Pipe endpoint direction.

 Anonymous POSIX pipes are split into one readable endpoint and one writable
 endpoint. `DUPLEX` is reserved for future socketpair-backed endpoints.
*>
constdef Direction : inline char
{
	READ   = 1,
	WRITE  = 2,
	DUPLEX = 3,
}

<*
 POSIX `pipe2` binding used where descriptor flags can be applied atomically.
*>
extern fn CInt posix_pipe2(CInt[2]* pipes, CInt flags) @cname("pipe2") @if(env::LINUX);

<*
 Per-read pipe options.

 `min_bytes` controls terminal success: `0` requests at least one byte, and
 non-zero values must not exceed the submitted read buffer length. `wait_readiness` skips
 the immediate non-blocking read attempt and waits for readiness first. To bound
 a read, arm a `timer` and cancel the read by its `Ref`.
*>
struct ReadOptions
{
	sz min_bytes;
	bool wait_readiness;
}

<*
 Per-write pipe options.

 `wait_readiness` skips the immediate non-blocking write attempt and waits for writable
 readiness first. To bound a write, arm a `timer` and cancel by its `Ref`.
*>
struct WriteOptions
{
	bool wait_readiness;
}

<*
 Async pipe close behavior.

 `abortive` is accepted for API symmetry with stream handles and ignored for
 pipe endpoints.
*>
struct CloseOptions
{
	bool abortive;
}

<*
 Options for attaching an existing native pipe descriptor to an endpoint.

 Adopted descriptors are configured as nonblocking and close-on-exec. When
 `owns_handle` is true, closing the endpoint closes the descriptor. Borrowed
 endpoints unregister from nova on close but leave descriptor ownership with the
 caller.
*>
struct OpenOptions
{
	bool owns_handle;
	Direction direction;
}

<*
 Caller-owned pipe endpoint handle.

 Endpoints created by `Pair.open` own their native handle while `open` is true;
 endpoints attached with `Endpoint.adopt` use that call's explicit ownership.
 At most one read, one write and one close operation may be active on an endpoint
 at a time.
*>
struct Endpoint
{
	NativeHandle native_handle;
	backend::Watcher watcher;
	op::Header* active_read;
	op::Header* active_write;
	op::Header* active_close;
	Direction direction;
	bool initialized;
	bool open;
	bool owns_handle;
}

<*
 Caller-owned anonymous pipe pair.

 `read` is readable only; `write` is writable only. Each endpoint must be closed
 before the pair storage is destroyed.
*>
struct Pair
{
	Endpoint read;
	Endpoint write;
}

<*
 Caller-owned async pipe endpoint close operation storage.

 The callback field is set by `close` and cleared before the terminal callback
 starts, so the same storage may be reused from that callback.
*>
struct EndpointCloseOp
{
	inline op::Header header;
	CloseResult result;
	EndpointCloseCallback callback;
}

<*
 POSIX pipe descriptor pair.
*>
struct NativePipePair
{
	NativeHandle read;
	NativeHandle write;
}

<*
 Open a nonblocking close-on-exec anonymous pipe pair.

 @param [&inout] self : "Pair storage to initialize"
 @return "Initialized open pipe pair"
 @return ? nova::INVALID_STATE : "A pair endpoint is already initialized"
 @return ? nova::BACKEND_FAILED : "Native pipe creation or setup failed"
 @ensure self.read.initialized : "Read endpoint is initialized when open succeeds"
 @ensure self.write.initialized : "Write endpoint is initialized when open succeeds"
*>
fn Pair*? Pair.open(&self)
{
	if (self.read.initialized || self.write.initialized) return nova::INVALID_STATE~;
	NativePipePair handles = native_pipe_pair()!;
	*self = { };
	endpoint_open(&self.read, handles.read, { .owns_handle = true, .direction = Direction.READ });
	endpoint_open(&self.write, handles.write, { .owns_handle = true, .direction = Direction.WRITE });
	return self;
}

<*
 Destroy closed pipe pair storage.

 @param [&inout] self : "Closed pipe pair"
 @require self.read.initialized : "Read endpoint must be initialized"
 @require self.write.initialized : "Write endpoint must be initialized"
 @require !self.read.open : "Read endpoint must be closed"
 @require !self.write.open : "Write endpoint must be closed"
 @ensure !self.read.initialized : "Read endpoint is uninitialized after destroy"
 @ensure !self.write.initialized : "Write endpoint is uninitialized after destroy"
*>
fn void Pair.destroy(&self)
{
	self.read.destroy();
	self.write.destroy();
}

<*
 Destroy closed endpoint storage.

 @param [&inout] self : "Closed endpoint"
 @require self.initialized : "Endpoint must be initialized"
 @require !self.open : "Endpoint must be closed"
 @require self.active_read == null : "Read operation must be inactive"
 @require self.active_write == null : "Write operation must be inactive"
 @require self.active_close == null : "Close operation must be inactive"
 @ensure !self.initialized : "Endpoint is uninitialized after destroy"
*>
fn void Endpoint.destroy(&self)
{
	*self = { };
	self.native_handle = (NativeHandle)-1;
}

<*
 Attach an existing native pipe descriptor to endpoint storage.

 The descriptor is configured as nonblocking and close-on-exec before the
 endpoint becomes open. If setup fails for an owned descriptor, the descriptor is
 closed before the fault is returned. Borrowed descriptors remain open on setup
 failure and when the endpoint is later closed.

 @param [&inout] self : "Endpoint storage to initialize"
 @param handle : "Open native pipe descriptor"
 @param options : "Direction and ownership for the descriptor"
 @return "Initialized open pipe endpoint"
 @return ? nova::INVALID_SOCKET : "Native descriptor is invalid"
 @return ? nova::INVALID_STATE : "Endpoint is already initialized or direction is invalid"
 @return ? nova::BACKEND_FAILED : "Native descriptor setup failed"
*>
fn Endpoint*? Endpoint.adopt(&self, NativeHandle handle, OpenOptions options)
{
	if (self.initialized) return nova::INVALID_STATE~;
	if ((int)handle < 0) return nova::INVALID_SOCKET~;
	if (!direction_valid(options.direction)) return nova::INVALID_STATE~;

	if (catch err = native_pipe_prepare((CInt)(int)handle))
	{
		if (options.owns_handle) (void)native_pipe_close(handle);
		return err~;
	}

	endpoint_open(self, handle, options);
	return self;
}

<*
 Report whether this endpoint currently owns or borrows an open descriptor.

 @param self : "Endpoint storage to inspect"
 @return "True when the endpoint is open"
*>
fn bool Endpoint.is_open(&self) => self.open;

<*
 Borrow this endpoint's native descriptor.

 The returned handle remains owned by the endpoint when `owns_handle` is true and
 must not be closed directly. For borrowed endpoints, the caller still owns the
 descriptor and is responsible for closing it after the endpoint is closed.

 @param self : "Endpoint storage to inspect"
 @return "Open native descriptor"
 @return ? nova::INVALID_STATE : "Endpoint is not initialized or not open"
*>
fn NativeHandle? Endpoint.borrow_native(&self)
{
	if (!self.initialized || !self.open) return nova::INVALID_STATE~;
	return self.native_handle;
}

<*
 Try to write bytes to this pipe immediately without submitting an operation.

 This preserves the ordering of async writes: when a write is active, the call
 returns `BUSY` instead of writing around queued data.

 @param self : "Open writable pipe endpoint"
 @param bytes : "Caller-owned source bytes"
 @return "Bytes accepted by the OS"
 @return ? nova::INVALID_STATE : "Endpoint is not initialized, writable, open or bytes are empty"
 @return ? nova::BUSY : "Endpoint has an active close or write operation"
 @return ? std::io::WOULD_BLOCK : "No bytes can be written now"
 @return ? nova::CLOSED : "The read side is closed"
 @return ? nova::INVALID_SOCKET : "Native descriptor is invalid"
 @return ? nova::BACKEND_FAILED : "Native write failed"
*>
fn sz? Endpoint.try_write(&self, char[] bytes)
{
	if (!self.initialized || !self.open || !(self.direction & Direction.WRITE)) return nova::INVALID_STATE~;
	if (self.active_close || self.active_write) return nova::BUSY~;
	if (!bytes.len) return nova::INVALID_STATE~;
	return native_pipe_write(self.native_handle, bytes);
}

<*
 Return bytes still pending in this endpoint's active write operation.

 @param self : "Endpoint storage to inspect"
 @return "Pending async write bytes, or zero when no write is active"
*>
fn sz Endpoint.write_queue_size(&self) => evstream::pending_write_bytes(self.active_write);

<*
 Submit one pipe read operation using a caller-owned buffer.

 The buffer is borrowed until the terminal callback starts. The callback starts
 after `op` is reusable.

 @param loop : "Loop that owns the read operation"
 @param endpoint : "Open readable pipe endpoint"
 @param [out] buffer : "Caller-owned destination bytes borrowed until callback"
 @param op : "Read operation storage"
 @param options : "Read timeout and minimum byte options"
 @param callback : "Callback invoked when read reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, endpoint, buffer or options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Endpoint or operation already has an active read or close"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require endpoint != null : "Endpoint pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
*>
fn Ref? read(
	Loop* loop,
	Endpoint* endpoint,
	char[] buffer,
	ReadOp* op,
	ReadOptions options,
	ReadCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !endpoint.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (endpoint.active_close) return nova::BUSY~;
	if (!endpoint.open || !(endpoint.direction & Direction.READ)) return nova::INVALID_STATE~;
	if (!buffer.len || options.min_bytes < 0) return nova::INVALID_STATE~;
	if (options.min_bytes > buffer.len) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (endpoint.active_read || op.header.active()) return nova::BUSY~;

	sz min_bytes = 1;
	if (options.min_bytes > 0) min_bytes = options.min_bytes;
	return evstream::submit_read(
		loop,
		endpoint_handle_state(endpoint),
		endpoint,
		buffer,
		min_bytes,
		op,
		&native_pipe_read,
		(evstream::ReadCallback)callback,
		userdata,
		!options.wait_readiness
	);
}

<*
 Submit one pipe write operation using caller-owned bytes.

 The byte slice is borrowed until the terminal callback starts. The callback
 starts after `op` is reusable.

 @param loop : "Loop that owns the write operation"
 @param endpoint : "Open writable pipe endpoint"
 @param bytes : "Caller-owned source bytes borrowed until callback"
 @param op : "Write operation storage"
 @param options : "Write timeout options"
 @param callback : "Callback invoked when write reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop, endpoint, bytes or options are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Endpoint or operation already has an active write or close"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require endpoint != null : "Endpoint pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn Ref? write(
	Loop* loop,
	Endpoint* endpoint,
	char[] bytes,
	WriteOp* op,
	WriteOptions options,
	WriteCallback callback,
	void* userdata = null
)
{
	if (!loop.initialized || !endpoint.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (endpoint.active_close) return nova::BUSY~;
	if (!endpoint.open || !(endpoint.direction & Direction.WRITE)) return nova::INVALID_STATE~;
	if (!bytes.len) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;
	if (endpoint.active_write || op.header.active()) return nova::BUSY~;

	return evstream::submit_write(
		loop,
		endpoint_handle_state(endpoint),
		endpoint,
		bytes,
		op,
		!options.wait_readiness,
		&native_pipe_write,
		(evstream::WriteCallback)callback,
		userdata
	);
}

<*
 Submit async pipe endpoint close.

 Close first completes active stream operations with `CLOSED`, then unregisters
 backend readiness and closes the native descriptor only when this endpoint owns
 it. `options.abortive` is ignored for pipe endpoints.

 @param loop : "Loop that owns the close operation"
 @param endpoint : "Pipe endpoint being closed"
 @param op : "Close operation storage"
 @param options : "Close behavior options"
 @param callback : "Callback invoked when close reaches a terminal result"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop or endpoint is not ready for close"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Endpoint or operation already has an active close"
 @return ? nova::BACKEND_FAILED : "Owned native close failed"
 @require loop != null : "Loop pointer must not be null"
 @require endpoint != null : "Endpoint pointer must not be null"
 @require op != null : "Close operation pointer must not be null"
*>
fn Ref? close(
	Loop* loop,
	Endpoint* endpoint,
	EndpointCloseOp* op,
	CloseOptions options,
	EndpointCloseCallback callback,
	void* userdata = null
)
{
	(void)options;
	if (!loop.initialized || !endpoint.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (endpoint.active_close || op.header.active()) return nova::BUSY~;
	if (!endpoint.open && !endpoint.active_read && !endpoint.active_write) return nova::INVALID_STATE~;
	if (!callback) return nova::INVALID_STATE~;

	if (endpoint.active_read) op::complete(loop, endpoint.active_read, nova::CLOSED)!;
	if (endpoint.active_write) op::complete(loop, endpoint.active_write, nova::CLOSED)!;

	backend::watcher_close(loop, &endpoint.watcher);
	fault status;
	if (endpoint.owns_handle) status = @catch(native_pipe_close(endpoint.native_handle));

	endpoint.native_handle = (NativeHandle)-1;
	endpoint.open = false;
	endpoint.owns_handle = false;
	op.result = { };
	op.callback = callback;

	Ref? submitted = nova::submit_pipe_close(loop, &op.header, &dispatch_close, endpoint, userdata, status);
	if (catch submitted)
	{
		reset_close_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	endpoint.active_close = &op.header;
	return oref;
}

<*
 Close a pipe endpoint synchronously when it has no active operations.

 If the endpoint has a registered watcher from previous read or write
 operations, `close_now` unregisters it on the owning loop thread. Borrowed
 endpoints are detached from nova but their native descriptor is left open.

 @param endpoint : "Open pipe endpoint with no active operations"
 @return ? nova::INVALID_STATE : "Endpoint is not initialized, not open or not owned by the current thread"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Endpoint has an active read, write or close operation"
 @return ? nova::INVALID_SOCKET : "Owned native descriptor was invalid"
 @return ? nova::BACKEND_FAILED : "Owned native close failed"
 @require endpoint != null : "Endpoint pointer must not be null"
*>
fn void? close_now(Endpoint* endpoint)
{
	if (!endpoint.initialized) return nova::INVALID_STATE~;
	if (endpoint.active_read) return nova::BUSY~;
	if (endpoint.active_write) return nova::BUSY~;
	if (endpoint.active_close) return nova::BUSY~;
	if (!endpoint.open) return nova::INVALID_STATE~;
	if (endpoint.watcher.registered)
	{
		Loop* loop = endpoint.watcher.loop;
		if (!loop || !loop.initialized) return nova::INVALID_STATE~;
		if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
		backend::watcher_close(loop, &endpoint.watcher);
	}
	if (endpoint.owns_handle) native_pipe_close(endpoint.native_handle)!;
	endpoint.watcher = { };
	endpoint.native_handle = (NativeHandle)-1;
	endpoint.open = false;
	endpoint.owns_handle = false;
}

<*
 Borrow endpoint state for the shared stream read/write driver.

 @param endpoint : "Pipe endpoint whose state will back one operation"
 @return "Shared stream handle state pointing into the endpoint"
 @require endpoint != null : "Endpoint pointer must not be null"
*>
fn evstream::HandleState endpoint_handle_state(Endpoint* endpoint) @local
{
	return {
		.handle = &endpoint.native_handle,
		.watcher = &endpoint.watcher,
		.active_read = &endpoint.active_read,
		.active_write = &endpoint.active_write,
	};
}

<*
 Attach an open native descriptor to endpoint storage.

 @param endpoint : "Endpoint storage to initialize"
 @param handle : "Open native pipe descriptor"
 @param options : "Endpoint direction and ownership"
 @require endpoint != null : "Endpoint pointer must not be null"
*>
fn void endpoint_open(Endpoint* endpoint, NativeHandle handle, OpenOptions options)
{
	*endpoint = { };
	endpoint.native_handle = handle;
	endpoint.direction = options.direction;
	endpoint.initialized = true;
	endpoint.open = true;
	endpoint.owns_handle = options.owns_handle;
}

<*
 Validate a public pipe endpoint direction.

 @param direction : "Direction value to validate"
 @return "True when the direction is supported"
*>
fn bool direction_valid(Direction direction) @local
{
	return direction == Direction.READ || direction == Direction.WRITE;
}

<*
 Dispatch an async pipe close completion through the typed callback.

 @param loop : "Loop dispatching the close operation"
 @param raw : "Header pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_close(Loop* loop, void* raw)
{
	op::Header* header             = (op::Header*)raw;
	EndpointCloseOp* op            = (EndpointCloseOp*)raw;
	Endpoint* endpoint             = (Endpoint*)header.owner;
	EndpointCloseCallback callback = op.callback;
	void* userdata                 = header.userdata;

	CloseResult result;
	result.error.status = header.terminal_status;
	reset_close(endpoint, op);
	callback(loop, endpoint, op, &result, userdata);
}

<*
 Release pipe close operation state before its callback starts.

 @param endpoint : "Pipe endpoint owner"
 @param op : "Close operation storage"
 @require endpoint != null : "Endpoint pointer must not be null"
 @require op != null : "Close operation pointer must not be null"
*>
fn void reset_close(Endpoint* endpoint, EndpointCloseOp* op)
{
	if (endpoint.active_close == &op.header) endpoint.active_close = null;
	reset_close_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear close-specific fields after a close operation leaves the runtime.

 @param op : "Close operation storage to clear"
 @require op != null : "Close operation pointer must not be null"
*>
fn void reset_close_fields(EndpointCloseOp* op)
{
	op.result = { };
	op.callback = null;
}

<*
 Create a nonblocking close-on-exec POSIX pipe pair.

 @return "Native readable and writable descriptors"
 @return ? nova::BACKEND_FAILED : "pipe or fcntl failed"
*>
fn NativePipePair? native_pipe_pair() @local
{
	CInt[2] fds = { -1, -1 };
	$if env::LINUX:
		if (posix_pipe2(&fds, PIPE_O_CLOEXEC | PIPE_O_NONBLOCK) == 0)
		{
			return { .read = (NativeHandle)fds[0], .write = (NativeHandle)fds[1] };
		}
		Errno err = libc::errno();
		if (err != posix_errno::E_INVAL && err != posix_errno::E_NOSYS) return nova::BACKEND_FAILED~;
	$endif

	if (posix::pipe(&fds) != 0) return nova::BACKEND_FAILED~;

	if (catch native_pipe_prepare(fds[0]))
	{
		(void)libc::close(fds[0]);
		(void)libc::close(fds[1]);
		return nova::BACKEND_FAILED~;
	}
	if (catch native_pipe_prepare(fds[1]))
	{
		(void)libc::close(fds[0]);
		(void)libc::close(fds[1]);
		return nova::BACKEND_FAILED~;
	}

	return { .read = (NativeHandle)fds[0], .write = (NativeHandle)fds[1] };
}

<*
 Put a POSIX pipe descriptor in close-on-exec and nonblocking mode.

 @param fd : "Native pipe descriptor"
 @return ? nova::BACKEND_FAILED : "fcntl failed"
*>
fn void? native_pipe_prepare(CInt fd) @local
{
	os::NativeSocket socket = (os::NativeSocket)fd;
	int fd_flags            = fcntl_retry(socket, (CInt)F_GETFD, 0);
	if (fd_flags < 0) return pipe_setup_fault()~;
	if (fcntl_retry(socket, (CInt)F_SETFD, fd_flags | FD_CLOEXEC) < 0) return pipe_setup_fault()~;

	int flags = fcntl_retry(socket, (CInt)os::F_GETFL, 0);
	if (flags < 0) return pipe_setup_fault()~;
	if (fcntl_retry(socket, (CInt)os::F_SETFL, flags | os::O_NONBLOCK) < 0) return pipe_setup_fault()~;
}

<*
 Convert the current pipe setup errno to a portable fault.

 @return "Portable setup fault"
*>
fn fault pipe_setup_fault() @local
{
	if (libc::errno() == posix_errno::E_BADF) return nova::INVALID_SOCKET;
	return nova::BACKEND_FAILED;
}

<*
 Retry `fcntl` while it is interrupted by `EINTR`.

 @param fd : "Native descriptor"
 @param cmd : "fcntl command"
 @param arg : "fcntl integer argument"
 @return "Native fcntl result"
*>
fn int fcntl_retry(os::NativeSocket fd, CInt cmd, int arg)
{
	int result;
	do
	{
		result = os::fcntl(fd, cmd, arg);
	} while (result < 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Read from a nonblocking POSIX pipe.

 @param handle : "Native pipe descriptor"
 @param [out] buffer : "Caller-owned destination bytes"
 @return "Bytes read, or zero for EOF"
 @return ? std::io::WOULD_BLOCK : "No bytes are ready now"
 @return ? nova::INVALID_SOCKET : "Native descriptor is invalid"
 @return ? nova::BACKEND_FAILED : "read failed"
*>
fn sz? native_pipe_read(NativeHandle handle, char[] buffer) @local
{
	if ((int)handle < 0) return nova::INVALID_SOCKET~;

	while (true)
	{
		sz received = libc::read((Fd)(int)handle, buffer.ptr, (usz)buffer.len);
		if (received >= 0) return received;

		Errno err = libc::errno();
		if (err == posix_errno::E_INTR) continue;
		if (err == posix_errno::E_AGAIN || err == posix_errno::E_WOULDBLOCK) return io::WOULD_BLOCK~;
		if (err == posix_errno::E_BADF) return nova::INVALID_SOCKET~;
		return nova::BACKEND_FAILED~;
	}
}

<*
 Write caller-owned bytes to a nonblocking POSIX pipe.

 @param handle : "Native pipe descriptor"
 @param bytes : "Caller-owned source bytes"
 @return "Bytes accepted by the OS"
 @return ? std::io::WOULD_BLOCK : "No bytes can be written now"
 @return ? nova::CLOSED : "The read side is closed"
 @return ? nova::INVALID_SOCKET : "Native descriptor is invalid"
 @return ? nova::BACKEND_FAILED : "write failed"
*>
fn sz? native_pipe_write(NativeHandle handle, char[] bytes) @local
{
	if ((int)handle < 0) return nova::INVALID_SOCKET~;
	ignore_sigpipe_once();

	while (true)
	{
		sz written = libc::write((Fd)(int)handle, bytes.ptr, (usz)bytes.len);
		if (written >= 0) return written;

		Errno err = libc::errno();
		if (err == posix_errno::E_INTR) continue;
		if (err == posix_errno::E_AGAIN || err == posix_errno::E_WOULDBLOCK) return io::WOULD_BLOCK~;
		if (err == posix_errno::E_PIPE) return nova::CLOSED~;
		if (err == posix_errno::E_BADF) return nova::INVALID_SOCKET~;
		return nova::BACKEND_FAILED~;
	}
}

<*
 Close a POSIX pipe descriptor.

 @param handle : "Native pipe descriptor"
 @return ? nova::INVALID_SOCKET : "Native descriptor is invalid"
 @return ? nova::BACKEND_FAILED : "close failed"
*>
fn void? native_pipe_close(NativeHandle handle) @local
{
	if ((int)handle < 0) return;
	if (libc::close((CInt)(int)handle) != 0)
	{
		Errno err = libc::errno();
		if (err == posix_errno::E_BADF) return nova::INVALID_SOCKET~;
		if (err == posix_errno::E_INTR || err == posix_errno::E_INPROGRESS) return;
		return nova::BACKEND_FAILED~;
	}
}

<*
 Ignore process SIGPIPE once so pipe writes can report `EPIPE` as a fault.

 POSIX `write` to a pipe with no reader raises SIGPIPE before returning EPIPE
 unless the signal is ignored or blocked. nova uses the same process-wide
 policy common to event libraries so pipe writes report through callbacks.
*>
fn void ignore_sigpipe_once() @local
{
	static uint ignored;
	if (@atomic_load(ignored) != 0) return;
	(void)libc::signal(libc::SIGPIPE, (libc::SignalFunction)1);
	@atomic_store(ignored, (uint)1);
}
