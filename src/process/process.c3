module nova::process;

import std::io;

import nova @norecurse;
import nova::backend @public;
import nova::op @public;
import nova::pipe;

<*
 Callback invoked on the loop owner thread after process exit is observed.

 @param loop : "Loop dispatching the process exit"
 @param process : "Process handle that exited"
 @param result : "Exit result valid during the callback"
 @param userdata : "Submission userdata"
*>
alias Callback = fn void(Loop* loop, Process* process, ExitResult* result, void* userdata);

<*
 Child stdio action.

 `IGNORE` redirects standard descriptors to the platform null device.
 `INHERIT` keeps the parent's descriptor. `FD` duplicates a caller-provided
 native handle. `PIPE` creates a nova pipe endpoint for parent-child I/O.
*>
constdef StdioAction : inline char
{
	IGNORE  = 0,
	INHERIT = 1,
	FD      = 2,
	PIPE    = 3,
}

<*
 Portable process identifier exposed by nova process APIs.
*>
typedef Pid = inline int;

<*
 One child stdio descriptor configuration.

 `fd` is used only when `action == FD`.
*>
struct Stdio
{
	StdioAction action;
	NativeHandle fd;
}

<*
 Child process spawn configuration.

 `file` is argv[0]. `args` contains arguments after argv[0].
 Empty `cwd` inherits the parent's current directory. `env` is used only when
 `inherit_env == false`.
*>
struct SpawnOptions
{
	String file;
	String[] args;
	String[] env;
	String cwd;
	Stdio stdin;
	Stdio stdout;
	Stdio stderr;
	bool inherit_env;
	bool search_path;
	bool detached;
	bool stderr_to_stdout;
}

<*
 Result delivered when a child process is reaped.

 A non-zero exit status is reported as data, not as `error.status`.
*>
struct ExitResult
{
	ErrorInfo error;
	Pid pid;
	int exit_status;
	CInt term_signal;
	bool exited;
	bool signaled;
}

<*
 Caller-owned child process handle.

 The process header is active while nova is responsible for reaping the child.
 Stdio endpoints are initialized only when their matching `has_*` flag is true.
 Backend wait fields are internal and are valid only while the handle is active.
*>
struct Process
{
	inline op::Header header;
	backend::OpState wait_backend;
	Pid pid;
	NativeHandle wait_handle;
	pipe::Endpoint stdin;
	pipe::Endpoint stdout;
	pipe::Endpoint stderr;
	Process* loop_next;
	Process* loop_prev;
	ExitResult result;
	Callback callback;
	bool has_stdin;
	bool has_stdout;
	bool has_stderr;
	bool initialized;
	bool spawned;
	bool exited;
	bool detached;
	bool backend_wait;
	bool wait_handle_owned;
}

<*
 Build spawn options with nova defaults.

 @param file : "Executable path or name"
 @return "Spawn options with inherited environment and PATH search enabled"
*>
fn SpawnOptions make_options(String file)
{
	return { .file = file, .inherit_env = true, .search_path = true, };
}

<*
 Build an ignored stdio descriptor configuration.

 @return "Ignored stdio configuration"
*>
fn Stdio ignore() => { .action = StdioAction.IGNORE };

<*
 Build an inherited stdio descriptor configuration.

 @return "Inherited stdio configuration"
*>
fn Stdio inherit() => { .action = StdioAction.INHERIT };

<*
 Build a stdio descriptor configuration from a borrowed native handle.

 @param handle : "Native descriptor to duplicate into the child"
 @return "Borrowed native-handle stdio configuration"
*>
fn Stdio fd(NativeHandle handle) => { .action = StdioAction.FD, .fd = handle };

<*
 Build a stdio pipe descriptor configuration.

 @return "Pipe-backed stdio configuration"
*>
fn Stdio piped() => { .action = StdioAction.PIPE };

<*
 Initialize caller-owned process handle storage.

 @param [&inout] self : "Process handle storage"
 @return "Initialized process handle"
 @require self.header.state == State.OP_FREE : "Process handle must not be active"
 @ensure self.initialized : "Process handle is initialized after init"
*>
fn Process* Process.init(&self)
{
	*self = { };
	self.header.kind = op::Kind.PROCESS;
	self.header.state = op::State.OP_FREE;
	self.pid = (Pid)0;
	self.wait_handle = (NativeHandle)-1;
	self.initialized = true;
	return self;
}

<*
 Destroy reusable process handle storage.

 @param [&inout] self : "Process handle storage"
 @require self.initialized : "Process handle must be initialized"
 @require self.header.state == State.OP_FREE : "Process handle must be free"
 @require !self.has_stdin : "stdin endpoint must be closed"
 @require !self.has_stdout : "stdout endpoint must be closed"
 @require !self.has_stderr : "stderr endpoint must be closed"
 @ensure !self.initialized : "Process handle is uninitialized after destroy"
*>
fn void Process.destroy(&self)
{
	*self = { };
	self.header.kind = op::Kind.PROCESS;
	self.header.state = op::State.OP_FREE;
	self.wait_handle = (NativeHandle)-1;
}

<*
 Report whether nova still owns an active process wait operation.

 @param self : "Process handle storage to inspect"
 @return "True when the process header is active"
*>
fn bool Process.active(&self) => self.header.active();

<*
 Report whether the child was spawned and has not yet been reaped.

 @param self : "Process handle storage to inspect"
 @return "True while the process is considered running"
*>
fn bool Process.is_running(&self) => self.spawned && !self.exited;

<*
 Report whether process exit has been observed.

 @param self : "Process handle storage to inspect"
 @return "True after the child has been reaped"
*>
fn bool Process.has_exited(&self) => self.exited;

<*
 Return the process identifier captured at spawn time.

 @param self : "Process handle storage"
 @return "Process identifier, or zero before spawn"
*>
fn Pid Process.get_pid(&self) => self.pid;

<*
 Submit a child process spawn request.

 POSIX supports `IGNORE`, `INHERIT`, `FD`, `PIPE`, `stderr_to_stdout`, and
 platform-backed `cwd`/detached spawn where the native backend exposes those
 capabilities.

 @param loop : "Loop that will own the process handle"
 @param process : "Caller-owned process handle storage"
 @param options : "Spawn configuration"
 @param callback : "Callback invoked after process exit"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return ? nova::INVALID_STATE : "Loop, process, options or callback are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Process handle is already active"
 @return ? nova::UNSUPPORTED : "Requested spawn feature is not supported here"
 @return ? io::FILE_NOT_FOUND : "Executable was not found"
 @return ? io::NAME_TOO_LONG : "Executable path or name is too long"
 @return ? io::NO_PERMISSION : "Executable could not be launched by this process"
 @return ? nova::BACKEND_FAILED : "Native spawn setup failed unexpectedly"
 @require loop != null : "Loop pointer must not be null"
*>
fn op::Ref? spawn(Loop* loop, Process* process, SpawnOptions options, Callback callback, void* userdata = null)
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!process || !process.initialized) return nova::INVALID_STATE~;
	if (!callback || !options.file.len) return nova::INVALID_STATE~;
	if (!stdio_valid(options.stdin) || !stdio_valid(options.stdout) || !stdio_valid(options.stderr))
	{
		return nova::INVALID_STATE~;
	}
	if (process.header.active()) return nova::BUSY~;
	if (process.has_stdin || process.has_stdout || process.has_stderr) return nova::BUSY~;
	return native_spawn(loop, process, options, callback, userdata)!;
}

<*
 Send a native signal to a process handle.

 @param process : "Spawned process handle"
 @param signum : "Native signal number"
 @return ? nova::INVALID_STATE : "Process handle or signal is invalid"
 @return ? NOT_FOUND : "Process is not running"
 @return ? io::NO_PERMISSION : "Caller cannot signal the target process"
 @return ? nova::BACKEND_FAILED : "Native kill failed unexpectedly"
*>
fn void? kill(Process* process, CInt signum)
{
	if (!process || !process.initialized || signum < 0) return nova::INVALID_STATE~;
	if (!process.is_running()) return NOT_FOUND~;
	native_kill_process(process, signum)!;
}

<*
 Send a native signal to a raw process id.

 Raw pid use can target an unrelated process if the pid has been reused.

 @param pid : "Native process id"
 @param signum : "Native signal number"
 @return ? nova::INVALID_STATE : "Pid or signal is invalid"
 @return ? NOT_FOUND : "Native process does not exist"
 @return ? io::NO_PERMISSION : "Caller cannot signal the target process"
 @return ? nova::BACKEND_FAILED : "Native kill failed unexpectedly"
*>
fn void? kill_pid(Pid pid, CInt signum)
{
	if ((int)pid <= 0 || signum < 0) return nova::INVALID_STATE~;
	native_kill_pid(pid, signum)!;
}

<*
 Poll active child processes and queue callbacks for exited children.

 POSIX loops normally call this from the internal SIGCHLD watcher. Tests and
 embedders may call it directly when they need an explicit waitpid drain point.

 @param loop : "Loop that owns active process handles"
 @return "Number of process exits queued"
 @return ? nova::INVALID_STATE : "Loop is not initialized"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @require loop != null : "Loop pointer must not be null"
*>
fn sz? drain_exited(Loop* loop) => native_drain_exited(loop);

<*
 Close all currently open process stdio endpoints synchronously.

 @param process : "Process handle whose stdio endpoints should be closed"
 @return ? nova::INVALID_STATE : "Process handle is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "A stdio endpoint has active pipe operations"
 @return ? nova::INVALID_SOCKET : "Owned native descriptor was invalid"
 @return ? nova::BACKEND_FAILED : "Native close failed"
*>
fn void? close_stdio_now(Process* process)
{
	if (!process || !process.initialized) return nova::INVALID_STATE~;
	if (process.has_stdin)
	{
		pipe::close_now(&process.stdin)!;
		process.has_stdin = false;
	}
	if (process.has_stdout)
	{
		pipe::close_now(&process.stdout)!;
		process.has_stdout = false;
	}
	if (process.has_stderr)
	{
		pipe::close_now(&process.stderr)!;
		process.has_stderr = false;
	}
}

<*
 Cancel a process operation from owner-loop code.

 Live process handles cannot be detached because nova must still reap the child.

 @param loop : "Loop that owns the process operation"
 @param header : "Active process operation header"
 @return ? nova::BUSY : "Process is live, already reaped, or not ready for cancellation"
 @require loop != null : "Loop pointer must not be null"
 @require header != null : "Process operation header must not be null"
*>
fn void? cancel(Loop* loop, op::Header* header)
{
	(void)loop;
	return nova::BUSY~;
}

<*
 Validate a stdio descriptor configuration.

 @param stdio : "Stdio descriptor configuration"
 @return "True when the action and handle are coherent"
*>
fn bool stdio_valid(Stdio stdio) @local
{
	if (stdio.action == StdioAction.IGNORE) return true;
	if (stdio.action == StdioAction.INHERIT) return true;
	if (stdio.action == StdioAction.PIPE) return true;
	if (stdio.action == StdioAction.FD) return (int)stdio.fd >= 0;
	return false;
}
