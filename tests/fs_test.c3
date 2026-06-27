module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import std::io, std::os::posix;
import std::thread;
import libc;

import nova @norecurse, nova::fs, nova::op @public, nova::work;

extern fn CInt test_symlink(ZString target, ZString linkpath) @cname("symlink");
extern fn CInt test_getrlimit(CInt resource, TestRlimit* limit) @cname("getrlimit");
extern fn CInt test_setrlimit(CInt resource, TestRlimit* limit) @cname("setrlimit");

const CInt TEST_RLIMIT_FSIZE = 1;

struct TestRlimit
{
	ulong current;
	ulong maximum;
}

struct FsSeen
{
	int calls;
	fault status;
	nova::ErrorInfo error;
	fs::FsKind kind;
	fs::File file;
	fs::Dir* dir;
	fs::Stat stat;
	fs::StatFs statfs;
	char[] path;
	char[512] path_storage;
	sz bytes;
	sz count;
	bool eof;
	bool owner_thread;
	bool op_active;
}

struct FsCancelCtx
{
	int blocker_calls;
	int after_calls;
	int fs_calls;
	fault fs_status;
}

fn void on_fs_seen(Loop* loop, fs::Op* op, fs::Result* result, void* userdata)
{
	FsSeen* seen = (FsSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.error = result.error;
	seen.kind = result.kind;
	seen.file = result.file;
	seen.dir = result.dir;
	seen.stat = result.stat;
	seen.statfs = result.statfs;
	if (result.path.len && result.path.len <= seen.path_storage.len)
	{
		mem::copy(seen.path_storage[0:result.path.len].ptr, result.path.ptr, result.path.len);
		seen.path = seen.path_storage[0:result.path.len];
	}
	else
	{
		seen.path = result.path;
	}
	seen.bytes = result.bytes;
	seen.count = result.count;
	seen.eof = result.eof;
	seen.owner_thread = loop.is_owner_thread();
	seen.op_active = op.active();
}

fn void? fs_blocker_work(WorkOp* op)
{
	FsCancelCtx* ctx = (FsCancelCtx*)op.header.userdata;
	ctx.blocker_calls++;
	thread::sleep_ms(80);
}

fn void after_fs_cancel_blocker(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)op;
	(void)status;
	FsCancelCtx* ctx = (FsCancelCtx*)userdata;
	ctx.after_calls++;
	if (ctx.after_calls == 2) loop.stop();
}

fn void on_fs_cancelled(Loop* loop, fs::Op* op, fs::Result* result, void* userdata)
{
	(void)op;
	FsCancelCtx* ctx = (FsCancelCtx*)userdata;
	ctx.after_calls++;
	ctx.fs_calls++;
	ctx.fs_status = result.error.status;
	if (ctx.after_calls == 2) loop.stop();
}

fn void ignore_xfsz(CInt signum)
{
	(void)signum;
}

const ZString FS_TEMP_BASE @if(env::DARWIN)  = "/private/tmp";
const ZString FS_TEMP_BASE @if(!env::DARWIN) = "/tmp";

fn String fs_temp_path(char[] buffer, int id)
{
	CInt len = libc::snprintf(buffer.ptr, (usz)buffer.len, "%s/nova_fs_%d_%d", FS_TEMP_BASE, posix::getpid(), id);
	test::@check(len > 0);
	test::@check((sz)len < buffer.len);
	return (String)buffer[0:(sz)len];
}

fn String fs_temp_child_path(char[] buffer, int dir_id, int child_id)
{
	CInt len = libc::snprintf(
		buffer.ptr,
		(usz)buffer.len,
		"%s/nova_fs_%d_%d/%d",
		FS_TEMP_BASE,
		posix::getpid(),
		dir_id,
		child_id
	);
	test::@check(len > 0);
	test::@check((sz)len < buffer.len);
	return (String)buffer[0:(sz)len];
}

fn String fs_temp_dir_template(char[] buffer, int id)
{
	CInt len = libc::snprintf(
		buffer.ptr,
		(usz)buffer.len,
		"%s/nova_fs_%d_%d_dir_XXXXXX",
		FS_TEMP_BASE,
		posix::getpid(),
		id
	);
	test::@check(len > 0);
	test::@check((sz)len < buffer.len);
	return (String)buffer[0:(sz)len];
}

fn String fs_temp_file_template(char[] buffer, int id)
{
	CInt len = libc::snprintf(
		buffer.ptr,
		(usz)buffer.len,
		"%s/nova_fs_%d_%d_file_XXXXXX",
		FS_TEMP_BASE,
		posix::getpid(),
		id
	);
	test::@check(len > 0);
	test::@check((sz)len < buffer.len);
	return (String)buffer[0:(sz)len];
}

fn bool fs_string_equals(String expected, char[] actual)
{
	return expected.len == actual.len && mem::equals(expected.ptr, actual.ptr, expected.len);
}

fn bool fs_entry_seen(fs::DirEntry[] entries, sz count, String name)
{
	for (sz i = 0; i < count; i++)
	{
		if (fs_string_equals(name, entries[i].name())) return true;
	}
	return false;
}

fn void fs_run_one(Loop* loop, FsSeen* seen)
{
	nova::run(loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, seen.calls);
	test::@check(seen.owner_thread);
	test::@check(!seen.op_active);
}

fn void fs_reset_seen(FsSeen* seen)
{
	*seen = { };
}

fn void fs_cleanup_path(String path)
{
	(void)libc::remove(path.zstr_tcopy());
}

fn void fs_touch_file(String path)
{
	CFile file = libc::fopen(path.zstr_tcopy(), "w");
	test::@check(file != null);
	test::eq((CInt)0, libc::fclose(file));
}

fn void test_fs_stat_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();
	Allocator allocator = &tracker;

	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	char[128] storage;
	String path = fs_temp_path(storage[0:128], 7);

	fs_touch_file(path);
	pool.init({ .workers = 1, .queue_capacity = 4 }, allocator)!!;
	loop.init({ .blocking_pool = &pool }, allocator)!!;
	op.init();
	sz allocation_count = tracker.total_allocation_count();

	fs::stat(&loop, &op, path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);

	test::@check(!seen.status);
	test::eq(allocation_count, tracker.total_allocation_count());

	op.destroy();
	loop.destroy();
	pool.destroy();
	fs_cleanup_path(path);
	test::@check(!tracker.has_leaks());
}

fn void test_fs_open_missing_reports_not_found() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	char[128] storage;
	String missing_path = fs_temp_path(storage[0:128], 1);

	fs_cleanup_path(missing_path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(&loop, &op, missing_path, { .access = fs::OpenAccess.READ }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);

	test::eq(fs::FsKind.OPEN, seen.kind);
	test::eq(io::FILE_NOT_FOUND, seen.status);
	test::eq(nova::ErrorDomain.POSIX_ERRNO, seen.error.platform.domain);

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_create_write_read_stat_truncate_and_close() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	char[128] storage;
	char[8] payload = { 'c', '3', 'e', 'v', '-', 'f', 's', '!' };
	char[8] input;
	String path     = fs_temp_path(storage[0:128], 2);

	fs_cleanup_path(path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(
		&loop,
		&op,
		path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::@check(seen.file.valid());
	file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, payload[0:8], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)8, seen.bytes);

	fs_reset_seen(&seen);
	fs::fsync(&loop, &op, file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::fdatasync(&loop, &op, file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::read(&loop, &op, file, input[0:8], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)8, seen.bytes);
	test::@check(mem::equals(payload[0:8].ptr, input[0:8].ptr, 8));

	fs_reset_seen(&seen);
	fs::fstat(&loop, &op, file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FileType.FILE, seen.stat.type);
	test::eq((long)8, seen.stat.size);

	fs_reset_seen(&seen);
	fs::ftruncate(&loop, &op, file, (fs::Offset)3, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::stat(&loop, &op, path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((long)3, seen.stat.size);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::@check(!file.valid());

	fs_cleanup_path(path);
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_open_directory_and_nofollow_options() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	char[128] dir_storage;
	char[128] file_storage;
	char[128] link_storage;
	String dir_path  = fs_temp_path(dir_storage[0:128], 21);
	String file_path = fs_temp_path(file_storage[0:128], 22);
	String link_path = fs_temp_path(link_storage[0:128], 23);

	fs_cleanup_path(link_path);
	fs_cleanup_path(file_path);
	(void)posix::rmdir(dir_path.zstr_tcopy());
	test::eq((CInt)0, posix::mkdir(dir_path.zstr_tcopy(), 0o700));
	fs_touch_file(file_path);
	test::eq((CInt)0, test_symlink(file_path.zstr_tcopy(), link_path.zstr_tcopy()));
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(&loop, &op, dir_path, { .access = fs::OpenAccess.READ, .directory = true }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::open(&loop, &op, file_path, { .access = fs::OpenAccess.READ, .directory = true }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(io::FILE_NOT_DIR, seen.status);

	fs_reset_seen(&seen);
	fs::open(&loop, &op, link_path, { .access = fs::OpenAccess.READ, .nofollow = true }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(io::SYMLINK_FAILED, seen.status);

	fs_cleanup_path(link_path);
	fs_cleanup_path(file_path);
	(void)posix::rmdir(dir_path.zstr_tcopy());
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_path_ops_mkdir_access_rename_readlink_realpath_unlink_rmdir() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	char[128] dir_storage;
	char[128] a_storage;
	char[128] b_storage;
	char[128] link_storage;
	char[128] dir_path;
	char[256] resolved;
	char[256] link_out;
	String dir    = fs_temp_path(dir_storage[0:128], 3);
	String path_a = fs_temp_path(a_storage[0:128], 4);
	String path_b = fs_temp_path(b_storage[0:128], 5);
	String link   = fs_temp_path(link_storage[0:128], 6);
	char[1] byte  = { 'x' };

	fs_cleanup_path(link);
	fs_cleanup_path(path_a);
	fs_cleanup_path(path_b);
	(void)posix::rmdir(dir.zstr_tcopy());
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::mkdir(&loop, &op, dir, 0o700, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::access(&loop, &op, dir, { }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::realpath(&loop, &op, dir, dir_path[0:128], &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::@check(fs_string_equals(dir, seen.path));

	fs_reset_seen(&seen);
	fs::open(
		&loop,
		&op,
		path_a,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, byte[0:1], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::rename(&loop, &op, path_a, path_b, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	test::eq((CInt)0, test_symlink(path_b.zstr_tcopy(), link.zstr_tcopy()));

	fs_reset_seen(&seen);
	fs::lstat(&loop, &op, link, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FileType.LINK, seen.stat.type);

	fs_reset_seen(&seen);
	fs::readlink(&loop, &op, link, link_out[0:256], &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::@check(fs_string_equals(path_b, seen.path));

	fs_reset_seen(&seen);
	fs::realpath(&loop, &op, link, resolved[0:256], &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::@check(seen.path.len > 0);

	fs_reset_seen(&seen);
	fs::unlink(&loop, &op, link, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::unlink(&loop, &op, path_b, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::rmdir(&loop, &op, dir, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_readlink_reports_buffer_full_without_truncating() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	char[128] link_storage;
	char[128] target_storage;
	char[8] small;
	String link   = fs_temp_path(link_storage[0:128], 19);
	String target = fs_temp_path(target_storage[0:128], 20);

	fs_cleanup_path(link);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::symlink(&loop, &op, target, link, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::readlink(&loop, &op, link, small[0:8], &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(nova::BUFFER_FULL, seen.status);
	test::@check(seen.bytes > small.len);
	test::eq((char)0, small[0]);

	fs_cleanup_path(link);
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_mktemp_and_statfs() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	char[128] dir_template_storage;
	char[128] file_template_storage;
	char[128] invalid_template_storage;
	char[5] payload         = { 't', 'e', 'm', 'p', '!' };
	String dir_template     = fs_temp_dir_template(dir_template_storage[0:128], 29);
	String file_template    = fs_temp_file_template(file_template_storage[0:128], 30);
	String invalid_template = fs_temp_path(invalid_template_storage[0:128], 31);
	char[512] dir_path;
	char[512] file_path;

	fs_cleanup_path(invalid_template);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::mkdtemp(&loop, &op, dir_template, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FsKind.MKDTEMP, seen.kind);
	test::@check(seen.path.len > 0);
	test::@check(seen.bytes == seen.path.len);
	test::@check(seen.path.len < dir_path.len);
	mem::copy(dir_path[0:seen.path.len].ptr, seen.path.ptr, seen.path.len);
	String created_dir = (String)dir_path[0:seen.path.len];

	fs_reset_seen(&seen);
	fs::stat(&loop, &op, created_dir, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FileType.DIR, seen.stat.type);

	fs_reset_seen(&seen);
	fs::statfs(&loop, &op, created_dir, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FsKind.STATFS, seen.kind);
	test::@check(seen.statfs.block_size > 0);
	test::@check(seen.statfs.fragment_size > 0);
	test::@check(seen.statfs.blocks > 0);

	fs_reset_seen(&seen);
	fs::mkstemp(&loop, &op, file_template, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FsKind.MKSTEMP, seen.kind);
	test::@check(seen.file.valid());
	test::@check(seen.path.len > 0);
	test::@check(seen.bytes == seen.path.len);
	test::@check(seen.path.len < file_path.len);
	file = seen.file;
	mem::copy(file_path[0:seen.path.len].ptr, seen.path.ptr, seen.path.len);
	String created_file = (String)file_path[0:seen.path.len];

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, payload[0:5], fs::CURRENT_OFFSET, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)5, seen.bytes);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::@check(!file.valid());

	fs_reset_seen(&seen);
	fs::stat(&loop, &op, created_file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FileType.FILE, seen.stat.type);
	test::eq((long)5, seen.stat.size);

	fs_reset_seen(&seen);
	fs::mkstemp(&loop, &op, invalid_template, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(seen.status);
	test::eq(fs::FsKind.MKSTEMP, seen.kind);
	test::eq(nova::ErrorDomain.POSIX_ERRNO, seen.error.platform.domain);

	fs_cleanup_path(created_file);
	(void)posix::rmdir(created_dir.zstr_tcopy());
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_requires_blocking_pool() @test
{
	Loop loop;
	fs::Op op;
	char[128] storage;
	FsSeen seen;
	String path = fs_temp_path(storage[0:128], 7);

	loop.init()!!;
	op.init();

	test::@error(
		fs::open(&loop, &op, path, { .access = fs::OpenAccess.READ }, &on_fs_seen, &seen),
		nova::INVALID_STATE
	);

	op.destroy();
	loop.destroy();
}

fn void test_fs_rejects_open_file_with_invalid_native_handle() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File invalid = { .handle = (NativeHandle)-1, .open = true };
	char[1] buffer;
	char[1] payload  = { 'x' };

	pool.init({ .workers = 1, .queue_capacity = 1 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	test::@check(!invalid.valid());
	test::@error(fs::read(&loop, &op, invalid, buffer[0:1], (fs::Offset)0, &on_fs_seen, &seen), nova::INVALID_STATE);
	test::@error(fs::write(&loop, &op, invalid, payload[0:1], (fs::Offset)0, &on_fs_seen, &seen), nova::INVALID_STATE);
	test::@error(fs::fstat(&loop, &op, invalid, &on_fs_seen, &seen), nova::INVALID_STATE);
	test::@error(fs::fsync(&loop, &op, invalid, &on_fs_seen, &seen), nova::INVALID_STATE);
	test::@error(
		fs::sendfile(&loop, &op, invalid, invalid, (fs::Offset)0, (sz)1, &on_fs_seen, &seen),
		nova::INVALID_STATE
	);
	test::@error(fs::close(&loop, &op, &invalid, &on_fs_seen, &seen), nova::INVALID_STATE);

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_queued_cancel_completes_cancelled() @test
{
	work::Pool pool;
	work::WorkOp blocker;
	Loop loop;
	fs::Op op;
	FsCancelCtx ctx;
	char[128] storage;
	String path = fs_temp_path(storage[0:128], 8);
	op::Ref ref;

	fs_cleanup_path(path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	blocker.init();
	op.init();

	work::queue(&loop, &blocker, &fs_blocker_work, &after_fs_cancel_blocker, &ctx)!!;
	ref = fs::open(
		&loop,
		&op,
		path,
		{ .access = fs::OpenAccess.READ, .mode = 0o600, .create = true },
		&on_fs_cancelled,
		&ctx
	)!!;
	op::cancel_ref(&loop, ref)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, ctx.blocker_calls);
	test::eq(2, ctx.after_calls);
	test::eq(1, ctx.fs_calls);
	test::eq(nova::CANCELLED, ctx.fs_status);
	test::@check(!op.active());

	op.destroy();
	blocker.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_directory_open_read_close_and_busy_state() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	fs::Op busy_op;
	FsSeen seen;
	fs::Dir* dir    = null;
	fs::Dir dir_handle;
	char[128] dir_storage;
	char[128] file_a_storage;
	char[128] file_b_storage;
	String dir_path = fs_temp_path(dir_storage[0:128], 9);
	String file_a   = fs_temp_child_path(file_a_storage[0:128], 9, 1);
	String file_b   = fs_temp_child_path(file_b_storage[0:128], 9, 2);
	fs::DirEntry[4] entries;

	fs_cleanup_path(file_a);
	fs_cleanup_path(file_b);
	(void)posix::rmdir(dir_path.zstr_tcopy());
	test::eq((CInt)0, posix::mkdir(dir_path.zstr_tcopy(), 0o700));
	fs_touch_file(file_a);
	fs_touch_file(file_b);

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();
	busy_op.init();

	fs::opendir(&loop, &op, &dir_handle, dir_path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::@check(seen.dir != null);
	test::@check(seen.dir.valid());
	dir = seen.dir;

	fs_reset_seen(&seen);
	fs::readdir(&loop, &op, dir, entries[0:4], &on_fs_seen, &seen)!!;
	test::@error(fs::closedir(&loop, &busy_op, dir, &on_fs_seen, &seen), nova::BUSY);
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;
	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq((sz)2, seen.count);
	test::@check(fs_entry_seen(entries[0:4], seen.count, "1"));
	test::@check(fs_entry_seen(entries[0:4], seen.count, "2"));
	test::@check(!fs_entry_seen(entries[0:4], seen.count, "."));
	test::@check(!fs_entry_seen(entries[0:4], seen.count, ".."));
	test::@check(dir.valid());

	fs_reset_seen(&seen);
	fs::readdir(&loop, &op, dir, entries[0:4], &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)0, seen.count);

	fs_reset_seen(&seen);
	fs::closedir(&loop, &op, dir, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_cleanup_path(file_a);
	fs_cleanup_path(file_b);
	(void)posix::rmdir(dir_path.zstr_tcopy());
	busy_op.destroy();
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_scandir_reports_buffer_full_with_partial_count() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	char[128] dir_storage;
	char[128] file_a_storage;
	char[128] file_b_storage;
	String dir_path = fs_temp_path(dir_storage[0:128], 10);
	String file_a   = fs_temp_child_path(file_a_storage[0:128], 10, 1);
	String file_b   = fs_temp_child_path(file_b_storage[0:128], 10, 2);
	fs::DirEntry[1] entries;

	fs_cleanup_path(file_a);
	fs_cleanup_path(file_b);
	(void)posix::rmdir(dir_path.zstr_tcopy());
	test::eq((CInt)0, posix::mkdir(dir_path.zstr_tcopy(), 0o700));
	fs_touch_file(file_a);
	fs_touch_file(file_b);

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::scandir(&loop, &op, dir_path, entries[0:1], &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(nova::BUFFER_FULL, seen.status);
	test::eq((sz)1, seen.count);

	fs_cleanup_path(file_a);
	fs_cleanup_path(file_b);
	(void)posix::rmdir(dir_path.zstr_tcopy());
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_metadata_and_links() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	char[128] storage;
	char[128] hard_storage;
	char[128] sym_storage;
	char[128] out_storage;
	String path         = fs_temp_path(storage[0:128], 11);
	String hard_path    = fs_temp_path(hard_storage[0:128], 12);
	String sym_path     = fs_temp_path(sym_storage[0:128], 13);
	fs::Timestamp atime = { .seconds = 1_700_000_000 };
	fs::Timestamp mtime = { .seconds = 1_700_000_100 };
	char[1] byte        = { 'm' };

	fs_cleanup_path(path);
	fs_cleanup_path(hard_path);
	fs_cleanup_path(sym_path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(
		&loop,
		&op,
		path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, byte[0:1], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::fchmod(&loop, &op, file, 0o600, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::chmod(&loop, &op, path, 0o640, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::utime(&loop, &op, path, atime, mtime, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::futime(&loop, &op, file, atime, mtime, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::chown(&loop, &op, path, uint::max, uint::max, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::fchown(&loop, &op, file, uint::max, uint::max, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::link(&loop, &op, path, hard_path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::symlink(&loop, &op, path, sym_path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::lutime(&loop, &op, sym_path, atime, mtime, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::lchown(&loop, &op, sym_path, uint::max, uint::max, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::lstat(&loop, &op, sym_path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FileType.LINK, seen.stat.type);

	fs_reset_seen(&seen);
	fs::readlink(&loop, &op, sym_path, out_storage[0:128], &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::@check(fs_string_equals(path, seen.path));

	fs_reset_seen(&seen);
	fs::stat(&loop, &op, path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((ulong)0o640, seen.stat.mode & (ulong)0o777);
	test::eq(mtime.seconds, seen.stat.modified.seconds);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_cleanup_path(sym_path);
	fs_cleanup_path(hard_path);
	fs_cleanup_path(path);
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_utime_preserves_nanoseconds_when_supported() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	char[128] storage;
	String path         = fs_temp_path(storage[0:128], 14);
	fs::Timestamp atime = { .seconds = 1_700_001_000, .nanoseconds = 123_456_789 };
	fs::Timestamp mtime = { .seconds = 1_700_001_100, .nanoseconds = 987_654_321 };

	fs_cleanup_path(path);
	fs_touch_file(path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::utime(&loop, &op, path, atime, mtime, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::stat(&loop, &op, path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(mtime.seconds, seen.stat.modified.seconds);
	test::eq(mtime.nanoseconds, seen.stat.modified.nanoseconds);

	fs_cleanup_path(path);
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_copyfile_copies_payload_and_exclusive_fails() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	char[128] src_storage;
	char[128] dst_storage;
	char[128] dir_storage;
	String src_path  = fs_temp_path(src_storage[0:128], 14);
	String dst_path  = fs_temp_path(dst_storage[0:128], 15);
	String dir_path  = fs_temp_path(dir_storage[0:128], 18);
	char[10] payload = { 'c', 'o', 'p', 'y', '-', 'f', 'i', 'l', 'e', '!' };
	char[10] input;

	fs_cleanup_path(src_path);
	fs_cleanup_path(dst_path);
	(void)posix::rmdir(dir_path.zstr_tcopy());
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(
		&loop,
		&op,
		src_path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, payload[0:10], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::copyfile(&loop, &op, src_path, dst_path, { }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FsKind.COPYFILE, seen.kind);
	test::eq((sz)10, seen.bytes);
	test::@check(!seen.eof);

	fs_reset_seen(&seen);
	fs::open(&loop, &op, dst_path, { .access = fs::OpenAccess.READ }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::read(&loop, &op, file, input[0:10], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)10, seen.bytes);
	test::@check(mem::equals(payload[0:10].ptr, input[0:10].ptr, 10));

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::stat(&loop, &op, dst_path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((ulong)0o600, seen.stat.mode & (ulong)0o777);

	fs_reset_seen(&seen);
	fs::copyfile(&loop, &op, src_path, dst_path, { .exclusive = true }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(io::ALREADY_EXISTS, seen.status);
	test::eq(fs::FsKind.COPYFILE, seen.kind);

	fs_reset_seen(&seen);
	fs::copyfile(&loop, &op, src_path, src_path, { }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FsKind.COPYFILE, seen.kind);

	fs_reset_seen(&seen);
	fs::open(&loop, &op, src_path, { .access = fs::OpenAccess.READ }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	input = { };
	fs_reset_seen(&seen);
	fs::read(&loop, &op, file, input[0:10], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)10, seen.bytes);
	test::@check(mem::equals(payload[0:10].ptr, input[0:10].ptr, 10));

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	test::eq((CInt)0, posix::mkdir(dir_path.zstr_tcopy(), 0o700));
	fs_reset_seen(&seen);
	fs::copyfile(&loop, &op, dir_path, dst_path, { }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(io::FILE_IS_DIR, seen.status);
	test::eq(fs::FsKind.COPYFILE, seen.kind);

	fs_cleanup_path(dst_path);
	fs_cleanup_path(src_path);
	(void)posix::rmdir(dir_path.zstr_tcopy());
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_copyfile_follows_destination_symlink_to_missing_target() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	char[128] src_storage;
	char[128] link_storage;
	char[128] target_storage;
	String src_path    = fs_temp_path(src_storage[0:128], 26);
	String link_path   = fs_temp_path(link_storage[0:128], 27);
	String target_path = fs_temp_path(target_storage[0:128], 28);
	char[7] payload    = { 's', 'y', 'm', '-', 'd', 's', 't' };
	char[7] input;

	fs_cleanup_path(link_path);
	fs_cleanup_path(target_path);
	fs_cleanup_path(src_path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(
		&loop,
		&op,
		src_path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, payload[0:7], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	test::eq((CInt)0, test_symlink(target_path.zstr_tcopy(), link_path.zstr_tcopy()));

	fs_reset_seen(&seen);
	fs::copyfile(&loop, &op, src_path, link_path, { }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)7, seen.bytes);

	fs_reset_seen(&seen);
	fs::open(&loop, &op, target_path, { .access = fs::OpenAccess.READ }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::read(&loop, &op, file, input[0:7], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)7, seen.bytes);
	test::@check(mem::equals(payload[0:7].ptr, input[0:7].ptr, 7));

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_cleanup_path(link_path);
	fs_cleanup_path(target_path);
	fs_cleanup_path(src_path);
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_copyfile_removes_partial_destination_after_write_error() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	libc::Sigaction old;
	libc::Sigaction guard;
	TestRlimit old_limit;
	TestRlimit low_limit;
	char[128] src_storage;
	char[128] dst_storage;
	String src_path  = fs_temp_path(src_storage[0:128], 18);
	String dst_path  = fs_temp_path(dst_storage[0:128], 19);
	char[10] payload = { 'p', 'a', 'r', 't', 'i', 'a', 'l', '-', 'x', '!' };

	fs_cleanup_path(src_path);
	fs_cleanup_path(dst_path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(
		&loop,
		&op,
		src_path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, payload[0:10], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	guard.sa_handler = &ignore_xfsz;
	(void)libc::sigemptyset(&guard.sa_mask);
	test::eq(0, libc::sigaction(libc::SIGXFSZ, &guard, &old));
	defer (void)libc::sigaction(libc::SIGXFSZ, &old, null);
	test::eq((CInt)0, test_getrlimit(TEST_RLIMIT_FSIZE, &old_limit));
	defer (void)test_setrlimit(TEST_RLIMIT_FSIZE, &old_limit);
	low_limit = { .current = 8, .maximum = old_limit.maximum };
	test::eq((CInt)0, test_setrlimit(TEST_RLIMIT_FSIZE, &low_limit));

	fs_reset_seen(&seen);
	fs::copyfile(&loop, &op, src_path, dst_path, { }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(io::OUT_OF_SPACE, seen.status);
	test::eq(fs::FsKind.COPYFILE, seen.kind);
	test::eq((CInt)0, test_setrlimit(TEST_RLIMIT_FSIZE, &old_limit));

	fs_reset_seen(&seen);
	fs::stat(&loop, &op, dst_path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(io::FILE_NOT_FOUND, seen.status);

	fs_cleanup_path(dst_path);
	fs_cleanup_path(src_path);
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_copyfile_preserves_existing_destination_after_write_error() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File file;
	libc::Sigaction old;
	libc::Sigaction guard;
	TestRlimit old_limit;
	TestRlimit low_limit;
	char[128] src_storage;
	char[128] dst_storage;
	String src_path     = fs_temp_path(src_storage[0:128], 24);
	String dst_path     = fs_temp_path(dst_storage[0:128], 25);
	char[10] payload    = { 'p', 'r', 'e', 's', 'e', 'r', 'v', 'e', 'd', '!' };
	char[3] old_payload = { 'o', 'l', 'd' };

	fs_cleanup_path(src_path);
	fs_cleanup_path(dst_path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(
		&loop,
		&op,
		src_path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, payload[0:10], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::open(
		&loop,
		&op,
		dst_path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, file, old_payload[0:3], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	guard.sa_handler = &ignore_xfsz;
	(void)libc::sigemptyset(&guard.sa_mask);
	test::eq(0, libc::sigaction(libc::SIGXFSZ, &guard, &old));
	defer (void)libc::sigaction(libc::SIGXFSZ, &old, null);
	test::eq((CInt)0, test_getrlimit(TEST_RLIMIT_FSIZE, &old_limit));
	defer (void)test_setrlimit(TEST_RLIMIT_FSIZE, &old_limit);
	low_limit = { .current = 8, .maximum = old_limit.maximum };
	test::eq((CInt)0, test_setrlimit(TEST_RLIMIT_FSIZE, &low_limit));

	fs_reset_seen(&seen);
	fs::copyfile(&loop, &op, src_path, dst_path, { }, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::eq(io::OUT_OF_SPACE, seen.status);
	test::eq(fs::FsKind.COPYFILE, seen.kind);
	test::eq((CInt)0, test_setrlimit(TEST_RLIMIT_FSIZE, &old_limit));

	fs_reset_seen(&seen);
	fs::stat(&loop, &op, dst_path, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_cleanup_path(dst_path);
	fs_cleanup_path(src_path);
	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_fs_sendfile_transfers_between_open_files() @test
{
	work::Pool pool;
	Loop loop;
	fs::Op op;
	FsSeen seen;
	fs::File in_file;
	fs::File out_file;
	char[128] in_storage;
	char[128] out_storage;
	String in_path  = fs_temp_path(in_storage[0:128], 16);
	String out_path = fs_temp_path(out_storage[0:128], 17);
	char[9] payload = { 's', 'e', 'n', 'd', '-', 'f', 'i', 'l', 'e' };
	char[4] input;

	fs_cleanup_path(in_path);
	fs_cleanup_path(out_path);
	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	fs::open(
		&loop,
		&op,
		in_path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	in_file = seen.file;

	fs_reset_seen(&seen);
	fs::write(&loop, &op, in_file, payload[0:9], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::open(
		&loop,
		&op,
		out_path,
		{ .access = fs::OpenAccess.READ_WRITE, .mode = 0o600, .create = true, .truncate = true },
		&on_fs_seen,
		&seen
	)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	out_file = seen.file;

	test::@error(
		fs::sendfile(&loop, &op, out_file, in_file, (fs::Offset)0, (sz)-1, &on_fs_seen, &seen),
		nova::INVALID_STATE
	);

	fs_reset_seen(&seen);
	fs::sendfile(&loop, &op, out_file, in_file, (fs::Offset)5, (sz)4, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FsKind.SENDFILE, seen.kind);
	test::eq((sz)4, seen.bytes);

	fs_reset_seen(&seen);
	fs::sendfile(&loop, &op, out_file, in_file, (fs::Offset)0, (sz)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq(fs::FsKind.SENDFILE, seen.kind);
	test::eq((sz)0, seen.bytes);

	fs_reset_seen(&seen);
	fs::read(&loop, &op, out_file, input[0:4], (fs::Offset)0, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);
	test::eq((sz)4, seen.bytes);
	test::@check(mem::equals(payload[5:4].ptr, input[0:4].ptr, 4));

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &out_file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_reset_seen(&seen);
	fs::close(&loop, &op, &in_file, &on_fs_seen, &seen)!!;
	fs_run_one(&loop, &seen);
	test::@check(!seen.status);

	fs_cleanup_path(out_path);
	fs_cleanup_path(in_path);
	op.destroy();
	loop.destroy();
	pool.destroy();
}
