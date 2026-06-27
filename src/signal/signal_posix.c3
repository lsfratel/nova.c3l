module nova::signal;

import std::atomic, std::os::posix, std::thread;
import libc;

import nova @norecurse;
import nova::op @public;
import nova::posix_errno @public;

<*
 Native signal and file descriptor constants used by the POSIX signal bridge.
*>
const CInt SIGNAL_SIG_SETMASK    = env::LINUX ? 2 : 3;
const CInt SIGNAL_F_GETFD        = 1;
const CInt SIGNAL_F_SETFD        = 2;
const CInt SIGNAL_FD_CLOEXEC     = 1;
const CInt SIGNAL_O_CLOEXEC      = env::LINUX ? 0o2000000 : 0x01000000;
const sz SIGNAL_HANDLER_CAPACITY = 128;
const CInt SIGNAL_SLOT_COUNT     = 65;

<*
 Native signal-mask and descriptor-control calls used by the POSIX bridge.
*>
extern fn CInt sigfillset(libc::Sigset_t* set);
extern fn CInt pthread_sigmask(CInt how, libc::Sigset_t* set, libc::Sigset_t* oldset);
extern fn CInt fcntl(CInt fd, CInt cmd, ...);
extern fn CInt signal_pipe2(CInt[2]* pipes, CInt flags) @cname("pipe2") @if(env::LINUX);
extern fn CInt native_sigaction(CInt signum, NativeSigaction* action, NativeSigaction* oldaction) @cname("sigaction");

<*
 Native `struct sigaction` with the field order the kernel actually uses.

 The c3c stdlib `libc::Sigaction` swaps `sa_mask` and `sa_flags` on Darwin (its
 kernel layout is handler, then mask, then flags). Using that struct makes
 `sigfillset(&sa_mask)` write into the kernel's `sa_flags`, enabling
 `SA_RESETHAND` and resetting the handler to the default disposition after the
 first delivery. Nova owns this layout so handler installation targets the
 correct native fields. Both supported platforms order mask before flags; Linux
 additionally carries `sa_restorer`.
*>
struct NativeSigaction
{
	libc::SignalFunction sa_handler;
	libc::Sigset_t sa_mask;
	CInt sa_flags;
	void* sa_restorer @if(env::LINUX);
}

<*
 Process-global native handler registration slot.
*>
struct SignalHandlerRecord
{
	CInt signum;
	NativeSigaction previous;
	bool active;
}

<*
 Process-global state shared by native signal handlers and loop drains.

 POSIX delivers signals to the process, so the registry buckets, handler table, and
 async-signal-safe lock pipe must be a single process-wide instance. Grouping
 them here keeps that shared surface in one named place.

 `buckets` indexes registered operations by signal number (`global_next`/
 `global_prev` link operations within a bucket), so the async signal handler and
 the install/uninstall decisions touch only operations for the delivered signal
 instead of scanning every registered operation.
*>
struct SignalGlobalState
{
	CInt[2] lock_pipe;
	thread::OnceFlag once;
	bool init_failed;
	SignalOp*[SIGNAL_SLOT_COUNT] buckets;
	SignalHandlerRecord[SIGNAL_HANDLER_CAPACITY] handler_records;
}

SignalGlobalState signal_state = { .lock_pipe = { -1, -1 } };

<*
 Initialize process-wide signal registry state once.
*>
fn void signal_once_init() @local
{
	CInt[2] pipes = { -1, -1 };
	bool prepared = false;
	$if env::LINUX:
		if (signal_pipe2(&pipes, SIGNAL_O_CLOEXEC) == 0)
		{
			prepared = true;
		}
		else
		{
			Errno err = libc::errno();
			if (err != posix_errno::E_INVAL && err != posix_errno::E_NOSYS)
			{
				signal_state.init_failed = true;
				return;
			}
		}
	$endif
	if (!prepared && posix::pipe(&pipes) != 0)
	{
		signal_state.init_failed = true;
		return;
	}
	if (!prepared && (!signal_prepare_pipe_fd(pipes[0]) || !signal_prepare_pipe_fd(pipes[1])))
	{
		(void)libc::close(pipes[0]);
		(void)libc::close(pipes[1]);
		signal_state.init_failed = true;
		return;
	}
	signal_state.lock_pipe[0] = pipes[0];
	signal_state.lock_pipe[1] = pipes[1];
	if (!signal_unlock_raw())
	{
		(void)libc::close(pipes[0]);
		(void)libc::close(pipes[1]);
		signal_state.lock_pipe[0] = -1;
		signal_state.lock_pipe[1] = -1;
		signal_state.init_failed = true;
	}
}

<*
 Ensure process-wide signal registry state is initialized.

 @return ? nova::BACKEND_FAILED : "Signal lock pipe initialization failed"
*>
fn void? signal_global_init() @local
{
	signal_state.once.call(&signal_once_init);
	if (signal_state.init_failed || signal_state.lock_pipe[0] < 0
		|| signal_state.lock_pipe[1] < 0) return nova::BACKEND_FAILED~;
}

<*
 Submit a signal watcher owned by the current loop thread.

 @param loop : "Loop that owns the signal operation"
 @param op : "Caller-owned signal operation header"
 @param signum : "Native signal number to observe"
 @param oneshot : "Stop after the first delivered signal"
 @param callback : "Typed dispatch trampoline"
 @param owner : "Typed signal operation storage"
 @param userdata : "Opaque user pointer captured by this operation"
 @return "Generation-checked reference for the submitted operation"
 @return ? nova::INVALID_STATE : "Signal number is invalid"
 @return ? nova::BACKEND_FAILED : "Signal handler registration failed"
*>
fn Ref? submit(
	Loop* loop,
	SignalOp* op,
	CInt signum,
	bool oneshot,
	OperationCallback callback,
	void* owner,
	void* userdata
)
{
	if (!valid(signum)) return nova::INVALID_STATE~;
	signal_global_init()!;

	op::init_header(&op.header, Kind.SIGNAL, loop, callback, owner, userdata);
	op.signum = signum;
	op.oneshot = oneshot;
	signal_attach_loop(loop, op);
	if (catch err = signal_register(op))
	{
		signal_detach_loop(loop, op);
		op::reset_header(&op.header);
		return err~;
	}
	return op.header.to_ref();
}

<*
 Remove a signal operation from process and loop registries.

 @param loop : "Loop that owns the signal operation"
 @param header : "Registered signal operation header"
 @require loop != null : "Loop pointer must not be null"
 @require header != null : "Header pointer must not be null"
*>
fn void unregister(Loop* loop, Header* header)
{
	SignalOp* op = signal_from_header(header);
	if (!op) return;
	if (!op.registered && !op.loop_prev && !op.loop_next && loop.signal_head != op) return;
	signal_unregister_global(op);
	signal_detach_loop(loop, op);
	op.registered = false;
}

<*
 Drain pending process signal notifications for one loop.

 @param loop : "Loop that owns signal operations"
 @return "Number of signal operations queued for callback dispatch"
 @require loop != null : "Loop pointer must not be null"
 @require loop.initialized : "Loop must be initialized"
*>
fn sz drain(Loop* loop)
{
	sz progress  = 0;
	SignalOp* op = loop.signal_head;
	while (op)
	{
		SignalOp* next = op.loop_next;
		if (op.header.state == State.OP_ACTIVE)
		{
			uint count = signal_take_pending(op);
			if (count > 0)
			{
				op.ready_count = (ulong)count;
				if (op.oneshot) unregister(loop, &op.header);
				nova::queue_ready(loop, &op.header, nova::ok_status());
				progress++;
			}
		}
		op = next;
	}
	return progress;
}

<*
 Report whether a native signal number may be observed.

 @param signum : "Native signal number"
 @return "True when the signal can be handled by the runtime"
*>
fn bool valid(CInt signum)
{
	if (signum <= 0 || signum >= SIGNAL_SLOT_COUNT) return false;
	if (signum == libc::SIGKILL || signum == libc::SIGSTOP) return false;
	return true;
}

<*
 Link a signal operation into its owner loop.

 @param loop : "Loop that owns the signal operation"
 @param op : "Signal operation to link"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Signal operation pointer must not be null"
*>
fn void signal_attach_loop(Loop* loop, SignalOp* op) @local
{
	op.loop_next = null;
	op.loop_prev = loop.signal_tail;
	if (loop.signal_tail)
	{
		loop.signal_tail.loop_next = op;
	}
	else
	{
		loop.signal_head = op;
	}
	loop.signal_tail = op;
	loop.signal_count++;
}

<*
 Unlink a signal operation from its owner loop.

 @param loop : "Loop that owns the signal operation"
 @param op : "Signal operation to unlink"
 @require loop != null : "Loop pointer must not be null"
 @require op != null : "Signal operation pointer must not be null"
*>
fn void signal_detach_loop(Loop* loop, SignalOp* op) @local
{
	if (op.loop_prev)
	{
		op.loop_prev.loop_next = op.loop_next;
	}
	else if (loop.signal_head == op)
	{
		loop.signal_head = op.loop_next;
	}
	if (op.loop_next)
	{
		op.loop_next.loop_prev = op.loop_prev;
	}
	else if (loop.signal_tail == op)
	{
		loop.signal_tail = op.loop_prev;
	}
	if (loop.signal_count > 0) loop.signal_count--;
	op.loop_next = null;
	op.loop_prev = null;
}

<*
 Atomically take the pending delivery count for a signal operation.

 @param op : "Signal operation to drain"
 @return "Number of pending signal deliveries"
 @require op != null : "Signal operation pointer must not be null"
*>
fn uint signal_take_pending(SignalOp* op) @local
{
	while (true)
	{
		uint count = @atomic_load(op.pending);
		if (!count) return 0;
		if (mem::compare_exchange(&op.pending, count, (uint)0) == count) return count;
	}
}

<*
 Block process signals in the current thread and take the signal-safe lock.

 @param [out] saved : "Previous thread signal mask"
 @require saved != null : "Saved mask pointer must not be null"
*>
fn void signal_block_and_lock(libc::Sigset_t* saved) @local
{
	libc::Sigset_t mask;
	if (sigfillset(&mask) != 0) abort("sigfillset failed");
	if (pthread_sigmask(SIGNAL_SIG_SETMASK, &mask, saved) != 0) abort("pthread_sigmask failed");
	if (!signal_lock_raw()) abort("signal lock failed");
}

<*
 Release the signal-safe lock and restore the previous thread signal mask.

 @param saved : "Previous thread signal mask"
 @require saved != null : "Saved mask pointer must not be null"
*>
fn void signal_unlock_and_unblock(libc::Sigset_t* saved) @local
{
	if (!signal_unlock_raw()) abort("signal unlock failed");
	if (pthread_sigmask(SIGNAL_SIG_SETMASK, saved, null) != 0) abort("pthread_sigmask restore failed");
}

<*
 Take the process-wide signal registry lock using async-signal-safe syscalls.

 @return "True when the lock token was acquired"
*>
fn bool signal_lock_raw() @local
{
	char value;
	while (true)
	{
		sz read = libc::read(signal_state.lock_pipe[0], &value, 1);
		if (read == 1) return true;
		if (read < 0 && libc::errno() == EINTR) continue;
		return false;
	}
}

<*
 Release the process-wide signal registry lock using async-signal-safe syscalls.

 @return "True when the lock token was released"
*>
fn bool signal_unlock_raw() @local
{
	char value = 1;
	while (true)
	{
		sz written = libc::write(signal_state.lock_pipe[1], &value, 1);
		if (written == 1) return true;
		if (written < 0 && libc::errno() == EINTR) continue;
		return false;
	}
}

<*
 Put one signal lock pipe descriptor in close-on-exec mode.

 @param fd : "Pipe descriptor to prepare"
 @return "True when the descriptor flags were updated"
*>
fn bool signal_prepare_pipe_fd(CInt fd) @local
{
	CInt flags = signal_fcntl_retry(fd, SIGNAL_F_GETFD, 0);
	if (flags < 0) return false;
	return signal_fcntl_retry(fd, SIGNAL_F_SETFD, flags | SIGNAL_FD_CLOEXEC) == 0;
}

<*
 Retry signal bridge `fcntl` while it is interrupted by `EINTR`.

 @param fd : "Native descriptor"
 @param cmd : "fcntl command"
 @param arg : "fcntl integer argument"
 @return "Native fcntl result"
*>
fn CInt signal_fcntl_retry(CInt fd, CInt cmd, CInt arg) @local
{
	CInt result;
	do
	{
		result = fcntl(fd, cmd, arg);
	} while (result < 0 && libc::errno() == EINTR);
	return result;
}

<*
 Find the first registered operation for a native signal number.

 @param signum : "Native signal number"
 @return "First matching operation, or null"
*>
fn SignalOp* signal_first(CInt signum) @local
{
	if (signum < 1 || signum >= SIGNAL_SLOT_COUNT) return null;
	return signal_state.buckets[signum];
}

<*
 Register a signal operation in the process-wide registry.

 @param op : "Signal operation to register"
 @return ? nova::BACKEND_FAILED : "Native signal handler registration failed"
 @require op != null : "Signal operation pointer must not be null"
*>
fn void? signal_register(SignalOp* op) @local
{
	libc::Sigset_t saved;
	signal_block_and_lock(&saved);

	bool install = signal_first(op.signum) == null;
	op.global_prev = null;
	op.global_next = signal_state.buckets[op.signum];
	if (op.global_next) op.global_next.global_prev = op;
	signal_state.buckets[op.signum] = op;
	op.registered = true;

	if (install && !signal_register_handler(op.signum))
	{
		signal_unregister_global_locked(op);
		signal_unlock_and_unblock(&saved);
		return nova::BACKEND_FAILED~;
	}

	signal_unlock_and_unblock(&saved);
	return;
}

<*
 Remove a signal operation from the process-wide registry.

 @param op : "Signal operation to unregister"
 @require op != null : "Signal operation pointer must not be null"
*>
fn void signal_unregister_global(SignalOp* op) @local
{
	if (!op.registered) return;
	libc::Sigset_t saved;
	signal_block_and_lock(&saved);
	signal_unregister_global_locked(op);
	if (signal_first(op.signum) == null) signal_unregister_handler(op.signum);
	signal_unlock_and_unblock(&saved);
}

<*
 Unlink a signal operation while the process-wide registry lock is held.

 @param op : "Signal operation to unlink"
 @require op != null : "Signal operation pointer must not be null"
*>
fn void signal_unregister_global_locked(SignalOp* op) @local
{
	if (op.global_prev)
	{
		op.global_prev.global_next = op.global_next;
	}
	else if (op.signum >= 1 && op.signum < SIGNAL_SLOT_COUNT && signal_state.buckets[op.signum] == op)
	{
		signal_state.buckets[op.signum] = op.global_next;
	}
	if (op.global_next) op.global_next.global_prev = op.global_prev;
	op.global_next = null;
	op.global_prev = null;
	op.registered = false;
}

<*
 Install the native handler for a signal number.

 @param signum : "Native signal number"
 @return "True when the native handler was installed"
*>
fn bool signal_register_handler(CInt signum) @local
{
	if (signal_find_handler_record(signum)) return true;
	SignalHandlerRecord* record = signal_free_handler_record();
	if (!record) return false;

	NativeSigaction action;
	NativeSigaction previous;
	action.sa_handler = &signal_handler;
	action.sa_flags = (CInt)libc::SA_RESTART;
	if (sigfillset(&action.sa_mask) != 0) return false;
	if (native_sigaction(signum, &action, &previous) != 0) return false;
	record.signum = signum;
	record.previous = previous;
	record.active = true;
	return true;
}

<*
 Restore the native handling that was active before nova installed its handler.

 @param signum : "Native signal number"
*>
fn void signal_unregister_handler(CInt signum) @local
{
	SignalHandlerRecord* record = signal_find_handler_record(signum);
	if (!record) return;
	NativeSigaction current;
	if (native_sigaction(signum, null, &current) == 0 && current.sa_handler == &signal_handler)
	{
		(void)native_sigaction(signum, &record.previous, null);
	}
	*record = { };
}

<*
 Native signal trampoline.

 @param signum : "Delivered native signal number"
*>
fn void signal_handler(CInt signum) @local
{
	Errno saved_errno = libc::errno();
	if (!signal_lock_raw())
	{
		libc::errno_set(saved_errno);
		return;
	}
	if (signum >= 1 && signum < SIGNAL_SLOT_COUNT)
	{
		for (SignalOp* op = signal_state.buckets[signum]; op; op = op.global_next)
		{
			(void)atomic::fetch_add(&op.pending, (uint)1);
			signal_wake_loop(op.header.loop);
		}
	}
	(void)signal_unlock_raw();
	libc::errno_set(saved_errno);
}

<*
 Wake a loop from the native signal handler path.

 @param loop : "Loop to wake"
*>
fn void signal_wake_loop(Loop* loop) @local
{
	if (!loop || !loop.initialized) return;
	$if env::LINUX:
		if ((int)loop.wake_handle < 0) return;
		ulong value = 1;
		signal_write_wake((int)loop.wake_handle, &value, (usz)ulong::size);
	$else
		if ((int)loop.wake_write_handle < 0) return;
		char value = 1;
		signal_write_wake((int)loop.wake_write_handle, &value, 1);
	$endif
}

<*
 Write a backend wake notification from the signal handler path.

 `EAGAIN` means the nonblocking wake source is already signaled. `EINTR` is
 retried so pending signal counters cannot be left sleeping behind an
 interrupted wake write.

 @param fd : "Wake file descriptor"
 @param value : "Wake payload"
 @param len : "Payload size"
 @require value != null : "Wake payload pointer must not be null"
*>
fn void signal_write_wake(CInt fd, void* value, usz len) @local
{
	while (true)
	{
		sz written = libc::write(fd, value, len);
		if (written == (sz)len) return;
		if (written >= 0) return;
		Errno err = libc::errno();
		if (err == EAGAIN || err == EWOULDBLOCK) return;
		if (err != EINTR) return;
	}
}

<*
 Return the saved native handler record for a signal number.

 @param signum : "Native signal number"
 @return "Saved handler record, or null"
*>
fn SignalHandlerRecord* signal_find_handler_record(CInt signum) @local
{
	for (sz i = 0; i < SIGNAL_HANDLER_CAPACITY; i++)
	{
		if (signal_state.handler_records[i].active
			&& signal_state.handler_records[i].signum == signum) return &signal_state.handler_records[i];
	}
	return null;
}

<*
 Return unused storage for a native handler record.

 @return "Free handler record, or null"
*>
fn SignalHandlerRecord* signal_free_handler_record() @local
{
	for (sz i = 0; i < SIGNAL_HANDLER_CAPACITY; i++)
	{
		if (!signal_state.handler_records[i].active) return &signal_state.handler_records[i];
	}
	return null;
}

<*
 Recover typed signal storage from an active signal header.

 @param header : "Signal operation header"
 @return "Typed signal operation storage, or null when the header is not a signal"
 @require header != null : "Header pointer must not be null"
*>
fn SignalOp* signal_from_header(Header* header) @local
{
	if (!header || header.kind != Kind.SIGNAL) return null;
	return (SignalOp*)header.owner;
}
