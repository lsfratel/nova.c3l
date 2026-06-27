module nova::framed;

import std::core::mem;
import std::core::mem::alloc;

import nova @norecurse, nova::net, nova::net::tcp;

<*
 Called when new bytes are available in the input buffer. The application frames
 messages with `peek`/`consume` and builds replies with `reserve`/`commit`, then
 returns; the layer flushes pending output and re-arms reading.
*>
alias DataCallback = fn void(Loop* loop, FramedConn* conn, void* userdata);

<*
 Called when a `read_into` body transfer has filled its destination in full.
*>
alias BodyCallback = fn void(Loop* loop, FramedConn* conn, void* userdata);

<*
 Called on peer EOF (`status` empty) or a read/write error (`status` set).
*>
alias ErrorCallback = fn void(Loop* loop, FramedConn* conn, fault status, void* userdata);

<*
 Fixed-capacity linear byte buffer with compaction.

 Live data always occupies a single contiguous run `[start, start+len)`, so any
 prefix can be viewed contiguously with `peek` (unlike a ring, which may wrap).
 Reads land in the contiguous `tail`; `compact` slides the live run back to the
 front to reclaim space consumed from the head. All storage is reserved in `init`;
 no method allocates.
*>
struct FrameBuffer
{
	char[] storage;
	usz start;
	usz count;
}

<*
 Caller-owned framed connection over an already-open `tcp::Stream`.

 A pair of linear buffers turns the raw proactor read/write model into a
 message-framed one. Incoming bytes accumulate contiguously in `input` (framed
 with `peek`/`consume`); responses are built in place in `output` with
 `reserve`/`commit` and flushed coalesced with one `tcp::write`. A `read_into`
 escape hatch streams a large body straight into caller storage (e.g. a slab
 item) without buffering it. All storage is reserved in `init`, so the hot path
 never allocates. Not used by the core; opt in by wrapping a stream after accept.

 The driver protocol: a completed read commits into `input` and calls `on_data`;
 when `on_data` returns, pending output is flushed and a read re-armed; a
 completed write drains the sent bytes from `output` and, if input remains,
 re-invokes `on_data` to drain the frames that did not fit before the flush.
*>
struct FramedConn
{
	Allocator allocator;
	tcp::Stream* stream;
	FrameBuffer input;
	FrameBuffer output;
	tcp::ReadOp read_op;
	tcp::WriteOp write_op;
	usz read_high;
	DataCallback on_data;
	ErrorCallback on_error;
	void* userdata;
	char[] body_dst;
	usz body_total;
	usz body_filled;
	BodyCallback on_body;
	bool reading;
	bool writing;
	bool read_paused;
	bool in_body;
	bool closed;
	bool initialized;
}

<*
 Configuration for `FramedConn.init`. Zero `read_high` means "the input
 capacity" (read until the input buffer is full).
*>
struct Config
{
	usz input_capacity;
	usz output_capacity;
	usz read_high;
	DataCallback on_data;
	ErrorCallback on_error;
	void* userdata;
}

<*
 Reserve `capacity` bytes for the buffer.

 @require !self.storage.len : "buffer must be uninitialized"
 @require capacity > 0 : "capacity must be positive"
 @return ? mem::OUT_OF_MEMORY : "backing allocator could not reserve storage"
*>
fn void? FrameBuffer.init(&self, usz capacity, Allocator allocator = mem)
{
	self.storage = alloc::new_array_try(allocator, char, (sz)capacity)!;
	self.start = 0;
	self.count = 0;
}

<*
 Release the buffer's storage with the same allocator passed to `init`. Idempotent.
*>
fn void FrameBuffer.destroy(&self, Allocator allocator)
{
	if (!self.storage.len) return;
	alloc::free(allocator, self.storage.ptr);
	self.storage = { };
	self.start = 0;
	self.count = 0;
}

<*
 Total reserved capacity in bytes.
 @return "Buffer capacity"
*>
fn usz FrameBuffer.capacity(&self) => self.storage.len;

<*
 Number of live (unconsumed) bytes.
 @return "Live byte count"
*>
fn usz FrameBuffer.len(&self) => self.count;

<*
 Contiguous view of the first `n` live bytes, or an empty slice when fewer than
 `n` are buffered (a normal "need more data" no-op, not a fault).
 @require n > 0 : "peek length must be positive"
 @return "Contiguous slice of length n, or empty"
*>
fn char[] FrameBuffer.peek(&self, usz n)
{
	if (self.count < n) return { };
	return self.storage[self.start:n];
}

<*
 Drop `n` bytes from the front of the live data. Resets to the buffer start once
 fully drained, avoiding needless compaction.
 @require n <= self.count : "cannot consume more than is buffered"
*>
fn void FrameBuffer.consume(&self, usz n)
{
	self.start += n;
	self.count -= n;
	if (self.count == 0) self.start = 0;
}

<*
 Contiguous free space at the end of the buffer, for reads or response building.
 @return "Writable tail slice (possibly empty)"
*>
fn char[] FrameBuffer.tail(&self)
{
	usz used = self.start + self.count;
	return self.storage[used:self.storage.len - used];
}

<*
 Free byte count contiguous at the tail.
 @return "Contiguous trailing free byte count"
*>
fn usz FrameBuffer.tail_space(&self) => self.storage.len - (self.start + self.count);

<*
 Mark `n` bytes written into `tail` as live.
 @require self.start + self.count + n <= self.storage.len : "commit must not exceed capacity"
*>
fn void FrameBuffer.commit(&self, usz n)
{
	self.count += n;
}

<*
 Slide the live run back to the buffer start to reclaim head space.
*>
fn void FrameBuffer.compact(&self)
{
	if (self.start == 0 || self.count == 0)
	{
		self.start = 0;
		return;
	}
	mem::move(self.storage.ptr, &self.storage[self.start], (sz)self.count);
	self.start = 0;
}

<*
 Drop all live data, keeping the reserved storage.
*>
fn void FrameBuffer.clear(&self)
{
	self.start = 0;
	self.count = 0;
}

<*
 Initialize a framed connection over an open stream.

 @require !self.initialized : "double init would leak the buffers"
 @require stream != null : "stream must not be null"
 @require config.input_capacity > 0 && config.output_capacity > 0 : "capacities must be positive"
 @require config.on_data != null : "a data callback is required"
 @require config.on_error != null : "an error callback is required"
 @return ? mem::OUT_OF_MEMORY : "backing allocator could not reserve the buffers"
 @ensure self.initialized
*>
fn void? FramedConn.init(&self, tcp::Stream* stream, Config config, Allocator allocator = mem)
{
	self.allocator = allocator;
	self.stream = stream;
	self.input.init(config.input_capacity, allocator)!;
	if (catch err = self.output.init(config.output_capacity, allocator))
	{
		self.input.destroy(allocator);
		return err~;
	}
	self.read_high = config.read_high ? config.read_high : config.input_capacity;
	if (self.read_high > config.input_capacity) self.read_high = config.input_capacity;
	self.on_data = config.on_data;
	self.on_error = config.on_error;
	self.userdata = config.userdata;
	self.initialized = true;
}

<*
 Release the buffers. Does not close the caller-owned stream.
 @ensure !self.initialized
*>
fn void FramedConn.destroy(&self)
{
	if (!self.initialized) return;
	self.input.destroy(self.allocator);
	self.output.destroy(self.allocator);
	self.initialized = false;
}

<*
 Clear all runtime state for reuse on a new connection, keeping the reserved
 buffers (zero-alloc connection pooling: `init` once, `reset` + `start` per accept).
 @require self.initialized
*>
fn void FramedConn.reset(&self)
{
	self.input.clear();
	self.output.clear();
	self.reading = false;
	self.writing = false;
	self.read_paused = false;
	self.in_body = false;
	self.closed = false;
	self.body_dst = { };
	self.body_total = 0;
	self.body_filled = 0;
	self.on_body = null;
}

<*
 Bytes currently buffered and available to frame.
 @return "Input byte count"
*>
fn usz FramedConn.available(&self) => self.input.len();

<*
 Bytes queued in the output buffer but not yet handed to a write.
 @return "Pending output byte count"
*>
fn usz FramedConn.output_pending(&self) => self.output.len();

<*
 Mark the connection closed so the driver issues no further I/O on it. The caller
 still owns the stream (close it separately). `reset` clears this for reuse.
*>
fn void FramedConn.mark_closed(&self)
{
	self.closed = true;
}

<*
 Reserved input capacity. A frame larger than this can never be fully buffered;
 stream its body with `read_into`.
 @return "Input buffer capacity"
*>
fn usz FramedConn.input_capacity(&self) => self.input.capacity();

<*
 Contiguous view of the first `n` input bytes, or empty when fewer are buffered.
 @require n > 0 : "peek length must be positive"
 @return "Contiguous slice of length n, or empty"
*>
fn char[] FramedConn.peek(&self, usz n) => self.input.peek(n);

<*
 Drop `n` input bytes after framing them.
 @require n <= self.input.len() : "cannot consume more than is buffered"
*>
fn void FramedConn.consume(&self, usz n) => self.input.consume(n);

<*
 Reserve a contiguous output region of at least `min` bytes to build a response
 in place, or an empty slice when the output lacks room now (the caller should
 `flush` and resume on the next cycle). Follow a fill with `commit`.

 @require min > 0 : "reserve length must be positive"
 @require min <= self.output.capacity() : "min exceeds output capacity (config error)"
 @return "Contiguous writable region of length >= min, or empty"
*>
fn char[] FramedConn.reserve(&self, usz min)
{
	if (self.output.tail_space() < min) return { };
	return self.output.tail();
}

<*
 Mark `n` bytes built into a `reserve` region as queued output.
 @require self.output.tail_space() >= n : "commit must not exceed reserved space"
*>
fn void FramedConn.commit(&self, usz n) => self.output.commit(n);

<*
 Begin reading from the stream into the input buffer.
 @require self.initialized
*>
fn void? FramedConn.start(&self, Loop* loop) => self.arm_read(loop);

<*
 Re-arm reading after the application drained the input below the high watermark
 from outside the data callback (manual backpressure release).
 @require self.initialized
*>
fn void? FramedConn.resume_read(&self, Loop* loop)
{
	if (self.read_paused) self.arm_read(loop)!;
}

<*
 Submit a coalesced write of the queued output if there is data and no write is
 already in flight. The output buffer is contiguous and always written in full,
 so a single `tcp::write` suffices.
 @require self.initialized
*>
fn void? FramedConn.flush(&self, Loop* loop)
{
	if (self.writing || self.output.len() == 0 || self.closed) return;
	tcp::write(loop, self.stream, self.output.peek(self.output.len()), &self.write_op, { }, &on_framed_write, self)!;
	self.writing = true;
}

<*
 Stream the next `total` bytes straight into `dst` (e.g. a slab item), bypassing
 the input buffer. Any bytes already buffered are copied into `dst` first and
 consumed; the remainder is read directly. Framing is suspended until the body
 completes, then `callback` fires and framing resumes. Call from inside `on_data`
 after a header indicates a body larger than what the input buffer can hold.

 Use it only for a body that is not already fully buffered (the large-body case);
 a fully-buffered payload should be read with `peek`/`consume` instead.

 @require self.initialized
 @require !self.in_body : "a body transfer is already in progress"
 @require total > self.available() : "read_into is for bodies larger than what is buffered"
 @require dst.len >= total : "destination must hold the whole body"
 @return ? nova::INVALID_STATE : "stream not ready"
 @return ? nova::NOT_OWNER : "current thread does not own the loop"
 @return ? nova::BUSY : "a read is already active"
*>
fn void? FramedConn.read_into(&self, Loop* loop, char[] dst, usz total, BodyCallback callback)
{
	if (self.closed) return;
	self.body_dst = dst;
	self.body_total = total;
	self.on_body = callback;

	usz avail = self.input.len();
	usz take  = avail < total ? avail : total;
	if (take > 0)
	{
		mem::copy(dst.ptr, self.input.peek(take).ptr, (sz)take);
		self.input.consume(take);
	}
	self.body_filled = take;
	self.in_body = true;
	if (catch err = arm_body_read(self, loop))
	{
		self.in_body = false;
		return err~;
	}
}

<*
 Arm a read that fills the contiguous tail of the input buffer (normal framing).
 Compacts first when the tail is exhausted but head space is reclaimable.
*>
fn void? FramedConn.arm_read(&self, Loop* loop)
{
	if (self.closed || self.reading || self.writing || self.in_body) return;
	if (self.input.len() >= self.read_high)
	{
		self.read_paused = true;
		return;
	}
	if (self.input.tail_space() == 0) self.input.compact();
	if (self.input.tail_space() == 0)
	{
		self.read_paused = true;
		return;
	}
	self.read_paused = false;
	tcp::read(loop, self.stream, self.input.tail(), &self.read_op, { }, &on_framed_read, self)!;
	self.reading = true;
}

<*
 Arm the direct read of a body's remaining bytes into the caller destination.
*>
fn void? arm_body_read(FramedConn* self, Loop* loop) @local
{
	usz remaining = self.body_total - self.body_filled;
	char[] dst    = self.body_dst[self.body_filled:remaining];
	tcp::read(loop, self.stream, dst, &self.read_op, { .min_bytes = (sz)remaining }, &on_framed_read, self)!;
	self.reading = true;
}

<*
 Deliver `on_data`, then flush pending output or re-arm reading unless the
 callback started a body transfer.
*>
fn void deliver_data(FramedConn* self, Loop* loop) @local
{
	self.on_data(loop, self, self.userdata);
	if (self.in_body || self.closed) return;
	post_process(self, loop);
}

<*
 After `on_data` (or a completed body): flush queued output if any, otherwise
 re-arm reading. The flush completion drives further processing.
*>
fn void post_process(FramedConn* self, Loop* loop) @local
{
	if (self.closed) return;
	if (self.output.len() > 0)
	{
		if (catch err = self.flush(loop)) fail(self, loop, err);
		return;
	}
	if (catch err = self.arm_read(loop)) fail(self, loop, err);
}

<*
 Mark the connection closed and report a terminal fault once.
*>
fn void fail(FramedConn* self, Loop* loop, fault status)
{
	if (self.closed) return;
	self.closed = true;
	self.on_error(loop, self, status, self.userdata);
}

<*
 Finish a body transfer: clear body state, deliver `on_body`, resume framing.
*>
fn void finish_body(FramedConn* self, Loop* loop) @local
{
	BodyCallback callback = self.on_body;
	self.in_body = false;
	self.body_dst = { };
	self.body_total = 0;
	self.body_filled = 0;
	self.on_body = null;

	callback(loop, self, self.userdata);
	if (self.closed) return;
	if (self.input.len() > 0)
	{
		deliver_data(self, loop);
		return;
	}
	post_process(self, loop);
}

<*
 Read completion: route to the body accumulator while a `read_into` is active,
 otherwise commit into the input buffer and deliver `on_data`.

 @param loop : "Loop dispatching the read"
 @param result : "Read result (bytes, eof, error)"
 @param ud : "The owning FramedConn"
*>
fn void on_framed_read(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* ud) @local
{
	(void)stream;
	(void)op;
	FramedConn* self = (FramedConn*)ud;
	self.reading = false;

	if (result.error.status || result.eof)
	{
		fail(self, loop, result.error.status);
		return;
	}

	if (self.in_body)
	{
		self.body_filled += (usz)result.bytes;
		if (self.body_filled >= self.body_total)
		{
			finish_body(self, loop);
			return;
		}
		if (catch err = arm_body_read(self, loop)) fail(self, loop, err);
		return;
	}

	self.input.commit((usz)result.bytes);
	deliver_data(self, loop);
}

<*
 Write completion: drop the bytes just sent, then flush any output committed
 meanwhile, continue draining buffered frames, or re-arm reading.

 `tcp::write` completes only when the whole submitted slice was sent, so
 `result.bytes` equals the flushed length; consuming exactly that preserves any
 bytes appended after the flush was submitted (defends manual/server-push use).

 @param loop : "Loop dispatching the write"
 @param result : "Write result (bytes, error)"
 @param ud : "The owning FramedConn"
*>
fn void on_framed_write(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* ud) @local
{
	(void)stream;
	(void)op;
	FramedConn* self = (FramedConn*)ud;
	self.writing = false;

	if (result.error.status)
	{
		fail(self, loop, result.error.status);
		return;
	}

	self.output.consume((usz)result.bytes);
	if (self.closed) return;
	if (self.output.len() > 0)
	{
		if (catch err = self.flush(loop)) fail(self, loop, err);
		return;
	}
	if (self.input.len() > 0)
	{
		deliver_data(self, loop);
		return;
	}
	if (catch err = self.arm_read(loop)) fail(self, loop, err);
}
