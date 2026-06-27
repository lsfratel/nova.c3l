module nova::buffered;

import std::core::mem;
import std::core::mem::alloc;

import nova @norecurse, nova::net, nova::net::tcp;

<*
 Called when new bytes are available in the input ring. Consume via
 `available`/`peek`/`find_byte`/`copyout`/`consume`.
*>
alias DataCallback = fn void(Loop* loop, StreamConn* conn, void* userdata);

<*
 Called when the output ring has drained to or below the write low watermark
 (safe to enqueue more without unbounded buffering).
*>
alias DrainCallback = fn void(Loop* loop, StreamConn* conn, void* userdata);

<*
 Called on peer EOF (`status` empty) or a read/write error (`status` set).
*>
alias ErrorCallback = fn void(Loop* loop, StreamConn* conn, fault status, void* userdata);

<*
 Fixed-capacity single-producer/single-consumer byte ring buffer.

 Live data occupies `count` bytes starting at `head` (wrapping); free space is
 the remainder. All storage is reserved in `init`; no method allocates. Live data
 and free space are each at most two contiguous segments (the wrap point), which
 maps directly onto vectored I/O.
*>
struct RingBuffer
{
	char[] storage;
	usz head;
	usz count;
}

<*
 Caller-owned buffered connection over an already-open `tcp::Stream`.

 A per-connection pair of ring buffers turns the raw proactor read/write model
 into a batching one: incoming bytes accumulate in `input` (the user reads frames
 with `peek`/`find_byte`/`drain` without handling partial reads or re-arming),
 and outgoing bytes accumulate in `output`, flushed with a single coalesced
 `tcp::write_vectored` armed only while data remains. Read-high and write-low
 watermarks provide backpressure. All storage is embedded or reserved in `init`,
 so the hot path never allocates. Not used by the core; opt in by wrapping a
 stream after accept/connect.
*>
struct StreamConn
{
	Allocator allocator;
	tcp::Stream* stream;
	RingBuffer input;
	RingBuffer output;
	tcp::ReadOp read_op;
	tcp::WriteOp write_op;
	char[][2] in_vectors;
	char[][2] out_vectors;
	usz read_high;
	usz write_low;
	usz scan_offset;
	DataCallback on_data;
	DrainCallback on_drain;
	ErrorCallback on_error;
	void* userdata;
	bool reading;
	bool writing;
	bool read_paused;
	bool closed;
	bool initialized;
}

<*
 Configuration for `StreamConn.init`. Zero `read_high` means "the input
 capacity" (read until full); zero `write_low` fires `on_drain` only when the
 output is fully empty.
*>
struct Config
{
	usz input_capacity;
	usz output_capacity;
	usz read_high;
	usz write_low;
	DataCallback on_data;
	DrainCallback on_drain;
	ErrorCallback on_error;
	void* userdata;
}

<*
 Reserve `capacity` bytes for the ring.

 @require !self.storage.len : "ring must be uninitialized"
 @require capacity > 0 : "capacity must be positive"
 @return ? mem::OUT_OF_MEMORY : "backing allocator could not reserve storage"
*>
fn void? RingBuffer.init(&self, usz capacity, Allocator allocator = mem)
{
	self.storage = alloc::new_array_try(allocator, char, (sz)capacity)!;
	self.head = 0;
	self.count = 0;
}

<*
 Release the ring's storage with the same allocator passed to `init`. Idempotent.
*>
fn void RingBuffer.destroy(&self, Allocator allocator)
{
	if (!self.storage.len) return;
	alloc::free(allocator, self.storage.ptr);
	self.storage = { };
	self.head = 0;
	self.count = 0;
}

<*
 Total reserved capacity in bytes.
 @return "Ring capacity"
*>
fn usz RingBuffer.capacity(&self) => self.storage.len;

<*
 Number of live (unconsumed) bytes buffered.
 @return "Buffered byte count"
*>
fn usz RingBuffer.len(&self) => self.count;

<*
 Free space available for appends/reads.
 @return "Free byte count"
*>
fn usz RingBuffer.space(&self) => self.storage.len - self.count;

<*
 Whether the ring holds no live data.
 @return "True when empty"
*>
fn bool RingBuffer.is_empty(&self) => self.count == 0;

<*
 Drop all live data, keeping the reserved storage.
*>
fn void RingBuffer.clear(&self)
{
	self.head = 0;
	self.count = 0;
}

<*
 Fill `out` (length >= 2) with the live-data segments and return the segment
 count (0, 1 or 2). Zero-copy views into the ring storage.

 @require out.len >= 2 : "needs room for two segments"
*>
fn usz RingBuffer.data_vectors(&self, char[][] out)
{
	if (self.count == 0) return 0;
	usz cap   = self.storage.len;
	usz first = cap - self.head;
	if (first > self.count) first = self.count;
	out[0] = self.storage[self.head:first];
	if (first == self.count) return 1;
	out[1] = self.storage[0:self.count - first];
	return 2;
}

<*
 Fill `out` (length >= 2) with the free-space segments and return the segment
 count (0, 1 or 2). Mirror of `data_vectors` for the free region; feed these to a
 vectored read so one syscall fills the ring across the wrap point.

 @require out.len >= 2 : "needs room for two segments"
*>
fn usz RingBuffer.free_vectors(&self, char[][] out)
{
	usz cap  = self.storage.len;
	usz free = cap - self.count;
	if (free == 0) return 0;
	usz tail = self.head + self.count;
	if (tail >= cap) tail -= cap;
	usz first = cap - tail;
	if (first > free) first = free;
	out[0] = self.storage[tail:first];
	if (first == free) return 1;
	out[1] = self.storage[0:free - first];
	return 2;
}

<*
 First contiguous free segment, for writing freshly-received bytes into. Returns
 an empty slice when the ring is full. Follow a fill with `commit`.
*>
fn char[] RingBuffer.write_region(&self)
{
	usz cap   = self.storage.len;
	usz space = cap - self.count;
	if (space == 0) return { };
	usz tail = self.head + self.count;
	if (tail >= cap) tail -= cap;
	usz seg = cap - tail;
	if (seg > space) seg = space;
	return self.storage[tail:seg];
}

<*
 Mark `n` bytes written into `write_region` as live.
 @require self.count + n <= self.storage.len : "commit must not exceed capacity"
*>
fn void RingBuffer.commit(&self, usz n)
{
	self.count += n;
}

<*
 Drop `n` bytes from the front of the live data.
 @require n <= self.count : "cannot drain more than is buffered"
*>
fn void RingBuffer.drain(&self, usz n)
{
	self.head += n;
	if (self.head >= self.storage.len) self.head -= self.storage.len;
	self.count -= n;
}

<*
 Append `src` to the ring (copying), wrapping as needed.
 @return ? nova::BACKPRESSURE : "not enough free space for src"
*>
fn void? RingBuffer.append(&self, char[] src)
{
	if (src.len > self.storage.len - self.count) return nova::BACKPRESSURE~;
	usz cap  = self.storage.len;
	usz tail = self.head + self.count;
	if (tail >= cap) tail -= cap;
	usz first = cap - tail;
	if (first > src.len) first = src.len;
	mem::copy(&self.storage[tail], src.ptr, (sz)first);
	if (first < src.len) mem::copy(&self.storage[0], &src[first], (sz)(src.len - first));
	self.count += src.len;
}

<*
 Copy up to `n` leading data bytes into `dst` (handles wrap). Returns bytes
 copied (min of n, buffered, dst length). Does not drain.
*>
fn usz RingBuffer.copyout(&self, char[] dst, usz n)
{
	if (n > self.count) n = self.count;
	if (n > dst.len) n = dst.len;
	if (n == 0) return 0;
	usz cap   = self.storage.len;
	usz first = cap - self.head;
	if (first > n) first = n;
	mem::copy(dst.ptr, &self.storage[self.head], (sz)first);
	if (first < n) mem::copy(&dst[first], &self.storage[0], (sz)(n - first));
	return n;
}

<*
 Logical index of the first occurrence of `needle` in the live data, or -1.
 Used for delimiter framing (e.g. find a newline, then copyout/drain the line).
*>
fn sz RingBuffer.find_byte(&self, char needle) => self.find_byte_from(needle, 0);

<*
 Logical index of the first `needle` at or after logical offset `from`, or -1.

 Scans the ≤2 contiguous live segments with `index_of_char` per segment (no
 per-byte wrap branch). `from` lets callers skip a prefix already known to be
 needle-free (see `StreamConn.find_byte` memoization).
*>
fn sz RingBuffer.find_byte_from(&self, char needle, usz from)
{
	if (from >= self.count) return -1;
	usz cap       = self.storage.len;
	usz remaining = self.count - from;
	usz pos       = self.head + from;
	if (pos >= cap) pos -= cap;

	usz first = cap - pos;
	if (first > remaining) first = remaining;
	if (try i = ((String)self.storage[pos:first]).index_of_char(needle)) return (sz)from + i;
	if (first == remaining) return -1;

	usz second = remaining - first;
	if (try i = ((String)self.storage[0:second]).index_of_char(needle)) return (sz)(from + first) + i;
	return -1;
}

<*
 Initialize a buffered connection over an open stream.

 @require !self.initialized : "double init would leak the rings"
 @require stream != null : "stream must not be null"
 @require config.input_capacity > 0 && config.output_capacity > 0 : "capacities must be positive"
 @require config.on_data != null : "a data callback is required"
 @return ? mem::OUT_OF_MEMORY : "backing allocator could not reserve the rings"
 @ensure self.initialized
*>
fn void? StreamConn.init(&self, tcp::Stream* stream, Config config, Allocator allocator = mem)
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
	self.write_low = config.write_low;
	self.on_data = config.on_data;
	self.on_drain = config.on_drain;
	self.on_error = config.on_error;
	self.userdata = config.userdata;
	self.initialized = true;
}

<*
 Release the rings. Does not close the caller-owned stream.
 @ensure !self.initialized
*>
fn void StreamConn.destroy(&self)
{
	if (!self.initialized) return;
	self.input.destroy(self.allocator);
	self.output.destroy(self.allocator);
	self.initialized = false;
}

<*
 Bytes currently buffered and available to read.
 @return "Input byte count"
*>
fn usz StreamConn.available(&self) => self.input.len();

<*
 Logical index of the first `needle` in the input data, or -1 (delimiter framing).
 @return "Offset of needle, or -1"
*>
fn sz StreamConn.find_byte(&self, char needle)
{
	sz idx = self.input.find_byte_from(needle, self.scan_offset);
	if (idx < 0)
	{
		self.scan_offset = self.input.len();
		return -1;
	}
	return idx;
}

<*
 Fill `out` (length >= 2) with zero-copy views of the input data segments.
 @return "Segment count (0, 1 or 2)"
*>
fn usz StreamConn.peek(&self, char[][] out) => self.input.data_vectors(out);

<*
 Copy up to `n` leading input bytes into `dst` (handles wrap). Does not consume.
 @return "Bytes copied"
*>
fn usz StreamConn.copyout(&self, char[] dst, usz n) => self.input.copyout(dst, n);

<*
 Drop `n` bytes from the front of the input after processing them.
*>
fn void StreamConn.consume(&self, usz n)
{
	self.input.drain(n);
	self.scan_offset = self.scan_offset > n ? self.scan_offset - n : 0;
}

<*
 Begin reading from the stream into the input ring.
 @require self.initialized
*>
fn void? StreamConn.start(&self, Loop* loop) => self.arm_read(loop);

<*
 Re-arm reading after the application drained the input below the high watermark.
 @require self.initialized
*>
fn void? StreamConn.resume_read(&self, Loop* loop)
{
	if (self.read_paused) self.arm_read(loop)!;
}

<*
 Arm a read if the connection is open, no read is in flight, and the input is
 below the high watermark; otherwise mark it paused.
*>
fn void? StreamConn.arm_read(&self, Loop* loop)
{
	if (self.closed || self.reading) return;
	if (self.input.len() >= self.read_high || self.input.space() == 0)
	{
		self.read_paused = true;
		return;
	}
	self.read_paused = false;
	usz n = self.input.free_vectors(self.in_vectors[..]);
	if (n == 1)
	{
		tcp::read(loop, self.stream, self.in_vectors[0], &self.read_op, { }, &on_buffered_read, self)!;
	}
	else
	{
		tcp::read_vectored(loop, self.stream, self.in_vectors[0:n], &self.read_op, { }, &on_buffered_read, self)!;
	}
	self.reading = true;
}

<*
 Queue bytes for sending and flush as soon as no write is in flight.

 Fast path: when nothing is buffered and no write is in flight, send directly
 with a synchronous `try_write` and copy only the unsent remainder into the
 output ring. This avoids a full-payload copy and an async write submission when
 the socket accepts the data immediately. Order is preserved because the fast
 path runs only while the output ring is empty; any `try_write` failure (e.g.
 `WOULD_BLOCK`) falls back to buffering and the async write path.

 @require self.initialized
 @return ? nova::BACKPRESSURE : "output ring is full"
*>
fn void? StreamConn.write(&self, Loop* loop, char[] bytes)
{
	if (bytes.len && self.output.is_empty() && !self.writing && !self.closed)
	{
		if (try sent = self.stream.try_write(bytes))
		{
			if ((usz)sent >= bytes.len) return;
			bytes = bytes[(usz)sent..];
		}
	}
	self.output.append(bytes)!;
	self.flush(loop)!;
}

<*
 Submit a coalesced vectored write of the output ring if there is data and no
 write is already in flight.
*>
fn void? StreamConn.flush(&self, Loop* loop)
{
	if (self.writing || self.output.is_empty() || self.closed) return;
	usz n = self.output.data_vectors(self.out_vectors[..]);
	if (n == 1)
	{
		tcp::write(loop, self.stream, self.out_vectors[0], &self.write_op, { }, &on_buffered_write, self)!;
	}
	else
	{
		tcp::write_vectored(loop, self.stream, self.out_vectors[0:n], &self.write_op, { }, &on_buffered_write, self)!;
	}
	self.writing = true;
}

<*
 Read completion: commit received bytes, deliver `on_data`, then re-arm reading
 (or report EOF/error through `on_error`).

 @param loop : "Loop dispatching the read"
 @param result : "Read result (bytes, eof, error)"
 @param ud : "The owning StreamConn"
*>
fn void on_buffered_read(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* ud) @local
{
	(void)stream;
	(void)op;
	StreamConn* self = (StreamConn*)ud;
	self.reading = false;

	if (result.error.status || result.eof)
	{
		self.closed = true;
		self.on_error(loop, self, result.error.status, self.userdata);
		return;
	}

	self.input.commit((usz)result.bytes);
	self.on_data(loop, self, self.userdata);

	if (catch err = self.arm_read(loop))
	{
		self.closed = true;
		self.on_error(loop, self, err, self.userdata);
	}
}

<*
 Write completion: drain the sent bytes, re-flush any remaining output, and fire
 `on_drain` when the output falls to the write low watermark.

 @param loop : "Loop dispatching the write"
 @param result : "Write result (bytes, error)"
 @param ud : "The owning StreamConn"
*>
fn void on_buffered_write(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* ud) @local
{
	(void)stream;
	(void)op;
	StreamConn* self = (StreamConn*)ud;
	self.writing = false;

	if (result.error.status)
	{
		self.closed = true;
		self.on_error(loop, self, result.error.status, self.userdata);
		return;
	}

	self.output.drain((usz)result.bytes);

	if (self.output.len() <= self.write_low && self.on_drain != null) self.on_drain(loop, self, self.userdata);

	if (!self.output.is_empty())
	{
		if (catch err = self.flush(loop))
		{
			self.closed = true;
			self.on_error(loop, self, err, self.userdata);
		}
	}
}
