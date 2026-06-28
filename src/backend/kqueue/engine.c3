module nova::backend::kqueue @if(env::DARWIN);

import std::core::mem::alloc, std::net::os, std::os::posix;
import libc;

import nova @norecurse;
import nova::op @public;
import nova::backend @public;
import nova::timer;

<*
 Platform `EVFILT_READ` and `EVFILT_WRITE` filter values.
*>
const CShort EVFILT_READ  = (CShort)-1;
const CShort EVFILT_WRITE = (CShort)-2;
const CShort EVFILT_PROC  = (CShort)-5;

<*
 Portable subset of kqueue event flags used by the backend.
*>
const uint EV_ADD     = 0x0001;
const uint EV_DELETE  = 0x0002;
const uint EV_ENABLE  = 0x0004;
const uint EV_ONESHOT = 0x0010;
const uint EV_CLEAR   = 0x0020;
const uint EV_RECEIPT = 0x0040;
const uint EV_ERROR   = 0x4000;
const uint EV_EOF     = 0x8000;
const uint NOTE_EXIT  = 0x80000000;

<*
 File descriptor control constants used for close-on-exec and non-blocking
 setup.
*>
const int F_GETFD    = 1;
const int F_SETFD    = 2;
const int F_GETFL    = 3;
const int F_SETFL    = 4;
const int FD_CLOEXEC = 1;

<*
 Low-bit userdata tags used to distinguish watcher and wake events from raw
 operation pointers.
*>
const ulong BACKEND_WATCHER_TAG = 1;
const ulong BACKEND_WAKE_TAG    = 2;
const ulong BACKEND_TAG_MASK    = 3;

<*
 Native kqueue descriptor constructors.
*>
extern fn int kqueue();

<*
 Darwin `kevent` entry point using `int` event counts.
*>
extern fn int kevent(int kq, Kevent* changelist, int nchanges, Kevent* eventlist, int nevents, TimeSpec* timeout);

<*
 Darwin native `struct kevent` layout.
*>
struct Kevent @private @align(4)
{
	uptr ident;
	CShort filter;
	CUShort flags;
	CUInt fflags;
	iptr data;
	void* udata;
}

<*
 Fill a portable `kevent` change record.

 @param [out] event : "kqueue event record to fill"
 @param fd : "Native descriptor identifier"
 @param filter : "kqueue filter"
 @param flags : "kqueue event flags"
 @param udata : "Opaque userdata stored in the event"
 @param fflags : "Filter-specific flags"
 @require event != null : "Kqueue event pointer must not be null"
*>
fn void backend_event_set(Kevent* event, int fd, CShort filter, uint flags, void* udata, uint fflags = 0) @local
{
	event.ident = (uptr)fd;
	event.filter = filter;
	event.flags = (CUShort)flags;
	event.fflags = fflags;
	event.data = 0;
	event.udata = udata;
}

<*
 Store an operation pointer as native event userdata.

 @param op : "Header to tag"
 @return "Tagged operation userdata"
 @require op != null : "Header pointer must not be null"
*>
fn void* backend_op_tag(Header* op) @local => (void*)((uptr)op);

<*
 Store a watcher pointer with the low-bit watcher tag.

 @param watcher : "backend::Watcher to tag"
 @return "Tagged watcher userdata"
 @require watcher != null : "backend::Watcher pointer must not be null"
*>
fn void* backend_watcher_tag(backend::Watcher* watcher) @local => (void*)((uptr)watcher | (uptr)BACKEND_WATCHER_TAG);

<*
 Store the reserved wake tag as native event userdata.

 @return "Tagged wake-source userdata"
*>
fn void* backend_wake_tag() @local => (void*)((uptr)BACKEND_WAKE_TAG);

<*
 Report whether a kqueue event contains a tagged watcher pointer.

 @param event : "kqueue event to inspect"
 @return "True when event stores a watcher pointer"
 @require event != null : "Kqueue event pointer must not be null"
*>
fn bool backend_event_is_watcher(Kevent* event) @private
{
	return (((uptr)event.udata & (uptr)BACKEND_TAG_MASK) == (uptr)BACKEND_WATCHER_TAG);
}

<*
 Report whether a kqueue event is for the loop wake source.

 @param event : "kqueue event to inspect"
 @return "True when event stores the wake tag"
 @require event != null : "Kqueue event pointer must not be null"
*>
fn bool backend_event_is_wake(Kevent* event) @local
{
	return (((uptr)event.udata & (uptr)BACKEND_TAG_MASK) == (uptr)BACKEND_WAKE_TAG);
}

<*
 Recover the watcher pointer stored in a tagged kqueue event.

 @param event : "Tagged kqueue event"
 @return "Backend watcher stored in the event"
 @require event != null : "Kqueue event pointer must not be null"
*>
fn backend::Watcher* backend_event_watcher(Kevent* event) @private
{
	return (backend::Watcher*)((uptr)event.udata & ~(uptr)BACKEND_TAG_MASK);
}

<*
 Call the platform `kevent` entry point with the native count type.

 @param kq : "Native kqueue descriptor"
 @param changes : "Change list pointer"
 @param change_count : "Number of changes"
 @param events : "Event output pointer"
 @param event_count : "Event output capacity"
 @param timeout : "Optional native timeout"
 @return "Native kevent result"
*>
fn int backend_kevent(
	int kq,
	Kevent* changes,
	sz change_count,
	Kevent* events,
	sz event_count,
	TimeSpec* timeout
) @local
{
	return kevent(kq, changes, (int)change_count, events, (int)event_count, timeout);
}

<*
 Apply one kqueue change and optionally return an `EV_RECEIPT` error.

 @param loop : "Loop that owns the kqueue backend"
 @param fd : "Native descriptor identifier"
 @param filter : "kqueue filter"
 @param flags : "kqueue event flags"
 @param udata : "Opaque userdata stored in the event"
 @param fflags : "Filter-specific flags"
 @param [out] event_error : "Optional receipt error"
 @return "Zero on success, negative on failure"
 @require loop != null : "Loop pointer must not be null"
*>
fn int backend_apply_event(
	Loop* loop,
	int fd,
	CShort filter,
	uint flags,
	void* udata,
	uint fflags = 0,
	Errno* event_error = null
) @local
{
	Kevent event;
	Kevent receipt;
	backend_event_set(&event, fd, filter, flags, udata, fflags);
	event.flags |= EV_RECEIPT;

	int count = backend_kevent((int)loop.backend_handle, &event, 1, &receipt, 1, null);
	if (count < 0) return -1;
	if (count == 0) return 0;
	if (((uint)receipt.flags & EV_ERROR) && receipt.data == 0) return 0;
	if (event_error)
	{
		if ((uint)receipt.flags & EV_ERROR)
		{
			*event_error = (Errno)receipt.data;
		}
		else
		{
			*event_error = libc::errno();
		}
	}
	return -1;
}

<*
 Add one kqueue event filter for a descriptor.

 @param loop : "Loop that owns the kqueue backend"
 @param fd : "Native descriptor identifier"
 @param filter : "kqueue filter"
 @param oneshot : "Register a one-shot event"
 @param udata : "Opaque userdata stored in the event"
 @return ? nova::BACKEND_FAILED : "kevent add failed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? backend_add_event(Loop* loop, int fd, CShort filter, bool oneshot, void* udata) @local
{
	uint flags = EV_ADD | EV_ENABLE;
	if (oneshot) flags |= EV_ONESHOT;
	if (!oneshot) flags |= EV_CLEAR;
	if (backend_apply_event(loop, fd, filter, flags, udata) < 0) return nova::BACKEND_FAILED~;
}

<*
 Delete one kqueue event filter, ignoring already-removed descriptors.

 @param loop : "Loop that owns the kqueue backend"
 @param fd : "Native descriptor identifier"
 @param filter : "kqueue filter"
 @require loop != null : "Loop pointer must not be null"
*>
fn void backend_delete_event(Loop* loop, int fd, CShort filter) @local
{
	if ((int)loop.backend_handle < 0) return;
	(void)backend_apply_event(loop, fd, filter, EV_DELETE, null);
}

<*
 Register read and/or write kqueue events for a descriptor.

 @param loop : "Loop that owns the kqueue backend"
 @param fd : "Native descriptor identifier"
 @param interests : "Backend-neutral readiness interests"
 @param oneshot : "Register one-shot events"
 @param udata : "Opaque userdata stored in each event"
 @return ? nova::INVALID_STATE : "No supported readiness interest was requested"
 @return ? nova::BACKEND_FAILED : "kevent registration failed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? backend_register_events(Loop* loop, int fd, uint interests, bool oneshot, void* udata) @local
{
	if (!(interests & (nova::READY_READABLE | nova::READY_WRITABLE))) return nova::INVALID_STATE~;

	uint flags = EV_ADD | EV_ENABLE | EV_RECEIPT;
	if (oneshot) flags |= EV_ONESHOT;
	if (!oneshot) flags |= EV_CLEAR;

	Kevent[2] changes;
	Kevent[2] receipts;
	sz n = 0;
	if (interests & nova::READY_READABLE)
	{
		backend_event_set(&changes[n], fd, EVFILT_READ, flags, udata);
		n++;
	}
	if (interests & nova::READY_WRITABLE)
	{
		backend_event_set(&changes[n], fd, EVFILT_WRITE, flags, udata);
		n++;
	}

	int count = backend_kevent((int)loop.backend_handle, &changes[0], n, &receipts[0], n, null);
	if (!backend_changes_applied(&receipts[0], n, count))
	{
		backend_delete_events(loop, fd, interests);
		return nova::BACKEND_FAILED~;
	}
}

<*
 Report whether every batched `EV_RECEIPT` change applied without error.

 With `EV_RECEIPT` the kernel returns one receipt per submitted change, each
 carrying `EV_ERROR` and a `data` errno that is zero on success.

 @param receipts : "Receipt array filled by `kevent`"
 @param n : "Number of submitted changes"
 @param count : "kevent return value"
 @return "True when all `n` changes applied successfully"
 @require receipts != null : "Receipt pointer must not be null"
*>
fn bool backend_changes_applied(Kevent* receipts, sz n, int count) @local
{
	if (count < 0 || (sz)count != n) return false;
	for (sz i = 0; i < n; i++)
	{
		if (((uint)receipts[i].flags & EV_ERROR) && receipts[i].data != 0) return false;
	}
	return true;
}

<*
 Delete read and/or write kqueue events for a descriptor.

 @param loop : "Loop that owns the kqueue backend"
 @param fd : "Native descriptor identifier"
 @param interests : "Backend-neutral readiness interests"
 @require loop != null : "Loop pointer must not be null"
*>
fn void backend_delete_events(Loop* loop, int fd, uint interests) @local
{
	if ((int)loop.backend_handle < 0) return;

	Kevent[2] changes;
	Kevent[2] receipts;
	sz n = 0;
	if (interests & nova::READY_READABLE)
	{
		backend_event_set(&changes[n], fd, EVFILT_READ, EV_DELETE | EV_RECEIPT, null);
		n++;
	}
	if (interests & nova::READY_WRITABLE)
	{
		backend_event_set(&changes[n], fd, EVFILT_WRITE, EV_DELETE | EV_RECEIPT, null);
		n++;
	}
	if (n == 0) return;
	(void)backend_kevent((int)loop.backend_handle, &changes[0], n, &receipts[0], n, null);
}

<*
 Add a one-shot process exit event for a child PID.

 @param loop : "Loop that owns the kqueue backend"
 @param pid : "Child process identifier"
 @param udata : "Operation pointer stored in the kqueue event"
 @return ? nova::BACKEND_FAILED : "kevent process registration failed"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? backend_add_process_event(Loop* loop, int pid, void* udata) @local
{
	uint flags = EV_ADD | EV_ENABLE | EV_ONESHOT;
	if (backend_apply_event(loop, pid, EVFILT_PROC, flags, udata, NOTE_EXIT) < 0) return nova::BACKEND_FAILED~;
}

<*
 Initialize the macOS kqueue backend using loop-owned fixed storage.

 The event array is allocated during `Loop.init`. One extra event slot is
 reserved for the loop wake pipe.

 @param loop : "Loop being initialized"
 @return ? mem::OUT_OF_MEMORY : "Event array allocation failed"
 @return ? nova::BACKEND_FAILED : "kqueue, pipe or wake registration failed"
*>
fn void? init(Loop* loop) @inline @private
{
	sz event_capacity = loop.options.max_events + 1;
	Kevent[] events   = alloc::new_array_try(loop.allocator, Kevent, event_capacity)!;
	loop.backend_events = events.ptr;
	loop.backend_event_capacity = events.len;

	int kq = backend_open_kqueue();
	if (kq < 0)
	{
		alloc::free(loop.allocator, loop.backend_events);
		loop.backend_events = null;
		loop.backend_event_capacity = 0;
		return nova::BACKEND_FAILED~;
	}

	CInt[2] wake_fds = { -1, -1 };
	if (catch backend_open_wake_pipe(&wake_fds))
	{
		(void)libc::close(kq);
		alloc::free(loop.allocator, loop.backend_events);
		loop.backend_events = null;
		loop.backend_event_capacity = 0;
		return nova::BACKEND_FAILED~;
	}

	if (catch backend_prepare_kqueue_fd(kq))
	{
		(void)libc::close(wake_fds[0]);
		(void)libc::close(wake_fds[1]);
		(void)libc::close(kq);
		alloc::free(loop.allocator, loop.backend_events);
		loop.backend_events = null;
		loop.backend_event_capacity = 0;
		return nova::BACKEND_FAILED~;
	}
	if (catch backend_prepare_fd(wake_fds[0]))
	{
		(void)libc::close(wake_fds[0]);
		(void)libc::close(wake_fds[1]);
		(void)libc::close(kq);
		alloc::free(loop.allocator, loop.backend_events);
		loop.backend_events = null;
		loop.backend_event_capacity = 0;
		return nova::BACKEND_FAILED~;
	}
	if (catch backend_prepare_fd(wake_fds[1]))
	{
		(void)libc::close(wake_fds[0]);
		(void)libc::close(wake_fds[1]);
		(void)libc::close(kq);
		alloc::free(loop.allocator, loop.backend_events);
		loop.backend_events = null;
		loop.backend_event_capacity = 0;
		return nova::BACKEND_FAILED~;
	}

	loop.backend_handle = (NativeHandle)kq;
	loop.wake_handle = (NativeHandle)wake_fds[0];
	loop.wake_write_handle = (NativeHandle)wake_fds[1];

	if (catch backend_add_event(loop, wake_fds[0], EVFILT_READ, false, backend_wake_tag()))
	{
		destroy(loop);
		return nova::BACKEND_FAILED~;
	}
}

<*
 Create the native kqueue descriptor.

 @return "Native kqueue descriptor, or negative on failure"
*>
fn int backend_open_kqueue() @local
{
	return kqueue();
}

<*
 Prepare the kqueue descriptor after creation.

 Darwin exposes `kqueue()`, so close-on-exec is applied with fcntl.

 @param fd : "Native kqueue descriptor"
 @return ? nova::BACKEND_FAILED : "fcntl failed"
*>
fn void? backend_prepare_kqueue_fd(int fd) @local
{
	backend_set_cloexec(fd)!;
}

<*
 Create the kqueue wake pipe.

 @param [out] fds : "Wake pipe descriptors"
 @return ? nova::BACKEND_FAILED : "Pipe creation failed"
 @require fds != null : "Wake pipe output must not be null"
*>
fn void? backend_open_wake_pipe(CInt[2]* fds) @local
{
	if (posix::pipe(fds) != 0) return nova::BACKEND_FAILED~;
}

<*
 Mark a descriptor close-on-exec.

 @param fd : "Native descriptor to mark"
 @return ? nova::BACKEND_FAILED : "fcntl failed"
*>
fn void? backend_set_cloexec(int fd) @local
{
	os::NativeSocket socket = (os::NativeSocket)fd;
	int fd_flags            = backend_fcntl_retry(socket, (CInt)F_GETFD, 0);
	if (fd_flags < 0) return nova::BACKEND_FAILED~;
	if (backend_fcntl_retry(socket, (CInt)F_SETFD, fd_flags | FD_CLOEXEC) < 0) return nova::BACKEND_FAILED~;
}

<*
 Put a descriptor in close-on-exec and nonblocking mode.

 @param fd : "Native descriptor to prepare"
 @return ? nova::BACKEND_FAILED : "fcntl failed"
*>
fn void? backend_prepare_fd(int fd) @local
{
	backend_set_cloexec(fd)!;
	os::NativeSocket socket = (os::NativeSocket)fd;
	int flags               = backend_fcntl_retry(socket, (CInt)F_GETFL, 0);
	if (flags < 0) return nova::BACKEND_FAILED~;
	if (backend_fcntl_retry(socket, (CInt)F_SETFL, flags | os::O_NONBLOCK) < 0) return nova::BACKEND_FAILED~;
}

<*
 Retry kqueue backend `fcntl` while it is interrupted by `EINTR`.

 @param fd : "Native descriptor"
 @param cmd : "fcntl command"
 @param arg : "fcntl integer argument"
 @return "Native fcntl result"
*>
fn int backend_fcntl_retry(os::NativeSocket fd, CInt cmd, int arg) @local
{
	int result;
	do
	{
		result = os::fcntl(fd, cmd, arg);
	} while (result < 0 && libc::errno() == EINTR);
	return result;
}

<*
 Destroy the macOS kqueue backend.

 @param loop : "Loop whose backend is being destroyed"
*>
fn void destroy(Loop* loop) @inline @private
{
	if (!loop.initialized && !loop.backend_events && !loop.backend_event_capacity && !loop.backend_active_count)
	{
		loop.backend_handle = (NativeHandle)-1;
		loop.wake_handle = (NativeHandle)-1;
		loop.wake_write_handle = (NativeHandle)-1;
		return;
	}

	if ((int)loop.wake_write_handle >= 0) (void)libc::close((int)loop.wake_write_handle);
	if ((int)loop.wake_handle >= 0) (void)libc::close((int)loop.wake_handle);
	if ((int)loop.backend_handle >= 0) (void)libc::close((int)loop.backend_handle);
	alloc::free(loop.allocator, loop.backend_events);
	loop.backend_handle = (NativeHandle)-1;
	loop.wake_handle = (NativeHandle)-1;
	loop.wake_write_handle = (NativeHandle)-1;
	loop.backend_events = null;
	loop.backend_event_capacity = 0;
	loop.backend_active_count = 0;
}

<*
 Submit a one-shot generic watch operation to kqueue.

 @param loop : "Initialized loop"
 @param op : "Caller-owned watch operation header"
 @param state : "Caller-owned backend state embedded in the watch operation"
 @param handle : "Borrowed native descriptor"
 @param interests : "Normalized watch interests"
 @param callback : "Typed dispatch trampoline"
 @param owner : "Typed watch handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized or interests are invalid"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
*>
fn Ref? watch_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	NativeHandle handle,
	uint interests,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;
	if (!(interests & (nova::READY_READABLE | nova::READY_WRITABLE))) return nova::INVALID_STATE~;

	if (catch backend_register_events(
		loop,
		(int)handle,
		interests,
		true,
		backend_op_tag(op)
	)) return nova::BACKEND_FAILED~;

	op::init_header(op, Kind.WATCH, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, interests);
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Submit a kqueue process wait operation using `EVFILT_PROC | NOTE_EXIT`.

 The handle argument is a child PID, not an owned file descriptor. The process
 module performs the `waitpid` reap after this backend reports readiness.

 @param loop : "Initialized loop"
 @param op : "Process operation header"
 @param state : "Process-owned backend wait state"
 @param handle : "Child process identifier"
 @param callback : "Typed dispatch trampoline"
 @param owner : "Process handle"
 @param userdata : "Opaque user pointer captured by the process operation"
 @return "Generation-checked reference for the active process wait"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized or the child PID is not positive"
 @return ? nova::BUSY : "Process header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "kevent process registration failed"
*>
fn Ref? process_wait_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;
	if ((int)handle <= 0) return nova::INVALID_STATE~;

	backend_add_process_event(loop, (int)handle, backend_op_tag(op))!;

	op::init_header(op, Kind.PROCESS, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, null, 0);
	loop.backend_active_count++;
	state.counted = true;
	return op.to_ref();
}

<*
 Submit or attach the listener-owned TCP accept readiness driver.

 @param loop : "Initialized loop"
 @param op : "Listener-owned accept driver operation"
 @param state : "Listener-owned backend state for the accept driver"
 @param watcher : "Listener-owned backend watcher"
 @param handle : "Native listener descriptor"
 @param callback : "Driver dispatch trampoline"
 @param owner : "Typed listener handle"
 @return "Generation-checked reference for the active driver"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Driver operation is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
*>
fn Ref? tcp_accept_driver_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	backend_register_tcp_listener(loop, watcher, handle)!;

	op::init_header(op, Kind.TCP_ACCEPT_DRIVER, loop, callback, owner, null);
	backend::attach_op_state(op, state, handle, watcher, nova::READY_READABLE);
	backend::backend_wait_read(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit a TCP connect operation, optionally already completed by the platform.

 @param loop : "Initialized loop"
 @param op : "Caller-owned connect operation header"
 @param state : "Caller-owned backend state embedded in the connect operation"
 @param watcher : "Persistent stream watcher"
 @param handle : "Native stream descriptor"
 @param complete : "Whether connect already reached a terminal result"
 @param status : "Immediate terminal status when complete"
 @param callback : "Typed connect dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
*>
fn Ref? tcp_connect_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	bool complete,
	fault status,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (!complete && loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	if (!complete) backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.TCP_CONNECT, loop, callback, owner, userdata);

	if (complete)
	{
		nova::queue_ready(loop, op, status);
		return op.to_ref();
	}

	backend::attach_op_state(op, state, handle, watcher, nova::READY_WRITABLE);
	backend::backend_wait_write(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit a stream read operation to kqueue readiness.

 @param loop : "Initialized loop"
 @param op : "Caller-owned read operation header"
 @param state : "Caller-owned backend state embedded in the read operation"
 @param watcher : "Persistent stream watcher"
 @param handle : "Native stream descriptor"
 @param callback : "Typed read dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
*>
fn Ref? stream_read_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.STREAM_READ, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, watcher, nova::READY_READABLE);
	backend::backend_wait_read(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit a stream write operation to kqueue readiness.

 @param loop : "Initialized loop"
 @param op : "Caller-owned write operation header"
 @param state : "Caller-owned backend state embedded in the write operation"
 @param watcher : "Persistent stream watcher"
 @param handle : "Native stream descriptor"
 @param callback : "Typed write dispatch trampoline"
 @param owner : "Typed stream handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
*>
fn Ref? stream_write_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.STREAM_WRITE, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, watcher, nova::READY_WRITABLE);
	backend::backend_wait_write(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit a one-shot UDP receive readiness operation.

 @param loop : "Initialized loop"
 @param op : "Caller-owned receive operation header"
 @param state : "Caller-owned backend state embedded in the receive operation"
 @param handle : "Native datagram descriptor"
 @param callback : "Typed receive dispatch trampoline"
 @param owner : "Typed UDP socket handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
*>
fn Ref? udp_recv_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.UDP_RECV, loop, callback, owner, userdata);
	backend::attach_op_state(op, state, handle, watcher, nova::READY_READABLE);
	backend::backend_wait_read(loop, watcher, op);
	return op.to_ref();
}

<*
 Submit a UDP send operation, optionally already completed by the platform.

 @param loop : "Initialized loop"
 @param op : "Caller-owned send operation header"
 @param state : "Caller-owned backend state embedded in the send operation"
 @param handle : "Native datagram descriptor"
 @param complete : "Whether send already reached a terminal result"
 @param status : "Immediate terminal status when complete"
 @param callback : "Typed send dispatch trampoline"
 @param owner : "Typed UDP socket handle"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Loop backend is not initialized"
 @return ? nova::BUSY : "Header is already active"
 @return ? CAPACITY_EXCEEDED : "Loop has no backend event capacity"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
*>
fn Ref? udp_send_submit(
	Loop* loop,
	Header* op,
	backend::OpState* state,
	backend::Watcher* watcher,
	NativeHandle handle,
	bool complete,
	fault status,
	OperationCallback callback,
	void* owner,
	void* userdata
) @inline @private
{
	if (!complete && loop.options.max_events <= 0) return CAPACITY_EXCEEDED~;

	if (!complete) backend_register_stream(loop, watcher, handle)!;

	op::init_header(op, Kind.UDP_SEND, loop, callback, owner, userdata);

	if (!complete)
	{
		backend::attach_op_state(op, state, handle, watcher, nova::READY_WRITABLE);
		backend::backend_wait_write(loop, watcher, op);
	}

	if (complete) nova::queue_ready(loop, op, status);
	return op.to_ref();
}

<*
 Rearm a TCP accept driver after stale readiness.

 @param loop : "Loop that owns the accept operation"
 @param op : "TCP accept or accept-driver operation to rearm"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
 @require op.kind == Kind.TCP_ACCEPT || op.kind == Kind.TCP_ACCEPT_DRIVER : "Only TCP accept operations can be rearmed"
 @require op.loop == loop : "Accept operation must belong to this loop"
*>
fn void? tcp_accept_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_read(loop, state.watcher, op);
}

<*
 Rearm a stream read operation after stale readiness.

 @param loop : "Loop that owns the read operation"
 @param op : "Stream read operation to rearm"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
 @require op.kind == Kind.STREAM_READ : "Only stream read operations can be rearmed"
 @require op.loop == loop : "Read operation must belong to this loop"
*>
fn void? stream_read_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_read(loop, state.watcher, op);
}

<*
 Rearm a stream write operation after stale readiness.

 @param loop : "Loop that owns the write operation"
 @param op : "Stream write operation to rearm"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
 @require op.kind == Kind.STREAM_WRITE : "Only stream write operations can be rearmed"
 @require op.loop == loop : "Write operation must belong to this loop"
*>
fn void? stream_write_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_write(loop, state.watcher, op);
}

<*
 Rearm a one-shot UDP receive event after stale readiness.

 @param loop : "Loop that owns the receive operation"
 @param op : "UDP receive operation to rearm"
 @require op.kind == Kind.UDP_RECV : "Only UDP receive operations can be rearmed"
 @require op.loop == loop : "Receive operation must belong to this loop"
*>
fn void? udp_recv_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_read(loop, state.watcher, op);
}

<*
 Rearm a one-shot UDP send event after stale readiness.

 @param loop : "Loop that owns the send operation"
 @param op : "UDP send operation to rearm"
 @require op.kind == Kind.UDP_SEND : "Only UDP send operations can be rearmed"
 @require op.loop == loop : "Send operation must belong to this loop"
*>
fn void? udp_send_rearm(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	always_assert(state != null && state.watcher != null);
	op.terminal_status = { };
	op.ready_flags = 0;
	op.state = State.OP_ACTIVE;
	backend::backend_wait_write(loop, state.watcher, op);
}

<*
 Poll kqueue and queue ready operations.

 @param loop : "Loop that owns the kqueue backend"
 @param timeout_ms : "kevent timeout in milliseconds"
 @return "Number of backend events consumed"
*>
fn sz poll(Loop* loop, int timeout_ms) @inline @private
{
	if ((int)loop.backend_handle < 0 || loop.backend_event_capacity <= 0) return 0;

	TimeSpec timeout;
	TimeSpec* timeout_ptr = null;
	if (timeout_ms >= 0)
	{
		timeout.s = (Time_t)(timeout_ms / 1000);
		timeout.ns = (CLong)((timeout_ms % 1000) * 1000000);
		timeout_ptr = &timeout;
	}

	Kevent* events = (Kevent*)loop.backend_events;
	int count = backend_kevent((int)loop.backend_handle, null, 0, events, loop.backend_event_capacity, timeout_ptr);
	if (count <= 0) return 0;

	sz progress = 0;
	for (int i = 0; i < count; i++)
	{
		if (backend_event_is_wake(&events[i]))
		{
			backend_drain_wake(loop);
			progress++;
			continue;
		}
		if (backend_event_is_watcher(&events[i]))
		{
			backend::Watcher* watcher = backend_event_watcher(&events[i]);
			progress += backend::backend_watcher_ready(loop, watcher, ready_flags_from_kqueue_event(&events[i]));
			continue;
		}

		Header* op = (Header*)events[i].udata;
		if (op.loop != loop || op.state != State.OP_ACTIVE) continue;

		if (op.kind == Kind.WATCH || op.kind == Kind.PROCESS)
		{
			uint ready    = ready_flags_from_kqueue_event(&events[i]);
			uint interest = op.backend.interest;
			if (op.kind == Kind.WATCH && (interest & nova::READY_READABLE) != 0
				&& (interest & nova::READY_WRITABLE) != 0)
			{
				for (int j = i + 1; j < count; j++)
				{
					if (backend_event_is_wake(&events[j]) || backend_event_is_watcher(&events[j])) continue;
					if ((Header*)events[j].udata == op) ready |= ready_flags_from_kqueue_event(&events[j]);
				}
			}
			op.ready_flags = ready;
			unregister_fired_op(loop, op, ready);
			nova::queue_ready(loop, op, nova::ok_status());
			progress++;
		}
	}
	return progress;
}

<*
 Remove backend interest for an active operation and clear its native handle.

 @param loop : "Loop that owns the kqueue backend"
 @param op : "Header registered with kqueue"
*>
fn void backend_unregister_op(Loop* loop, Header* op) @inline @private
{
	backend::OpState* state = op.backend;
	if (!state) return;
	if (state.counted && (int)loop.backend_handle >= 0)
	{
		if (op.kind == Kind.PROCESS)
		{
			backend_delete_event(loop, (int)state.handle, EVFILT_PROC);
		}
		else
		{
			backend_delete_events(loop, (int)state.handle, state.interest);
		}
		backend::backend_mark_inactive(loop);
	}
	backend::reset_op_state(state);
}

<*
 Detach a one-shot operation whose event just fired without re-issuing a delete
 for the filter the kernel already removed.

 An `EV_ONESHOT` filter is auto-removed by the kernel when it delivers its event,
 so deleting it again is a wasted `kevent` syscall that returns `ENOENT`. Only a
 watcher filter whose direction did not fire this batch (not covered by `fired`)
 is still registered and must be deleted.

 @param loop : "Loop that owns the kqueue backend"
 @param op : "Operation whose event fired"
 @param fired : "Readiness directions delivered for this op this batch"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Header pointer must not be null"
*>
fn void unregister_fired_op(Loop* loop, Header* op, uint fired) @inline @local
{
	backend::OpState* state = op.backend;
	if (!state) return;
	if (state.counted && (int)loop.backend_handle >= 0)
	{
		if (op.kind != Kind.PROCESS)
		{
			uint remaining = state.interest & ~fired & (nova::READY_READABLE | nova::READY_WRITABLE);
			if (remaining) backend_delete_events(loop, (int)state.handle, remaining);
		}
		backend::backend_mark_inactive(loop);
	}
	backend::reset_op_state(state);
}

<*
 Register or move a listener watcher to a native descriptor.

 @param loop : "Loop that owns the kqueue backend"
 @param watcher : "Persistent listener watcher"
 @param handle : "Native listener descriptor"
 @return ? nova::INVALID_STATE : "backend::Watcher is registered on another loop"
 @return ? nova::BUSY : "backend::Watcher still has active operations"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "backend::Watcher pointer must not be null"
*>
fn void? backend_register_tcp_listener(Loop* loop, backend::Watcher* watcher, NativeHandle handle) @private
{
	if (watcher.registered)
	{
		if (watcher.loop != loop) return nova::INVALID_STATE~;
		if (watcher.handle == handle) return;
		if (watcher.read_op || watcher.write_op || watcher.read_counted || watcher.write_counted) return nova::BUSY~;
		backend_delete_events(loop, (int)watcher.handle, watcher.interests);
		watcher.registered = false;
		watcher.ready_flags = 0;
	}

	backend_register_events(loop, (int)handle, nova::READY_READABLE, false, backend_watcher_tag(watcher))!;

	watcher.loop = loop;
	watcher.handle = handle;
	watcher.interests = nova::READY_READABLE;
	watcher.registered = true;
}

<*
 Register or move a stream watcher to a native descriptor.

 @param loop : "Loop that owns the kqueue backend"
 @param watcher : "Persistent stream watcher"
 @param handle : "Native stream descriptor"
 @return ? nova::INVALID_STATE : "backend::Watcher is registered on another loop"
 @return ? nova::BUSY : "backend::Watcher still has active operations"
 @return ? nova::BACKEND_FAILED : "kqueue event registration failed"
 @require loop != null : "Loop pointer must not be null"
 @require watcher != null : "backend::Watcher pointer must not be null"
*>
fn void? backend_register_stream(Loop* loop, backend::Watcher* watcher, NativeHandle handle) @private
{
	if (watcher.registered)
	{
		if (watcher.loop != loop) return nova::INVALID_STATE~;
		if (watcher.handle == handle) return;
		if (watcher.read_op || watcher.write_op || watcher.read_counted || watcher.write_counted) return nova::BUSY~;
		backend_delete_events(loop, (int)watcher.handle, watcher.interests);
		watcher.registered = false;
		watcher.ready_flags = 0;
	}

	backend_register_events(
		loop,
		(int)handle,
		nova::READY_READABLE | nova::READY_WRITABLE,
		false,
		backend_watcher_tag(watcher)
	)!;

	watcher.loop = loop;
	watcher.handle = handle;
	watcher.interests = nova::READY_READABLE | nova::READY_WRITABLE;
	watcher.registered = true;
}

<*
 Remove a watcher from kqueue and release any activity counted for attached operations.

 @param loop : "Loop that owns the watcher"
 @param watcher : "backend::Watcher to close"
*>
fn void watcher_close(Loop* loop, backend::Watcher* watcher) @inline @private
{
	if (watcher.read_counted) backend::backend_mark_inactive(loop);
	if (watcher.write_counted) backend::backend_mark_inactive(loop);

	if (watcher.registered && (int)loop.backend_handle >= 0)
	{
		backend_delete_events(loop, (int)watcher.handle, watcher.interests);
	}
	*watcher = { };
}

<*
 Wake a loop blocked in kqueue.

 Multiple wake calls may coalesce in the nonblocking pipe.

 @param loop : "Loop whose wake pipe is signaled"
 @return ? nova::INVALID_STATE : "Wake source is not initialized"
 @return ? nova::BACKEND_FAILED : "Pipe write failed"
*>
fn void? wake(Loop* loop) @inline @private
{
	if ((int)loop.wake_write_handle < 0) return nova::INVALID_STATE~;

	char value = 1;
	bool done  = false;
	while (!done)
	{
		sz written = libc::write((int)loop.wake_write_handle, &value, 1);
		if (written == 1)
		{
			done = true;
			continue;
		}
		Errno err = libc::errno();
		if (err == EAGAIN)
		{
			done = true;
			continue;
		}
		if (err != EINTR) return nova::BACKEND_FAILED~;
	}
}

<*
 Drain all pending pipe wake notifications.

 @param loop : "Loop whose wake pipe is drained"
 @require loop != null : "Loop pointer must not be null"
*>
fn void backend_drain_wake(Loop* loop) @private
{
	if ((int)loop.wake_handle >= 0)
	{
		char[64] buffer;
		bool draining = true;
		while (draining)
		{
			sz read = libc::read((int)loop.wake_handle, &buffer, (usz)buffer.len);
			if (read > 0) continue;
			if (read < 0 && libc::errno() == EINTR) continue;
			draining = false;
		}
	}
}

<*
 Convert native kqueue event flags into runtime readiness flags.

 @param event : "Native kqueue event"
 @return "Backend-neutral readiness flags"
 @require event != null : "Kqueue event pointer must not be null"
*>
fn uint ready_flags_from_kqueue_event(Kevent* event) @local
{
	uint flags = 0;
	if (event.filter == EVFILT_READ) flags |= nova::READY_READABLE;
	if (event.filter == EVFILT_WRITE) flags |= nova::READY_WRITABLE;
	if ((uint)event.flags & EV_ERROR) flags |= nova::READY_ERROR;
	if ((uint)event.flags & EV_EOF) flags |= nova::READY_HANGUP;
	return flags;
}
