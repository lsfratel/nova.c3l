module nova::backend::uring @if(env::LINUX);

import std::core::mem;
import libc;

<*
 A mapped io_uring instance: the ring file descriptor, the shared memory regions,
 and the cached index pointers into them.

 `sq_ring` and `cq_ring` alias the same mapping when the kernel reports
 `IORING_FEAT_SINGLE_MMAP`; otherwise they are two distinct mappings. The `*_sz`
 fields record the mapped lengths for `munmap`. All index pointers reference
 kernel-shared memory and must be accessed with the acquire/release ordering used
 by `push_poll` and the poll-time completion drain.
*>
struct UringState
{
	int ring_fd;
	void* sq_ring;
	usz sq_ring_sz;
	void* cq_ring;
	usz cq_ring_sz;
	void* sqes;
	usz sqes_sz;
	bool single_mmap;
	bool cap_recv;
	bool cap_send;
	bool cap_accept;
	bool cap_connect;
	bool cap_recvmsg;
	bool cap_sendmsg;
	uint sq_entries;
	uint pending;
	uint* sq_head;
	uint* sq_tail;
	uint sq_mask;
	uint* sq_array;
	IoUringSqe* sqe_arr;
	uint* cq_head;
	uint* cq_tail;
	uint cq_mask;
	IoUringCqe* cqes;
}

<*
 Set up and map an io_uring instance with the requested submission depth.

 The kernel rounds `entries` up to a power of two. On any failure the partially
 acquired ring fd and mappings are released before returning.

 @param [&inout] self : "Uninitialized ring state"
 @param entries : "Requested submission queue depth"
 @return "True when the ring is set up and mapped"
 @require self.ring_fd == 0 : "Ring state must be zeroed before init"
 @require entries > 0 : "Submission depth must be positive"
*>
fn bool UringState.init(&self, uint entries)
{
	IoUringParams params;
	long fd = sys_setup(entries, &params);
	if (fd < 0) return false;

	self.ring_fd = (int)fd;
	self.sq_entries = params.sq_entries;
	self.single_mmap = (params.features & IORING_FEAT_SINGLE_MMAP) != 0;

	usz sring_sz = (usz)params.sq_off.array + (usz)params.sq_entries * 4;
	usz cring_sz = (usz)params.cq_off.cqes + (usz)params.cq_entries * IoUringCqe::size;

	if (self.single_mmap)
	{
		usz ring_sz = sring_sz > cring_sz ? sring_sz : cring_sz;
		self.sq_ring = map_region(self.ring_fd, ring_sz, IORING_OFF_SQ_RING);
		if (!self.sq_ring)
		{
			self.destroy();
			return false;
		}
		self.sq_ring_sz = ring_sz;
		self.cq_ring = self.sq_ring;
		self.cq_ring_sz = 0;
	}
	else
	{
		self.sq_ring = map_region(self.ring_fd, sring_sz, IORING_OFF_SQ_RING);
		self.cq_ring = map_region(self.ring_fd, cring_sz, IORING_OFF_CQ_RING);
		if (!self.sq_ring || !self.cq_ring)
		{
			self.destroy();
			return false;
		}
		self.sq_ring_sz = sring_sz;
		self.cq_ring_sz = cring_sz;
	}

	self.sqes_sz = (usz)params.sq_entries * IoUringSqe::size;
	self.sqes = map_region(self.ring_fd, self.sqes_sz, IORING_OFF_SQES);
	if (!self.sqes)
	{
		self.destroy();
		return false;
	}
	self.sqe_arr = (IoUringSqe*)self.sqes;

	char* sb = (char*)self.sq_ring;
	self.sq_head = (uint*)(sb + params.sq_off.head);
	self.sq_tail = (uint*)(sb + params.sq_off.tail);
	self.sq_mask = *(uint*)(sb + params.sq_off.ring_mask);
	self.sq_array = (uint*)(sb + params.sq_off.array);

	char* cb = (char*)self.cq_ring;
	self.cq_head = (uint*)(cb + params.cq_off.head);
	self.cq_tail = (uint*)(cb + params.cq_off.tail);
	self.cq_mask = *(uint*)(cb + params.cq_off.ring_mask);
	self.cqes = (IoUringCqe*)(cb + params.cq_off.cqes);
	return true;
}

<*
 Unmap the ring regions and close the ring fd. Idempotent and safe on a
 partially initialized state (used as the init failure path).

 @param [&inout] self : "Ring state to release"
*>
fn void UringState.destroy(&self)
{
	if (self.sqes) unmap_region(self.sqes, self.sqes_sz);
	if (!self.single_mmap && self.cq_ring) unmap_region(self.cq_ring, self.cq_ring_sz);
	if (self.sq_ring) unmap_region(self.sq_ring, self.sq_ring_sz);
	if (self.ring_fd > 0) (void)libc::close(self.ring_fd);
	*self = { };
}

<*
 Stage one `POLL_ADD` submission queue entry.

 Publishes the new submission tail with release ordering so the kernel never
 observes a half-written SQE (§3.9). Does not call `io_uring_enter`; pair with
 `submit`.

 @param [&inout] self : "Mapped ring state"
 @param fd : "Descriptor to poll"
 @param events : "Poll event mask (POLLIN/POLLOUT/...)"
 @param user_data : "Identity token returned in the completion"
 @param multishot : "Keep the poll armed and emit a CQE per event"
 @return "False when the submission queue is full"
*>
fn bool UringState.push_poll(&self, int fd, uint events, ulong user_data, bool multishot)
{
	uint tail = *self.sq_tail;
	uint head = @atomic_load(*self.sq_head, mem::AtomicOrdering.ACQUIRE);
	if (tail - head >= self.sq_entries) return false;

	uint index    = tail & self.sq_mask;
	IoUringSqe* e = &self.sqe_arr[index];
	*e = { };
	e.opcode = IORING_OP_POLL_ADD;
	e.fd = fd;
	e.poll_events = events;
	e.user_data = user_data;
	if (multishot) e.len = IORING_POLL_ADD_MULTI;

	self.sq_array[index] = index;
	@atomic_store(*self.sq_tail, tail + 1, mem::AtomicOrdering.RELEASE);
	self.pending++;
	return true;
}

<*
 Stage one `POLL_REMOVE` submission queue entry cancelling a prior poll by its
 `user_data`. Publishes the tail with release ordering (§3.9).

 @param [&inout] self : "Mapped ring state"
 @param target : "The `user_data` of the poll to cancel"
 @return "False when the submission queue is full"
*>
fn bool UringState.push_poll_remove(&self, ulong target)
{
	uint tail = *self.sq_tail;
	uint head = @atomic_load(*self.sq_head, mem::AtomicOrdering.ACQUIRE);
	if (tail - head >= self.sq_entries) return false;

	uint index    = tail & self.sq_mask;
	IoUringSqe* e = &self.sqe_arr[index];
	*e = { };
	e.opcode = IORING_OP_POLL_REMOVE;
	e.addr = target;
	e.user_data = 0;

	self.sq_array[index] = index;
	@atomic_store(*self.sq_tail, tail + 1, mem::AtomicOrdering.RELEASE);
	self.pending++;
	return true;
}

<*
 Stage a `POLL_ADD`, flushing the submission queue first if it is full so the
 stage always succeeds while ring space exists.

 @param [&inout] self : "Mapped ring state"
 @param fd : "Descriptor to poll"
 @param events : "Poll event mask"
 @param user_data : "Identity token"
 @param multishot : "Keep the poll armed across events"
 @return "False only when the ring is full even after a flush"
*>
fn bool UringState.stage_poll(&self, int fd, uint events, ulong user_data, bool multishot)
{
	if (self.push_poll(fd, events, user_data, multishot)) return true;
	(void)self.flush(0, 0, null, 0);
	return self.push_poll(fd, events, user_data, multishot);
}

<*
 Stage a `POLL_REMOVE`, flushing first if the submission queue is full.

 @param [&inout] self : "Mapped ring state"
 @param target : "user_data of the poll to cancel"
 @return "False only when the ring is full even after a flush"
*>
fn bool UringState.stage_poll_remove(&self, ulong target)
{
	if (self.push_poll_remove(target)) return true;
	(void)self.flush(0, 0, null, 0);
	return self.push_poll_remove(target);
}

<*
 Stage one `ASYNC_CANCEL` submission queue entry cancelling an in-flight
 completion operation (`RECV`/`SEND`/...) by its `user_data`. The kernel completes
 the target with `-ECANCELED`; the cancel SQE itself uses `user_data == 0` so its
 own completion is ignored. Publishes the tail with release ordering (§3.9).

 @param [&inout] self : "Mapped ring state"
 @param target : "The `user_data` of the operation to cancel"
 @return "False when the submission queue is full"
*>
fn bool UringState.push_cancel(&self, ulong target)
{
	uint tail = *self.sq_tail;
	uint head = @atomic_load(*self.sq_head, mem::AtomicOrdering.ACQUIRE);
	if (tail - head >= self.sq_entries) return false;

	uint index    = tail & self.sq_mask;
	IoUringSqe* e = &self.sqe_arr[index];
	*e = { };
	e.opcode = IORING_OP_ASYNC_CANCEL;
	e.fd = -1;
	e.addr = target;
	e.user_data = 0;

	self.sq_array[index] = index;
	@atomic_store(*self.sq_tail, tail + 1, mem::AtomicOrdering.RELEASE);
	self.pending++;
	return true;
}

<*
 Stage an `ASYNC_CANCEL`, flushing first if the submission queue is full.

 @param [&inout] self : "Mapped ring state"
 @param target : "user_data of the operation to cancel"
 @return "False only when the ring is full even after a flush"
*>
fn bool UringState.stage_cancel(&self, ulong target)
{
	if (self.push_cancel(target)) return true;
	(void)self.flush(0, 0, null, 0);
	return self.push_cancel(target);
}

<*
 Stage one `ACCEPT` SQE: the kernel accepts a connection on `fd` and reports the
 accepted descriptor (or `-errno`) in the completion, writing the peer address
 into `addr_ptr`/`socklen_ptr`.

 `addr_ptr` is the SQE `addr` (sockaddr-out), `socklen_ptr` the offset-8 union
 (`addr2`, the in/out socklen pointer), and `flags` the offset-28 union
 (`accept_flags`, e.g. `SOCK_NONBLOCK|SOCK_CLOEXEC`). Publishes the tail with
 release ordering (§3.9).

 @param [&inout] self : "Mapped ring state"
 @param fd : "Listener descriptor"
 @param addr_ptr : "Pointer to the caller sockaddr-out storage"
 @param socklen_ptr : "Pointer to the caller socklen (in: capacity, out: length)"
 @param flags : "accept(2) flags applied to the accepted descriptor"
 @param user_data : "Identity token returned in the completion"
 @return "False when the submission queue is full"
*>
fn bool UringState.push_accept(&self, int fd, ulong addr_ptr, ulong socklen_ptr, uint flags, ulong user_data)
{
	uint tail = *self.sq_tail;
	uint head = @atomic_load(*self.sq_head, mem::AtomicOrdering.ACQUIRE);
	if (tail - head >= self.sq_entries) return false;

	uint index    = tail & self.sq_mask;
	IoUringSqe* e = &self.sqe_arr[index];
	*e = { };
	e.opcode = IORING_OP_ACCEPT;
	e.fd = fd;
	e.addr = addr_ptr;
	e.off = socklen_ptr;
	e.poll_events = flags;
	e.user_data = user_data;

	self.sq_array[index] = index;
	@atomic_store(*self.sq_tail, tail + 1, mem::AtomicOrdering.RELEASE);
	self.pending++;
	return true;
}

<*
 Stage an `ACCEPT`, flushing first if the submission queue is full.

 @param [&inout] self : "Mapped ring state"
 @param fd : "Listener descriptor"
 @param addr_ptr : "Pointer to the caller sockaddr-out storage"
 @param socklen_ptr : "Pointer to the caller socklen"
 @param flags : "accept(2) flags"
 @param user_data : "Identity token"
 @return "False only when the ring is full even after a flush"
*>
fn bool UringState.stage_accept(&self, int fd, ulong addr_ptr, ulong socklen_ptr, uint flags, ulong user_data)
{
	if (self.push_accept(fd, addr_ptr, socklen_ptr, flags, user_data)) return true;
	(void)self.flush(0, 0, null, 0);
	return self.push_accept(fd, addr_ptr, socklen_ptr, flags, user_data);
}

<*
 Stage one `CONNECT` SQE: the kernel connects `fd` to the sockaddr at `addr_ptr`
 and reports `0` (or `-errno`) in the completion.

 `addr_ptr` is the SQE `addr` (sockaddr) and `addrlen` the offset-8 union (`off`,
 holding the address length as a value, not a pointer). Publishes the tail with
 release ordering (§3.9).

 @param [&inout] self : "Mapped ring state"
 @param fd : "Stream descriptor"
 @param addr_ptr : "Pointer to the caller sockaddr storage"
 @param addrlen : "Address length"
 @param user_data : "Identity token returned in the completion"
 @return "False when the submission queue is full"
*>
fn bool UringState.push_connect(&self, int fd, ulong addr_ptr, ulong addrlen, ulong user_data)
{
	uint tail = *self.sq_tail;
	uint head = @atomic_load(*self.sq_head, mem::AtomicOrdering.ACQUIRE);
	if (tail - head >= self.sq_entries) return false;

	uint index    = tail & self.sq_mask;
	IoUringSqe* e = &self.sqe_arr[index];
	*e = { };
	e.opcode = IORING_OP_CONNECT;
	e.fd = fd;
	e.addr = addr_ptr;
	e.off = addrlen;
	e.user_data = user_data;

	self.sq_array[index] = index;
	@atomic_store(*self.sq_tail, tail + 1, mem::AtomicOrdering.RELEASE);
	self.pending++;
	return true;
}

<*
 Stage a `CONNECT`, flushing first if the submission queue is full.

 @param [&inout] self : "Mapped ring state"
 @param fd : "Stream descriptor"
 @param addr_ptr : "Pointer to the caller sockaddr storage"
 @param addrlen : "Address length"
 @param user_data : "Identity token"
 @return "False only when the ring is full even after a flush"
*>
fn bool UringState.stage_connect(&self, int fd, ulong addr_ptr, ulong addrlen, ulong user_data)
{
	if (self.push_connect(fd, addr_ptr, addrlen, user_data)) return true;
	(void)self.flush(0, 0, null, 0);
	return self.push_connect(fd, addr_ptr, addrlen, user_data);
}

<*
 Stage one `RECVMSG`/`SENDMSG` SQE: the kernel performs the scatter/gather datagram
 or stream message described by the `msghdr` at `msg_ptr` and reports the byte count
 (or `-errno`) in the completion.

 `msg_ptr` is the SQE `addr` (the `struct msghdr`), `len` is `1` (the conventional
 message count; the kernel uses `msghdr.msg_iovlen`), and `op_flags` lands in the
 offset-28 union (`msg_flags`: `MSG_TRUNC` for recv, `MSG_NOSIGNAL` for send).
 Publishes the tail with release ordering (§3.9).

 @param [&inout] self : "Mapped ring state"
 @param opcode : "`IORING_OP_RECVMSG` or `IORING_OP_SENDMSG`"
 @param fd : "Socket descriptor"
 @param msg_ptr : "Pointer to the caller `msghdr`"
 @param op_flags : "msg flags"
 @param user_data : "Identity token returned in the completion"
 @return "False when the submission queue is full"
*>
fn bool UringState.push_msg(&self, char opcode, int fd, ulong msg_ptr, uint op_flags, ulong user_data)
{
	uint tail = *self.sq_tail;
	uint head = @atomic_load(*self.sq_head, mem::AtomicOrdering.ACQUIRE);
	if (tail - head >= self.sq_entries) return false;

	uint index    = tail & self.sq_mask;
	IoUringSqe* e = &self.sqe_arr[index];
	*e = { };
	e.opcode = opcode;
	e.fd = fd;
	e.addr = msg_ptr;
	e.len = 1;
	e.poll_events = op_flags;
	e.user_data = user_data;

	self.sq_array[index] = index;
	@atomic_store(*self.sq_tail, tail + 1, mem::AtomicOrdering.RELEASE);
	self.pending++;
	return true;
}

<*
 Stage a `RECVMSG`/`SENDMSG`, flushing first if the submission queue is full.

 @param [&inout] self : "Mapped ring state"
 @param opcode : "`IORING_OP_RECVMSG` or `IORING_OP_SENDMSG`"
 @param fd : "Socket descriptor"
 @param msg_ptr : "Pointer to the caller `msghdr`"
 @param op_flags : "msg flags"
 @param user_data : "Identity token"
 @return "False only when the ring is full even after a flush"
*>
fn bool UringState.stage_msg(&self, char opcode, int fd, ulong msg_ptr, uint op_flags, ulong user_data)
{
	if (self.push_msg(opcode, fd, msg_ptr, op_flags, user_data)) return true;
	(void)self.flush(0, 0, null, 0);
	return self.push_msg(opcode, fd, msg_ptr, op_flags, user_data);
}

<*
 Stage one buffer I/O SQE (`RECV`/`SEND`): the kernel performs the read/write into
 the caller buffer and reports the byte count (or `-errno`) in the completion.

 `op_flags` lands in the SQE offset-28 union shared by poll/rw/msg flags; for
 `SEND` it is `MSG_NOSIGNAL`, for `RECV` it is zero. Publishes the tail with
 release ordering (§3.9).

 @param [&inout] self : "Mapped ring state"
 @param opcode : "`IORING_OP_RECV` or `IORING_OP_SEND`"
 @param fd : "Stream descriptor"
 @param buffer : "Caller buffer the kernel reads into / writes from"
 @param op_flags : "msg flags (`MSG_NOSIGNAL` for send, 0 for recv)"
 @param user_data : "Identity token returned in the completion"
 @return "False when the submission queue is full"
*>
fn bool UringState.push_rw(&self, char opcode, int fd, char[] buffer, uint op_flags, ulong user_data)
{
	uint tail = *self.sq_tail;
	uint head = @atomic_load(*self.sq_head, mem::AtomicOrdering.ACQUIRE);
	if (tail - head >= self.sq_entries) return false;

	uint index    = tail & self.sq_mask;
	IoUringSqe* e = &self.sqe_arr[index];
	*e = { };
	e.opcode = opcode;
	e.fd = fd;
	e.addr = (ulong)(uptr)buffer.ptr;
	e.len = (uint)buffer.len;
	e.poll_events = op_flags;
	e.user_data = user_data;

	self.sq_array[index] = index;
	@atomic_store(*self.sq_tail, tail + 1, mem::AtomicOrdering.RELEASE);
	self.pending++;
	return true;
}

<*
 Stage a buffer I/O SQE, flushing first if the submission queue is full.

 @param [&inout] self : "Mapped ring state"
 @param opcode : "`IORING_OP_RECV` or `IORING_OP_SEND`"
 @param fd : "Stream descriptor"
 @param buffer : "Caller buffer"
 @param op_flags : "msg flags"
 @param user_data : "Identity token"
 @return "False only when the ring is full even after a flush"
*>
fn bool UringState.stage_rw(&self, char opcode, int fd, char[] buffer, uint op_flags, ulong user_data)
{
	if (self.push_rw(opcode, fd, buffer, op_flags, user_data)) return true;
	(void)self.flush(0, 0, null, 0);
	return self.push_rw(opcode, fd, buffer, op_flags, user_data);
}

<*
 Submit all staged SQEs (and optionally wait) via `io_uring_enter`, clearing the
 pending count on success. Deferring submission to here batches registrations and
 makes readiness evaluate at poll time, matching the epoll backend.

 @param [&inout] self : "Mapped ring state"
 @param min_complete : "Completions to wait for, or zero to not block"
 @param flags : "Enter flags"
 @param arg : "Extended argument pointer, or null"
 @param argsz : "Extended argument size, or zero"
 @return "io_uring_enter result, or a negative errno; zero when nothing to do"
*>
fn long UringState.flush(&self, uint min_complete, uint flags, void* arg, usz argsz)
{
	if (self.pending == 0 && min_complete == 0) return 0;
	long r = sys_enter(self.ring_fd, self.pending, min_complete, flags, arg, argsz);
	if (r >= 0) self.pending = 0;
	return r;
}
