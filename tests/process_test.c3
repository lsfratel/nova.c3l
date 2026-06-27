module nova_tests;

import std::io;
import std::core::test;
import std::os::posix;
import std::thread;
import libc;

import nova @norecurse, nova::op @public, nova::pipe, nova::process, nova::signal;

extern fn CInt test_dup(CInt oldfd) @cname("dup");
extern fn CInt test_dup2(CInt oldfd, CInt newfd) @cname("dup2");
extern fn CInt test_open(ZString pathname, CInt flags, ...) @cname("open");
extern fn CInt test_pthread_sigmask(CInt how, libc::Sigset_t* set, libc::Sigset_t* oldset) @cname("pthread_sigmask");
extern fn CInt test_sigaddset(libc::Sigset_t* set, CInt signum) @cname("sigaddset");

const CInt TEST_SIG_BLOCK   = env::LINUX ? 0 : 1;
const CInt TEST_SIG_SETMASK = env::LINUX ? 2 : 3;
const CInt TEST_O_RDWR      = 2;

struct ProcessSeen
{
	int calls;
	fault status;
	process::Pid pid;
	int exit_status;
	CInt term_signal;
	bool owner_thread;
	bool exited;
	bool signaled;
}

struct ProcessSignalSeen
{
	int calls;
	CInt signum;
	bool owner_thread;
}

struct ProcessPipeReadSeen
{
	fault status;
	int calls;
	sz bytes;
	bool eof;
	bool op_active;
}

struct ProcessPipeWriteSeen
{
	fault status;
	int calls;
	sz bytes;
	bool op_active;
}

fn void on_process_exit(Loop* loop, process::Process* child, process::ExitResult* result, void* userdata)
{
	ProcessSeen* seen = (ProcessSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.pid = child.get_pid();
	seen.exit_status = result.exit_status;
	seen.term_signal = result.term_signal;
	seen.owner_thread = loop.is_owner_thread();
	seen.exited = result.exited;
	seen.signaled = result.signaled;
}

fn void on_user_sigchld(Loop* loop, signal::SignalOp* op, signal::SignalResult* result, void* userdata)
{
	(void)op;
	ProcessSignalSeen* seen = (ProcessSignalSeen*)userdata;
	if (result.error.status) return;
	seen.calls += (int)result.count;
	seen.signum = result.signum;
	seen.owner_thread = loop.is_owner_thread();
}

fn void on_process_pipe_read(
	Loop* loop,
	pipe::Endpoint* endpoint,
	pipe::ReadOp* op,
	pipe::ReadResult* result,
	void* userdata
)
{
	(void)loop;
	(void)endpoint;
	ProcessPipeReadSeen* seen = (ProcessPipeReadSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.bytes = result.bytes;
	seen.eof = result.eof;
	seen.op_active = op.header.active();
}

fn void on_process_pipe_write(
	Loop* loop,
	pipe::Endpoint* endpoint,
	pipe::WriteOp* op,
	pipe::WriteResult* result,
	void* userdata
)
{
	(void)loop;
	(void)endpoint;
	ProcessPipeWriteSeen* seen = (ProcessPipeWriteSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.bytes = result.bytes;
	seen.op_active = op.header.active();
}

fn void process_dummy_dispatch(Loop* loop, void* raw)
{
	(void)loop;
	(void)raw;
}

fn void wait_for_process_exit(Loop* loop, process::Process* child)
{
	for (int i = 0; i < 1000 && child.active(); i++)
	{
		process::drain_exited(loop)!!;
		nova::run(loop, nova::RunMode.NO_WAIT)!!;
		if (child.active()) (void)thread::sleep_ms(1);
	}
}

fn void wait_for_process_signal_exit(Loop* loop, process::Process* child)
{
	for (int i = 0; i < 1000 && child.active(); i++)
	{
		nova::run(loop, nova::RunMode.NO_WAIT)!!;
		if (child.active()) (void)thread::sleep_ms(1);
	}
}

fn void wait_for_signal_stop(Loop* loop, signal::SignalOp* op)
{
	for (int i = 0; i < 1000 && op.active(); i++)
	{
		nova::run(loop, nova::RunMode.NO_WAIT)!!;
		if (op.active()) (void)thread::sleep_ms(1);
	}
}

fn void restore_test_stdin(CInt saved_stdin)
{
	(void)libc::close(libc::STDIN_FD);
	if (saved_stdin >= 0)
	{
		(void)test_dup2(saved_stdin, libc::STDIN_FD);
		(void)libc::close(saved_stdin);
		return;
	}

	CInt null_fd = test_open("/dev/null", 0);
	if (null_fd >= 0 && null_fd != libc::STDIN_FD) (void)libc::close(null_fd);
}

fn void restore_test_fd(CInt saved_fd, CInt target_fd)
{
	(void)libc::close(target_fd);
	if (saved_fd >= 0)
	{
		(void)test_dup2(saved_fd, target_fd);
		(void)libc::close(saved_fd);
		return;
	}

	CInt null_fd = test_open("/dev/null", TEST_O_RDWR);
	if (null_fd >= 0 && null_fd != target_fd)
	{
		(void)test_dup2(null_fd, target_fd);
		(void)libc::close(null_fd);
	}
}

fn String process_temp_path(char[] buffer, int id)
{
	CInt len = libc::snprintf(buffer.ptr, (usz)buffer.len, "/tmp/nova_process_%d_%d", posix::getpid(), id);
	test::@check(len > 0);
	test::@check((sz)len < buffer.len);
	return (String)buffer[0:(sz)len];
}

fn sz process_read_file(String path, char[] out)
{
	CFile file = libc::fopen(path.zstr_tcopy(), "rb");
	test::@check(file != null);
	defer (void)libc::fclose(file);
	return (sz)libc::fread(out.ptr, 1, (usz)out.len, file);
}

fn void test_process_init_destroy_lifecycle() @test
{
	process::Process child;

	child.init();
	test::@check(child.initialized);
	test::@check(!child.active());
	test::@check(!child.is_running());
	test::@check(!child.has_exited());
	test::eq((process::Pid)0, child.get_pid());
	test::@check(child.header.kind == op::Kind.PROCESS);

	child.destroy();
	test::@check(!child.initialized);
	test::@check(!child.active());
	test::@check(child.header.kind == op::Kind.PROCESS);
}

fn void test_process_stdio_helpers_and_options_defaults() @test
{
	process::Stdio ignored        = process::ignore();
	process::Stdio inherit        = process::inherit();
	process::Stdio fd             = process::fd((NativeHandle)3);
	process::Stdio piped          = process::piped();
	process::SpawnOptions options = process::make_options("sh");

	test::@check(ignored.action == process::StdioAction.IGNORE);
	test::@check(inherit.action == process::StdioAction.INHERIT);
	test::@check(fd.action == process::StdioAction.FD);
	test::eq((NativeHandle)3, fd.fd);
	test::@check(piped.action == process::StdioAction.PIPE);
	test::eq("sh", options.file);
	test::@check(options.inherit_env);
	test::@check(options.search_path);
}

fn void test_process_spawn_validation() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	process::SpawnOptions ok = process::make_options("sh");

	test::@error(process::spawn(&loop, &child, ok, &on_process_exit, &seen), nova::INVALID_STATE);

	loop.init()!!;
	test::@error(process::spawn(&loop, &child, ok, &on_process_exit, &seen), nova::INVALID_STATE);

	child.init();
	test::@error(process::spawn(&loop, &child, { }, &on_process_exit, &seen), nova::INVALID_STATE);

	ok.stdin = process::fd((NativeHandle)-1);
	test::@error(process::spawn(&loop, &child, ok, &on_process_exit, &seen), nova::INVALID_STATE);

	child.destroy();
	loop.destroy();
}

fn void test_process_kill_validation() @test
{
	process::Process child;

	test::@error(process::kill(&child, 15), nova::INVALID_STATE);
	test::@error(process::kill_pid((process::Pid)0, 15), nova::INVALID_STATE);
	test::@error(process::kill_pid((process::Pid)1, -1), nova::INVALID_STATE);

	child.init();
	test::@error(process::kill(&child, 15), NOT_FOUND);

	child.spawned = true;
	child.exited = false;
	child.pid = (process::Pid)2147483647;
	test::@error(process::kill(&child, 0), NOT_FOUND);
	test::@error(process::kill(&child, 15), NOT_FOUND);

	child.spawned = false;
	child.destroy();
}

fn void test_process_spawn_sh_exit_zero() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[2] args = { "-c", "exit 0" };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	test::@check(child.active());
	test::eq((sz)1, loop.process_count);

	wait_for_process_exit(&loop, &child);

	test::@check(!child.active());
	test::eq((sz)0, loop.process_count);
	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.exited);
	test::@check(!seen.signaled);
	test::eq(0, seen.exit_status);
	test::@check(seen.pid > (process::Pid)0);
	test::@check(seen.owner_thread);

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_sh_exit_nonzero() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[2] args = { "-c", "exit 42" };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	wait_for_process_exit(&loop, &child);

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.exited);
	test::@check(!seen.signaled);
	test::eq(42, seen.exit_status);

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_invalid_file() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	process::SpawnOptions options = process::make_options("nova-process-test-missing-executable");

	loop.init()!!;
	child.init();

	test::@error(process::spawn(&loop, &child, options, &on_process_exit, &seen), io::FILE_NOT_FOUND);
	test::@check(!child.active());
	test::eq((sz)0, loop.process_count);
	test::eq(0, seen.calls);

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_search_path_uses_custom_environment_path() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[1] env  = { "PATH=/tmp/nova_process_missing_path" };
	String[2] args = { "-c", "exit 0" };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.inherit_env = false;
	options.env = env[..];
	options.args = args[..];

	test::@error(process::spawn(&loop, &child, options, &on_process_exit, &seen), io::FILE_NOT_FOUND);
	test::@check(!child.active());
	test::eq((sz)0, loop.process_count);
	test::eq(0, seen.calls);

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_search_path_finds_executable_in_custom_environment_path() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[1] env  = { "PATH=/bin:/usr/bin" };
	String[2] args = { "-c", "exit 0" };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.inherit_env = false;
	options.env = env[..];
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	wait_for_process_exit(&loop, &child);

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.exited);
	test::@check(!seen.signaled);
	test::eq(0, seen.exit_status);

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_search_path_uses_platform_default_when_custom_environment_has_no_path() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[1] env  = { "C3EV_PROCESS_TEST_DEFAULT_PATH=1" };
	String[2] args = { "-c", "exit 0" };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.inherit_env = false;
	options.env = env[..];
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	wait_for_process_exit(&loop, &child);

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.exited);
	test::@check(!seen.signaled);
	test::eq(0, seen.exit_status);

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_search_path_skips_oversized_path_entry() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	char[5200] path_storage;
	String prefix            = "PATH=";
	String suffix            = ":/bin:/usr/bin";
	sz oversized_segment_len = 5000;
	String[2] args           = { "-c", "exit 0" };

	mem::copy(path_storage[..].ptr, prefix.ptr, prefix.len);
	for (sz i = 0; i < oversized_segment_len; i++) path_storage[prefix.len + i] = 'x';
	mem::copy(path_storage[..].ptr + prefix.len + oversized_segment_len, suffix.ptr, suffix.len);
	String[1] env = { (String)path_storage[0:prefix.len + oversized_segment_len + suffix.len] };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.inherit_env = false;
	options.env = env[..];
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	wait_for_process_exit(&loop, &child);

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.exited);
	test::@check(!seen.signaled);
	test::eq(0, seen.exit_status);

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_search_path_reports_oversized_executable_name() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	char[300] name;

	for (sz i = 0; i < name.len; i++) name[i] = 'x';

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options((String)name[..]);
	test::@error(process::spawn(&loop, &child, options, &on_process_exit, &seen), io::NAME_TOO_LONG);
	test::@check(!child.active());
	test::eq((sz)0, loop.process_count);
	test::eq(0, seen.calls);

	child.destroy();
	loop.destroy();
}

fn void test_process_fd_stdio_swaps_low_numbered_descriptors() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	char[128] stdout_storage;
	char[128] stderr_storage;
	String stdout_path   =  process_temp_path(stdout_storage[0:128], 21);
	String stderr_path   =  process_temp_path(stderr_storage[0:128], 22);
	String[2] args       =  { "-c", "printf out; printf err >&2" };
	char[8] stdout_contents;
	char[8] stderr_contents;
	CFile stdout_file    =  null;
	CFile stderr_file    =  null;
	CInt saved_stdout    = -1;
	CInt saved_stderr    = -1;
	bool stdout_restored =  false;
	bool stderr_restored =  false;

	(void)libc::remove(stdout_path.zstr_tcopy());
	(void)libc::remove(stderr_path.zstr_tcopy());
	defer
	{
		if (!stdout_restored) restore_test_fd(saved_stdout, libc::STDOUT_FD);
		if (!stderr_restored) restore_test_fd(saved_stderr, libc::STDERR_FD);
		if (stdout_file) (void)libc::fclose(stdout_file);
		if (stderr_file) (void)libc::fclose(stderr_file);
		(void)libc::remove(stdout_path.zstr_tcopy());
		(void)libc::remove(stderr_path.zstr_tcopy());
	}

	loop.init()!!;
	child.init();

	stdout_file = libc::fopen(stdout_path.zstr_tcopy(), "w+b");
	stderr_file = libc::fopen(stderr_path.zstr_tcopy(), "w+b");
	test::@check(stdout_file != null);
	test::@check(stderr_file != null);

	saved_stdout = test_dup(libc::STDOUT_FD);
	saved_stderr = test_dup(libc::STDERR_FD);
	test::@check(saved_stdout >= 0);
	test::@check(saved_stderr >= 0);
	(void)libc::fflush(null);
	test::eq(libc::STDOUT_FD, test_dup2((CInt)libc::fileno(stdout_file), libc::STDOUT_FD));
	test::eq(libc::STDERR_FD, test_dup2((CInt)libc::fileno(stderr_file), libc::STDERR_FD));

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	options.stdout = process::fd((NativeHandle)(int)libc::STDERR_FD);
	options.stderr = process::fd((NativeHandle)(int)libc::STDOUT_FD);

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	wait_for_process_exit(&loop, &child);

	restore_test_fd(saved_stdout, libc::STDOUT_FD);
	stdout_restored = true;
	restore_test_fd(saved_stderr, libc::STDERR_FD);
	stderr_restored = true;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.exited);
	test::eq(0, seen.exit_status);

	(void)libc::fclose(stdout_file);
	stdout_file = null;
	(void)libc::fclose(stderr_file);
	stderr_file = null;

	test::eq((sz)3, process_read_file(stdout_path, stdout_contents[0:8]));
	test::eq((sz)3, process_read_file(stderr_path, stderr_contents[0:8]));
	test::@check(mem::equals("err".ptr, stdout_contents[0:3].ptr, 3));
	test::@check(mem::equals("out".ptr, stderr_contents[0:3].ptr, 3));

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_kill_sigterm() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[1] args = { "5" };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sleep");
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	process::kill(&child, 0)!!;
	process::kill_pid(child.get_pid(), 0)!!;
	process::kill(&child, libc::SIGTERM)!!;
	wait_for_process_exit(&loop, &child);

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(!seen.exited);
	test::@check(seen.signaled);
	test::eq(libc::SIGTERM, seen.term_signal);

	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_resets_ignored_sigterm() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[1] args                = { "5" };
	libc::SignalFunction previous = (libc::SignalFunction)0;
	libc::Sigset_t mask;
	libc::Sigset_t saved_mask;
	bool parent_restored          = false;

	loop.init()!!;
	child.init();

	test::eq(0, libc::sigemptyset(&mask));
	test::eq(0, test_sigaddset(&mask, libc::SIGTERM));
	test::eq(0, test_pthread_sigmask(TEST_SIG_BLOCK, &mask, &saved_mask));
	previous = libc::signal(libc::SIGTERM, (libc::SignalFunction)1);
	defer
	{
		if (!parent_restored)
		{
			(void)libc::signal(libc::SIGTERM, previous);
			(void)test_pthread_sigmask(TEST_SIG_SETMASK, &saved_mask, null);
		}
	}

	process::SpawnOptions options = process::make_options("sleep");
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	(void)libc::signal(libc::SIGTERM, previous);
	test::eq(0, test_pthread_sigmask(TEST_SIG_SETMASK, &saved_mask, null));
	parent_restored = true;

	process::kill(&child, libc::SIGTERM)!!;
	wait_for_process_exit(&loop, &child);
	bool sigterm_exited = !child.active();
	if (!sigterm_exited)
	{
		process::kill(&child, libc::SIGKILL)!!;
		wait_for_process_exit(&loop, &child);
	}

	test::@check(sigterm_exited);
	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(!seen.exited);
	test::@check(seen.signaled);
	test::eq(libc::SIGTERM, seen.term_signal);

	child.destroy();
	loop.destroy();
}

fn void test_process_sigchld_exits_before_first_run() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[2] args = { "-c", "exit 0" };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	(void)thread::sleep_ms(10);
	wait_for_process_signal_exit(&loop, &child);

	test::@check(!child.active());
	test::eq((sz)0, loop.process_count);
	test::eq((sz)0, loop.signal_count);
	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.exited);
	test::eq(0, seen.exit_status);

	child.destroy();
	loop.destroy();
}

fn void test_process_sigchld_drains_multiple_children() @test
{
	Loop loop;
	process::Process[3] child;
	ProcessSeen[3] seen;
	String[2] args                = { "-c", "exit 0" };
	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];

	loop.init()!!;
	for (int i = 0; i < 3; i++)
	{
		child[i].init();
		process::spawn(&loop, &child[i], options, &on_process_exit, &seen[i])!!;
	}

	for (int i = 0; i < 1000 && (child[0].active() || child[1].active() || child[2].active()); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (child[0].active() || child[1].active() || child[2].active()) (void)thread::sleep_ms(1);
	}

	test::eq((sz)0, loop.process_count);
	test::eq((sz)0, loop.signal_count);
	for (int i = 0; i < 3; i++)
	{
		test::@check(!child[i].active());
		test::eq(1, seen[i].calls);
		test::@check(!seen[i].status);
		test::@check(seen[i].exited);
		test::eq(0, seen[i].exit_status);
		child[i].destroy();
	}
	loop.destroy();
}

fn void test_process_sigchld_user_watcher_coexists() @test
{
	Loop loop;
	process::Process child;
	signal::SignalOp user_signal;
	ProcessSeen seen;
	ProcessSignalSeen sig_seen;
	String[2] args = { "-c", "exit 0" };

	loop.init()!!;
	child.init();
	user_signal.init();
	signal::start(&loop, &user_signal, { .signum = libc::SIGCHLD }, &on_user_sigchld, &sig_seen)!!;

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	for (int i = 0; i < 1000 && (child.active() || sig_seen.calls == 0); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (child.active() || sig_seen.calls == 0) (void)thread::sleep_ms(1);
	}

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(sig_seen.calls > 0);
	test::eq(libc::SIGCHLD, sig_seen.signum);
	test::@check(sig_seen.owner_thread);

	if (user_signal.active()) signal::stop(&loop, &user_signal)!!;
	wait_for_signal_stop(&loop, &user_signal);
	user_signal.destroy();
	child.destroy();
	loop.destroy();
}

fn void test_process_stdout_pipe_capture() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	pipe::ReadOp read_op;
	ProcessPipeReadSeen read_seen;
	char[8] buffer;
	String[2] args = { "-c", "printf hello" };

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	options.stdout = process::piped();

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	test::@check(child.has_stdout);
	pipe::read(&loop, &child.stdout, buffer[0:8], &read_op, { .min_bytes = 5 }, &on_process_pipe_read, &read_seen)!!;

	for (int i = 0; i < 1000 && (read_seen.calls == 0 || child.active()); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (read_seen.calls == 0 || child.active()) (void)thread::sleep_ms(1);
	}

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)5, read_seen.bytes);
	test::@check(!read_seen.eof);
	test::@check(!read_seen.op_active);
	test::@check(buffer[0] == 'h');
	test::@check(buffer[1] == 'e');
	test::@check(buffer[2] == 'l');
	test::@check(buffer[3] == 'l');
	test::@check(buffer[4] == 'o');
	test::eq(1, seen.calls);

	process::close_stdio_now(&child)!!;
	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_with_cwd_pipe_capture_on_supported_posix() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	pipe::ReadOp read_op;
	ProcessPipeReadSeen read_seen;
	char[4] buffer;
	String[2] args = { "-c", "pwd -P" };

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	options.cwd = "/";
	options.stdout = process::piped();

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	test::@check(child.has_stdout);
	pipe::read(&loop, &child.stdout, buffer[0:4], &read_op, { .min_bytes = 2 }, &on_process_pipe_read, &read_seen)!!;

	for (int i = 0; i < 1000 && (read_seen.calls == 0 || child.active()); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (read_seen.calls == 0 || child.active()) (void)thread::sleep_ms(1);
	}

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)2, read_seen.bytes);
	test::@check(buffer[0] == '/');
	test::@check(buffer[1] == '\n');
	test::eq(1, seen.calls);
	test::eq(0, seen.exit_status);

	process::close_stdio_now(&child)!!;
	child.destroy();
	loop.destroy();
}

fn void test_process_spawn_missing_cwd_fails_on_supported_posix() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[2] args = { "-c", "exit 0" };

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	options.cwd = "/definitely/missing/nova/process/cwd";

	test::@error(process::spawn(&loop, &child, options, &on_process_exit, &seen), io::FILE_NOT_FOUND);
	test::@check(!child.active());
	test::eq((sz)0, loop.process_count);
	test::eq(0, seen.calls);

	child.destroy();
	loop.destroy();
}

fn void test_process_detached_spawn_reaps_on_supported_posix() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[2] args = { "-c", "exit 7" };

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	options.detached = true;

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	test::@check(child.detached);

	wait_for_process_exit(&loop, &child);

	test::@check(child.has_exited());
	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq(7, seen.exit_status);

	child.destroy();
	loop.destroy();
}

fn void test_process_reuse_requires_closed_stdio() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[2] args = { "-c", "printf hello" };

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	options.stdout = process::piped();

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	wait_for_process_exit(&loop, &child);

	test::@check(!child.active());
	test::@check(child.has_stdout);
	test::@error(process::spawn(&loop, &child, process::make_options("sh"), &on_process_exit, &seen), nova::BUSY);
	test::@check(child.has_stdout);

	process::close_stdio_now(&child)!!;
	child.destroy();
	loop.destroy();
}

fn void test_process_stderr_pipe_capture() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	pipe::ReadOp read_op;
	ProcessPipeReadSeen read_seen;
	char[8] buffer;
	String[2] args = { "-c", "printf err >&2" };

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	options.stderr = process::piped();

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	test::@check(child.has_stderr);
	pipe::read(&loop, &child.stderr, buffer[0:8], &read_op, { .min_bytes = 3 }, &on_process_pipe_read, &read_seen)!!;

	for (int i = 0; i < 1000 && (read_seen.calls == 0 || child.active()); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (read_seen.calls == 0 || child.active()) (void)thread::sleep_ms(1);
	}

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)3, read_seen.bytes);
	test::@check(buffer[0] == 'e');
	test::@check(buffer[1] == 'r');
	test::@check(buffer[2] == 'r');
	test::eq(1, seen.calls);

	process::close_stdio_now(&child)!!;
	child.destroy();
	loop.destroy();
}

fn void test_process_stdin_pipe_write_echo() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	pipe::ReadOp read_op;
	pipe::WriteOp write_op;
	ProcessPipeReadSeen read_seen;
	ProcessPipeWriteSeen write_seen;
	char[8] buffer;
	char[4] payload   = { 'p', 'i', 'n', 'g' };
	bool stdin_closed = false;

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("cat");
	options.stdin = process::piped();
	options.stdout = process::piped();

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	test::@check(child.has_stdin);
	test::@check(child.has_stdout);
	pipe::read(&loop, &child.stdout, buffer[0:8], &read_op, { .min_bytes = 4 }, &on_process_pipe_read, &read_seen)!!;
	pipe::write(&loop, &child.stdin, payload[0:4], &write_op, { }, &on_process_pipe_write, &write_seen)!!;

	for (int i = 0; i < 1000 && (read_seen.calls == 0 || child.active()); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (!stdin_closed && write_seen.calls > 0)
		{
			pipe::close_now(&child.stdin)!!;
			child.has_stdin = false;
			stdin_closed = true;
		}
		if (read_seen.calls == 0 || child.active()) (void)thread::sleep_ms(1);
	}

	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::eq((sz)4, write_seen.bytes);
	test::@check(!write_seen.op_active);
	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)4, read_seen.bytes);
	test::@check(buffer[0] == 'p');
	test::@check(buffer[1] == 'i');
	test::@check(buffer[2] == 'n');
	test::@check(buffer[3] == 'g');
	test::eq(1, seen.calls);

	process::close_stdio_now(&child)!!;
	child.destroy();
	loop.destroy();
}

fn void test_process_stdin_pipe_survives_closed_parent_stdin() @test
{
	Loop loop;
	signal::SignalOp signal_op;
	process::Process child;
	ProcessSeen seen;
	ProcessSignalSeen signal_seen;
	pipe::ReadOp read_op;
	pipe::WriteOp write_op;
	ProcessPipeReadSeen read_seen;
	ProcessPipeWriteSeen write_seen;
	char[8] buffer;
	char[4] payload     =  { 'p', 'i', 'n', 'g' };
	bool stdin_closed   =  false;
	bool stdin_restored =  false;
	CInt saved_stdin    = -1;

	loop.init({ .max_events = 8 })!!;
	signal_op.init();
	child.init();

	signal::start(&loop, &signal_op, { .signum = libc::SIGUSR1 }, &on_user_sigchld, &signal_seen)!!;
	saved_stdin = test_dup(libc::STDIN_FD);
	(void)libc::close(libc::STDIN_FD);
	defer
	{
		if (!stdin_restored) restore_test_stdin(saved_stdin);
	}

	process::SpawnOptions options = process::make_options("cat");
	options.stdin = process::piped();
	options.stdout = process::piped();

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;

	test::@check(child.has_stdin);
	test::@check(child.has_stdout);
	pipe::read(&loop, &child.stdout, buffer[0:8], &read_op, { .min_bytes = 4 }, &on_process_pipe_read, &read_seen)!!;
	pipe::write(&loop, &child.stdin, payload[0:4], &write_op, { }, &on_process_pipe_write, &write_seen)!!;

	for (int i = 0; i < 1000 && (read_seen.calls == 0 || child.active()); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (!stdin_closed && write_seen.calls > 0)
		{
			pipe::close_now(&child.stdin)!!;
			child.has_stdin = false;
			stdin_closed = true;
		}
		if (read_seen.calls == 0 || child.active()) (void)thread::sleep_ms(1);
	}

	test::eq(1, write_seen.calls);
	test::@check(!write_seen.status);
	test::eq((sz)4, write_seen.bytes);
	test::@check(!write_seen.op_active);
	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)4, read_seen.bytes);
	test::@check(buffer[0] == 'p');
	test::@check(buffer[1] == 'i');
	test::@check(buffer[2] == 'n');
	test::@check(buffer[3] == 'g');
	test::eq(1, seen.calls);

	process::close_stdio_now(&child)!!;
	restore_test_stdin(saved_stdin);
	stdin_restored = true;
	child.destroy();
	signal::stop(&loop, &signal_op)!!;
	wait_for_signal_stop(&loop, &signal_op);
	signal_op.destroy();
	loop.destroy();
}

fn void test_process_stdin_close_produces_stdout_eof() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	pipe::ReadOp read_op;
	ProcessPipeReadSeen read_seen;
	char[8] buffer;

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("cat");
	options.stdin = process::piped();
	options.stdout = process::piped();

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	pipe::close_now(&child.stdin)!!;
	child.has_stdin = false;
	pipe::read(&loop, &child.stdout, buffer[0:8], &read_op, { }, &on_process_pipe_read, &read_seen)!!;

	for (int i = 0; i < 1000 && (read_seen.calls == 0 || child.active()); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (read_seen.calls == 0 || child.active()) (void)thread::sleep_ms(1);
	}

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)0, read_seen.bytes);
	test::@check(read_seen.eof);
	test::eq(1, seen.calls);

	process::close_stdio_now(&child)!!;
	child.destroy();
	loop.destroy();
}

fn void test_process_stderr_to_stdout_pipe_capture() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	pipe::ReadOp read_op;
	ProcessPipeReadSeen read_seen;
	char[8] buffer;
	String[2] args = { "-c", "printf out; printf err >&2" };

	loop.init({ .max_events = 8 })!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	options.stdout = process::piped();
	options.stderr = process::piped();
	options.stderr_to_stdout = true;

	process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;
	test::@check(child.has_stdout);
	test::@check(!child.has_stderr);
	pipe::read(&loop, &child.stdout, buffer[0:8], &read_op, { .min_bytes = 6 }, &on_process_pipe_read, &read_seen)!!;

	for (int i = 0; i < 1000 && (read_seen.calls == 0 || child.active()); i++)
	{
		nova::run(&loop, nova::RunMode.NO_WAIT)!!;
		if (read_seen.calls == 0 || child.active()) (void)thread::sleep_ms(1);
	}

	test::eq(1, read_seen.calls);
	test::@check(!read_seen.status);
	test::eq((sz)6, read_seen.bytes);
	test::@check(buffer[0] == 'o');
	test::@check(buffer[1] == 'u');
	test::@check(buffer[2] == 't');
	test::@check(buffer[3] == 'e');
	test::@check(buffer[4] == 'r');
	test::@check(buffer[5] == 'r');
	test::eq(1, seen.calls);

	process::close_stdio_now(&child)!!;
	child.destroy();
	loop.destroy();
}

fn void test_process_cancel_live_handle_returns_busy() @test
{
	Loop loop;
	process::Process child;

	loop.init()!!;
	child.init();
	op::init_header(&child.header, op::Kind.PROCESS, &loop, &process_dummy_dispatch, &child, null);

	test::@error(op::cancel_op(&loop, &child.header), nova::BUSY);
	test::@check(child.active());

	op::reset_header(&child.header);
	child.destroy();
	loop.destroy();
}

fn void test_process_cancel_ready_exit_returns_busy_and_preserves_result() @test
{
	Loop loop;
	process::Process child;
	ProcessSeen seen;
	String[2] args = { "-c", "exit 7" };

	loop.init()!!;
	child.init();

	process::SpawnOptions options = process::make_options("sh");
	options.args = args[..];
	op::Ref ref = process::spawn(&loop, &child, options, &on_process_exit, &seen)!!;

	for (int i = 0; i < 1000 && child.header.state != op::State.OP_READY; i++)
	{
		process::drain_exited(&loop)!!;
		if (child.header.state != op::State.OP_READY) (void)thread::sleep_ms(1);
	}

	test::@check(child.header.state == op::State.OP_READY);
	test::@error(op::cancel_ref(&loop, ref), nova::BUSY);
	test::@check(child.header.state == op::State.OP_READY);

	nova::run(&loop, nova::RunMode.NO_WAIT)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.exited);
	test::@check(!seen.signaled);
	test::eq(7, seen.exit_status);
	test::@check(!child.active());

	child.destroy();
	loop.destroy();
}

fn void test_process_close_stdio_now_without_endpoints() @test
{
	process::Process child;

	test::@error(process::close_stdio_now(&child), nova::INVALID_STATE);

	child.init();
	process::close_stdio_now(&child)!!;
	child.destroy();
}

fn void test_process_many_concurrent_children_all_reaped() @test
{
	const int CHILDREN = 16;
	Loop loop;
	process::Process[CHILDREN] children;
	ProcessSeen[CHILDREN] seen;
	String[2] args     = { "-c", "exit 0" };

	loop.init()!!;

	for (int i = 0; i < CHILDREN; i++)
	{
		children[i].init();
		process::SpawnOptions options = process::make_options("sh");
		options.args = args[..];
		process::spawn(&loop, &children[i], options, &on_process_exit, &seen[i])!!;
	}
	test::eq((sz)CHILDREN, loop.process_count);

	for (int i = 0; i < 5000 && loop.process_count > 0; i++)
	{
		process::drain_exited(&loop)!!;
		nova::run(&loop, RunMode.NO_WAIT)!!;
		if (loop.process_count > 0) (void)thread::sleep_ms(1);
	}

	test::eq((sz)0, loop.process_count);
	for (int i = 0; i < CHILDREN; i++)
	{
		test::eq(1, seen[i].calls);
		test::@check(!seen[i].status);
		test::@check(seen[i].exited);
		test::eq(0, seen[i].exit_status);
		children[i].destroy();
	}
	loop.destroy();
}
