module nova::fs;

import std::io, std::os::posix;
import libc;

import nova @norecurse;
import nova::posix_errno @public;

<*
 Retryable POSIX callback shapes used by EINTR wrappers.
*>
alias FdOp = fn CInt(CInt fd);
alias FileModeOp = fn CInt(CInt fd, libc::Mode_t mode);
alias FileStatOp = fn CInt(CInt fd, libc::Stat* statbuf);
alias FileTimeOp = fn CInt(CInt fd, libc::TimeSpec* times);
alias FileChownOp = fn CInt(CInt fd, libc::Uid_t uid, libc::Gid_t gid);
alias PathOp = fn CInt(ZString path);
alias Path2Op = fn CInt(ZString path, ZString new_path);
alias PathModeOp = fn CInt(ZString path, libc::Mode_t mode);
alias PathStatOp = fn CInt(ZString path, libc::Stat* statbuf);
alias PathChownOp = fn CInt(ZString path, libc::Uid_t uid, libc::Gid_t gid);

<*
 POSIX open flag values normalized for Linux and macOS.
*>
const CInt FS_O_RDONLY    = 0;
const CInt FS_O_WRONLY    = 1;
const CInt FS_O_RDWR      = 2;
const CInt FS_O_CREAT     = env::LINUX ? 0o100 : 0x0200;
const CInt FS_O_EXCL      = env::LINUX ? 0o200 : 0x0800;
const CInt FS_O_TRUNC     = env::LINUX ? 0o1000 : 0x0400;
const CInt FS_O_APPEND    = env::LINUX ? 0o2000 : 0x0008;
const CInt FS_O_NONBLOCK  = env::LINUX ? 0o4000 : 0x0004;
const CInt FS_O_CLOEXEC   = env::LINUX ? 0o2000000 : 0x01000000;
const CInt FS_O_DIRECTORY = env::LINUX ? 0o200000 : 0x00100000;
const CInt FS_O_NOFOLLOW  = env::LINUX ? 0o400000 : 0x00000100;

<*
 POSIX access mode bit values.
*>
const CInt FS_X_OK = 1;
const CInt FS_W_OK = 2;
const CInt FS_R_OK = 4;

<*
 POSIX descriptor and path constants used by filesystem operations.
*>
const CInt FS_F_GETFD             = 1;
const CInt FS_F_SETFD             = 2;
const CInt FS_FD_CLOEXEC          = 1;
const CInt FS_AT_FDCWD            = env::DARWIN ? -2 : -100;
const CInt FS_AT_SYMLINK_NOFOLLOW = env::DARWIN ? 0x0020 : 0x0100;
const sz FS_REALPATH_MAX          = 4096;
const sz FS_COPY_BUFFER_SIZE      = 65536;
const usz FS_COPY_RANGE_MAX       = 0x7fff_f000;

<*
 POSIX filesystem C bindings used by worker implementations.

 These declarations preserve native errno semantics; wrappers inspect
 `libc::errno()` after failing return values and convert them to portable
 nova filesystem faults.
*>
extern fn CInt posix_open(ZString pathname, CInt flags, ...) @cname("open");
extern fn CInt posix_fcntl(CInt fd, CInt cmd, ...) @cname("fcntl");
extern fn sz posix_pread(CInt fd, void* buf, usz count, libc::Off_t offset) @cname("pread");
extern fn sz posix_pwrite(CInt fd, void* buf, usz count, libc::Off_t offset) @cname("pwrite");
extern fn CInt posix_fstat(CInt fd, libc::Stat* statbuf) @cname("fstat");
extern fn CInt posix_lstat(ZString path, libc::Stat* statbuf) @cname("lstat");
extern fn CInt posix_fsync(CInt fd) @cname("fsync");
extern fn CInt posix_fdatasync(CInt fd) @cname("fdatasync") @if(env::LINUX);
extern fn sz posix_copy_file_range(
	CInt fd_in,
	libc::Off_t* off_in,
	CInt fd_out,
	libc::Off_t* off_out,
	usz len,
	uint flags
) @cname("copy_file_range") @if(env::LINUX);
extern fn CInt posix_ftruncate(CInt fd, libc::Off_t length) @cname("ftruncate");
extern fn CInt posix_unlink(ZString path) @cname("unlink");
extern fn char* posix_realpath(ZString path, char* resolved) @cname("realpath");
extern fn CInt posix_chmod(ZString path, libc::Mode_t mode) @cname("chmod");
extern fn CInt posix_fchmod(CInt fd, libc::Mode_t mode) @cname("fchmod");
extern fn CInt posix_chown(ZString path, libc::Uid_t uid, libc::Gid_t gid) @cname("chown");
extern fn CInt posix_fchown(CInt fd, libc::Uid_t uid, libc::Gid_t gid) @cname("fchown");
extern fn CInt posix_lchown(ZString path, libc::Uid_t uid, libc::Gid_t gid) @cname("lchown");
extern fn CInt posix_link(ZString path, ZString new_path) @cname("link");
extern fn CInt posix_symlink(ZString target, ZString path) @cname("symlink");
extern fn char* posix_mkdtemp(char* template_path) @cname("mkdtemp");
extern fn CInt posix_mkstemp(char* template_path) @cname("mkstemp");
extern fn CInt posix_futimens(CInt fd, libc::TimeSpec* times) @cname("futimens");
extern fn CInt posix_utimensat(CInt fd, ZString path, libc::TimeSpec* times, CInt flags) @cname("utimensat");
extern fn CInt posix_statfs(ZString path, NativeStatFs* statbuf) @cname("statfs") @if(env::LINUX);
extern fn CInt posix_statfs(ZString path, NativeStatFs* statbuf) @cname(darwin_statfs_cname()) @if(env::DARWIN);

<*
 Open destination descriptor for `copyfile`.

 `created` is true when this operation created the destination and should remove
 it if a later copy step fails.
*>
struct CopyDestination
{
	CInt fd;
	bool created;
}

<*
 Native filesystem statistics storage.

 The layouts mirror the platform C headers for the fields used by `statfs`.
*>
struct NativeStatFs @if(env::LINUX)
{
	long f_type;
	long f_bsize;
	ulong f_blocks;
	ulong f_bfree;
	ulong f_bavail;
	ulong f_files;
	ulong f_ffree;
	CInt[2] f_fsid;
	long f_namelen;
	long f_frsize;
	long f_flags;
	long[4] f_spare;
}

struct NativeStatFs @if(env::DARWIN)
{
	uint f_bsize;
	int f_iosize;
	ulong f_blocks;
	ulong f_bfree;
	ulong f_bavail;
	ulong f_files;
	ulong f_ffree;
	CInt[2] f_fsid;
	libc::Uid_t f_owner;
	uint f_type;
	uint f_flags;
	uint f_fssubtype;
	char[16] f_fstypename;
	char[1024] f_mntonname;
	char[1024] f_mntfromname;
	uint[8] f_reserved;
}

macro String darwin_statfs_cname() @const
{
	$switch:
		$case env::X86_64:
			return "statfs$INODE64";
		$default:
			return "statfs";
	$endswitch
}

<*
 Dispatch one filesystem operation to its POSIX worker implementation.

 @param op : "Filesystem operation to execute on a worker thread"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_dispatch(Op* op) @private
{
	op.result.kind = op.kind;
	switch (op.kind)
	{
		case FsKind.OPEN: native_open(op);
		case FsKind.CLOSE: native_close(op);
		case FsKind.READ: native_read(op);
		case FsKind.WRITE: native_write(op);
		case FsKind.STAT: native_stat(op);
		case FsKind.FSTAT: native_fstat(op);
		case FsKind.LSTAT: native_lstat(op);
		case FsKind.FSYNC: native_fsync(op);
		case FsKind.FDATASYNC: native_fdatasync(op);
		case FsKind.FTRUNCATE: native_ftruncate(op);
		case FsKind.ACCESS: native_access(op);
		case FsKind.MKDIR: native_mkdir(op);
		case FsKind.RMDIR: native_rmdir(op);
		case FsKind.UNLINK: native_unlink(op);
		case FsKind.RENAME: native_rename(op);
		case FsKind.READLINK: native_readlink(op);
		case FsKind.REALPATH: native_realpath(op);
		case FsKind.OPENDIR: native_opendir(op);
		case FsKind.READDIR: native_readdir(op);
		case FsKind.CLOSEDIR: native_closedir(op);
		case FsKind.SCANDIR: native_scandir(op);
		case FsKind.CHMOD: native_chmod(op);
		case FsKind.FCHMOD: native_fchmod(op);
		case FsKind.UTIME: native_utime(op);
		case FsKind.FUTIME: native_futime(op);
		case FsKind.LUTIME: native_lutime(op);
		case FsKind.LINK: native_link(op);
		case FsKind.SYMLINK: native_symlink(op);
		case FsKind.CHOWN: native_chown(op);
		case FsKind.FCHOWN: native_fchown(op);
		case FsKind.LCHOWN: native_lchown(op);
		case FsKind.COPYFILE: native_copyfile(op);
		case FsKind.SENDFILE: native_sendfile(op);
		case FsKind.MKDTEMP: native_mkdtemp(op);
		case FsKind.MKSTEMP: native_mkstemp(op);
		case FsKind.STATFS: native_statfs(op);
		default: native_error(op, nova::UNSUPPORTED);
	}
}

<*
 Open a native POSIX file descriptor and return it as `fs::File`.

 @param op : "Prepared open operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_open(Op* op) @local
{
	CInt flags = open_flags(op, op.request.open.options);
	if (op.result.error.status) return;

	CInt fd;
	do
	{
		fd = posix_open((ZString)op.request.open.path, flags, (CInt)op.request.open.options.mode);
	} while (fd < 0 && libc::errno() == posix_errno::E_INTR);

	if (fd < 0)
	{
		native_errno(op, libc::errno());
		return;
	}

	op.result.file = { .handle = (NativeHandle)fd, .open = true };
}

<*
 Close a native POSIX file descriptor captured by the close request.

 @param op : "Prepared close operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_close(Op* op) @local
{
	CInt fd = (CInt)op.request.close.handle;
	if (libc::close(fd) < 0)
	{
		Errno err = libc::errno();
		if (err == posix_errno::E_INTR || err == posix_errno::E_INPROGRESS) return;
		native_errno(op, err);
	}
}

<*
 Read from a native POSIX file descriptor into the borrowed output buffer.

 @param op : "Prepared read operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_read(Op* op)
{
	ReadRequest* request = &op.request.read;
	CInt fd              = (CInt)request.file.handle;
	sz read_bytes;
	do
	{
		if (request.offset == CURRENT_OFFSET)
		{
			read_bytes = libc::read(fd, request.buffer.ptr, (usz)request.buffer.len);
		}
		else
		{
			read_bytes = posix_pread(fd, request.buffer.ptr, (usz)request.buffer.len, (libc::Off_t)request.offset);
		}
	} while (read_bytes < 0 && libc::errno() == posix_errno::E_INTR);
	if (read_bytes < 0)
	{
		native_errno(op, libc::errno());
		return;
	}
	op.result.bytes = read_bytes;
	op.result.eof = read_bytes == 0;
}

<*
 Write the full borrowed byte slice to a native POSIX file descriptor.

 @param op : "Prepared write operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_write(Op* op)
{
	WriteRequest* request = &op.request.write;
	CInt fd               = (CInt)request.file.handle;
	sz written            = 0;

	while (written < request.bytes.len)
	{
		sz remaining = request.bytes.len - written;
		char* base   = request.bytes.ptr + written;
		sz step;
		if (request.offset == CURRENT_OFFSET)
		{
			step = libc::write(fd, base, (usz)remaining);
		}
		else
		{
			if (!offset_step_valid(op, request.offset, written))
			{
				op.result.bytes = written;
				return;
			}
			step = posix_pwrite(fd, base, (usz)remaining, (libc::Off_t)((long)request.offset + written));
		}

		if (step < 0)
		{
			Errno err = libc::errno();
			if (err == posix_errno::E_INTR) continue;
			op.result.bytes = written;
			native_errno(op, err);
			return;
		}
		if (step == 0)
		{
			op.result.bytes = written;
			native_error(op, io::INCOMPLETE_WRITE);
			return;
		}
		written += step;
	}
	op.result.bytes = written;
}

<*
 Stat a path and convert the native result to `fs::Stat`.

 @param op : "Prepared stat operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_stat(Op* op) @local
{
	libc::Stat statbuf;
	if (retry_path_stat_op((ZString)op.request.path.path, &statbuf, &libc::stat) != 0)
	{
		native_errno(op, libc::errno());
		return;
	}
	op.result.stat = convert_stat(&statbuf);
}

<*
 Stat a zero-terminated path for fs_poll worker code.

 @param path : "Zero-terminated path owned by fs_poll"
 @return "Filesystem result with either `stat` or native error details"
 @require path != null : "Path pointer must not be null"
*>
fn Result native_poll_stat_result(char* path)
{
	Result result = { .kind = FsKind.STAT };
	libc::Stat statbuf;
	if (retry_path_stat_op((ZString)path, &statbuf, &libc::stat) != 0)
	{
		result.error.status = fs_fault_from_errno(libc::errno());
		result.error.platform = { .domain = nova::ErrorDomain.POSIX_ERRNO, .code = (int)libc::errno() };
		return result;
	}
	result.stat = convert_stat(&statbuf);
	return result;
}

<*
 Stat an open file handle and convert the native result to `fs::Stat`.

 @param op : "Prepared fstat operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_fstat(Op* op) @local
{
	libc::Stat statbuf;
	if (retry_file_stat_op((CInt)op.request.file.file.handle, &statbuf, &posix_fstat) != 0)
	{
		native_errno(op, libc::errno());
		return;
	}
	op.result.stat = convert_stat(&statbuf);
}

<*
 Stat a symlink path without following the final link.

 @param op : "Prepared lstat operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_lstat(Op* op) @local
{
	libc::Stat statbuf;
	if (retry_path_stat_op((ZString)op.request.path.path, &statbuf, &posix_lstat) != 0)
	{
		native_errno(op, libc::errno());
		return;
	}
	op.result.stat = convert_stat(&statbuf);
}

<*
 Query filesystem capacity statistics for a path.

 @param op : "Prepared statfs operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_statfs(Op* op) @local
{
	NativeStatFs statbuf;
	if (retry_path_statfs_op((ZString)op.request.path.path, &statbuf) != 0)
	{
		native_errno(op, libc::errno());
		return;
	}
	op.result.statfs = convert_statfs(&statbuf);
}

<*
 Flush file data and metadata with `fsync`.

 @param op : "Prepared fsync operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_fsync(Op* op) @local
{
	if (retry_fd_op((CInt)op.request.file.file.handle, &posix_fsync) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Flush file data, falling back to `fsync` where `fdatasync` is unavailable.

 @param op : "Prepared fdatasync operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_fdatasync(Op* op) @local
{
	CInt fd = (CInt)op.request.file.file.handle;
	$if env::LINUX:
		if (retry_fd_op(fd, &posix_fdatasync) != 0)
		{
			native_errno(op, libc::errno());
		}
	$else
		if (retry_fd_op(fd, &posix_fsync) != 0)
		{
			native_errno(op, libc::errno());
		}
	$endif
}

<*
 Truncate an open file to the requested size.

 @param op : "Prepared ftruncate operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_ftruncate(Op* op) @local
{
	CInt fd = (CInt)op.request.file.file.handle;
	do
	{
		if (posix_ftruncate(fd, (libc::Off_t)op.request.file.offset) == 0) return;
	} while (libc::errno() == posix_errno::E_INTR);
	native_errno(op, libc::errno());
}

<*
 Check access permissions for a path.

 @param op : "Prepared access operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_access(Op* op) @local
{
	CInt mode = access_mode(op.request.access.mode);
	CInt result;
	do
	{
		result = posix::access((ZString)op.request.access.path, mode);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	if (result != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Create a directory at the requested path.

 @param op : "Prepared mkdir operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_mkdir(Op* op) @local
{
	CInt result;
	do
	{
		result = posix::mkdir((ZString)op.request.path_mode.path, (ushort)op.request.path_mode.mode);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	if (result != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Report whether a temporary-file template ends in the required `XXXXXX` suffix.

 glibc `mkstemp`/`mkdtemp` reject templates without the trailing `XXXXXX` with
 `EINVAL`, but the macOS/BSD libc accepts them and uses the literal name. nova
 validates the suffix so the documented contract behaves the same on every
 supported platform.

 @param template_path : "Zero-terminated mutable template path"
 @return "True when the template ends in `XXXXXX`"
 @require template_path != null : "Template path pointer must not be null"
*>
fn bool mkstemp_template_valid(char* template_path) @local
{
	return ((ZString)template_path).str_view().ends_with("XXXXXX");
}

<*
 Create a unique temporary directory from the mutable request template.

 @param op : "Prepared mkdtemp operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_mkdtemp(Op* op) @local
{
	if (!mkstemp_template_valid(op.request.path.path))
	{
		native_errno(op, posix_errno::E_INVAL);
		return;
	}
	if (!posix_mkdtemp(op.request.path.path))
	{
		native_errno(op, libc::errno());
		return;
	}
	set_generated_path_result(op, op.request.path.path);
}

<*
 Create a unique temporary file from the mutable request template.

 @param op : "Prepared mkstemp operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_mkstemp(Op* op) @local
{
	if (!mkstemp_template_valid(op.request.path.path))
	{
		native_errno(op, posix_errno::E_INVAL);
		return;
	}
	CInt fd = posix_mkstemp(op.request.path.path);
	if (fd < 0)
	{
		native_errno(op, libc::errno());
		return;
	}
	if (!set_fd_cloexec(op, fd))
	{
		close_fd_preserving_error(op, fd);
		return;
	}
	op.result.file = { .handle = (NativeHandle)fd, .open = true };
	set_generated_path_result(op, op.request.path.path);
}

<*
 Remove an empty directory.

 @param op : "Prepared rmdir operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_rmdir(Op* op) @local
{
	if (retry_path_op((ZString)op.request.path.path, &posix::rmdir) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Remove a directory entry with `unlink`.

 @param op : "Prepared unlink operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_unlink(Op* op) @local
{
	if (retry_path_op((ZString)op.request.path.path, &posix_unlink) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Rename or move a filesystem entry.

 @param op : "Prepared rename operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_rename(Op* op) @local
{
	if (retry_path2_op((ZString)op.request.path2.path, (ZString)op.request.path2.new_path, &libc::rename) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Read a symlink target into caller output storage.

 @param op : "Prepared readlink operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_readlink(Op* op) @local
{
	OutputPathRequest* request = &op.request.output_path;
	char[FS_REALPATH_MAX] scratch;
	sz bytes;
	do
	{
		bytes = libc::readlink((ZString)request.path, scratch[0:FS_REALPATH_MAX].ptr, (int)FS_REALPATH_MAX);
	} while (bytes < 0 && libc::errno() == posix_errno::E_INTR);
	if (bytes < 0)
	{
		native_errno(op, libc::errno());
		return;
	}
	if (bytes > request.out.len)
	{
		op.result.bytes = bytes;
		native_error(op, nova::BUFFER_FULL);
		return;
	}
	mem::copy(request.out.ptr, scratch[0:FS_REALPATH_MAX].ptr, bytes);
	op.result.path = request.out[0:bytes];
	op.result.bytes = bytes;
}

<*
 Resolve a path to its canonical absolute path.

 @param op : "Prepared realpath operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_realpath(Op* op) @local
{
	OutputPathRequest* request = &op.request.output_path;
	char[FS_REALPATH_MAX] temp;
	char* resolved;
	do
	{
		resolved = posix_realpath((ZString)request.path, temp[0:FS_REALPATH_MAX].ptr);
	} while (!resolved && libc::errno() == posix_errno::E_INTR);
	if (!resolved)
	{
		native_errno(op, libc::errno());
		return;
	}
	sz len = (sz)libc::strlen((ZString)temp[0:FS_REALPATH_MAX].ptr);
	if (len > request.out.len)
	{
		op.result.bytes = len;
		native_error(op, nova::BUFFER_FULL);
		return;
	}
	mem::copy(request.out.ptr, temp[0:FS_REALPATH_MAX].ptr, len);
	op.result.path = request.out[0:len];
	op.result.bytes = len;
}

<*
 Open a directory stream and attach it to caller directory storage.

 @param op : "Prepared opendir operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_opendir(Op* op) @local
{
	Dir* dir = op.request.opendir.dir;
	posix::DIRPtr native;
	do
	{
		native = posix::opendir((ZString)op.request.opendir.path);
	} while (!native && libc::errno() == posix_errno::E_INTR);
	if (!native)
	{
		native_errno(op, libc::errno());
		return;
	}
	dir.native = (void*)native;
	dir.open = true;
	op.result.dir = dir;
}

<*
 Read entries from an already open directory stream.

 @param op : "Prepared readdir operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_readdir(Op* op) @local
{
	DirRequest* request = &op.request.dir;
	read_dir_entries(op, (posix::DIRPtr)request.dir.native, request.out, false);
}

<*
 Close an open directory stream.

 @param op : "Prepared closedir operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_closedir(Op* op) @local
{
	Dir* dir = op.request.dir.dir;
	if (posix::closedir((posix::DIRPtr)dir.native) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Open, read and close a directory path in one worker operation.

 @param op : "Prepared scandir operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_scandir(Op* op) @local
{
	ScanDirRequest* request = &op.request.scandir;
	posix::DIRPtr native;
	do
	{
		native = posix::opendir((ZString)request.path);
	} while (!native && libc::errno() == posix_errno::E_INTR);
	if (!native)
	{
		native_errno(op, libc::errno());
		return;
	}
	defer (void)posix::closedir(native);
	read_dir_entries(op, native, request.out, true);
}

<*
 Change mode bits for a path.

 @param op : "Prepared chmod operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_chmod(Op* op) @local
{
	if (retry_path_mode_op(
		(ZString)op.request.path_mode.path,
		(libc::Mode_t)op.request.path_mode.mode,
		&posix_chmod
	) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Change mode bits for an open file.

 @param op : "Prepared fchmod operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_fchmod(Op* op) @local
{
	if (retry_file_mode_op(
		(CInt)op.request.file_mode.file.handle,
		(libc::Mode_t)op.request.file_mode.mode,
		&posix_fchmod
	) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Update access and modification timestamps for a path.

 @param op : "Prepared utime operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_utime(Op* op) @local
{
	TimeRequest* request    = &op.request.time;
	libc::TimeSpec[2] times = { timestamp_to_timespec(request.accessed), timestamp_to_timespec(request.modified), };
	if (retry_utimensat((ZString)request.path, times[0:2].ptr, 0) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Update access and modification timestamps for an open file.

 @param op : "Prepared futime operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_futime(Op* op) @local
{
	TimeRequest* request    = &op.request.time;
	libc::TimeSpec[2] times = { timestamp_to_timespec(request.accessed), timestamp_to_timespec(request.modified), };
	if (retry_file_time_op((CInt)request.file.handle, times[0:2].ptr, &posix_futimens) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Update access and modification timestamps for a symlink itself.

 @param op : "Prepared lutime operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_lutime(Op* op) @local
{
	TimeRequest* request    = &op.request.time;
	libc::TimeSpec[2] times = { timestamp_to_timespec(request.accessed), timestamp_to_timespec(request.modified), };
	if (retry_utimensat((ZString)request.path, times[0:2].ptr, FS_AT_SYMLINK_NOFOLLOW) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Create a hard link.

 @param op : "Prepared link operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_link(Op* op) @local
{
	if (retry_path2_op((ZString)op.request.path2.path, (ZString)op.request.path2.new_path, &posix_link) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Create a symbolic link.

 @param op : "Prepared symlink operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_symlink(Op* op) @local
{
	if (retry_path2_op((ZString)op.request.path2.path, (ZString)op.request.path2.new_path, &posix_symlink) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Change owner and group for a path.

 @param op : "Prepared chown operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_chown(Op* op) @local
{
	ChownRequest* request = &op.request.chown;
	if (retry_path_chown_op(
		(ZString)request.path,
		(libc::Uid_t)request.uid,
		(libc::Gid_t)request.gid,
		&posix_chown
	) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Change owner and group for an open file.

 @param op : "Prepared fchown operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_fchown(Op* op) @local
{
	ChownRequest* request = &op.request.chown;
	if (retry_file_chown_op(
		(CInt)request.file.handle,
		(libc::Uid_t)request.uid,
		(libc::Gid_t)request.gid,
		&posix_fchown
	) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Change owner and group for a symlink itself.

 @param op : "Prepared lchown operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_lchown(Op* op) @local
{
	ChownRequest* request = &op.request.chown;
	if (retry_path_chown_op(
		(ZString)request.path,
		(libc::Uid_t)request.uid,
		(libc::Gid_t)request.gid,
		&posix_lchown
	) != 0)
	{
		native_errno(op, libc::errno());
	}
}

<*
 Copy one regular file to another path.

 @param op : "Prepared copyfile operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_copyfile(Op* op) @local
{
	CopyFileRequest* request = &op.request.copyfile;
	CInt in_fd               = open_copy_source(op, request.path);
	if (op.result.error.status) return;

	libc::Stat in_stat;
	if (retry_file_stat_op(in_fd, &in_stat, &posix_fstat) != 0)
	{
		native_errno(op, libc::errno());
		close_fd_preserving_error(op, in_fd);
		return;
	}
	if (!regular_copy_file(op, &in_stat))
	{
		close_fd_preserving_error(op, in_fd);
		return;
	}

	CopyDestination destination = open_copy_destination(op, request.new_path, request.options, &in_stat);
	if (op.result.error.status)
	{
		close_fd_preserving_error(op, in_fd);
		return;
	}
	CInt out_fd = destination.fd;

	libc::Stat out_stat;
	if (retry_file_stat_op(out_fd, &out_stat, &posix_fstat) != 0)
	{
		native_errno(op, libc::errno());
		close_copy_descriptors(op, out_fd, in_fd, request.new_path, destination.created);
		return;
	}
	if (!regular_copy_file(op, &out_stat))
	{
		close_copy_descriptors(op, out_fd, in_fd, request.new_path, destination.created);
		return;
	}
	if (!request.options.exclusive && same_file(&in_stat, &out_stat))
	{
		close_fd_preserving_error(op, out_fd);
		close_fd_preserving_error(op, in_fd);
		return;
	}

	if (!truncate_copy_destination(op, out_fd))
	{
		close_copy_descriptors(op, out_fd, in_fd, request.new_path, destination.created);
		return;
	}

	if (!chmod_copy_destination(op, out_fd, &in_stat))
	{
		close_copy_descriptors(op, out_fd, in_fd, request.new_path, destination.created);
		return;
	}

	copy_fd_to_fd(op, out_fd, in_fd, CURRENT_OFFSET, sz::max);
	if (!op.result.error.status) op.result.eof = false;
	close_copy_descriptors(op, out_fd, in_fd, request.new_path, destination.created);
}

<*
 Copy bytes between two already open file handles.

 @param op : "Prepared sendfile operation"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_sendfile(Op* op) @local
{
	SendFileRequest* request = &op.request.sendfile;
	copy_fd_to_fd(op, (CInt)request.out_file.handle, (CInt)request.in_file.handle, request.in_offset, request.length);
}

<*
 Read native directory entries into caller output storage.

 `full_scan` reports `BUFFER_FULL` when the output buffer fills before EOF;
 non-full scans stop at the caller capacity and can be resumed later.

 @param op : "Operation receiving result count and errors"
 @param dir : "Open native directory stream"
 @param [out] out : "Caller-owned output entries"
 @param full_scan : "Whether filling `out` before EOF is an error"
 @require op != null : "Operation pointer must not be null"
*>
fn void read_dir_entries(Op* op, posix::DIRPtr dir, DirEntry[] out, bool full_scan) @local
{
	while (true)
	{
		posix::Posix_dirent* entry;
		do
		{
			libc::errno_set((Errno)0);
			entry = posix::readdir(dir);
		} while (!entry && libc::errno() == posix_errno::E_INTR);
		if (!entry)
		{
			if (libc::errno() != 0) native_errno(op, libc::errno());
			return;
		}
		String name = ((ZString)&entry.name).str_view();
		if (!name || name == "." || name == "..") continue;
		if (op.result.count >= out.len)
		{
			if (full_scan) native_error(op, nova::BUFFER_FULL);
			return;
		}
		if (!copy_dir_entry(op, &out[op.result.count], name, entry.d_type)) return;
		op.result.count++;
		if (!full_scan && op.result.count == out.len) return;
	}
}

<*
 Copy one native directory entry into portable output storage.

 @param op : "Operation receiving overflow errors"
 @param [out] out : "Directory entry to fill"
 @param name : "Entry name"
 @param native_type : "Native dirent type code"
 @return "True when the entry was copied"
 @require op != null : "Operation pointer must not be null"
 @require out != null : "Output entry pointer must not be null"
*>
fn bool copy_dir_entry(Op* op, DirEntry* out, String name, char native_type) @local
{
	if (name.len >= out.name_storage.len)
	{
		native_error(op, nova::BUFFER_FULL);
		return false;
	}
	out.type = dir_entry_type(native_type);
	out.name_len = name.len;
	mem::copy(out.name_storage[0:name.len].ptr, name.ptr, name.len);
	return true;
}

<*
 Convert native dirent type code to portable `DirEntryType`.

 @param native_type : "Native dirent type code"
 @return "Portable directory entry type"
*>
fn DirEntryType dir_entry_type(char native_type) @local
{
	if (native_type == posix::DT_REG) return DirEntryType.FILE;
	if (native_type == posix::DT_DIR) return DirEntryType.DIR;
	if (native_type == posix::DT_LNK) return DirEntryType.LINK;
	if (native_type == posix::DT_FIFO) return DirEntryType.FIFO;
	if (native_type == posix::DT_SOCK) return DirEntryType.SOCKET;
	if (native_type == posix::DT_CHR) return DirEntryType.CHAR;
	if (native_type == posix::DT_BLK) return DirEntryType.BLOCK;
	return DirEntryType.UNKNOWN;
}

<*
 Convert a portable timestamp to native `timespec`.

 @param timestamp : "Portable timestamp"
 @return "Native POSIX timestamp"
*>
fn libc::TimeSpec timestamp_to_timespec(Timestamp timestamp) @local
{
	return { .s = (libc::Time_t)timestamp.seconds, .ns = (CLong)timestamp.nanoseconds };
}

<*
 Retry a descriptor operation while it is interrupted by `EINTR`.

 @param fd : "Native descriptor"
 @param callback : "Native operation"
 @return "Native callback result"
*>
fn CInt retry_fd_op(CInt fd, FdOp callback) @local
{
	CInt result;
	do
	{
		result = callback(fd);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a descriptor mode operation while it is interrupted by `EINTR`.
*>
fn CInt retry_file_mode_op(CInt fd, libc::Mode_t mode, FileModeOp callback) @local
{
	CInt result;
	do
	{
		result = callback(fd, mode);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a descriptor stat operation while it is interrupted by `EINTR`.
*>
fn CInt retry_file_stat_op(CInt fd, libc::Stat* statbuf, FileStatOp callback) @local
{
	CInt result;
	do
	{
		result = callback(fd, statbuf);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a descriptor timestamp operation while it is interrupted by `EINTR`.
*>
fn CInt retry_file_time_op(CInt fd, libc::TimeSpec* times, FileTimeOp callback) @local
{
	CInt result;
	do
	{
		result = callback(fd, times);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a descriptor ownership operation while it is interrupted by `EINTR`.
*>
fn CInt retry_file_chown_op(CInt fd, libc::Uid_t uid, libc::Gid_t gid, FileChownOp callback) @local
{
	CInt result;
	do
	{
		result = callback(fd, uid, gid);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a path operation while it is interrupted by `EINTR`.
*>
fn CInt retry_path_op(ZString path, PathOp callback) @local
{
	CInt result;
	do
	{
		result = callback(path);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a two-path operation while it is interrupted by `EINTR`.
*>
fn CInt retry_path2_op(ZString path, ZString new_path, Path2Op callback) @local
{
	CInt result;
	do
	{
		result = callback(path, new_path);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a path mode operation while it is interrupted by `EINTR`.
*>
fn CInt retry_path_mode_op(ZString path, libc::Mode_t mode, PathModeOp callback) @local
{
	CInt result;
	do
	{
		result = callback(path, mode);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a path stat operation while it is interrupted by `EINTR`.
*>
fn CInt retry_path_stat_op(ZString path, libc::Stat* statbuf, PathStatOp callback) @local
{
	CInt result;
	do
	{
		result = callback(path, statbuf);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a filesystem statistics operation while it is interrupted by `EINTR`.
*>
fn CInt retry_path_statfs_op(ZString path, NativeStatFs* statbuf) @local
{
	CInt result;
	do
	{
		result = posix_statfs(path, statbuf);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry a path ownership operation while it is interrupted by `EINTR`.
*>
fn CInt retry_path_chown_op(ZString path, libc::Uid_t uid, libc::Gid_t gid, PathChownOp callback) @local
{
	CInt result;
	do
	{
		result = callback(path, uid, gid);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Retry `utimensat` while it is interrupted by `EINTR`.
*>
fn CInt retry_utimensat(ZString path, libc::TimeSpec* times, CInt flags) @local
{
	CInt result;
	do
	{
		result = posix_utimensat(FS_AT_FDCWD, path, times, flags);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Open the source file for copyfile.

 @param op : "Operation receiving native errors"
 @param path : "Zero-terminated source path"
 @return "Native source descriptor, or -1 when an error was stored"
 @require op != null : "Operation pointer must not be null"
*>
fn CInt open_copy_source(Op* op, char* path) @local
{
	CInt fd;
	do
	{
		fd = posix_open((ZString)path, FS_O_RDONLY | FS_O_NONBLOCK | FS_O_CLOEXEC, 0);
	} while (fd < 0 && libc::errno() == posix_errno::E_INTR);
	if (fd < 0) native_errno(op, libc::errno());
	return fd;
}

<*
 Open the destination file for copyfile.

 @param op : "Operation receiving native errors"
 @param path : "Zero-terminated destination path"
 @param options : "Copyfile behavior"
 @param source_stat : "Source stat used for initial destination permissions"
 @return "Destination descriptor and creation ownership"
 @require op != null : "Operation pointer must not be null"
 @require source_stat != null : "Source stat pointer must not be null"
*>
fn CopyDestination open_copy_destination(Op* op, char* path, CopyFileOptions options, libc::Stat* source_stat) @local
{
	CInt flags = FS_O_WRONLY | FS_O_CREAT | FS_O_NONBLOCK | FS_O_CLOEXEC | FS_O_EXCL;

	CInt fd;
	do
	{
		fd = posix_open((ZString)path, flags, (CInt)((ulong)source_stat.st_mode & (ulong)0o777));
	} while (fd < 0 && libc::errno() == posix_errno::E_INTR);

	bool created = fd >= 0;
	if (fd < 0 && !options.exclusive && libc::errno() == posix_errno::E_EXIST)
	{
		flags = FS_O_WRONLY | FS_O_CREAT | FS_O_NONBLOCK | FS_O_CLOEXEC;
		do
		{
			fd = posix_open((ZString)path, flags, (CInt)((ulong)source_stat.st_mode & (ulong)0o777));
		} while (fd < 0 && libc::errno() == posix_errno::E_INTR);
		created = false;
	}

	if (fd < 0) native_errno(op, libc::errno());
	return { .fd = fd, .created = created };
}

<*
 Validate that a stat result names a regular file.

 @param op : "Operation receiving unsupported-file errors"
 @param statbuf : "Native stat result"
 @return "True when the file type is regular"
 @require op != null : "Operation pointer must not be null"
 @require statbuf != null : "Stat pointer must not be null"
*>
fn bool regular_copy_file(Op* op, libc::Stat* statbuf) @local
{
	if (libc_S_ISTYPE((ulong)statbuf.st_mode, libc::S_IFREG)) return true;
	fault dir_status = io::UNSUPPORTED_OPERATION;
	if (libc_S_ISTYPE((ulong)statbuf.st_mode, libc::S_IFDIR)) dir_status = io::FILE_IS_DIR;
	native_error(op, dir_status);
	return false;
}

<*
 Compare two native stat results for same-file identity.

 @param in_stat : "Source stat"
 @param out_stat : "Destination stat"
 @return "True when device and inode match"
 @require in_stat != null : "Source stat pointer must not be null"
 @require out_stat != null : "Destination stat pointer must not be null"
*>
fn bool same_file(libc::Stat* in_stat, libc::Stat* out_stat) @local
{
	return in_stat.st_dev == out_stat.st_dev && in_stat.st_ino == out_stat.st_ino;
}

<*
 Truncate an opened copy destination before writing.

 @param op : "Operation receiving native errors"
 @param fd : "Destination descriptor"
 @return "True when truncation succeeded"
 @require op != null : "Operation pointer must not be null"
*>
fn bool truncate_copy_destination(Op* op, CInt fd) @local
{
	do
	{
		if (posix_ftruncate(fd, (libc::Off_t)0) == 0) return true;
	} while (libc::errno() == posix_errno::E_INTR);
	native_errno(op, libc::errno());
	return false;
}

<*
 Apply source mode bits to an opened copy destination.

 @param op : "Operation receiving native errors"
 @param fd : "Destination descriptor"
 @param source_stat : "Source stat whose mode is copied"
 @return "True when chmod succeeded"
 @require op != null : "Operation pointer must not be null"
 @require source_stat != null : "Source stat pointer must not be null"
*>
fn bool chmod_copy_destination(Op* op, CInt fd, libc::Stat* source_stat) @local
{
	if (retry_file_mode_op(fd, (libc::Mode_t)source_stat.st_mode, &posix_fchmod) == 0) return true;
	native_errno(op, libc::errno());
	return false;
}

<*
 Ensure close-on-exec is set on platforms where open flags may not cover it.

 @param op : "Operation receiving native errors"
 @param fd : "Native descriptor"
 @return "True when the descriptor is configured"
 @require op != null : "Operation pointer must not be null"
*>
fn bool set_fd_cloexec(Op* op, CInt fd)
{
	$if env::LINUX:
		return true;
	$else
		CInt current = posix_fcntl_retry(fd, FS_F_GETFD, 0);
		if (current < 0 || posix_fcntl_retry(fd, FS_F_SETFD, current | FS_FD_CLOEXEC) < 0)
		{
			native_errno(op, libc::errno());
			return false;
		}
		return true;
	$endif
}

<*
 Retry `fcntl` while it is interrupted by `EINTR`.

 @param fd : "Native descriptor"
 @param cmd : "fcntl command"
 @param arg : "fcntl integer argument"
 @return "Native fcntl result"
*>
fn CInt posix_fcntl_retry(CInt fd, CInt cmd, CInt arg) @local
{
	CInt result;
	do
	{
		result = posix_fcntl(fd, cmd, arg);
	} while (result < 0 && libc::errno() == posix_errno::E_INTR);
	return result;
}

<*
 Copy bytes from one descriptor to another with a stack buffer.

 The operation checks cooperative worker cancellation between chunks and stores
 total bytes written in `op.result.bytes`.

 @param op : "Operation receiving progress and errors"
 @param out_fd : "Destination descriptor"
 @param in_fd : "Source descriptor"
 @param in_offset : "Source offset or `CURRENT_OFFSET`"
 @param length : "Maximum bytes to copy"
 @require op != null : "Operation pointer must not be null"
*>
fn void copy_fd_to_fd(Op* op, CInt out_fd, CInt in_fd, Offset in_offset, sz length) @local
{
	$if env::LINUX:
		if (copy_range_fast(op, out_fd, in_fd, in_offset, length)) return;
	$endif

	char[FS_COPY_BUFFER_SIZE] storage;
	sz remaining = length;
	while (remaining > 0 && !op.result.error.status)
	{
		if (op.work.cancel_requested())
		{
			native_error(op, nova::CANCELLED);
			return;
		}

		sz wanted = remaining;
		if (remaining > storage.len) wanted = storage.len;
		sz read_bytes = read_copy_chunk(op, in_fd, storage[0:wanted], in_offset, op.result.bytes);
		if (op.result.error.status) return;
		if (read_bytes == 0)
		{
			op.result.eof = true;
			return;
		}
		write_copy_chunk(op, out_fd, storage[0:read_bytes]);
		if (remaining != sz::max) remaining -= read_bytes;
	}
}

<*
 Attempt an in-kernel `copy_file_range` transfer.

 Returns true when the copy was fully handled — success (progress, EOF or
 cancellation) or a stored native error — so the caller returns. Returns false
 only when the syscall does not apply to these descriptors and nothing has been
 copied yet, so `copy_fd_to_fd` falls back to its userspace read/write loop from a
 clean offset. A failing `copy_file_range` does not advance descriptor positions,
 so the fallback resumes correctly.

 @param op : "Operation receiving progress and errors"
 @param out_fd : "Destination descriptor"
 @param in_fd : "Source descriptor"
 @param in_offset : "Source offset or `CURRENT_OFFSET`"
 @param length : "Maximum bytes to copy"
 @require op != null : "Operation pointer must not be null"
*>
fn bool copy_range_fast(Op* op, CInt out_fd, CInt in_fd, Offset in_offset, sz length) @local @if(env::LINUX)
{
	libc::Off_t in_pos      = (libc::Off_t)(long)in_offset;
	libc::Off_t* in_pos_ptr = in_offset == CURRENT_OFFSET ? null : &in_pos;
	sz remaining            = length;
	bool copied_any         = false;
	while (remaining > 0 && !op.result.error.status)
	{
		if (op.work.cancel_requested())
		{
			native_error(op, nova::CANCELLED);
			return true;
		}

		usz wanted = remaining == sz::max || (usz)remaining > FS_COPY_RANGE_MAX ? FS_COPY_RANGE_MAX : (usz)remaining;
		sz copied  = posix_copy_file_range(in_fd, in_pos_ptr, out_fd, null, wanted, 0);
		if (copied < 0)
		{
			Errno err = libc::errno();
			if (err == posix_errno::E_INTR) continue;
			if (!copied_any && copy_range_unsupported(err)) return false;
			native_errno(op, err);
			return true;
		}
		if (copied == 0)
		{
			op.result.eof = true;
			return true;
		}

		copied_any = true;
		if (!add_result_bytes(op, copied)) return true;
		if (remaining != sz::max) remaining -= copied;
	}
	return true;
}

<*
 Report whether a `copy_file_range` errno means the syscall cannot service these
 descriptors and the caller should fall back to a userspace copy.

 @param err : "errno reported by a failed `copy_file_range`"
 @return "True when the userspace fallback should run instead"
*>
fn bool copy_range_unsupported(Errno err) @local @if(env::LINUX)
{
	return err == posix_errno::E_NOSYS || err == posix_errno::E_INVAL || err == posix_errno::E_XDEV
		|| err == posix_errno::E_OPNOTSUPP
		|| err == posix_errno::E_BADF;
}

<*
 Read one copy chunk from a descriptor.

 @param op : "Operation receiving native errors"
 @param fd : "Source descriptor"
 @param [out] buffer : "Temporary chunk storage"
 @param offset : "Source offset or `CURRENT_OFFSET`"
 @param completed : "Bytes already copied"
 @return "Bytes read, or zero on EOF or stored error"
 @require op != null : "Operation pointer must not be null"
*>
fn sz read_copy_chunk(Op* op, CInt fd, char[] buffer, Offset offset, sz completed) @local
{
	sz read_bytes;
	do
	{
		if (offset == CURRENT_OFFSET)
		{
			read_bytes = libc::read(fd, buffer.ptr, (usz)buffer.len);
		}
		else
		{
			if (!offset_step_valid(op, offset, completed)) return 0;
			read_bytes = posix_pread(fd, buffer.ptr, (usz)buffer.len, (libc::Off_t)((long)offset + (long)completed));
		}
	} while (read_bytes < 0 && libc::errno() == posix_errno::E_INTR);
	if (read_bytes < 0)
	{
		native_errno(op, libc::errno());
		return 0;
	}
	return read_bytes;
}

<*
 Check whether adding progress to an absolute offset fits native offset range.

 @param op : "Operation receiving invalid-position errors"
 @param offset : "Base source offset"
 @param completed : "Bytes already copied"
 @return "True when the next positioned IO offset is valid"
 @require op != null : "Operation pointer must not be null"
*>
fn bool offset_step_valid(Op* op, Offset offset, sz completed) @local
{
	if (completed <= (sz)(long::max - (long)offset)) return true;
	native_error(op, io::INVALID_POSITION);
	return false;
}

<*
 Write one full copy chunk to a descriptor.

 @param op : "Operation receiving progress and errors"
 @param fd : "Destination descriptor"
 @param bytes : "Chunk bytes to write"
 @require op != null : "Operation pointer must not be null"
*>
fn void write_copy_chunk(Op* op, CInt fd, char[] bytes) @local
{
	sz written = 0;
	while (written < bytes.len)
	{
		sz step = libc::write(fd, bytes.ptr + written, (usz)(bytes.len - written));
		if (step < 0)
		{
			Errno err = libc::errno();
			if (err == posix_errno::E_INTR) continue;
			native_errno(op, err);
			return;
		}
		if (step == 0)
		{
			native_error(op, io::INCOMPLETE_WRITE);
			return;
		}
		written += step;
		if (!add_result_bytes(op, step)) return;
	}
}

<*
 Add written byte count to the operation result with overflow checking.

 @param op : "Operation whose byte counter is updated"
 @param bytes : "Bytes to add"
 @return "True when the counter was updated"
 @require op != null : "Operation pointer must not be null"
*>
fn bool add_result_bytes(Op* op, sz bytes) @local
{
	if (bytes <= sz::max - op.result.bytes)
	{
		op.result.bytes += bytes;
		return true;
	}
	native_error(op, io::OVERFLOW);
	return false;
}

<*
 Close a descriptor without overwriting an earlier operation error.

 @param op : "Operation receiving close errors only if still successful"
 @param fd : "Native descriptor"
 @require op != null : "Operation pointer must not be null"
*>
fn void close_fd_preserving_error(Op* op, CInt fd) @local
{
	if (fd < 0) return;
	if (libc::close(fd) == 0) return;
	Errno err = libc::errno();
	if (err == posix_errno::E_INTR || err == posix_errno::E_INPROGRESS || op.result.error.status) return;
	native_errno(op, err);
}

<*
 Close copyfile descriptors and remove a newly created destination on failure.

 @param op : "Operation receiving close errors"
 @param out_fd : "Destination descriptor"
 @param in_fd : "Source descriptor"
 @param new_path : "Destination path"
 @param remove_destination_on_error : "Whether failed copy should unlink destination"
 @require op != null : "Operation pointer must not be null"
*>
fn void close_copy_descriptors(Op* op, CInt out_fd, CInt in_fd, char* new_path, bool remove_destination_on_error) @local
{
	close_fd_preserving_error(op, out_fd);
	close_fd_preserving_error(op, in_fd);
	if (op.result.error.status && remove_destination_on_error) unlink_copy_destination(new_path);
}

<*
 Best-effort unlink for a failed newly created copy destination.

 @param path : "Zero-terminated destination path"
*>
fn void unlink_copy_destination(char* path) @local
{
	CInt result;
	do
	{
		result = posix_unlink((ZString)path);
	} while (result != 0 && libc::errno() == posix_errno::E_INTR);
}

<*
 Convert portable open options to native POSIX open flags.

 @param op : "Operation receiving invalid option errors"
 @param options : "Portable open options"
 @return "Native open flags, or zero when an invalid access mode was stored"
 @require op != null : "Operation pointer must not be null"
*>
fn CInt open_flags(Op* op, OpenOptions options)
{
	CInt flags = 0;
	switch (options.access)
	{
		case OpenAccess.READ: flags = FS_O_RDONLY;
		case OpenAccess.WRITE: flags = FS_O_WRONLY;
		case OpenAccess.READ_WRITE: flags = FS_O_RDWR;
		default:
			native_error(op, nova::INVALID_STATE);
			return 0;
	}
	if (options.create) flags |= FS_O_CREAT;
	if (options.exclusive) flags |= FS_O_EXCL;
	if (options.truncate) flags |= FS_O_TRUNC;
	if (options.append) flags |= FS_O_APPEND;
	if (options.nonblock) flags |= FS_O_NONBLOCK;
	if (!options.inherit_on_exec) flags |= FS_O_CLOEXEC;
	if (options.directory)
	{
		flags |= FS_O_DIRECTORY;
	}
	if (options.nofollow)
	{
		flags |= FS_O_NOFOLLOW;
	}
	return flags;
}

<*
 Convert portable access mode to native `access` bits.

 @param mode : "Portable access mode"
 @return "Native access mode bits"
*>
fn CInt access_mode(AccessMode mode) @local
{
	CInt native = 0;
	if (mode.read) native |= FS_R_OK;
	if (mode.write) native |= FS_W_OK;
	if (mode.execute) native |= FS_X_OK;
	return native;
}

<*
 Store a generated zero-terminated path in the operation result.

 @param op : "Operation receiving path result"
 @param path : "Mutable native path buffer"
 @require op != null : "Operation pointer must not be null"
 @require path != null : "Path pointer must not be null"
*>
fn void set_generated_path_result(Op* op, char* path) @local
{
	String value = ((ZString)path).str_view();
	op.result.path = value;
	op.result.bytes = value.len;
}

<*
 Convert native stat storage to portable `fs::Stat`.

 @param statbuf : "Native stat result"
 @return "Portable stat result"
 @require statbuf != null : "Stat pointer must not be null"
*>
fn Stat convert_stat(libc::Stat* statbuf) @local
{
	Stat out;
	out.type = file_type((ulong)statbuf.st_mode);
	out.mode = (ulong)statbuf.st_mode;
	out.uid = (ulong)statbuf.st_uid;
	out.gid = (ulong)statbuf.st_gid;
	out.dev = (ulong)statbuf.st_dev;
	out.ino = (ulong)statbuf.st_ino;
	out.nlink = (ulong)statbuf.st_nlink;
	out.rdev = (ulong)statbuf.st_rdev;
	out.size = (long)statbuf.st_size;
	out.blocks = (long)statbuf.st_blocks;

	$switch:
		$case env::DARWIN:
			out.block_size = (long)statbuf.st_blocksize;
			out.accessed = timestamp_from_timespec(statbuf.st_atimespec);
			out.modified = timestamp_from_timespec(statbuf.st_mtimespec);
			out.changed = timestamp_from_timespec(statbuf.st_ctimespec);
			out.created = timestamp_from_timespec(statbuf.st_birthtimespec);
		$case env::LINUX:
			out.block_size = (long)statbuf.st_blksize;
			out.accessed = { .seconds = (long)statbuf.st_atime, .nanoseconds = (int)statbuf.st_atime_nsec };
			out.modified = { .seconds = (long)statbuf.st_mtime, .nanoseconds = (int)statbuf.st_mtime_nsec };
			out.changed = { .seconds = (long)statbuf.st_ctime, .nanoseconds = (int)statbuf.st_ctime_nsec };
	$endswitch
	return out;
}

<*
 Convert native filesystem statistics to portable `fs::StatFs`.

 @param statbuf : "Native filesystem statistics"
 @return "Portable filesystem statistics"
 @require statbuf != null : "StatFs pointer must not be null"
*>
fn StatFs convert_statfs(NativeStatFs* statbuf) @local
{
	StatFs out;
	$switch:
		$case env::LINUX:
			out.type = (ulong)statbuf.f_type;
			out.block_size = (ulong)statbuf.f_bsize;
			out.fragment_size = out.block_size;
			if (statbuf.f_frsize > 0) out.fragment_size = (ulong)statbuf.f_frsize;
		$case env::DARWIN:
			out.type = (ulong)statbuf.f_type;
			out.block_size = (ulong)statbuf.f_bsize;
			out.fragment_size = out.block_size;
	$endswitch
	out.blocks = (ulong)statbuf.f_blocks;
	out.blocks_free = (ulong)statbuf.f_bfree;
	out.blocks_available = (ulong)statbuf.f_bavail;
	out.files = (ulong)statbuf.f_files;
	out.files_free = (ulong)statbuf.f_ffree;
	return out;
}

<*
 Convert native timespec storage to portable timestamp.

 @param spec : "Native timestamp"
 @return "Portable timestamp"
*>
fn Timestamp timestamp_from_timespec(libc::TimeSpec spec) @local
{
	return { .seconds = (long)spec.s, .nanoseconds = (int)spec.ns };
}

<*
 Convert native mode bits to portable file type.

 @param mode : "Native st_mode bits"
 @return "Portable file type"
*>
fn FileType file_type(ulong mode) @local
{
	if (libc_S_ISTYPE(mode, libc::S_IFREG)) return FileType.FILE;
	if (libc_S_ISTYPE(mode, libc::S_IFDIR)) return FileType.DIR;
	if (libc_S_ISTYPE(mode, libc::S_IFLNK)) return FileType.LINK;
	if (libc_S_ISTYPE(mode, libc::S_IFIFO)) return FileType.FIFO;
	if (libc_S_ISTYPE(mode, libc::S_IFSOCK)) return FileType.SOCKET;
	if (libc_S_ISTYPE(mode, libc::S_IFCHR)) return FileType.CHAR;
	if (libc_S_ISTYPE(mode, libc::S_IFBLK)) return FileType.BLOCK;
	return FileType.UNKNOWN;
}

<*
 Store an errno-derived portable error and POSIX diagnostic on the result.

 @param op : "Operation result to update"
 @param err : "Native errno value"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_errno(Op* op, Errno err) @local
{
	op.result.error.status = fs_fault_from_errno(err);
	op.result.error.platform = { .domain = nova::ErrorDomain.POSIX_ERRNO, .code = (int)err };
}

<*
 Store a portable operation fault on the result.

 @param op : "Operation result to update"
 @param status : "Portable operation status"
 @require op != null : "Operation pointer must not be null"
*>
fn void native_error(Op* op, fault status) @local
{
	op.result.error.status = status;
}

<*
 Map POSIX errno values to portable filesystem faults.

 @param err : "Native errno value"
 @return "Portable fault for caller control flow"
*>
fn fault fs_fault_from_errno(Errno err) @local
{
	if (err == posix_errno::E_NOENT || err == posix_errno::E_NXIO) return io::FILE_NOT_FOUND;
	if (err == posix_errno::E_ACCES || err == posix_errno::E_PERM
		|| err == posix_errno::E_FAULT) return io::NO_PERMISSION;
	if (err == posix_errno::E_EXIST) return io::ALREADY_EXISTS;
	if (err == posix_errno::E_NOTDIR) return io::FILE_NOT_DIR;
	if (err == posix_errno::E_ISDIR) return io::FILE_IS_DIR;
	if (err == posix_errno::E_NOTEMPTY) return io::DIR_NOT_EMPTY;
	if (err == posix_errno::E_NAMETOOLONG) return io::NAME_TOO_LONG;
	if (err == posix_errno::E_MFILE) return io::TOO_MANY_DESCRIPTORS;
	if (err == posix_errno::E_NFILE || err == posix_errno::E_NOSPC || err == posix_errno::E_DQUOT
		|| err == posix_errno::E_FBIG) return io::OUT_OF_SPACE;
	if (err == posix_errno::E_ROFS) return io::READ_ONLY;
	if (err == posix_errno::E_BADF) return io::FILE_NOT_VALID;
	if (err == posix_errno::E_INTR) return io::INTERRUPTED;
	if (err == posix_errno::E_LOOP) return io::SYMLINK_FAILED;
	if (err == posix_errno::E_OPNOTSUPP) return io::UNSUPPORTED_OPERATION;
	if (err == posix_errno::E_AGAIN) return io::WOULD_BLOCK;
	if (err == posix_errno::E_SPIPE || err == posix_errno::E_PIPE) return io::FILE_IS_PIPE;
	if (err == posix_errno::E_INVAL) return io::INVALID_POSITION;
	if (err == posix_errno::E_OVERFLOW) return io::OVERFLOW;
	if (err == posix_errno::E_IO) return io::GENERAL_ERROR;
	return io::UNKNOWN_ERROR;
}
