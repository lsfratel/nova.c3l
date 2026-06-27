module nova::process;

import std::core::mem::alloc;
import std::io, std::os::posix;
import std::net::os;
import libc;

import nova @norecurse;
import nova::backend @public;
import nova::op @public;
import nova::pipe;
import nova::posix_errno @public;
import nova::signal;

<*
 POSIX process, descriptor and spawn constants normalized for Linux and macOS.
*>
const CInt PROCESS_O_RDONLY                              = 0;
const CInt PROCESS_O_RDWR                                = 2;
const CInt PROCESS_O_CLOEXEC                             = env::LINUX ? 0o2000000 : 0x01000000;
const CInt PROCESS_F_DUPFD                               = 0;
const CInt PROCESS_F_GETFD                               = 1;
const CInt PROCESS_F_SETFD                               = 2;
const CInt PROCESS_FD_CLOEXEC                            = 1;
const CInt PROCESS_STDIO_FD_COUNT                        = 3;
const CInt PROCESS_CHILD_STAGE_SETUP                     = 1;
const CInt PROCESS_CHILD_STAGE_EXEC                      = 2;
const CInt PROCESS_SIG_SETMASK                           = env::LINUX ? 2 : 3;
const CInt PROCESS_SIGNAL_COUNT                          = 32;
const sz PROCESS_NAME_MAX                                = 255;
const CShort PROCESS_POSIX_SPAWN_SETSIGDEF               = (CShort)0x04;
const CShort PROCESS_POSIX_SPAWN_SETSIGMASK              = (CShort)0x08;
const CShort PROCESS_POSIX_SPAWN_SETSID @if(env::LINUX)  = (CShort)0x80;
const CShort PROCESS_POSIX_SPAWN_SETSID @if(env::DARWIN) = (CShort)0x400;
const sz PROCESS_SYS_PIDFD_OPEN @if(env::LINUX)          = 434;

<*
 Platform default executable search path used when spawn options do not provide
 an explicit environment `PATH`.
*>
const String PROCESS_DEFAULT_PATH = "/usr/bin:/bin";

<*
 Empty environment vector used when spawn options disable inherited environment.
*>
const ZString[1] PROCESS_EMPTY_ENVIRONMENT = { null };

<*
 POSIX process and spawn C bindings used during native process setup.

 Return values are checked by the wrapper code and converted to nova faults or
 POSIX platform diagnostics.
*>
extern fn CInt process_open(ZString pathname, CInt flags, ...) @cname("open");
extern fn CInt process_pipe2(CInt[2]* pipes, CInt flags) @cname("pipe2") @if(env::LINUX);
extern fn Pid_t process_fork() @cname("fork");
extern fn CInt process_chdir(ZString path) @cname("chdir");
extern fn CInt process_dup2(CInt old_fd, CInt new_fd) @cname("dup2");
extern fn CInt process_execve(ZString path, ZString* argv, ZString* envp) @cname("execve");
extern fn CInt process_setsid() @cname("setsid");
extern fn CInt process_sigprocmask(CInt how, libc::Sigset_t* set, libc::Sigset_t* oldset) @cname("sigprocmask");
extern fn CInt process_spawn_file_actions_addchdir_np(
	posix::Posix_spawn_file_actions_t* actions,
	ZString path
) @cname("posix_spawn_file_actions_addchdir_np") @if(env::LINUX);
extern fn CInt process_spawnattr_init(posix::Posix_spawnattr_t* attr) @cname("posix_spawnattr_init");
extern fn CInt process_spawnattr_destroy(posix::Posix_spawnattr_t* attr) @cname("posix_spawnattr_destroy");
extern fn CInt process_spawnattr_setflags(
	posix::Posix_spawnattr_t* attr,
	CShort flags
) @cname("posix_spawnattr_setflags");
extern fn CInt process_spawnattr_setsigdefault(
	posix::Posix_spawnattr_t* attr,
	libc::Sigset_t* sigdefault
) @cname("posix_spawnattr_setsigdefault");
extern fn CInt process_spawnattr_setsigmask(
	posix::Posix_spawnattr_t* attr,
	libc::Sigset_t* sigmask
) @cname("posix_spawnattr_setsigmask");
extern fn CInt process_sigfillset(libc::Sigset_t* set) @cname("sigfillset");

<*
 Child-to-parent failure report used by the fork fallback path.
*>
struct ForkExecError
{
	CInt stage;
	CInt err;
}

<*
 Result of one fork and exec attempt.
*>
struct ForkExecAttempt
{
	CInt status;
	bool exec_error;
}

<*
 Native descriptor state accumulated while preparing `posix_spawn`.

 Parent endpoints are only attached to `Process` after the child is spawned
 successfully; temporary descriptors are closed during cleanup.
*>
struct NativeSpawnState
{
	NativeStdio stdin;
	NativeStdio stdout;
	NativeStdio stderr;
	CInt devnull_read;
	CInt devnull_write;
}

<*
 Native stdio descriptor pair for one child descriptor.

 `child_fd` is the descriptor wired into the child. `parent_fd` becomes a nova
 pipe endpoint when `parent_endpoint` is true.
*>
struct NativeStdio
{
	CInt parent_fd;
	CInt child_fd;
	pipe::Endpoint* endpoint;
	pipe::Direction parent_direction;
	bool parent_endpoint;
}

<*
 Submit a POSIX child process and attach it to the loop process list.

 @param loop : "Loop that will own the process handle"
 @param process : "Reusable process handle storage"
 @param options : "Validated spawn options"
 @param callback : "Callback invoked after the child is reaped"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked process reference"
 @return ? nova::INVALID_STATE : "Validated options were mutated into an invalid state"
 @return ? nova::UNSUPPORTED : "`cwd` or detached spawn is not supported on this target"
 @return ? io::FILE_NOT_FOUND : "Executable was not found"
 @return ? io::NAME_TOO_LONG : "Executable path or name is too long"
 @return ? io::NO_PERMISSION : "Executable could not be launched by this process"
 @return ? nova::BACKEND_FAILED : "Native spawn setup failed unexpectedly"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn op::Ref? native_spawn(Loop* loop, Process* process, SpawnOptions options, Callback callback, void* userdata) @private
{
	if (spawn_requires_fork(options))
	{
		return native_spawn_fork(loop, process, options, callback, userdata)!;
	}
	validate_spawn_platform_features(options)!;
	ensure_process_signal(loop)!;

	posix::Posix_spawn_file_actions_t actions;
	CInt init_status = posix::spawn_file_actions_init(&actions);
	if (init_status != 0) return spawn_status_to_fault((Errno)init_status)~;
	defer posix::spawn_file_actions_destroy(&actions);

	posix::Posix_spawnattr_t attrs;
	CInt attr_status = process_spawnattr_init(&attrs);
	if (attr_status != 0) return spawn_status_to_fault((Errno)attr_status)~;
	defer process_spawnattr_destroy(&attrs);
	configure_spawn_attrs(&attrs, options)!;

	NativeSpawnState state = make_spawn_state(process);
	bool spawned           = false;
	defer
	{
		if (!spawned) cleanup_failed_stdio(process, &state);
		state.close_temp_fds();
		if (!spawned && loop.process_count == 0) stop_process_signal_now(loop);
	}

	configure_stdio(&state, &state.stdin, &actions, libc::STDIN_FD, options.stdin)!;
	configure_stdio(&state, &state.stdout, &actions, libc::STDOUT_FD, options.stdout)!;
	if (options.stderr_to_stdout)
	{
		if (posix::spawn_file_actions_adddup2(&actions, libc::STDOUT_FD, libc::STDERR_FD) != 0)
		{
			return nova::BACKEND_FAILED~;
		}
	}
	else
	{
		configure_stdio(&state, &state.stderr, &actions, libc::STDERR_FD, options.stderr)!;
	}
	add_devnull_close_actions(&state, &actions)!;

	Pid_t child;
	CInt spawn_status;
	@stack_mem(4096 ; Allocator smem)
	{
		configure_spawn_cwd(smem, &actions, options)!;
		ZString* argv = copy_argv(smem, options);
		ZString* envp = posix::environ;
		if (!options.inherit_env) envp = copy_env(smem, options.env);
		if (options.search_path)
		{
			spawn_status = spawn_with_path_search(smem, &child, options, &actions, &attrs, argv, envp);
		}
		else
		{
			spawn_status = retry_spawn(&child, argv[0], &actions, &attrs, argv, envp);
		}
	};
	if (spawn_status != 0) return spawn_status_to_fault((Errno)spawn_status)~;

	spawned = true;
	return finish_spawn_success(loop, process, &state, child, options, callback, userdata)!;
}

<*
 Report whether this spawn needs fork/exec because posix_spawn lacks a required extension.

 @param options : "Spawn options to inspect"
 @return "True when the portable fork fallback is required"
*>
fn bool spawn_requires_fork(SpawnOptions options) @local
{
	$if env::LINUX:
		(void)options;
		return false;
	$else
		return options.cwd.len > 0;
	$endif
}

<*
 Submit a POSIX child process through fork and execve.

 This path is used only when a target's `posix_spawn` does not expose native
 file-action or attribute support for requested options. A close-on-exec pipe
 reports pre-exec errors synchronously to the parent.

 @param loop : "Loop that will own the process handle"
 @param process : "Reusable process handle storage"
 @param options : "Validated spawn options"
 @param callback : "Callback invoked after the child is reaped"
 @param userdata : "Opaque user pointer delivered to the callback"
 @return "Generation-checked process reference"
 @return ? nova::INVALID_STATE : "Stdio action is invalid, or loop is uninitialized or not owned"
 @return ? io::FILE_NOT_FOUND : "Executable or requested cwd was not found"
 @return ? io::NAME_TOO_LONG : "Executable path or name is too long"
 @return ? io::NO_PERMISSION : "Executable could not be launched by this process"
 @return ? nova::BACKEND_FAILED : "Native fork or exec setup failed unexpectedly"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn op::Ref? native_spawn_fork(
	Loop* loop,
	Process* process,
	SpawnOptions options,
	Callback callback,
	void* userdata
) @local
{
	ensure_process_signal(loop)!;

	NativeSpawnState state = make_spawn_state(process);
	bool spawned           = false;
	defer
	{
		if (!spawned) cleanup_failed_stdio(process, &state);
		state.close_temp_fds();
		if (!spawned && loop.process_count == 0) stop_process_signal_now(loop);
	}

	configure_stdio_fork(&state, &state.stdin, libc::STDIN_FD, options.stdin)!;
	configure_stdio_fork(&state, &state.stdout, libc::STDOUT_FD, options.stdout)!;
	if (!options.stderr_to_stdout)
	{
		configure_stdio_fork(&state, &state.stderr, libc::STDERR_FD, options.stderr)!;
	}

	Pid_t child;
	CInt spawn_status;
	@stack_mem(4096 ; Allocator smem)
	{
		ZString cwd = null;
		if (options.cwd.len) cwd = options.cwd.zstr_copy(smem);
		ZString* argv = copy_argv(smem, options);
		ZString* envp = posix::environ;
		if (!options.inherit_env) envp = copy_env(smem, options.env);
		spawn_status = fork_with_path_search(smem, &child, options, &state, argv, envp, cwd);
	};
	if (spawn_status != 0) return spawn_status_to_fault((Errno)spawn_status)~;

	spawned = true;
	return finish_spawn_success(loop, process, &state, child, options, callback, userdata)!;
}

<*
 Attach a successfully spawned child process to the loop.

 @param loop : "Loop that owns the process"
 @param process : "Process handle to publish"
 @param state : "Native stdio state prepared for spawn"
 @param child : "Spawned child pid"
 @param options : "Spawn options used to launch the child"
 @param callback : "Exit callback"
 @param userdata : "Submission userdata"
 @return "Generation-checked process reference"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
 @require state != null : "Spawn state pointer must not be null"
 @require callback != null : "Callback pointer must not be null"
*>
fn op::Ref? finish_spawn_success(
	Loop* loop,
	Process* process,
	NativeSpawnState* state,
	Pid_t child,
	SpawnOptions options,
	Callback callback,
	void* userdata
) @local
{
	process.pid = (Pid)child;
	process.result = { .pid = process.pid };
	process.callback = callback;
	process.spawned = true;
	process.exited = false;
	process.detached = options.detached;
	process.has_stdin = state.stdin.parent_endpoint;
	process.has_stdout = state.stdout.parent_endpoint;
	process.has_stderr = !options.stderr_to_stdout && state.stderr.parent_endpoint;

	bool backend_wait = start_process_backend_waiter(loop, process, userdata);
	if (!backend_wait)
	{
		op::init_header(&process.header, op::Kind.PROCESS, loop, &dispatch_process_exit, process, userdata);
	}
	attach_process(loop, process);
	if (!process_signal_required(loop)) stop_process_signal_now(loop);
	return process.header.to_ref();
}

<*
 Send a POSIX signal to a process handle.

 @param process : "Running process handle"
 @param signum : "Native signal number"
 @return ? nova::INVALID_STATE : "Native signal number is invalid"
 @return ? NOT_FOUND : "Process no longer exists"
 @return ? io::NO_PERMISSION : "Caller cannot signal the target process"
 @return ? nova::BACKEND_FAILED : "Native kill failed unexpectedly"
 @require process != null : "Process pointer must not be null"
*>
fn void? native_kill_process(Process* process, CInt signum) @private
{
	native_kill_pid(process.pid, signum)!;
}

<*
 Send a POSIX signal to a raw process id.

 @param pid : "Native process id"
 @param signum : "Native signal number"
 @return ? nova::INVALID_STATE : "Native signal number is invalid"
 @return ? NOT_FOUND : "Process no longer exists"
 @return ? io::NO_PERMISSION : "Caller cannot signal the target process"
 @return ? nova::BACKEND_FAILED : "Native kill failed unexpectedly"
*>
fn void? native_kill_pid(Pid pid, CInt signum) @private
{
	if (posix::kill((Pid_t)pid, signum) == 0) return;
	Errno err = libc::errno();
	if (err == posix_errno::E_SRCH) return NOT_FOUND~;
	if (err == posix_errno::E_PERM) return io::NO_PERMISSION~;
	if (err == posix_errno::E_INVAL) return nova::INVALID_STATE~;
	return nova::BACKEND_FAILED~;
}

<*
 Poll active POSIX child processes and queue callbacks for completed children.

 @param loop : "Loop that owns active process handles"
 @return "Number of process exits queued"
 @return ? nova::INVALID_STATE : "Loop is not initialized"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @require loop != null : "Loop pointer must not be null"
*>
fn sz? native_drain_exited(Loop* loop) @private
{
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;

	sz queued        = 0;
	Process* process = loop.process_head;
	while (process)
	{
		Process* next = process.loop_next;
		CInt status;
		Pid_t result  = waitpid_nohang(process.pid, &status);
		if (result == (Pid_t)process.pid)
		{
			finish_process_exit(loop, process, status, nova::ok_status(), { });
			queued++;
		}
		else if (result < 0)
		{
			Errno err = libc::errno();
			if (err == posix_errno::E_CHILD)
			{
				ErrorInfo error = posix_error_info(nova::BACKEND_FAILED, err);
				finish_process_exit(loop, process, 0, nova::BACKEND_FAILED, error);
				queued++;
			}
		}
		process = next;
	}
	return queued;
}

<*
 Build native spawn state bound to a process handle.

 @param process : "Process handle whose stdio endpoints may be initialized"
 @return "Native spawn state with all descriptors marked closed"
 @require process != null : "Process pointer must not be null"
*>
fn NativeSpawnState make_spawn_state(Process* process) @local
{
	return {
		.stdin = { .parent_fd = -1, .child_fd = -1, .endpoint = &process.stdin },
		.stdout = { .parent_fd = -1, .child_fd = -1, .endpoint = &process.stdout },
		.stderr = { .parent_fd = -1, .child_fd = -1, .endpoint = &process.stderr },
		.devnull_read = -1,
		.devnull_write = -1,
	};
}

<*
 Validate spawn features whose native support is platform-specific.

 Linux libc implementations in the support matrix expose both
 `posix_spawn_file_actions_addchdir_np` and `POSIX_SPAWN_SETSID`. macOS uses
 `POSIX_SPAWN_SETSID` for detached-only spawn, while `cwd` goes through the
 fork fallback to preserve relative executable path behavior.

 @param options : "Spawn options to validate for this native backend"
 @return ? nova::UNSUPPORTED : "`cwd` or detached spawn is not supported here"
*>
fn void? validate_spawn_platform_features(SpawnOptions options) @local
{
	(void)options;
}

<*
 Configure child process attributes for normal executable behavior.

 Event libraries may ignore or handle signals in the parent process. Children
 should still start with default signal dispositions and an empty signal mask,
 matching the behavior expected from a direct shell launch.

 @param attrs : "Initialized POSIX spawn attributes"
 @param options : "Spawn options that may request detached session creation"
 @return ? nova::UNSUPPORTED : "Detached spawn is not supported on this target"
 @return ? nova::BACKEND_FAILED : "Native spawn attribute setup failed"
 @require attrs != null : "Spawn attributes pointer must not be null"
*>
fn void? configure_spawn_attrs(posix::Posix_spawnattr_t* attrs, SpawnOptions options) @local
{
	CShort flags = PROCESS_POSIX_SPAWN_SETSIGDEF | PROCESS_POSIX_SPAWN_SETSIGMASK;
	if (options.detached)
	{
		flags |= PROCESS_POSIX_SPAWN_SETSID;
	}
	if (process_spawnattr_setflags(attrs, flags) != 0) return nova::BACKEND_FAILED~;

	libc::Sigset_t signals;
	if (process_sigfillset(&signals) != 0) return nova::BACKEND_FAILED~;
	if (process_spawnattr_setsigdefault(attrs, &signals) != 0) return nova::BACKEND_FAILED~;

	if (libc::sigemptyset(&signals) != 0) return nova::BACKEND_FAILED~;
	if (process_spawnattr_setsigmask(attrs, &signals) != 0) return nova::BACKEND_FAILED~;
}

<*
 Add a native file action that changes the child working directory before exec.

 @param allocator : "Scoped allocator whose storage remains live until spawn"
 @param actions : "Prepared POSIX spawn file actions"
 @param options : "Spawn options with optional child cwd"
 @return ? nova::UNSUPPORTED : "`cwd` spawn is not supported on this target"
 @return ? nova::BACKEND_FAILED : "Native file action setup failed"
 @require actions != null : "Spawn file actions pointer must not be null"
*>
fn void? configure_spawn_cwd(
	Allocator allocator,
	posix::Posix_spawn_file_actions_t* actions,
	SpawnOptions options
) @local
{
	if (!options.cwd.len) return;
	$if env::LINUX:
		ZString cwd = options.cwd.zstr_copy(allocator);
		CInt status = process_spawn_file_actions_addchdir_np(actions, cwd);
		if (status != 0) return spawn_status_to_fault((Errno)status)~;
	$else
		return nova::UNSUPPORTED~;
	$endif
}

<*
 Close temporary descriptors opened while preparing spawn actions.

 @param self : "Native spawn state"
*>
fn void NativeSpawnState.close_temp_fds(&self)
{
	close_child_fd(&self.stdin);
	close_child_fd(&self.stdout);
	close_child_fd(&self.stderr);
	if (self.devnull_read >= 0) (void)libc::close(self.devnull_read);
	if (self.devnull_write >= 0 && self.devnull_write != self.devnull_read) (void)libc::close(self.devnull_write);
	self.stdin.child_fd = -1;
	self.stdout.child_fd = -1;
	self.stderr.child_fd = -1;
	self.devnull_read = -1;
	self.devnull_write = -1;
}

<*
 Add POSIX spawn file actions for one child stdio descriptor.

 @param state : "Temporary native spawn state"
 @param native_stdio : "Native stdio state for this descriptor"
 @param actions : "POSIX spawn file actions to update"
 @param child_fd : "Child stdio descriptor number"
 @param stdio : "Validated stdio configuration"
 @return ? nova::INVALID_STATE : "Stdio action is invalid"
 @return ? io::FILE_NOT_FOUND : "`/dev/null` could not be opened"
 @return ? io::NO_PERMISSION : "`/dev/null` could not be opened by this process"
 @return ? nova::BACKEND_FAILED : "Native file action setup failed"
 @require state != null : "Spawn state pointer must not be null"
 @require native_stdio != null : "Native stdio pointer must not be null"
 @require actions != null : "File actions pointer must not be null"
*>
fn void? configure_stdio(
	NativeSpawnState* state,
	NativeStdio* native_stdio,
	posix::Posix_spawn_file_actions_t* actions,
	CInt child_fd,
	Stdio stdio
) @local
{
	switch (stdio.action)
	{
		case StdioAction.IGNORE:
			CInt null_fd = ensure_devnull(state, child_fd == libc::STDIN_FD)!;
			if (posix::spawn_file_actions_adddup2(actions, null_fd, child_fd) != 0) return nova::BACKEND_FAILED~;
		case StdioAction.INHERIT:
			return;
		case StdioAction.FD:
			configure_fd_stdio(native_stdio, actions, child_fd, (CInt)stdio.fd)!;
		case StdioAction.PIPE:
			configure_pipe_stdio(native_stdio, actions, child_fd)!;
		default:
			return nova::INVALID_STATE~;
	}
}

<*
 Prepare one child stdio descriptor for the fork fallback path.

 @param state : "Temporary native spawn state"
 @param native_stdio : "Native stdio state for this descriptor"
 @param child_fd : "Child stdio descriptor number"
 @param stdio : "Validated stdio configuration"
 @return ? nova::INVALID_STATE : "Stdio action is invalid"
 @return ? io::FILE_NOT_FOUND : "`/dev/null` could not be opened"
 @return ? io::NO_PERMISSION : "`/dev/null` could not be opened by this process"
 @return ? nova::BACKEND_FAILED : "Native descriptor setup failed"
 @require state != null : "Spawn state pointer must not be null"
 @require native_stdio != null : "Native stdio pointer must not be null"
*>
fn void? configure_stdio_fork(NativeSpawnState* state, NativeStdio* native_stdio, CInt child_fd, Stdio stdio) @local
{
	switch (stdio.action)
	{
		case StdioAction.IGNORE:
			(void)ensure_devnull(state, child_fd == libc::STDIN_FD)!;
		case StdioAction.INHERIT:
			return;
		case StdioAction.FD:
			configure_fd_stdio_fork(native_stdio, child_fd, (CInt)stdio.fd)!;
		case StdioAction.PIPE:
			configure_pipe_stdio_fork(native_stdio, child_fd)!;
		default:
			return nova::INVALID_STATE~;
	}
}

<*
 Prepare a borrowed descriptor for fork child dup2 setup.

 @param native_stdio : "Native stdio state that may own a temporary duplicate"
 @param child_fd : "Child stdio descriptor number"
 @param source_fd : "Borrowed parent descriptor to duplicate into the child"
 @return ? nova::BACKEND_FAILED : "Native duplicate failed"
 @require native_stdio != null : "Native stdio pointer must not be null"
*>
fn void? configure_fd_stdio_fork(NativeStdio* native_stdio, CInt child_fd, CInt source_fd) @local
{
	if (source_fd > child_fd) return;

	os::NativeSocket socket = (os::NativeSocket)source_fd;
	CInt use_fd             = fcntl_retry(socket, PROCESS_F_DUPFD, PROCESS_STDIO_FD_COUNT);
	if (use_fd < 0) return nova::BACKEND_FAILED~;
	native_stdio.child_fd = use_fd;
	set_fd_cloexec(use_fd)!;
}

<*
 Create and attach a process stdio pipe for fork child dup2 setup.

 @param native_stdio : "Native stdio state for this descriptor"
 @param child_fd : "Child stdio descriptor number"
 @return ? nova::BACKEND_FAILED : "Native pipe creation or descriptor setup failed"
 @require native_stdio != null : "Native stdio pointer must not be null"
*>
fn void? configure_pipe_stdio_fork(NativeStdio* native_stdio, CInt child_fd) @local
{
	CInt[2] fds = { -1, -1 };
	open_process_pipe(&fds)!;

	bool stdin_pipe = child_fd == libc::STDIN_FD;
	native_stdio.parent_fd = fds[0];
	native_stdio.child_fd = fds[1];
	native_stdio.parent_direction = pipe::Direction.READ;
	if (stdin_pipe)
	{
		native_stdio.parent_fd = fds[1];
		native_stdio.child_fd = fds[0];
		native_stdio.parent_direction = pipe::Direction.WRITE;
	}

	if (catch prepare_err = prepare_process_pipe_parent(native_stdio.parent_fd))
	{
		close_pipe_setup_fds(fds[0], fds[1]);
		native_stdio.parent_fd = -1;
		native_stdio.child_fd = -1;
		return prepare_err~;
	}
	if (catch prepare_err = prepare_process_pipe_child(native_stdio.child_fd))
	{
		close_pipe_setup_fds(fds[0], fds[1]);
		native_stdio.parent_fd = -1;
		native_stdio.child_fd = -1;
		return prepare_err~;
	}
	if (catch prepare_err = move_conflicting_child_stdio_fd(native_stdio, child_fd))
	{
		close_pipe_setup_fds(fds[0], fds[1]);
		native_stdio.parent_fd = -1;
		native_stdio.child_fd = -1;
		return prepare_err~;
	}
	pipe::endpoint_open(
		native_stdio.endpoint,
		(NativeHandle)(int)native_stdio.parent_fd,
		{ .owns_handle = true, .direction = native_stdio.parent_direction }
	);
	native_stdio.parent_endpoint = true;
}

<*
 Add spawn actions for a borrowed native descriptor.

 Low-numbered source descriptors must be moved above stdio before being duped
 into their target slot. Otherwise swaps such as stdout <- fd 2 and stderr <-
 fd 1 can collapse both descriptors onto the same file as actions run in order.

 @param native_stdio : "Native stdio state that may own a temporary duplicate"
 @param actions : "POSIX spawn file actions to update"
 @param child_fd : "Child stdio descriptor number"
 @param source_fd : "Borrowed parent descriptor to duplicate into the child"
 @return ? nova::BACKEND_FAILED : "Native duplicate or file action setup failed"
 @require native_stdio != null : "Native stdio pointer must not be null"
 @require actions != null : "File actions pointer must not be null"
*>
fn void? configure_fd_stdio(
	NativeStdio* native_stdio,
	posix::Posix_spawn_file_actions_t* actions,
	CInt child_fd,
	CInt source_fd
) @local
{
	CInt use_fd = source_fd;
	if (source_fd <= child_fd)
	{
		os::NativeSocket socket = (os::NativeSocket)source_fd;
		use_fd = fcntl_retry(socket, PROCESS_F_DUPFD, PROCESS_STDIO_FD_COUNT);
		if (use_fd < 0) return nova::BACKEND_FAILED~;
		native_stdio.child_fd = use_fd;
		set_fd_cloexec(use_fd)!;
	}

	if (posix::spawn_file_actions_adddup2(actions, use_fd, child_fd) != 0) return nova::BACKEND_FAILED~;
	if (use_fd != source_fd && posix::spawn_file_actions_addclose(actions, use_fd) != 0) return nova::BACKEND_FAILED~;
}

<*
 Create and attach a process stdio pipe.

 The parent endpoint is nonblocking and close-on-exec. The child descriptor is
 close-on-exec but remains blocking, matching normal child process expectations.

 @param native_stdio : "Native stdio state for this descriptor"
 @param actions : "POSIX spawn file actions to update"
 @param child_fd : "Child stdio descriptor number"
 @return ? nova::BACKEND_FAILED : "Native pipe creation or file action setup failed"
 @require native_stdio != null : "Native stdio pointer must not be null"
 @require actions != null : "File actions pointer must not be null"
*>
fn void? configure_pipe_stdio(
	NativeStdio* native_stdio,
	posix::Posix_spawn_file_actions_t* actions,
	CInt child_fd
) @local
{
	CInt[2] fds = { -1, -1 };
	open_process_pipe(&fds)!;

	bool stdin_pipe = child_fd == libc::STDIN_FD;
	native_stdio.parent_fd = fds[0];
	native_stdio.child_fd = fds[1];
	native_stdio.parent_direction = pipe::Direction.READ;
	if (stdin_pipe)
	{
		native_stdio.parent_fd = fds[1];
		native_stdio.child_fd = fds[0];
		native_stdio.parent_direction = pipe::Direction.WRITE;
	}

	if (catch prepare_err = prepare_process_pipe_parent(native_stdio.parent_fd))
	{
		close_pipe_setup_fds(fds[0], fds[1]);
		native_stdio.parent_fd = -1;
		native_stdio.child_fd = -1;
		return prepare_err~;
	}
	if (catch prepare_err = prepare_process_pipe_child(native_stdio.child_fd))
	{
		close_pipe_setup_fds(fds[0], fds[1]);
		native_stdio.parent_fd = -1;
		native_stdio.child_fd = -1;
		return prepare_err~;
	}
	if (catch prepare_err = move_conflicting_child_stdio_fd(native_stdio, child_fd))
	{
		close_pipe_setup_fds(fds[0], fds[1]);
		native_stdio.parent_fd = -1;
		native_stdio.child_fd = -1;
		return prepare_err~;
	}
	pipe::endpoint_open(
		native_stdio.endpoint,
		(NativeHandle)(int)native_stdio.parent_fd,
		{ .owns_handle = true, .direction = native_stdio.parent_direction }
	);
	native_stdio.parent_endpoint = true;

	if (posix::spawn_file_actions_adddup2(actions, native_stdio.child_fd, child_fd) != 0) return nova::BACKEND_FAILED~;
	if (native_stdio.child_fd != child_fd && posix::spawn_file_actions_addclose(actions, native_stdio.child_fd) != 0)
	{
		return nova::BACKEND_FAILED~;
	}
}

<*
 Create a child stdio pipe with close-on-exec set atomically when available.

 @param [out] fds : "Native pipe descriptors"
 @return ? nova::BACKEND_FAILED : "pipe creation failed"
 @require fds != null : "Pipe descriptor output must not be null"
*>
fn void? open_process_pipe(CInt[2]* fds) @local
{
	$if env::LINUX:
		if (process_pipe2(fds, PROCESS_O_CLOEXEC) == 0) return;
		Errno err = libc::errno();
		if (err != posix_errno::E_INVAL && err != posix_errno::E_NOSYS) return nova::BACKEND_FAILED~;
	$endif
	if (posix::pipe(fds) != 0) return nova::BACKEND_FAILED~;
}

<*
 Move a child-side pipe descriptor away from its target stdio slot.

 When the parent has closed fd 0, 1 or 2, `pipe()` may reuse that exact number
 for the child side. The child side is close-on-exec until the spawn action
 duplicates it, so `dup2(fd, fd)` would leave the stdio descriptor closed after
 exec. Moving it above stdio preserves the normal `dup2(source, target)` path.

 @param native_stdio : "Native stdio state whose child descriptor may move"
 @param child_fd : "Child stdio descriptor number"
 @return ? nova::BACKEND_FAILED : "fcntl failed"
 @require native_stdio != null : "Native stdio pointer must not be null"
*>
fn void? move_conflicting_child_stdio_fd(NativeStdio* native_stdio, CInt child_fd) @local
{
	if (native_stdio.child_fd != child_fd) return;

	os::NativeSocket socket = (os::NativeSocket)native_stdio.child_fd;
	CInt moved              = fcntl_retry(socket, PROCESS_F_DUPFD, PROCESS_STDIO_FD_COUNT);
	if (moved < 0) return nova::BACKEND_FAILED~;
	if (catch err = set_fd_cloexec(moved))
	{
		(void)libc::close(moved);
		return err~;
	}
	(void)libc::close(native_stdio.child_fd);
	native_stdio.child_fd = moved;
}

<*
 Close temporary `/dev/null` descriptors in the child after dup2 actions run.

 @param state : "Temporary native spawn state"
 @param actions : "POSIX spawn file actions to update"
 @return ? nova::BACKEND_FAILED : "Native close action setup failed"
 @require state != null : "Spawn state pointer must not be null"
 @require actions != null : "File actions pointer must not be null"
*>
fn void? add_devnull_close_actions(NativeSpawnState* state, posix::Posix_spawn_file_actions_t* actions) @local
{
	if (state.devnull_read >= 0 && state.devnull_read != libc::STDIN_FD)
	{
		if (posix::spawn_file_actions_addclose(actions, state.devnull_read) != 0) return nova::BACKEND_FAILED~;
	}
	if (state.devnull_write >= 0 && state.devnull_write != state.devnull_read && state.devnull_write != libc::STDOUT_FD
		&& state.devnull_write != libc::STDERR_FD)
	{
		if (posix::spawn_file_actions_addclose(actions, state.devnull_write) != 0) return nova::BACKEND_FAILED~;
	}
}

<*
 Put the parent side of a process pipe in close-on-exec and nonblocking mode.

 @param fd : "Parent-side pipe descriptor"
 @return ? nova::BACKEND_FAILED : "fcntl failed"
*>
fn void? prepare_process_pipe_parent(CInt fd) @local
{
	set_fd_cloexec(fd)!;
	os::NativeSocket socket = (os::NativeSocket)fd;
	int flags               = fcntl_retry(socket, (CInt)os::F_GETFL, 0);
	if (flags < 0) return nova::BACKEND_FAILED~;
	if (fcntl_retry(socket, (CInt)os::F_SETFL, flags | os::O_NONBLOCK) < 0) return nova::BACKEND_FAILED~;
}

<*
 Put the child side of a process pipe in close-on-exec mode.

 The descriptor intentionally remains blocking.

 @param fd : "Child-side pipe descriptor"
 @return ? nova::BACKEND_FAILED : "fcntl failed"
*>
fn void? prepare_process_pipe_child(CInt fd) @local
{
	set_fd_cloexec(fd)!;
}

<*
 Put one descriptor in close-on-exec mode.

 @param fd : "Descriptor to update"
 @return ? nova::BACKEND_FAILED : "fcntl failed"
*>
fn void? set_fd_cloexec(CInt fd)
{
	os::NativeSocket socket = (os::NativeSocket)fd;
	int flags               = fcntl_retry(socket, PROCESS_F_GETFD, 0);
	if (flags < 0) return nova::BACKEND_FAILED~;
	if (fcntl_retry(socket, PROCESS_F_SETFD, flags | PROCESS_FD_CLOEXEC) < 0) return nova::BACKEND_FAILED~;
}

<*
 Retry process `fcntl` while it is interrupted by `EINTR`.

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
 Close both descriptors from a failed pipe setup.

 @param first : "First descriptor"
 @param second : "Second descriptor"
*>
fn void close_pipe_setup_fds(CInt first, CInt second) @local
{
	if (first >= 0) (void)libc::close(first);
	if (second >= 0 && second != first) (void)libc::close(second);
}

<*
 Close a child-side pipe descriptor in the parent process.

 @param native_stdio : "Native stdio state to clean"
 @require native_stdio != null : "Native stdio pointer must not be null"
*>
fn void close_child_fd(NativeStdio* native_stdio) @local
{
	if (native_stdio.child_fd >= 0) (void)libc::close(native_stdio.child_fd);
	native_stdio.child_fd = -1;
}

<*
 Close parent stdio endpoints after a spawn setup failure.

 @param process : "Process handle being prepared"
 @param state : "Native spawn state"
 @require process != null : "Process pointer must not be null"
 @require state != null : "Spawn state pointer must not be null"
*>
fn void cleanup_failed_stdio(Process* process, NativeSpawnState* state) @local
{
	cleanup_failed_endpoint(&state.stdin);
	cleanup_failed_endpoint(&state.stdout);
	cleanup_failed_endpoint(&state.stderr);
	process.has_stdin = false;
	process.has_stdout = false;
	process.has_stderr = false;
}

<*
 Close and reset one parent endpoint after a spawn setup failure.

 @param native_stdio : "Native stdio state to clean"
 @require native_stdio != null : "Native stdio pointer must not be null"
*>
fn void cleanup_failed_endpoint(NativeStdio* native_stdio) @local
{
	if (!native_stdio.parent_endpoint) return;
	(void)pipe::close_now(native_stdio.endpoint);
	native_stdio.endpoint.destroy();
	native_stdio.parent_fd = -1;
	native_stdio.parent_endpoint = false;
}

<*
 Open or reuse a `/dev/null` descriptor for ignored stdio.

 @param state : "Temporary native spawn state"
 @param read_only : "Open the descriptor read-only for stdin"
 @return "Opened `/dev/null` descriptor"
 @return ? io::FILE_NOT_FOUND : "`/dev/null` could not be opened"
 @return ? io::NO_PERMISSION : "`/dev/null` could not be opened by this process"
 @return ? nova::BACKEND_FAILED : "Native open failed unexpectedly"
 @require state != null : "Spawn state pointer must not be null"
*>
fn CInt? ensure_devnull(NativeSpawnState* state, bool read_only) @local
{
	if (read_only && state.devnull_read >= 0) return state.devnull_read;
	if (!read_only && state.devnull_write >= 0) return state.devnull_write;

	CInt fd;
	CInt open_flags = PROCESS_O_RDWR | PROCESS_O_CLOEXEC;
	if (read_only) open_flags = PROCESS_O_RDONLY | PROCESS_O_CLOEXEC;
	do
	{
		fd = process_open("/dev/null", open_flags);
	} while (fd < 0 && libc::errno() == posix_errno::E_INTR);
	if (fd < 0) return spawn_status_to_fault(libc::errno())~;

	if (read_only)
	{
		state.devnull_read = fd;
		return fd;
	}
	state.devnull_write = fd;
	return fd;
}

<*
 Start a backend-specific process waiter when the current platform supports it.

 Linux uses pidfd readiness through epoll. Any setup failure falls back to the
 portable SIGCHLD path that was armed before spawn.

 @param loop : "Loop that owns the process"
 @param process : "Spawned process handle"
 @param userdata : "Opaque user pointer delivered to the exit callback"
 @return "True when a backend waiter was installed"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
*>
fn bool start_process_backend_waiter(Loop* loop, Process* process, void* userdata) @local
{
	$switch:
		$case env::LINUX:
			if (catch open_pidfd(process))
			{
				close_process_wait_handle(process);
				return false;
			}
			if (catch backend::process_wait_submit(
				loop,
				&process.header,
				&process.wait_backend,
				process.wait_handle,
				&dispatch_process_exit,
				process,
				userdata
			))
			{
				close_process_wait_handle(process);
				return false;
			}
			process.backend_wait = true;
			return true;
		$case env::DARWIN:
			process.wait_handle = (NativeHandle)(int)process.pid;
			process.wait_handle_owned = false;
			if (catch backend::process_wait_submit(
				loop,
				&process.header,
				&process.wait_backend,
				process.wait_handle,
				&dispatch_process_exit,
				process,
				userdata
			))
			{
				process.wait_handle = (NativeHandle)-1;
				return false;
			}
			process.backend_wait = true;
			return true;
		$default:
			(void)loop;
			(void)process;
			(void)userdata;
			return false;
	$endswitch
}

<*
 Open a Linux pidfd for a spawned child process.

 @param process : "Spawned process handle"
 @return ? nova::BACKEND_FAILED : "pidfd_open failed or is unavailable"
 @require process != null : "Process pointer must not be null"
*>
fn void? open_pidfd(Process* process) @local @if(env::LINUX)
{
	sz result = (sz)@syscall(PROCESS_SYS_PIDFD_OPEN, (uptr)(int)process.pid, (uptr)0);
	if (result < 0) return nova::BACKEND_FAILED~;
	process.wait_handle = (NativeHandle)(int)result;
	process.wait_handle_owned = true;
	set_fd_cloexec((CInt)(int)process.wait_handle)!;
}

<*
 Close a process backend wait descriptor if one is open.

 @param process : "Process handle that may own a pidfd"
 @require process != null : "Process pointer must not be null"
*>
fn void close_process_wait_handle(Process* process) @local
{
	if (process.wait_handle_owned && (int)process.wait_handle >= 0)
	{
		(void)libc::close((CInt)(int)process.wait_handle);
	}
	process.wait_handle = (NativeHandle)-1;
	process.wait_handle_owned = false;
}

<*
 Remove backend process wait interest and close the wait descriptor.

 @param loop : "Loop that owns the process backend wait"
 @param process : "Process handle leaving the active process list"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
*>
fn void close_backend_waiter(Loop* loop, Process* process) @local
{
	if (process.backend_wait)
	{
		backend::unregister_interest(loop, &process.header);
		process.backend_wait = false;
		loop.process_backed_count--;
	}
	close_process_wait_handle(process);
}

<*
 Start the loop's internal SIGCHLD watcher if it is not active.

 @param loop : "Loop that will own process handles"
 @return ? nova::BACKEND_FAILED : "Native signal handler registration failed"
 @return ? nova::INVALID_STATE : "Loop is invalid or not owned by the current thread"
 @require loop != null : "Loop pointer must not be null"
*>
fn void? ensure_process_signal(Loop* loop) @local
{
	if (loop.process_signal.header.active())
	{
		loop.process_signal_ready = true;
		return;
	}
	loop.process_signal.init();
	if (catch err = signal::start(loop, &loop.process_signal, { .signum = libc::SIGCHLD }, &on_process_signal, null))
	{
		loop.process_signal.destroy();
		loop.process_signal_ready = false;
		return err~;
	}
	loop.process_signal_ready = true;
}

<*
 Stop the loop's internal SIGCHLD watcher when no processes remain.

 @param loop : "Loop that owns the internal process signal watcher"
 @require loop != null : "Loop pointer must not be null"
*>
fn void stop_process_signal_now(Loop* loop) @local
{
	if (!loop.process_signal_ready || !loop.process_signal.header.active()) return;
	if (loop.process_signal.header.state == op::State.OP_ACTIVE)
	{
		signal::unregister(loop, &loop.process_signal.header);
		op::reset_header(&loop.process_signal.header);
		loop.process_signal.destroy();
		loop.process_signal_ready = false;
		return;
	}
	if (loop.process_signal.header.state == op::State.OP_READY) return;
	if (@ok(signal::stop(loop, &loop.process_signal))) loop.process_signal_ready = false;
}

<*
 Report whether any active process in the loop still needs SIGCHLD fallback.

 @param loop : "Loop that owns active process handles"
 @return "True when at least one child has no backend-specific waiter"
 @require loop != null : "Loop pointer must not be null"
*>
fn bool process_signal_required(Loop* loop) @local
{
	return loop.process_count > loop.process_backed_count;
}

<*
 Drain child exits after SIGCHLD is delivered.

 @param loop : "Loop dispatching the internal signal"
 @param op : "Internal signal operation"
 @param result : "Signal delivery result"
*>
fn void on_process_signal(Loop* loop, signal::SignalOp* op, signal::SignalResult* result, void* userdata) @local
{
	(void)op;
	(void)userdata;
	if (!result.error.status) (void)native_drain_exited(loop);
	if (!process_signal_required(loop)) stop_process_signal_now(loop);
}

<*
 Attach a newly spawned process to the owning loop list.

 @param loop : "Loop that owns the process"
 @param process : "Process handle to attach"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
*>
fn void attach_process(Loop* loop, Process* process) @local
{
	process.loop_prev = loop.process_tail;
	process.loop_next = null;
	if (loop.process_tail) loop.process_tail.loop_next = process;
	if (!loop.process_head) loop.process_head = process;
	loop.process_tail = process;
	loop.process_count++;
	if (process.backend_wait) loop.process_backed_count++;
}

<*
 Remove a process from its owning loop list.

 @param loop : "Loop that owns the process"
 @param process : "Process handle to detach"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
 @require loop.process_count > 0 : "Loop must track at least one process"
*>
fn void detach_process(Loop* loop, Process* process) @local
{
	if (process.loop_prev) process.loop_prev.loop_next = process.loop_next;
	if (process.loop_next) process.loop_next.loop_prev = process.loop_prev;
	if (loop.process_head == process) loop.process_head = process.loop_next;
	if (loop.process_tail == process) loop.process_tail = process.loop_prev;
	process.loop_next = null;
	process.loop_prev = null;
	always_assert(loop.process_count > 0);
	loop.process_count--;
	if (process.backend_wait) loop.process_backed_count--;
	if (!process_signal_required(loop)) stop_process_signal_now(loop);
}

<*
 Store a native wait status in the process handle and detach backend resources.

 @param loop : "Loop that owns the process"
 @param process : "Process handle that reached a terminal state"
 @param status : "Native wait status"
 @param error : "Process result error information"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
*>
fn void store_process_exit(Loop* loop, Process* process, CInt status, ErrorInfo error) @local
{
	close_backend_waiter(loop, process);
	detach_process(loop, process);
	process.exited = true;
	CInt exit_status = 0;
	if (posix::wIFEXITED(status)) exit_status = posix::wEXITSTATUS(status);
	CInt term_signal = 0;
	if (posix::wIFSIGNALED(status)) term_signal = posix::wTERMSIG(status);
	process.result = {
		.error = error,
		.pid = process.pid,
		.exit_status = exit_status,
		.term_signal = term_signal,
		.exited = posix::wIFEXITED(status),
		.signaled = posix::wIFSIGNALED(status),
	};
}

<*
 Convert a native wait status into `ExitResult` and queue the callback.

 @param loop : "Loop that owns the process"
 @param process : "Process handle that reached a terminal state"
 @param status : "Native wait status"
 @param terminal_status : "Ready-queue status"
 @param error : "Process result error information"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
*>
fn void finish_process_exit(Loop* loop, Process* process, CInt status, fault terminal_status, ErrorInfo error) @local
{
	store_process_exit(loop, process, status, error);
	nova::queue_ready(loop, &process.header, terminal_status);
}

<*
 Reap a process after a backend-specific readiness event.

 @param loop : "Loop dispatching the process wait"
 @param process : "Process handle whose pidfd became readable"
 @require loop != null : "Loop pointer must not be null"
 @require process != null : "Process pointer must not be null"
*>
fn void finish_backend_process_exit(Loop* loop, Process* process) @local
{
	CInt status;
	Pid_t result = waitpid_nohang(process.pid, &status);
	if (result == (Pid_t)process.pid)
	{
		store_process_exit(loop, process, status, { });
		return;
	}

	Errno err = posix_errno::E_CHILD;
	if (result < 0) err = libc::errno();
	ErrorInfo error = posix_error_info(nova::BACKEND_FAILED, err);
	store_process_exit(loop, process, 0, error);
}

<*
 Dispatch a completed process exit callback on the owner loop.

 @param loop : "Loop dispatching the process exit"
 @param raw : "Ready process operation header"
 @require loop != null : "Loop pointer must not be null"
 @require raw != null : "Ready header pointer must not be null"
*>
fn void dispatch_process_exit(Loop* loop, void* raw) @local
{
	op::Header* header = (op::Header*)raw;
	Process* process   = (Process*)header.owner;
	Callback callback  = process.callback;
	void* userdata     = header.userdata;

	if (!process.exited) finish_backend_process_exit(loop, process);
	if (header.terminal_status) process.result.error.status = header.terminal_status;
	op::reset_header(header);
	process.callback = null;
	if (callback) callback(loop, process, &process.result, userdata);
}

<*
 Copy spawn argv into scoped native zero-terminated strings.

 @param allocator : "Scoped allocator for copied strings"
 @param options : "Spawn options containing file and args"
 @return "Null-terminated argv vector"
*>
fn ZString* copy_argv(Allocator allocator, SpawnOptions options) @local
{
	ZString* copy = alloc::alloc_array(allocator, ZString, options.args.len + 2);
	copy[0] = options.file.zstr_copy(allocator);
	foreach (i, str : options.args)
	{
		copy[i + 1] = str.zstr_copy(allocator);
	}
	copy[options.args.len + 1] = null;
	return copy;
}

<*
 Copy environment entries into scoped native zero-terminated strings.

 @param allocator : "Scoped allocator for copied strings"
 @param environment : "Environment entries in NAME=VALUE form"
 @return "Null-terminated envp vector"
*>
fn ZString* copy_env(Allocator allocator, String[] environment) @local
{
	if (!environment.len) return &PROCESS_EMPTY_ENVIRONMENT;
	ZString* copy = alloc::alloc_array(allocator, ZString, environment.len + 1);
	foreach (i, str : environment)
	{
		copy[i] = str.zstr_copy(allocator);
	}
	copy[environment.len] = null;
	return copy;
}

<*
 Spawn an executable using the PATH that belongs to the selected environment.

 libc `posix_spawnp` searches the parent process environment on common POSIX
 platforms. When the child environment is overridden, emulate execvpe-style PATH
 lookup so `options.env` controls both the child environment and executable
 discovery.

 @param allocator : "Scoped allocator for candidate path strings"
 @param child : "Output child pid"
 @param options : "Spawn options"
 @param actions : "Prepared POSIX spawn file actions"
 @param attrs : "Prepared POSIX spawn attributes"
 @param argv : "Null-terminated child argv"
 @param envp : "Null-terminated child environment"
 @return "Zero on success, otherwise POSIX errno-style spawn status"
*>
fn CInt spawn_with_path_search(
	Allocator allocator,
	Pid_t* child,
	SpawnOptions options,
	posix::Posix_spawn_file_actions_t* actions,
	posix::Posix_spawnattr_t* attrs,
	ZString* argv,
	ZString* envp
) @local
{
	if (try options.file.index_of_char('/')) return retry_spawn(child, argv[0], actions, attrs, argv, envp);
	if (options.file.len > PROCESS_NAME_MAX) return (CInt)posix_errno::E_NAMETOOLONG;
	if (options.inherit_env) return retry_spawnp(child, argv[0], actions, attrs, argv, envp);

	String path      = environment_path(options.env);
	String remaining = path;
	bool seen_access = false;
	while (true)
	{
		sz segment_len = remaining.len;
		if (try colon = remaining.index_of_char(':')) segment_len = colon;

		String dir        = remaining[0:segment_len];
		ZString candidate = process_path_candidate(allocator, dir, options.file);
		CInt status       = retry_spawn(child, candidate, actions, attrs, argv, envp);
		if (status == 0) return 0;
		if ((Errno)status == posix_errno::E_ACCES)
		{
			seen_access = true;
		}
		else if ((Errno)status != posix_errno::E_NOENT && (Errno)status != posix_errno::E_NOTDIR
			&& (Errno)status != posix_errno::E_NAMETOOLONG)
		{
			return status;
		}

		if (segment_len == remaining.len) break;
		remaining = remaining[segment_len + 1:remaining.len - segment_len - 1];
	}

	if (seen_access) return (CInt)posix_errno::E_ACCES;
	return (CInt)posix_errno::E_NOENT;
}

<*
 Fork and exec an executable using the PATH selected by spawn options.

 @param allocator : "Scoped allocator for candidate path strings"
 @param child : "Output child pid"
 @param options : "Spawn options"
 @param state : "Prepared fork stdio state"
 @param argv : "Null-terminated child argv"
 @param envp : "Null-terminated child environment"
 @param cwd : "Optional zero-terminated child cwd"
 @return "Zero on success, otherwise POSIX errno-style status"
 @require child != null : "Output child pid pointer must not be null"
 @require state != null : "Spawn state pointer must not be null"
*>
fn CInt fork_with_path_search(
	Allocator allocator,
	Pid_t* child,
	SpawnOptions options,
	NativeSpawnState* state,
	ZString* argv,
	ZString* envp,
	ZString cwd
) @local
{
	if (!options.search_path)
	{
		ForkExecAttempt attempt = fork_exec_path(child, argv[0], state, options, argv, envp, cwd);
		return attempt.status;
	}
	if (try options.file.index_of_char('/'))
	{
		ForkExecAttempt attempt = fork_exec_path(child, argv[0], state, options, argv, envp, cwd);
		return attempt.status;
	}
	if (options.file.len > PROCESS_NAME_MAX) return (CInt)posix_errno::E_NAMETOOLONG;

	String path      = spawn_search_path(options);
	String remaining = path;
	bool seen_access = false;
	while (true)
	{
		sz segment_len = remaining.len;
		if (try colon = remaining.index_of_char(':')) segment_len = colon;

		String dir              = remaining[0:segment_len];
		ZString candidate       = process_path_candidate(allocator, dir, options.file);
		ForkExecAttempt attempt = fork_exec_path(child, candidate, state, options, argv, envp, cwd);
		if (attempt.status == 0) return 0;
		if (!attempt.exec_error) return attempt.status;
		if ((Errno)attempt.status == posix_errno::E_ACCES)
		{
			seen_access = true;
		}
		else if ((Errno)attempt.status != posix_errno::E_NOENT && (Errno)attempt.status != posix_errno::E_NOTDIR
			&& (Errno)attempt.status != posix_errno::E_NAMETOOLONG)
		{
			return attempt.status;
		}

		if (segment_len == remaining.len) break;
		remaining = remaining[segment_len + 1:remaining.len - segment_len - 1];
	}

	if (seen_access) return (CInt)posix_errno::E_ACCES;
	return (CInt)posix_errno::E_NOENT;
}

<*
 Attempt one fork/execve launch and report pre-exec failure synchronously.

 @param child : "Output child pid"
 @param path : "Executable path candidate"
 @param state : "Prepared fork stdio state"
 @param options : "Spawn options"
 @param argv : "Null-terminated child argv"
 @param envp : "Null-terminated child environment"
 @param cwd : "Optional zero-terminated child cwd"
 @return "Attempt status and whether failure came from execve"
 @require child != null : "Output child pid pointer must not be null"
 @require state != null : "Spawn state pointer must not be null"
*>
fn ForkExecAttempt fork_exec_path(
	Pid_t* child,
	ZString path,
	NativeSpawnState* state,
	SpawnOptions options,
	ZString* argv,
	ZString* envp,
	ZString cwd
) @local
{
	CInt[2] error_pipe = { -1, -1 };
	CInt pipe_status   = open_process_error_pipe(&error_pipe);
	if (pipe_status != 0) return { .status = pipe_status };

	Pid_t pid = process_fork();
	if (pid < 0)
	{
		CInt err = (CInt)libc::errno();
		close_pipe_setup_fds(error_pipe[0], error_pipe[1]);
		return { .status = err };
	}
	if (pid == 0)
	{
		(void)libc::close(error_pipe[0]);
		fork_child_exec(state, options, path, argv, envp, cwd, error_pipe[1]);
	}

	(void)libc::close(error_pipe[1]);
	ForkExecAttempt attempt = read_fork_exec_status(error_pipe[0], pid);
	(void)libc::close(error_pipe[0]);
	if (attempt.status == 0) *child = pid;
	return attempt;
}

<*
 Execute child setup after fork and replace the process image.

 @param state : "Prepared fork stdio state"
 @param options : "Spawn options"
 @param path : "Executable path"
 @param argv : "Null-terminated child argv"
 @param envp : "Null-terminated child environment"
 @param cwd : "Optional zero-terminated child cwd"
 @param error_fd : "Close-on-exec error report descriptor"
 @require state != null : "Spawn state pointer must not be null"
*>
fn void fork_child_exec(
	NativeSpawnState* state,
	SpawnOptions options,
	ZString path,
	ZString* argv,
	ZString* envp,
	ZString cwd,
	CInt error_fd
) @local
{
	fork_child_reset_signals(error_fd);
	if (options.detached && process_setsid() < 0) fork_child_fail(error_fd, PROCESS_CHILD_STAGE_SETUP);

	fork_child_apply_stdio(state, &state.stdin, libc::STDIN_FD, options.stdin, error_fd);
	fork_child_apply_stdio(state, &state.stdout, libc::STDOUT_FD, options.stdout, error_fd);
	if (options.stderr_to_stdout)
	{
		if (process_dup2(libc::STDOUT_FD, libc::STDERR_FD) < 0) fork_child_fail(error_fd, PROCESS_CHILD_STAGE_SETUP);
	}
	else
	{
		fork_child_apply_stdio(state, &state.stderr, libc::STDERR_FD, options.stderr, error_fd);
	}

	if (cwd && process_chdir(cwd) != 0) fork_child_fail(error_fd, PROCESS_CHILD_STAGE_SETUP);
	if (process_execve(path, argv, envp) != 0) fork_child_fail(error_fd, PROCESS_CHILD_STAGE_EXEC);
	fork_child_fail(error_fd, PROCESS_CHILD_STAGE_EXEC);
}

<*
 Reset child signal dispositions and mask before exec.

 This mirrors the `posix_spawn` attributes used by the fast path so fork
 fallback children do not inherit nova loop signal handlers.

 @param error_fd : "Error report descriptor"
*>
fn void fork_child_reset_signals(CInt error_fd) @local
{
	libc::Sigaction action;
	action.sa_handler = (libc::SignalFunction)null;
	for (CInt signum = 1; signum < PROCESS_SIGNAL_COUNT; signum++)
	{
		if (signum == libc::SIGKILL || signum == libc::SIGSTOP) continue;
		if (libc::sigaction(signum, &action, null) != 0)
		{
			fork_child_fail(error_fd, PROCESS_CHILD_STAGE_SETUP);
		}
	}
	libc::Sigset_t empty = { };
	if (process_sigprocmask(
		PROCESS_SIG_SETMASK,
		&empty,
		null
	) != 0) fork_child_fail(error_fd, PROCESS_CHILD_STAGE_SETUP);
}

<*
 Apply one fork-child stdio mapping.

 @param state : "Prepared fork stdio state"
 @param native_stdio : "Native stdio state for this descriptor"
 @param child_fd : "Child stdio descriptor number"
 @param stdio : "Validated stdio configuration"
 @param error_fd : "Error report descriptor"
 @require state != null : "Spawn state pointer must not be null"
 @require native_stdio != null : "Native stdio pointer must not be null"
*>
fn void fork_child_apply_stdio(
	NativeSpawnState* state,
	NativeStdio* native_stdio,
	CInt child_fd,
	Stdio stdio,
	CInt error_fd
) @local
{
	CInt source_fd = fork_child_stdio_source(state, native_stdio, child_fd, stdio);
	if (source_fd < 0) fork_child_fail(error_fd, PROCESS_CHILD_STAGE_SETUP);
	if (source_fd != child_fd && process_dup2(
		source_fd,
		child_fd
	) < 0) fork_child_fail(error_fd, PROCESS_CHILD_STAGE_SETUP);
}

<*
 Return the source descriptor for one fork-child stdio mapping.

 @param state : "Prepared fork stdio state"
 @param native_stdio : "Native stdio state for this descriptor"
 @param child_fd : "Child stdio descriptor number"
 @param stdio : "Validated stdio configuration"
 @return "Source descriptor, or negative when unavailable"
 @require state != null : "Spawn state pointer must not be null"
 @require native_stdio != null : "Native stdio pointer must not be null"
*>
fn CInt fork_child_stdio_source(NativeSpawnState* state, NativeStdio* native_stdio, CInt child_fd, Stdio stdio) @local
{
	switch (stdio.action)
	{
		case StdioAction.IGNORE:
			if (child_fd == libc::STDIN_FD) return state.devnull_read;
			return state.devnull_write;
		case StdioAction.INHERIT:
			return child_fd;
		case StdioAction.FD:
			if (native_stdio.child_fd >= 0) return native_stdio.child_fd;
			return (CInt)stdio.fd;
		case StdioAction.PIPE:
			return native_stdio.child_fd;
		default:
			return -1;
	}
}

<*
 Open a close-on-exec pipe for fork-child exec failure reporting.

 @param [out] fds : "Read/write pipe descriptors"
 @return "Zero on success, otherwise POSIX errno-style status"
 @require fds != null : "Pipe descriptor output must not be null"
*>
fn CInt open_process_error_pipe(CInt[2]* fds) @local
{
	CInt[2] local = { -1, -1 };
	$if env::LINUX:
		if (process_pipe2(&local, PROCESS_O_CLOEXEC) == 0)
		{
			*fds = local;
			return 0;
		}
		Errno err = libc::errno();
		if (err != posix_errno::E_INVAL && err != posix_errno::E_NOSYS) return (CInt)err;
	$endif
	if (posix::pipe(&local) != 0) return (CInt)libc::errno();
	if (catch set_fd_cloexec(local[0]))
	{
		close_pipe_setup_fds(local[0], local[1]);
		return (CInt)posix_errno::E_IO;
	}
	if (catch set_fd_cloexec(local[1]))
	{
		close_pipe_setup_fds(local[0], local[1]);
		return (CInt)posix_errno::E_IO;
	}
	*fds = local;
	return 0;
}

<*
 Read fork-child exec status and reap failed children.

 @param read_fd : "Parent read end of the close-on-exec error pipe"
 @param child : "Forked child pid"
 @return "Attempt status and whether the error came from execve"
*>
fn ForkExecAttempt read_fork_exec_status(CInt read_fd, Pid_t child) @local
{
	ForkExecError error;
	sz received;
	do
	{
		received = libc::read(read_fd, &error, (usz)ForkExecError::size);
	} while (received < 0 && libc::errno() == posix_errno::E_INTR);

	if (received == 0) return { };
	waitpid_blocking(child);
	if (received == (sz)ForkExecError::size)
	{
		return { .status = error.err, .exec_error = error.stage == PROCESS_CHILD_STAGE_EXEC };
	}
	return { .status = (CInt)posix_errno::E_IO };
}

<*
 Write a fork-child setup or exec error and exit the child.

 @param error_fd : "Child write end of the close-on-exec error pipe"
 @param stage : "Failure stage identifier"
*>
fn void fork_child_fail(CInt error_fd, CInt stage) @local
{
	ForkExecError error = { .stage = stage, .err = (CInt)libc::errno() };
	char* data          = (char*)&error;
	sz written          = 0;
	while (written < (sz)ForkExecError::size)
	{
		sz result = libc::write(error_fd, data + written, (usz)((sz)ForkExecError::size - written));
		if (result > 0)
		{
			written += result;
			continue;
		}
		if (result < 0 && libc::errno() == posix_errno::E_INTR) continue;
		break;
	}
	libc::_exit(127);
}

<*
 Reap a fork child after a pre-exec failure.

 @param child : "Child pid to wait for"
*>
fn void waitpid_blocking(Pid_t child) @local
{
	CInt status;
	Pid_t result;
	do
	{
		result = posix::waitpid(child, &status, 0);
	} while (result < 0 && libc::errno() == posix_errno::E_INTR);
}

<*
 Return the PATH used by fork fallback executable search.

 @param options : "Spawn options"
 @return "PATH from the selected environment or platform default"
*>
fn String spawn_search_path(SpawnOptions options) @local
{
	if (!options.inherit_env) return environment_path(options.env);
	ZString path = libc::getenv("PATH");
	if (path) return path.str_view();
	return PROCESS_DEFAULT_PATH;
}

<*
 Retry `posix_spawn` when interrupted before the child state is decided.

 @param child : "Output child pid"
 @param path : "Executable path"
 @param actions : "Prepared POSIX spawn file actions"
 @param attrs : "Prepared POSIX spawn attributes"
 @param argv : "Null-terminated child argv"
 @param envp : "Null-terminated child environment"
 @return "Zero on success, otherwise POSIX errno-style spawn status"
*>
fn CInt retry_spawn(
	Pid_t* child,
	ZString path,
	posix::Posix_spawn_file_actions_t* actions,
	posix::Posix_spawnattr_t* attrs,
	ZString* argv,
	ZString* envp
) @local
{
	CInt status;
	do
	{
		status = posix::spawn(child, path, actions, attrs, argv, envp);
	} while ((Errno)status == posix_errno::E_INTR);
	return status;
}

<*
 Retry `posix_spawnp` when interrupted before the child state is decided.

 @param child : "Output child pid"
 @param file : "Executable basename"
 @param actions : "Prepared POSIX spawn file actions"
 @param attrs : "Prepared POSIX spawn attributes"
 @param argv : "Null-terminated child argv"
 @param envp : "Null-terminated child environment"
 @return "Zero on success, otherwise POSIX errno-style spawn status"
*>
fn CInt retry_spawnp(
	Pid_t* child,
	ZString file,
	posix::Posix_spawn_file_actions_t* actions,
	posix::Posix_spawnattr_t* attrs,
	ZString* argv,
	ZString* envp
) @local
{
	CInt status;
	do
	{
		status = posix::spawnp(child, file, actions, attrs, argv, envp);
	} while ((Errno)status == posix_errno::E_INTR);
	return status;
}

<*
 Poll one child, retrying interrupted `waitpid` calls.

 @param pid : "Child process id"
 @param status : "Native wait status output"
 @return "waitpid result"
*>
fn Pid_t waitpid_nohang(Pid pid, CInt* status) @local
{
	Pid_t result;
	do
	{
		result = posix::waitpid((Pid_t)pid, status, posix::WNOHANG);
	} while (result < 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Return the PATH entry from a custom child environment.

 @param environment : "NAME=VALUE entries"
 @return "PATH value, or the platform default search path when absent"
*>
fn String environment_path(String[] environment) @local
{
	foreach (entry : environment)
	{
		if (entry.len >= 5 && mem::equals(entry.ptr, "PATH=".ptr, 5)) return entry[5:entry.len - 5];
	}
	return PROCESS_DEFAULT_PATH;
}

<*
 Build one PATH search candidate using scoped storage.

 @param allocator : "Scoped allocator for the returned zero-terminated string"
 @param dir : "PATH directory segment, empty for the current directory"
 @param file : "Executable basename"
 @return "Zero-terminated candidate path"
*>
fn ZString process_path_candidate(Allocator allocator, String dir, String file) @local
{
	sz slash = 0;
	if (dir.len) slash = 1;
	char[] out = alloc::alloc_array(allocator, char, dir.len + slash + file.len + 1);
	if (dir.len)
	{
		mem::copy(out.ptr, dir.ptr, dir.len);
		out[dir.len] = '/';
	}
	mem::copy(&out[dir.len + slash], file.ptr, file.len);
	out[out.len - 1] = 0;
	return (ZString)out.ptr;
}

<*
 Map POSIX spawn/open errno values to nova public faults.

 @param status : "POSIX errno value"
 @return "Portable fault for caller control flow"
*>
fn fault spawn_status_to_fault(Errno status) @local
{
	if (status == posix_errno::E_NOENT) return io::FILE_NOT_FOUND;
	if (status == posix_errno::E_NOTDIR) return io::FILE_NOT_FOUND;
	if (status == posix_errno::E_NAMETOOLONG) return io::NAME_TOO_LONG;
	if (status == posix_errno::E_ACCES) return io::NO_PERMISSION;
	if (status == posix_errno::E_PERM) return io::NO_PERMISSION;
	return nova::BACKEND_FAILED;
}

<*
 Build process error info with a POSIX errno diagnostic.

 @param status : "Portable operation status"
 @param err : "Captured POSIX errno"
 @return "Error info containing semantic status and native diagnostic"
*>
fn ErrorInfo posix_error_info(fault status, Errno err) @local
{
	return { .status = status, .platform = { .domain = nova::ErrorDomain.POSIX_ERRNO, .code = (int)err }, };
}
