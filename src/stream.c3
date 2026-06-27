module nova::stream;

import std::io;

import nova @norecurse;
import nova::backend @public;
import nova::op @public;
import nova::timer;

<*
 Native non-blocking read function used by the shared stream driver.

 A zero-byte success means EOF. `std::io::WOULD_BLOCK` means readiness was stale
 and the operation should be rearmed without invoking user code.
*>
alias NativeReadFn = fn sz?(NativeHandle handle, char[] buffer);

<*
 Native scatter-gather read used by the shared stream driver for vectored reads.

 `first_offset` is the number of already-filled bytes to skip at the start of
 `vectors[0]` (partial-read resume). Returns bytes read this call (zero means
 EOF); `std::io::WOULD_BLOCK` means readable readiness was stale.
*>
alias NativeReadVFn = fn sz?(NativeHandle handle, char[][] vectors, usz first_offset);

<*
 Native non-blocking write function used by the shared stream driver.

 `std::io::WOULD_BLOCK` means writable readiness was stale and the operation
 should be rearmed while preserving partial progress.
*>
alias NativeWriteFn = fn sz?(NativeHandle handle, char[] bytes);

<*
 Native scatter-gather write used by the shared stream driver for vectored
 writes. `first_offset` is the number of already-written bytes to skip at the
 start of `vectors[0]` (partial-write resume). Returns bytes accepted by the OS
 this call; `std::io::WOULD_BLOCK` means writable readiness was stale.
*>
alias NativeWriteVFn = fn sz?(NativeHandle handle, char[][] vectors, usz first_offset);

<*
 Callback invoked when a shared stream read reaches a terminal result.

 Concrete modules may cast their typed callback to this ABI-compatible erased
 form while still exposing typed public callback aliases.
*>
alias ReadCallback = fn void(Loop* loop, void* owner, ReadOp* op, ReadResult* result, void* userdata);

<*
 Callback invoked when a shared stream write reaches a terminal result.

 Concrete modules may cast their typed callback to this ABI-compatible erased
 form while still exposing typed public callback aliases.
*>
alias WriteCallback = fn void(Loop* loop, void* owner, WriteOp* op, WriteResult* result, void* userdata);

<*
 Map a completion-mode `-errno` (the negated CQE result) to the typed terminal
 fault.

 Concrete stream modules supply this so io_uring `RECV`/`SEND` failures map to the
 same faults their `recv`/`send` syscalls would have produced. Only consulted on
 the io_uring completion path; the readiness path maps errno inside its native
 read/write functions instead.
*>
alias FaultFromErrno = fn fault(int err);

<*
 Mutable handle state borrowed by one shared stream operation.

 The pointed-to fields remain owned by the concrete stream handle. They must
 stay valid until the terminal callback returns.
*>
struct HandleState @private
{
	NativeHandle* handle;
	backend::Watcher* watcher;
	op::Header** active_read;
	op::Header** active_write;
}

<*
 Result delivered for stream read completion.

 The buffer slice aliases caller-provided read storage and is valid only during
 the callback that receives this result. `bytes` is the total copied into
 `buffer` before `min_bytes`, an error, or EOF completed the operation.
 Timeout, cancellation and close completions preserve bytes already copied and
 report `eof == false`. `eof` reports peer shutdown and may be true with
 partial bytes.
*>
struct ReadResult
{
	ErrorInfo error;
	char[] buffer;
	sz bytes;
	bool eof;
}

<*
 Result delivered for stream write completion.

 `bytes` is the number of bytes accepted before the terminal status was
 reported. On error, timeout, cancellation or close, this may be less than the
 submitted byte slice length, including zero when no bytes were accepted.
*>
struct WriteResult
{
	ErrorInfo error;
	sz bytes;
}

<*
 Caller-owned stream read operation storage.

 The read buffer (scalar read) or the `vectors` slices (scatter-gather read) are
 borrowed from submission until the terminal callback starts. A non-empty
 `vectors` selects the vectored path. Progress fields `filled`, `vector_index`
 and `vector_offset` are runtime-owned while the operation is active.
*>
struct ReadOp
{
	inline op::Header header;
	backend::OpState backend;
	char[] buffer;
	sz min_bytes;
	sz filled;
	char[][] vectors;
	usz vector_index;
	usz vector_offset;
	backend::Msghdr msghdr;
	backend::IoVec scratch_iov;
	HandleState handle;
	NativeReadFn native_read;
	NativeReadVFn native_readv;
	FaultFromErrno result_fault;
	ReadCallback callback;
}

<*
 Caller-owned stream write operation storage.

 The byte slice (scalar write) or the `vectors` slices (scatter-gather write) are
 borrowed from submission until the terminal callback starts. A non-empty
 `vectors` selects the vectored path. Progress fields `written`, `vector_index`
 and `vector_offset` are runtime-owned while the operation is active.
*>
struct WriteOp
{
	inline op::Header header;
	backend::OpState backend;
	char[] bytes;
	sz written;
	char[][] vectors;
	usz vector_index;
	usz vector_offset;
	backend::Msghdr msghdr;
	backend::IoVec scratch_iov;
	HandleState handle;
	NativeWriteFn native_write;
	NativeWriteVFn native_writev;
	FaultFromErrno result_fault;
	WriteCallback callback;
}

<*
 Whether a write operation has sent all of its bytes (scalar or vectored).
*>
fn bool write_done(WriteOp* op) @local
{
	if (op.vectors.len > 0) return op.vector_index >= op.vectors.len;
	return op.written >= op.bytes.len;
}

<*
 Return the number of bytes still pending in an active stream write.

 @param active_write : "Active write header, or null when no write is pending"
 @return "Remaining bytes in the active write operation"
*>
fn sz pending_write_bytes(op::Header* active_write) @private
{
	if (!active_write) return 0;
	WriteOp* op = (WriteOp*)active_write;
	if (op.vectors.len > 0)
	{
		sz pending = 0;
		for (usz i = op.vector_index; i < op.vectors.len; i++)
		{
			usz off = i == op.vector_index ? op.vector_offset : 0;
			pending += (sz)(op.vectors[i].len - off);
		}
		return pending;
	}
	if (op.written >= op.bytes.len) return 0;
	return op.bytes.len - op.written;
}

<*
 Submit one shared stream read operation using caller-owned storage.

 Shared internal plumbing: the public `tcp`/`pipe` wrappers pre-validate the
 loop, handle, buffer, callback and busy state, so they are not re-checked here.

 @param loop : "Loop that owns the read operation"
 @param handle : "Borrowed concrete handle state"
 @param owner : "Concrete stream handle delivered to the callback"
 @param [out] buffer : "Caller-owned destination bytes borrowed until callback"
 @param min_bytes : "Minimum bytes required for successful terminal completion"
 @param op : "Read operation storage"
 @param native_read : "Concrete non-blocking read function"
 @param callback : "Erased terminal callback"
 @param userdata : "Opaque user pointer delivered to the callback"
 @param try_immediate : "Attempt bounded non-blocking progress before waiting for readiness"
 @param result_fault : "Maps a completion `-errno` to the typed fault, or null for readiness-only modules"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
*>
fn Ref? submit_read(
	Loop* loop,
	HandleState handle,
	void* owner,
	char[] buffer,
	sz min_bytes,
	ReadOp* op,
	NativeReadFn native_read,
	ReadCallback callback,
	void* userdata = null,
	bool try_immediate = false,
	FaultFromErrno result_fault = null
) @private
{
	op.buffer = buffer;
	op.min_bytes = min_bytes;
	op.filled = 0;
	op.handle = handle;
	op.native_read = native_read;
	op.result_fault = result_fault;
	op.callback = callback;

	bool completion = buffer.len > 0 && result_fault != null && backend::stream_completion_read_enabled(loop);
	Ref? submitted;
	if (completion)
	{
		submitted = backend::stream_recv_submit(
			loop,
			&op.header,
			&op.backend,
			*handle.handle,
			buffer,
			&dispatch_read,
			owner,
			userdata
		);
	}
	else if (try_immediate)
	{
		submitted = submit_read_ready_or_wait(loop, owner, op, userdata);
	}
	else
	{
		submitted = backend::stream_read_submit(
			loop,
			&op.header,
			&op.backend,
			handle.watcher,
			*handle.handle,
			&dispatch_read,
			owner,
			userdata
		);
	}
	if (catch submitted)
	{
		reset_read_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	*handle.active_read = &op.header;
	return oref;
}

<*
 Submit one shared vectored (scatter-gather) stream read using caller-owned
 storage. The `vectors` slices are borrowed until the terminal callback and are
 not mutated (progress is tracked by an internal cursor). One `recvmsg` per
 syscall scatters received bytes across the slices in order.

 Shared internal plumbing: the public `tcp` wrappers pre-validate the loop,
 handle, vectors, callback and busy state, so they are not re-checked here.

 @param loop : "Loop that owns the read operation"
 @param handle : "Borrowed concrete handle state"
 @param owner : "Concrete stream handle delivered to the callback"
 @param vectors : "Caller-owned destination slices borrowed until callback"
 @param min_bytes : "Minimum total bytes required for successful terminal completion"
 @param op : "Read operation storage"
 @param native_readv : "Concrete non-blocking vectored read function"
 @param callback : "Erased terminal callback"
 @param userdata : "Opaque user pointer delivered to the callback"
 @param try_immediate : "Attempt bounded non-blocking progress before waiting"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
*>
fn Ref? submit_read_vectored(
	Loop* loop,
	HandleState handle,
	void* owner,
	char[][] vectors,
	sz min_bytes,
	ReadOp* op,
	NativeReadVFn native_readv,
	ReadCallback callback,
	void* userdata = null,
	bool try_immediate = false,
	FaultFromErrno result_fault = null
) @private
{
	op.buffer = { };
	op.min_bytes = min_bytes;
	op.filled = 0;
	op.vectors = vectors;
	op.vector_index = 0;
	op.vector_offset = 0;
	op.handle = handle;
	op.native_read = null;
	op.native_readv = native_readv;
	op.result_fault = result_fault;
	op.callback = callback;

	bool completion = vectors.len > 0 && result_fault != null && backend::stream_recvmsg_completion_enabled(loop);
	Ref? submitted;
	if (completion)
	{
		backend::msghdr_init_vectors(&op.msghdr, &op.scratch_iov, vectors, 0, 0);
		submitted = backend::stream_recvmsg_submit(
			loop,
			&op.header,
			&op.backend,
			*handle.handle,
			(ulong)(uptr)&op.msghdr,
			&dispatch_read,
			owner,
			userdata
		);
	}
	else if (try_immediate)
	{
		submitted = submit_read_ready_or_wait(loop, owner, op, userdata);
	}
	else
	{
		submitted = backend::stream_read_submit(
			loop,
			&op.header,
			&op.backend,
			handle.watcher,
			*handle.handle,
			&dispatch_read,
			owner,
			userdata
		);
	}
	if (catch submitted)
	{
		reset_read_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	*handle.active_read = &op.header;
	return oref;
}

<*
 Attempt bounded non-blocking read progress before waiting for readiness.

 @param loop : "Loop that provides the IO progress budget"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Read operation storage"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BUSY : "Header is already active"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
*>
fn Ref? submit_read_ready_or_wait(Loop* loop, void* owner, ReadOp* op, void* userdata) @local
{
	fault status;
	bool eof = false;
	if (op.vectors.len > 0)
	{
		advance_read_vectored(loop, op, &status, &eof);
	}
	else
	{
		advance_read(loop, op, &status, &eof);
	}
	if (status || eof || op.filled >= op.min_bytes)
	{
		if (eof) return queue_immediate_read_eof(loop, owner, op, userdata);
		return queue_immediate_read(loop, owner, op, userdata, status);
	}

	Ref? submitted = backend::stream_read_submit(
		loop,
		&op.header,
		&op.backend,
		op.handle.watcher,
		*op.handle.handle,
		&dispatch_read,
		owner,
		userdata
	);
	if (catch err = submitted)
	{
		if (op.filled > 0)
		{
			return queue_immediate_read(loop, owner, op, userdata, err);
		}
		return err~;
	}
	return submitted;
}

<*
 Queue an immediate read completion after `submit_read` already validated the
 loop, operation storage and active-read slot.

 @param loop : "Loop that owns the operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Read operation storage"
 @param userdata : "Opaque user pointer delivered to the callback"
 @param status : "Terminal status delivered through the ready queue"
 @return "Generation-checked reference for the queued read"
 @require !op.header.active() : "Read operation header must be reusable"
*>
fn Ref queue_immediate_read(Loop* loop, void* owner, ReadOp* op, void* userdata, fault status) @local
{
	op::init_header(&op.header, Kind.STREAM_READ, loop, &dispatch_read, owner, userdata);
	nova::queue_ready(loop, &op.header, status);
	return op.header.to_ref();
}

<*
 Queue an immediate EOF read completion without storing extra state in `ReadOp`.

 @param loop : "Loop that owns the operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Read operation storage"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the queued read"
 @require !op.header.active() : "Read operation header must be reusable"
*>
fn Ref queue_immediate_read_eof(Loop* loop, void* owner, ReadOp* op, void* userdata) @local
{
	op::init_header(&op.header, Kind.STREAM_READ, loop, &dispatch_read_eof, owner, userdata);
	nova::queue_ready(loop, &op.header, { });
	return op.header.to_ref();
}

<*
 Submit one shared stream write operation using caller-owned storage.

 Shared internal plumbing: the public `tcp`/`pipe` wrappers pre-validate the
 loop, handle, bytes, callback and busy state, so they are not re-checked here.

 @param loop : "Loop that owns the write operation"
 @param handle : "Borrowed concrete handle state"
 @param owner : "Concrete stream handle delivered to the callback"
 @param bytes : "Caller-owned source bytes borrowed until callback"
 @param op : "Write operation storage"
 @param try_immediate : "Attempt bounded non-blocking progress before waiting for readiness"
 @param native_write : "Concrete non-blocking write function"
 @param callback : "Erased terminal callback"
 @param userdata : "Opaque user pointer delivered to the callback"
 @param result_fault : "Maps a completion `-errno` to the typed fault, or null for readiness-only modules"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn Ref? submit_write(
	Loop* loop,
	HandleState handle,
	void* owner,
	char[] bytes,
	WriteOp* op,
	bool try_immediate,
	NativeWriteFn native_write,
	WriteCallback callback,
	void* userdata = null,
	FaultFromErrno result_fault = null
) @private
{
	op.bytes = bytes;
	op.written = 0;
	op.handle = handle;
	op.native_write = native_write;
	op.result_fault = result_fault;
	op.callback = callback;

	bool completion = bytes.len > 0 && result_fault != null && backend::stream_completion_write_enabled(loop);
	Ref? submitted;
	if (completion)
	{
		submitted = backend::stream_send_submit(
			loop,
			&op.header,
			&op.backend,
			*handle.handle,
			bytes,
			&dispatch_write,
			owner,
			userdata
		);
	}
	else if (try_immediate)
	{
		submitted = submit_write_ready_or_wait(loop, owner, op, userdata);
	}
	else
	{
		submitted = backend::stream_write_submit(
			loop,
			&op.header,
			&op.backend,
			handle.watcher,
			*handle.handle,
			&dispatch_write,
			owner,
			userdata
		);
	}

	if (catch submitted)
	{
		reset_write_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	*handle.active_write = &op.header;
	return oref;
}

<*
 Submit one shared vectored (scatter-gather) stream write using caller-owned
 storage. The `vectors` slices are borrowed until the terminal callback and are
 not mutated (progress is tracked by an internal cursor).

 @param loop : "Loop that owns the write operation"
 @param handle : "Borrowed concrete handle state"
 @param owner : "Concrete stream handle delivered to the callback"
 @param vectors : "Caller-owned source slices borrowed until callback"
 @param op : "Write operation storage"
 @param try_immediate : "Attempt bounded non-blocking progress before waiting"
 @param native_writev : "Concrete non-blocking vectored write function"
 @param callback : "Erased terminal callback"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "All vectors are empty (zero total bytes)"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn Ref? submit_write_vectored(
	Loop* loop,
	HandleState handle,
	void* owner,
	char[][] vectors,
	WriteOp* op,
	bool try_immediate,
	NativeWriteVFn native_writev,
	WriteCallback callback,
	void* userdata = null,
	FaultFromErrno result_fault = null
) @private
{
	bool has_data = false;
	foreach (v : vectors)
	{
		if (v.len)
		{
			has_data = true;
			break;
		}
	}
	if (!has_data) return nova::INVALID_STATE~;

	op.bytes = { };
	op.written = 0;
	op.vectors = vectors;
	op.vector_index = 0;
	op.vector_offset = 0;
	op.handle = handle;
	op.native_write = null;
	op.native_writev = native_writev;
	op.result_fault = result_fault;
	op.callback = callback;

	bool completion = result_fault != null && backend::stream_sendmsg_completion_enabled(loop);
	Ref? submitted;
	if (completion)
	{
		backend::msghdr_init_vectors(&op.msghdr, &op.scratch_iov, vectors, 0, 0);
		submitted = backend::stream_sendmsg_submit(
			loop,
			&op.header,
			&op.backend,
			*handle.handle,
			(ulong)(uptr)&op.msghdr,
			&dispatch_write,
			owner,
			userdata
		);
	}
	else if (try_immediate)
	{
		submitted = submit_write_ready_or_wait(loop, owner, op, userdata);
	}
	else
	{
		submitted = backend::stream_write_submit(
			loop,
			&op.header,
			&op.backend,
			handle.watcher,
			*handle.handle,
			&dispatch_write,
			owner,
			userdata
		);
	}

	if (catch submitted)
	{
		reset_write_fields(op);
		return submitted;
	}

	Ref oref = submitted;
	*handle.active_write = &op.header;
	return oref;
}

<*
 Attempt bounded non-blocking write progress before waiting for readiness.

 @param loop : "Loop that provides the IO progress budget"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Write operation storage"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::BUSY : "Header is already active"
 @return ? nova::BACKEND_FAILED : "Backend registration failed"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event or timer capacity"
*>
fn Ref? submit_write_ready_or_wait(Loop* loop, void* owner, WriteOp* op, void* userdata) @local
{
	fault status = op.vectors.len > 0 ? advance_write_vectored(loop, op) : advance_write(loop, op);
	if (status || write_done(op))
	{
		return queue_immediate_write(loop, owner, op, userdata, status);
	}

	Ref? submitted = backend::stream_write_submit(
		loop,
		&op.header,
		&op.backend,
		op.handle.watcher,
		*op.handle.handle,
		&dispatch_write,
		owner,
		userdata
	);
	if (catch err = submitted)
	{
		if (op.written > 0)
		{
			return queue_immediate_write(loop, owner, op, userdata, err);
		}
		return err~;
	}
	return submitted;
}

<*
 Queue an immediate write completion after `submit_write` already validated the
 loop, operation storage and active-write slot.

 @param loop : "Loop that owns the operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Write operation storage"
 @param userdata : "Opaque user pointer delivered to the callback"
 @param status : "Terminal status delivered through the ready queue"
 @return "Generation-checked reference for the queued write"
 @require !op.header.active() : "Write operation header must be reusable"
*>
fn Ref queue_immediate_write(Loop* loop, void* owner, WriteOp* op, void* userdata, fault status) @local
{
	op::init_header(&op.header, Kind.STREAM_WRITE, loop, &dispatch_write, owner, userdata);
	nova::queue_ready(loop, &op.header, status);
	return op.header.to_ref();
}

<*
 Dispatch a stream read completion through the erased callback.

 @param loop : "Loop dispatching the read operation"
 @param raw : "Read operation storage pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_read(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	ReadOp* op         = (ReadOp*)raw;
	void* owner        = header.owner;

	if (header.terminal_status)
	{
		complete_read(loop, owner, op, header.terminal_status, op.filled, false);
		return;
	}

	if (backend::op_completion(header))
	{
		if (op.vectors.len > 0)
		{
			dispatch_read_completion_vectored(loop, owner, op);
		}
		else
		{
			dispatch_read_completion(loop, owner, op);
		}
		return;
	}

	fault status;
	bool blocked = false;
	bool eof     = false;
	if (op.vectors.len > 0)
	{
		advance_read_vectored(loop, op, &status, &eof, &blocked);
	}
	else
	{
		advance_read(loop, op, &status, &eof, &blocked);
	}

	if (status || eof || op.filled >= op.min_bytes)
	{
		complete_read(loop, owner, op, status, op.filled, eof);
		return;
	}

	if (blocked) backend::stream_ready_consumed(header, nova::READY_READABLE);
	if (catch rearm_err = backend::stream_read_rearm(loop, header))
	{
		complete_read(loop, owner, op, rearm_err, op.filled, false);
	}
}

<*
 Deliver an io_uring completion-mode read result (`RECV`).

 The CQE result is `bytes` (negative `-errno`, zero EOF, or a positive count). A
 short read below `min_bytes` re-submits a `RECV` for the remaining slice; the
 caller buffer stays valid across the re-submit.

 @param loop : "Loop dispatching the read operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Read operation storage"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
*>
fn void dispatch_read_completion(Loop* loop, void* owner, ReadOp* op) @local
{
	sz res = backend::op_completion_result(&op.header);
	if (res < 0)
	{
		fault status = op.result_fault != null ? op.result_fault((int)-res) : nova::BACKEND_FAILED;
		complete_read(loop, owner, op, status, op.filled, false);
		return;
	}
	if (res == 0)
	{
		complete_read(loop, owner, op, { }, op.filled, true);
		return;
	}

	op.filled += res;
	if (op.filled >= op.min_bytes || op.filled >= op.buffer.len)
	{
		complete_read(loop, owner, op, { }, op.filled, false);
		return;
	}

	char[] remaining = op.buffer[op.filled:op.buffer.len - op.filled];
	if (catch err = backend::stream_recv_resubmit(loop, &op.header, remaining))
	{
		complete_read(loop, owner, op, err, op.filled, false);
	}
}

<*
 Deliver an io_uring completion-mode vectored read result (`RECVMSG`).

 The CQE result is the scattered byte count (negative `-errno`, zero EOF, or a
 positive count). A short read below `min_bytes` advances the segment cursor and
 re-submits a `RECVMSG` for the remaining segments; the caller vectors stay valid
 across the re-submit.

 @param loop : "Loop dispatching the read operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Read operation storage"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
*>
fn void dispatch_read_completion_vectored(Loop* loop, void* owner, ReadOp* op) @local
{
	sz res = backend::op_completion_result(&op.header);
	if (res < 0)
	{
		fault status = op.result_fault != null ? op.result_fault((int)-res) : nova::BACKEND_FAILED;
		complete_read(loop, owner, op, status, op.filled, false);
		return;
	}
	if (res == 0)
	{
		complete_read(loop, owner, op, { }, op.filled, true);
		return;
	}

	advance_read_cursor(op, res);
	op.filled += res;
	if (op.filled >= op.min_bytes || op.vector_index >= op.vectors.len)
	{
		complete_read(loop, owner, op, { }, op.filled, false);
		return;
	}

	backend::msghdr_init_vectors(&op.msghdr, &op.scratch_iov, op.vectors, op.vector_index, op.vector_offset);
	if (catch err = backend::stream_recvmsg_resubmit(loop, &op.header, (ulong)(uptr)&op.msghdr))
	{
		complete_read(loop, owner, op, err, op.filled, false);
	}
}

<*
 Dispatch a read that already observed EOF during immediate submission.

 @param loop : "Loop dispatching the read operation"
 @param raw : "Read operation storage pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_read_eof(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	ReadOp* op         = (ReadOp*)raw;
	void* owner        = header.owner;

	if (header.terminal_status)
	{
		complete_read(loop, owner, op, header.terminal_status, op.filled, false);
		return;
	}

	complete_read(loop, owner, op, { }, op.filled, true);
}

<*
 Advance a stream read operation against its non-blocking native handle.

 @param loop : "Loop that provides the IO progress budget"
 @param op : "Read operation storage"
 @param status : "Set to the terminal fault, or success"
 @param eof : "Set when the handle reaches EOF"
 @param [out] blocked : "Optional output set when the handle would block"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
 @require status != null : "Status output pointer must not be null"
 @require eof != null : "EOF output pointer must not be null"
*>
fn void advance_read(Loop* loop, ReadOp* op, fault* status, bool* eof, bool* blocked = null) @local
{
	*status = { };
	bool blocked_value = false;
	if (blocked) *blocked = false;
	*eof = false;
	sz attempts         = 0;
	sz budget           = loop.options.io_progress_budget;
	NativeHandle handle = *op.handle.handle;

	while (!(*status) && !blocked_value && !(*eof) && op.filled < op.min_bytes && op.filled < op.buffer.len
		&& (!budget || attempts < budget))
	{
		char[] remaining = op.buffer[op.filled:op.buffer.len - op.filled];
		sz? read_result  = op.native_read(handle, remaining);
		fault err        = @catch(read_result);
		if (err == io::WOULD_BLOCK)
		{
			blocked_value = true;
			if (blocked) *blocked = true;
			continue;
		}
		if (err)
		{
			*status = err;
			continue;
		}

		if (try bytes = read_result)
		{
			if (bytes > 0)
			{
				op.filled += bytes;
				attempts++;
				if (op.filled >= op.min_bytes || op.filled >= op.buffer.len) return;
				continue;
			}
		}
		*eof = true;
	}
}

<*
 Move the vectored-read cursor forward by `n` bytes already filled by the OS.
 Does not mutate the caller's `vectors` slices (cursor-only bookkeeping).
*>
fn void advance_read_cursor(ReadOp* op, sz n) @local
{
	usz remaining = (usz)n;
	while (remaining > 0 && op.vector_index < op.vectors.len)
	{
		usz avail = op.vectors[op.vector_index].len - op.vector_offset;
		usz take  = remaining < avail ? remaining : avail;
		op.vector_offset += take;
		remaining -= take;
		if (op.vector_offset >= op.vectors[op.vector_index].len)
		{
			op.vector_index++;
			op.vector_offset = 0;
		}
	}
}

<*
 Advance a vectored stream read against its non-blocking native handle.

 Mirrors `advance_read` but over `op.vectors`, resuming from
 `op.vector_index`/`op.vector_offset`. One `recvmsg` scatters into the ≤N free
 segments per call. Empty or fully-filled leading vectors are skipped.

 @param loop : "Loop that provides the IO progress budget"
 @param op : "Read operation storage"
 @param status : "Set to the terminal fault, or success"
 @param eof : "Set when the handle reaches EOF"
 @param [out] blocked : "Optional output set when the handle would block"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
 @require status != null : "Status output pointer must not be null"
 @require eof != null : "EOF output pointer must not be null"
*>
fn void advance_read_vectored(Loop* loop, ReadOp* op, fault* status, bool* eof, bool* blocked = null) @local
{
	*status = { };
	bool blocked_value = false;
	if (blocked) *blocked = false;
	*eof = false;
	sz attempts         = 0;
	sz budget           = loop.options.io_progress_budget;
	NativeHandle handle = *op.handle.handle;

	while (!(*status) && !blocked_value && !(*eof) && op.filled < op.min_bytes && (!budget || attempts < budget))
	{
		while (op.vector_index < op.vectors.len && op.vector_offset >= op.vectors[op.vector_index].len)
		{
			op.vector_index++;
			op.vector_offset = 0;
		}
		if (op.vector_index >= op.vectors.len) return;

		char[][] remaining = op.vectors[op.vector_index:op.vectors.len - op.vector_index];
		sz? read_result    = op.native_readv(handle, remaining, op.vector_offset);
		fault err          = @catch(read_result);
		if (err == io::WOULD_BLOCK)
		{
			blocked_value = true;
			if (blocked) *blocked = true;
			continue;
		}
		if (err)
		{
			*status = err;
			continue;
		}

		if (try bytes = read_result)
		{
			if (bytes > 0)
			{
				advance_read_cursor(op, bytes);
				op.filled += bytes;
				attempts++;
				if (op.filled >= op.min_bytes) return;
				continue;
			}
		}
		*eof = true;
	}
}

<*
 Complete a read operation with a terminal semantic result.

 @param loop : "Loop that owns the operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Read operation storage"
 @param status : "Terminal status"
 @param bytes : "Read byte count"
 @param eof : "Whether the peer reached EOF"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Read operation pointer must not be null"
*>
fn void complete_read(Loop* loop, void* owner, ReadOp* op, fault status, sz bytes, bool eof) @local
{
	ReadCallback callback = op.callback;
	void* userdata        = op.header.userdata;
	char[] buffer         = op.buffer;

	timer::deadline_done(loop, &op.header);
	ReadResult result;
	result.error.status = status;
	result.buffer = buffer;
	result.bytes = bytes;
	result.eof = eof;
	reset_read(op);
	callback(loop, owner, op, &result, userdata);
}

<*
 Release handle and operation state before a terminal read callback starts.

 @param op : "Read operation storage"
 @require op != null : "Read operation pointer must not be null"
*>
fn void reset_read(ReadOp* op) @local
{
	if (op.handle.active_read && *op.handle.active_read == &op.header) *op.handle.active_read = null;
	reset_read_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear read-specific fields after a read operation leaves the runtime.

 @param op : "Read operation storage to clear"
 @require op != null : "Read operation pointer must not be null"
*>
fn void reset_read_fields(ReadOp* op) @local
{
	op.buffer = { };
	op.min_bytes = 0;
	op.filled = 0;
	op.vectors = { };
	op.vector_index = 0;
	op.vector_offset = 0;
	op.handle = { };
	op.native_read = null;
	op.native_readv = null;
	op.result_fault = null;
	op.callback = null;
}

<*
 Advance a stream write operation against its non-blocking native handle.

 @param loop : "Loop that provides the IO progress budget"
 @param op : "Write operation storage"
 @param [out] blocked : "Optional output set when the handle would block"
 @return "Terminal write status, or success"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn fault advance_write(Loop* loop, WriteOp* op, bool* blocked = null) @local
{
	fault status;
	bool blocked_value = false;
	if (blocked) *blocked = false;
	sz attempts         = 0;
	sz budget           = loop.options.io_progress_budget;
	NativeHandle handle = *op.handle.handle;

	while (!status && !blocked_value && op.written < op.bytes.len && (!budget || attempts < budget))
	{
		char[] remaining = op.bytes[op.written:op.bytes.len - op.written];
		sz? write_result = op.native_write(handle, remaining);
		fault err        = @catch(write_result);
		if (err == io::WOULD_BLOCK)
		{
			blocked_value = true;
			if (blocked) *blocked = true;
			continue;
		}
		if (err)
		{
			status = err;
			continue;
		}

		if (try bytes = write_result)
		{
			if (bytes > 0)
			{
				op.written += bytes;
				attempts++;
				if (op.written >= op.bytes.len) return status;
				continue;
			}
		}
		blocked_value = true;
		if (blocked) *blocked = true;
	}

	return status;
}

<*
 Move the vectored-write cursor forward by `n` bytes already accepted by the OS.
 Does not mutate the caller's `vectors` slices (cursor-only bookkeeping).
*>
fn void advance_vector_cursor(WriteOp* op, sz n) @local
{
	usz remaining = (usz)n;
	while (remaining > 0 && op.vector_index < op.vectors.len)
	{
		usz avail = op.vectors[op.vector_index].len - op.vector_offset;
		usz take  = remaining < avail ? remaining : avail;
		op.vector_offset += take;
		remaining -= take;
		if (op.vector_offset >= op.vectors[op.vector_index].len)
		{
			op.vector_index++;
			op.vector_offset = 0;
		}
	}
}

<*
 Advance a vectored stream write against its non-blocking native handle.

 Mirrors `advance_write` but over `op.vectors`, resuming from
 `op.vector_index`/`op.vector_offset` after partial writes. Empty or
 fully-consumed leading vectors are skipped.

 @param loop : "Loop that provides the IO progress budget"
 @param op : "Write operation storage"
 @param [out] blocked : "Optional output set when the handle would block"
 @return "Terminal write status, or success"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn fault advance_write_vectored(Loop* loop, WriteOp* op, bool* blocked = null) @local
{
	fault status;
	bool blocked_value = false;
	if (blocked) *blocked = false;
	sz attempts         = 0;
	sz budget           = loop.options.io_progress_budget;
	NativeHandle handle = *op.handle.handle;

	while (!status && !blocked_value && (!budget || attempts < budget))
	{
		while (op.vector_index < op.vectors.len && op.vector_offset >= op.vectors[op.vector_index].len)
		{
			op.vector_index++;
			op.vector_offset = 0;
		}
		if (op.vector_index >= op.vectors.len) return status;

		char[][] remaining = op.vectors[op.vector_index:op.vectors.len - op.vector_index];
		sz? write_result   = op.native_writev(handle, remaining, op.vector_offset);
		fault err          = @catch(write_result);
		if (err == io::WOULD_BLOCK)
		{
			blocked_value = true;
			if (blocked) *blocked = true;
			continue;
		}
		if (err)
		{
			status = err;
			continue;
		}

		if (try bytes = write_result)
		{
			if (bytes > 0)
			{
				advance_vector_cursor(op, bytes);
				op.written += bytes;
				attempts++;
				if (op.vector_index >= op.vectors.len) return status;
				continue;
			}
		}
		blocked_value = true;
		if (blocked) *blocked = true;
	}

	return status;
}

<*
 Dispatch a stream write completion through the erased callback.

 @param loop : "Loop dispatching the write operation"
 @param raw : "Write operation storage pointer"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Raw operation pointer must not be null"
*>
fn void dispatch_write(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	WriteOp* op        = (WriteOp*)raw;
	void* owner        = header.owner;

	if (header.terminal_status)
	{
		complete_write(loop, owner, op, header.terminal_status);
		return;
	}

	if (backend::op_completion(header))
	{
		if (op.vectors.len > 0)
		{
			dispatch_write_completion_vectored(loop, owner, op);
		}
		else
		{
			dispatch_write_completion(loop, owner, op);
		}
		return;
	}

	bool blocked = false;
	fault status = op.vectors.len > 0 ? advance_write_vectored(loop, op, &blocked) : advance_write(loop, op, &blocked);
	if (status || write_done(op))
	{
		complete_write(loop, owner, op, status);
		return;
	}

	if (blocked) backend::stream_ready_consumed(header, nova::READY_WRITABLE);
	if (catch rearm_err = backend::stream_write_rearm(loop, header))
	{
		complete_write(loop, owner, op, rearm_err);
	}
}

<*
 Deliver an io_uring completion-mode write result (`SEND`).

 The CQE result is `bytes` accepted (negative `-errno`, or a count). A partial
 send re-submits a `SEND` for the remaining slice; the caller bytes stay valid
 across the re-submit. A zero-byte send completes with the bytes accepted so far.

 @param loop : "Loop dispatching the write operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Write operation storage"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn void dispatch_write_completion(Loop* loop, void* owner, WriteOp* op) @local
{
	sz res = backend::op_completion_result(&op.header);
	if (res < 0)
	{
		fault status = op.result_fault != null ? op.result_fault((int)-res) : nova::BACKEND_FAILED;
		complete_write(loop, owner, op, status);
		return;
	}

	op.written += res;
	if (res == 0 || op.written >= op.bytes.len)
	{
		complete_write(loop, owner, op, { });
		return;
	}

	char[] remaining = op.bytes[op.written:op.bytes.len - op.written];
	if (catch err = backend::stream_send_resubmit(loop, &op.header, remaining))
	{
		complete_write(loop, owner, op, err);
	}
}

<*
 Deliver an io_uring completion-mode vectored write result (`SENDMSG`).

 The CQE result is the gathered byte count (negative `-errno`, or a count). A
 partial write advances the segment cursor and re-submits a `SENDMSG` for the
 remaining segments; the caller vectors stay valid across the re-submit.

 @param loop : "Loop dispatching the write operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Write operation storage"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn void dispatch_write_completion_vectored(Loop* loop, void* owner, WriteOp* op) @local
{
	sz res = backend::op_completion_result(&op.header);
	if (res < 0)
	{
		fault status = op.result_fault != null ? op.result_fault((int)-res) : nova::BACKEND_FAILED;
		complete_write(loop, owner, op, status);
		return;
	}

	advance_vector_cursor(op, res);
	op.written += res;
	if (res == 0 || op.vector_index >= op.vectors.len)
	{
		complete_write(loop, owner, op, { });
		return;
	}

	backend::msghdr_init_vectors(&op.msghdr, &op.scratch_iov, op.vectors, op.vector_index, op.vector_offset);
	if (catch err = backend::stream_sendmsg_resubmit(loop, &op.header, (ulong)(uptr)&op.msghdr))
	{
		complete_write(loop, owner, op, err);
	}
}

<*
 Complete a write operation with a terminal semantic result.

 @param loop : "Loop that owns the operation"
 @param owner : "Concrete stream handle delivered to the callback"
 @param op : "Write operation storage"
 @param status : "Terminal status"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Write operation pointer must not be null"
*>
fn void complete_write(Loop* loop, void* owner, WriteOp* op, fault status) @local
{
	WriteCallback callback = op.callback;
	void* userdata         = op.header.userdata;
	sz written             = op.written;

	timer::deadline_done(loop, &op.header);
	WriteResult result;
	result.error.status = status;
	result.bytes = written;
	reset_write(op);
	callback(loop, owner, op, &result, userdata);
}

<*
 Release handle and operation state before a terminal write callback starts.

 @param op : "Write operation storage"
 @require op != null : "Write operation pointer must not be null"
*>
fn void reset_write(WriteOp* op) @local
{
	if (op.handle.active_write && *op.handle.active_write == &op.header) *op.handle.active_write = null;
	reset_write_fields(op);
	op::reset_header(&op.header);
}

<*
 Clear write-specific fields after a write operation leaves the runtime.

 @param op : "Write operation storage to clear"
 @require op != null : "Write operation pointer must not be null"
*>
fn void reset_write_fields(WriteOp* op) @local
{
	op.bytes = { };
	op.written = 0;
	op.vectors = { };
	op.vector_index = 0;
	op.vector_offset = 0;
	op.handle = { };
	op.native_write = null;
	op.native_writev = null;
	op.result_fault = null;
	op.callback = null;
}
