module nova::fs;

import nova @norecurse;
import nova::op @public;
import nova::work;

<*
 Callback invoked on the loop owner thread after an FS operation finishes.

 The result pointer is valid only during the callback. The operation storage is
 reusable from inside this callback.

 @param loop : "Loop dispatching the completion"
 @param op : "Filesystem operation storage"
 @param result : "Result valid only during this callback"
 @param userdata : "Opaque pointer provided at submission"
*>
alias Callback = fn void(nova::Loop* loop, Op* op, Result* result, void* userdata);

<*
 Use the native file descriptor's current offset for read, write and sendfile.
*>
const Offset CURRENT_OFFSET = (Offset)-1;

<*
 Inline capacity for a copied request path, including the NUL terminator. Covers
 `PATH_MAX` on every supported platform (Linux 4096, macOS 1024), so request paths
 are stored in operation-owned storage without a runtime allocation. Longer paths
 are rejected — the kernel rejects them with `ENAMETOOLONG` anyway.
*>
const sz FS_PATH_MAX = 4096;

<*
 File operation type stored in `Op`.
*>
constdef FsKind : inline char
{
	NONE      = 0,
	OPEN      = 1,
	CLOSE     = 2,
	READ      = 3,
	WRITE     = 4,
	STAT      = 5,
	FSTAT     = 6,
	LSTAT     = 7,
	FSYNC     = 8,
	FDATASYNC = 9,
	FTRUNCATE = 10,
	ACCESS    = 11,
	MKDIR     = 12,
	RMDIR     = 13,
	UNLINK    = 14,
	RENAME    = 15,
	READLINK  = 16,
	REALPATH  = 17,
	OPENDIR   = 18,
	READDIR   = 19,
	CLOSEDIR  = 20,
	SCANDIR   = 21,
	CHMOD     = 22,
	FCHMOD    = 23,
	UTIME     = 24,
	FUTIME    = 25,
	LUTIME    = 26,
	LINK      = 27,
	SYMLINK   = 28,
	CHOWN     = 29,
	FCHOWN    = 30,
	LCHOWN    = 31,
	COPYFILE  = 32,
	SENDFILE  = 33,
	MKDTEMP   = 34,
	MKSTEMP   = 35,
	STATFS    = 36,
}

<*
 File open access mode.
*>
constdef OpenAccess : inline char
{
	READ       = 0,
	WRITE      = 1,
	READ_WRITE = 2,
}

<*
 Portable file type reported by `Stat`.
*>
constdef FileType : inline char
{
	UNKNOWN = 0,
	FILE    = 1,
	DIR     = 2,
	LINK    = 3,
	FIFO    = 4,
	SOCKET  = 5,
	CHAR    = 6,
	BLOCK   = 7,
}

<*
 Portable directory entry type reported by `DirEntry`.
*>
constdef DirEntryType : inline char
{
	UNKNOWN = 0,
	FILE    = 1,
	DIR     = 2,
	LINK    = 3,
	FIFO    = 4,
	SOCKET  = 5,
	CHAR    = 6,
	BLOCK   = 7,
}

<*
 Offset sentinel for current native file offset.
*>
typedef Offset = inline long;

<*
 POSIX-style timestamp storage.
*>
struct Timestamp
{
	long seconds;
	int nanoseconds;
}

<*
 Portable stat result.
*>
struct Stat
{
	FileType type;
	ulong mode;
	ulong uid;
	ulong gid;
	ulong dev;
	ulong ino;
	ulong nlink;
	ulong rdev;
	long size;
	long block_size;
	long blocks;
	Timestamp accessed;
	Timestamp modified;
	Timestamp changed;
	Timestamp created;
}

<*
 Portable filesystem capacity and inode statistics.
*>
struct StatFs
{
	ulong type;
	ulong block_size;
	ulong fragment_size;
	ulong blocks;
	ulong blocks_free;
	ulong blocks_available;
	ulong files;
	ulong files_free;
}

<*
 Async file handle.
*>
struct File
{
	NativeHandle handle;
	bool closing;
	bool open;
}

<*
 Caller-owned async directory handle.

 Storage is provided to `opendir` and must stay pointer-stable until the directory
 is closed. The runtime never allocates it.
*>
struct Dir
{
	void* native;
	bool busy;
	bool open;
}

<*
 Directory entry copied into caller-owned output storage.
*>
struct DirEntry
{
	DirEntryType type;
	char[256] name_storage;
	sz name_len;
}

<*
 Options for `open`.
*>
struct OpenOptions
{
	OpenAccess access;
	uint mode;
	bool create;
	bool exclusive;
	bool truncate;
	bool append;
	bool directory;
	bool nofollow;
	bool nonblock;
	bool inherit_on_exec;
}

<*
 Access check mode.
*>
struct AccessMode
{
	bool read;
	bool write;
	bool execute;
}

<*
 Options for `copyfile`.
*>
struct CopyFileOptions
{
	bool exclusive;
}

<*
 Result delivered for filesystem operation completion.
*>
struct Result
{
	nova::ErrorInfo error;
	FsKind kind;
	File file;
	Dir* dir;
	Stat stat;
	StatFs statfs;
	char[] path;
	sz bytes;
	sz count;
	bool eof;
}

<*
 Request payload for operations that only need one owned path.

 `path` is a zero-terminated allocator-owned copy made at submission time.
*>
struct PathRequest
{
	char* path;
}

<*
 Request payload for operations that need two owned paths.

 Both fields are zero-terminated allocator-owned copies made at submission time.
*>
struct Path2Request
{
	char* path;
	char* new_path;
}

<*
 Request payload for path operations with a file mode argument.
*>
struct PathModeRequest
{
	char* path;
	uint mode;
}

<*
 Request payload for file open.
*>
struct OpenRequest
{
	char* path;
	OpenOptions options;
}

<*
 Request payload for file close.

 `file` points to caller-owned handle storage updated on the loop owner thread
 after worker completion. `handle` captures the native descriptor value for the
 worker thread.
*>
struct CloseRequest
{
	File* file;
	NativeHandle handle;
}

<*
 Request payload for file read.

 `buffer` is borrowed caller storage and must remain valid until the callback.
*>
struct ReadRequest
{
	File file;
	char[] buffer;
	Offset offset;
}

<*
 Request payload for full file write.

 `bytes` is borrowed caller storage and must remain valid until the callback.
*>
struct WriteRequest
{
	File file;
	char[] bytes;
	Offset offset;
}

<*
 Request payload for file-handle operations that only need a file and offset.
*>
struct FileRequest
{
	File file;
	Offset offset;
}

<*
 Request payload for file-handle operations with a mode argument.
*>
struct FileModeRequest
{
	File file;
	uint mode;
}

<*
 Request payload for path access checks.
*>
struct AccessRequest
{
	char* path;
	AccessMode mode;
}

<*
 Request payload for path operations that write an output path.

 `out` is borrowed caller storage and must remain valid until the callback.
*>
struct OutputPathRequest
{
	char* path;
	char[] out;
}

<*
 Request payload for opening a directory.

 `dir` points to caller-owned directory storage updated on the loop owner thread.
*>
struct OpenDirRequest
{
	char* path;
	Dir* dir;
}

<*
 Request payload for operations on an open directory.

 `out` is borrowed caller storage and must remain valid until the callback.
*>
struct DirRequest
{
	Dir* dir;
	DirEntry[] out;
}

<*
 Request payload for scanning a path into directory entries.

 `out` is borrowed caller storage and must remain valid until the callback.
*>
struct ScanDirRequest
{
	char* path;
	DirEntry[] out;
}

<*
 Request payload for timestamp updates.

 `path` is set for path and symlink timestamp updates; `file` is set for file
 handle timestamp updates.
*>
struct TimeRequest
{
	char* path;
	File file;
	Timestamp accessed;
	Timestamp modified;
}

<*
 Request payload for ownership updates.

 `path` is set for path and symlink ownership updates; `file` is set for file
 handle ownership updates.
*>
struct ChownRequest
{
	char* path;
	File file;
	uint uid;
	uint gid;
}

<*
 Request payload for full file copy.

 Both paths are zero-terminated allocator-owned copies.
*>
struct CopyFileRequest
{
	char* path;
	char* new_path;
	CopyFileOptions options;
}

<*
 Request payload for copying bytes between open files.
*>
struct SendFileRequest
{
	File out_file;
	File in_file;
	Offset in_offset;
	sz length;
}

<*
 Operation-specific request storage.

 The active variant is selected by `Op.kind`. Owned path fields are released by
 `fs_cleanup` after worker completion or failed submission.
*>
union Request
{
	PathRequest path;
	Path2Request path2;
	PathModeRequest path_mode;
	OpenRequest open;
	CloseRequest close;
	ReadRequest read;
	WriteRequest write;
	FileRequest file;
	FileModeRequest file_mode;
	AccessRequest access;
	OutputPathRequest output_path;
	OpenDirRequest opendir;
	DirRequest dir;
	ScanDirRequest scandir;
	TimeRequest time;
	ChownRequest chown;
	CopyFileRequest copyfile;
	SendFileRequest sendfile;
}

<*
 Caller-owned filesystem operation storage.

 `work` must remain the first field because worker callbacks recover `Op*` from
 the embedded `WorkOp*`.
*>
struct Op
{
	work::WorkOp work;
	bool initialized;
	FsKind kind;
	Result result;
	Callback callback;
	Allocator allocator;
	Request request;
	char[FS_PATH_MAX] path_buf;
	char[FS_PATH_MAX] path2_buf;
}

<*
 Initialize caller-owned filesystem operation storage.

 @param [&inout] self : "Filesystem operation storage"
 @return "Initialized operation storage"
 @ensure self.initialized : "Operation storage is initialized after init"
*>
fn Op* Op.init(&self)
{
	*self = { };
	self.work.init();
	self.initialized = true;
	return self;
}

<*
 Destroy inactive filesystem operation storage.

 @param [&inout] self : "Filesystem operation storage"
 @require self.initialized : "Operation storage must be initialized"
 @require !self.work.active() : "Operation must not be active"
 @ensure !self.initialized : "Operation storage is uninitialized after destroy"
*>
fn void Op.destroy(&self)
{
	fs_cleanup(self);
	self.work.destroy();
	*self = { };
}

<*
 Report whether this filesystem operation is queued, running or completing.

 @param self : "Filesystem operation storage to inspect"
 @return "True while the embedded worker operation is active"
*>
fn bool Op.active(&self) => self.work.active();

<*
 Report whether this file handle can be used by new filesystem operations.

 @param self : "File handle to inspect"
 @return "True when the handle is open, not closing and non-negative"
*>
fn bool File.valid(&self) => self.open && !self.closing && (int)self.handle >= 0;

<*
 Report whether this directory handle can be used by new directory operations.

 @param self : "Directory handle to inspect"
 @return "True when the handle is open, idle and backed by native storage"
*>
fn bool Dir.valid(&self) => self.open && !self.busy && self.native != null;

<*
 Return this directory entry name as a slice.

 @param self : "Directory entry"
 @return "Name slice stored in `name_storage`"
*>
fn String DirEntry.name(&self) => (String)self.name_storage[0:self.name_len];

<*
 Validate timestamp nanosecond range.

 @param timestamp : "Timestamp to inspect"
 @return "True when `nanoseconds` is in the POSIX range 0..999999999"
*>
fn bool timestamp_valid(Timestamp timestamp) @local
{
	return timestamp.nanoseconds >= 0 && timestamp.nanoseconds < 1_000_000_000;
}

<*
 Queue an async file open.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path to open"
 @param options : "Open flags"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
*>
fn op::Ref? open(nova::Loop* loop, Op* op, String path, OpenOptions options, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.OPEN, path, callback)!;
	op.request.open.options = options;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async file close.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file to close"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? close(nova::Loop* loop, Op* op, File* file, Callback callback, void* userdata = null)
{
	if (!file || !file.valid()) return nova::INVALID_STATE~;
	prepare_op(loop, op, FsKind.CLOSE, callback)!;
	op.request.close.file = file;
	op.request.close.handle = file.handle;

	op::Ref? ref = queue_fs(loop, op, userdata);
	if (catch ref) return ref;
	file.closing = true;
	return ref;
}

<*
 Queue one async file read.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file to read from"
 @param [out] buffer : "Caller-owned destination buffer borrowed until callback"
 @param offset : "Absolute offset or `CURRENT_OFFSET`"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file, buffer, offset or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? read(
	nova::Loop* loop,
	Op* op,
	File file,
	char[] buffer,
	Offset offset,
	Callback callback,
	void* userdata = null
)
{
	if (!file.valid() || !buffer.len || offset < CURRENT_OFFSET) return nova::INVALID_STATE~;
	prepare_op(loop, op, FsKind.READ, callback)!;
	op.request.read = { .file = file, .buffer = buffer, .offset = offset };
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async full write.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file to write to"
 @param bytes : "Caller-owned bytes borrowed until callback"
 @param offset : "Absolute offset or `CURRENT_OFFSET`"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file, bytes, offset or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? write(
	nova::Loop* loop,
	Op* op,
	File file,
	char[] bytes,
	Offset offset,
	Callback callback,
	void* userdata = null
)
{
	if (!file.valid() || !bytes.len || offset < CURRENT_OFFSET) return nova::INVALID_STATE~;
	prepare_op(loop, op, FsKind.WRITE, callback)!;
	op.request.write = { .file = file, .bytes = bytes, .offset = offset };
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async stat.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path to inspect"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? stat(nova::Loop* loop, Op* op, String path, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.STAT, path, callback)!;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async filesystem statistics query.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path inside the filesystem to inspect"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? statfs(nova::Loop* loop, Op* op, String path, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.STATFS, path, callback)!;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async fstat.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file to inspect"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? fstat(nova::Loop* loop, Op* op, File file, Callback callback, void* userdata = null)
{
	return queue_file_op(loop, op, FsKind.FSTAT, file, (Offset)0, callback, userdata);
}

<*
 Queue an async lstat.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path or symlink to inspect"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? lstat(nova::Loop* loop, Op* op, String path, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.LSTAT, path, callback)!;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async fsync.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file to sync"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? fsync(nova::Loop* loop, Op* op, File file, Callback callback, void* userdata = null)
{
	return queue_file_op(loop, op, FsKind.FSYNC, file, (Offset)0, callback, userdata);
}

<*
 Queue an async fdatasync.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file to sync"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? fdatasync(nova::Loop* loop, Op* op, File file, Callback callback, void* userdata = null)
{
	return queue_file_op(loop, op, FsKind.FDATASYNC, file, (Offset)0, callback, userdata);
}

<*
 Queue an async ftruncate.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file to resize"
 @param size : "New file size"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file, size or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? ftruncate(nova::Loop* loop, Op* op, File file, Offset size, Callback callback, void* userdata = null)
{
	if (size < (Offset)0) return nova::INVALID_STATE~;
	return queue_file_op(loop, op, FsKind.FTRUNCATE, file, size, callback, userdata);
}

<*
 Queue an async access check.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path to check"
 @param mode : "Access bits to check; all false means existence"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? access(nova::Loop* loop, Op* op, String path, AccessMode mode, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.ACCESS, path, callback)!;
	op.request.access.mode = mode;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async mkdir.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Directory path to create"
 @param mode : "POSIX creation mode"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? mkdir(nova::Loop* loop, Op* op, String path, uint mode, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.MKDIR, path, callback)!;
	op.request.path_mode.mode = mode;
	return queue_fs(loop, op, userdata);
}

<*
 Queue async creation of a unique temporary directory.

 `template_path` is copied into operation-owned mutable storage before worker
 submission. It must end in `XXXXXX`. On success `Result.path` names the
 created directory and is valid only during the callback.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param template_path : "Directory template ending in `XXXXXX`"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, template or callback state is invalid"
 @return ? mem::OUT_OF_MEMORY : "Template copy allocation failed"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? mkdtemp(nova::Loop* loop, Op* op, String template_path, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.MKDTEMP, template_path, callback)!;
	return queue_fs(loop, op, userdata);
}

<*
 Queue async creation of a unique temporary file.

 `template_path` is copied into operation-owned mutable storage before worker
 submission. It must end in `XXXXXX`. On success `Result.path` names the
 created file and `Result.file` is an open file handle owned by the caller.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param template_path : "File template ending in `XXXXXX`"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, template or callback state is invalid"
 @return ? mem::OUT_OF_MEMORY : "Template copy allocation failed"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? mkstemp(nova::Loop* loop, Op* op, String template_path, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.MKSTEMP, template_path, callback)!;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async rmdir.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Directory path to remove"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? rmdir(nova::Loop* loop, Op* op, String path, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.RMDIR, path, callback)!;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async unlink.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "File path to remove"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? unlink(nova::Loop* loop, Op* op, String path, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.UNLINK, path, callback)!;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async rename.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Current path"
 @param new_path : "New path"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, paths or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? rename(nova::Loop* loop, Op* op, String path, String new_path, Callback callback, void* userdata = null)
{
	return queue_path2_op(loop, op, FsKind.RENAME, path, new_path, callback, userdata);
}

<*
 Queue an async readlink.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Symlink path"
 @param [out] out : "Caller-owned output storage borrowed until callback"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path, output or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? readlink(nova::Loop* loop, Op* op, String path, char[] out, Callback callback, void* userdata = null)
{
	return queue_output_path_op(loop, op, FsKind.READLINK, path, out, callback, userdata);
}

<*
 Queue an async realpath.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path to resolve"
 @param [out] out : "Caller-owned output storage borrowed until callback"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path, output or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? realpath(nova::Loop* loop, Op* op, String path, char[] out, Callback callback, void* userdata = null)
{
	return queue_output_path_op(loop, op, FsKind.REALPATH, path, out, callback, userdata);
}

<*
 Queue an async directory open.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param dir : "Caller-owned directory handle storage, pointer-stable until closed"
 @param path : "Directory path to open"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, directory, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? opendir(nova::Loop* loop, Op* op, Dir* dir, String path, Callback callback, void* userdata = null)
{
	if (!dir) return nova::INVALID_STATE~;
	prepare_path_op(loop, op, FsKind.OPENDIR, path, callback)!;
	*dir = { };
	op.request.opendir.dir = dir;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async directory read.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param dir : "Open directory to read"
 @param [out] out : "Caller-owned entry storage borrowed until callback"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, directory, output or callback state is invalid"
 @return ? nova::BUSY : "Directory already has an active operation"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? readdir(nova::Loop* loop, Op* op, Dir* dir, DirEntry[] out, Callback callback, void* userdata = null)
{
	if (!dir || !dir.open || !dir.native || !out.len) return nova::INVALID_STATE~;
	if (dir.busy) return nova::BUSY~;
	prepare_op(loop, op, FsKind.READDIR, callback)!;
	op.request.dir = { .dir = dir, .out = out };

	op::Ref? ref = queue_fs(loop, op, userdata);
	if (catch ref) return ref;
	dir.busy = true;
	return ref;
}

<*
 Queue an async directory close.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param dir : "Open directory to close"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, directory or callback state is invalid"
 @return ? nova::BUSY : "Directory already has an active operation"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? closedir(nova::Loop* loop, Op* op, Dir* dir, Callback callback, void* userdata = null)
{
	if (!dir || !dir.open || !dir.native) return nova::INVALID_STATE~;
	if (dir.busy) return nova::BUSY~;
	prepare_op(loop, op, FsKind.CLOSEDIR, callback)!;
	op.request.dir = { .dir = dir };

	op::Ref? ref = queue_fs(loop, op, userdata);
	if (catch ref) return ref;
	dir.busy = true;
	return ref;
}

<*
 Queue an async full directory scan.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Directory path to scan"
 @param [out] out : "Caller-owned entry storage borrowed until callback"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path, output or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? scandir(nova::Loop* loop, Op* op, String path, DirEntry[] out, Callback callback, void* userdata = null)
{
	if (!out.len) return nova::INVALID_STATE~;
	prepare_path_op(loop, op, FsKind.SCANDIR, path, callback)!;
	op.request.scandir.out = out;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async chmod.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path whose mode will be changed"
 @param mode : "POSIX mode bits"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? chmod(nova::Loop* loop, Op* op, String path, uint mode, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.CHMOD, path, callback)!;
	op.request.path_mode.mode = mode;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async fchmod.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file whose mode will be changed"
 @param mode : "POSIX mode bits"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? fchmod(nova::Loop* loop, Op* op, File file, uint mode, Callback callback, void* userdata = null)
{
	if (!file.valid()) return nova::INVALID_STATE~;
	prepare_op(loop, op, FsKind.FCHMOD, callback)!;
	op.request.file_mode = { .file = file, .mode = mode };
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async utime.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path whose access and modified timestamps will be changed"
 @param accessed : "Access timestamp"
 @param modified : "Modified timestamp"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? utime(
	nova::Loop* loop,
	Op* op,
	String path,
	Timestamp accessed,
	Timestamp modified,
	Callback callback,
	void* userdata = null
)
{
	if (!timestamp_valid(accessed) || !timestamp_valid(modified)) return nova::INVALID_STATE~;
	prepare_path_op(loop, op, FsKind.UTIME, path, callback)!;
	op.request.time.accessed = accessed;
	op.request.time.modified = modified;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async futime.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file whose access and modified timestamps will be changed"
 @param accessed : "Access timestamp"
 @param modified : "Modified timestamp"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? futime(
	nova::Loop* loop,
	Op* op,
	File file,
	Timestamp accessed,
	Timestamp modified,
	Callback callback,
	void* userdata = null
)
{
	if (!file.valid()) return nova::INVALID_STATE~;
	if (!timestamp_valid(accessed) || !timestamp_valid(modified)) return nova::INVALID_STATE~;
	prepare_op(loop, op, FsKind.FUTIME, callback)!;
	op.request.time.file = file;
	op.request.time.accessed = accessed;
	op.request.time.modified = modified;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async lutime.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path or symlink whose timestamps will be changed"
 @param accessed : "Access timestamp"
 @param modified : "Modified timestamp"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? lutime(
	nova::Loop* loop,
	Op* op,
	String path,
	Timestamp accessed,
	Timestamp modified,
	Callback callback,
	void* userdata = null
)
{
	if (!timestamp_valid(accessed) || !timestamp_valid(modified)) return nova::INVALID_STATE~;
	prepare_path_op(loop, op, FsKind.LUTIME, path, callback)!;
	op.request.time.accessed = accessed;
	op.request.time.modified = modified;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async hard link creation.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Existing path"
 @param new_path : "New hard link path"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, paths or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? link(nova::Loop* loop, Op* op, String path, String new_path, Callback callback, void* userdata = null)
{
	return queue_path2_op(loop, op, FsKind.LINK, path, new_path, callback, userdata);
}

<*
 Queue an async symbolic link creation.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param target : "Symlink target"
 @param path : "New symlink path"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, paths or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? symlink(nova::Loop* loop, Op* op, String target, String path, Callback callback, void* userdata = null)
{
	return queue_path2_op(loop, op, FsKind.SYMLINK, target, path, callback, userdata);
}

<*
 Queue an async chown.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path whose owner will be changed"
 @param uid : "POSIX user id"
 @param gid : "POSIX group id"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? chown(nova::Loop* loop, Op* op, String path, uint uid, uint gid, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.CHOWN, path, callback)!;
	op.request.chown.uid = uid;
	op.request.chown.gid = gid;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async fchown.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param file : "Open file whose owner will be changed"
 @param uid : "POSIX user id"
 @param gid : "POSIX group id"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, file or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? fchown(nova::Loop* loop, Op* op, File file, uint uid, uint gid, Callback callback, void* userdata = null)
{
	if (!file.valid()) return nova::INVALID_STATE~;
	prepare_op(loop, op, FsKind.FCHOWN, callback)!;
	op.request.chown.file = file;
	op.request.chown.uid = uid;
	op.request.chown.gid = gid;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async lchown.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Path or symlink whose owner will be changed"
 @param uid : "POSIX user id"
 @param gid : "POSIX group id"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? lchown(nova::Loop* loop, Op* op, String path, uint uid, uint gid, Callback callback, void* userdata = null)
{
	prepare_path_op(loop, op, FsKind.LCHOWN, path, callback)!;
	op.request.chown.uid = uid;
	op.request.chown.gid = gid;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async file copy.

 Source and destination paths are copied before the operation is submitted.
 `Result.bytes` reports how many bytes were copied. When `options.exclusive`
 is true, an existing destination fails with `io::ALREADY_EXISTS`.
 If the operation creates the destination and then fails after opening it,
 it attempts to remove that newly-created destination. A destination that
 existed before the call is left in place on failure, but its contents may
 have been truncated or partially overwritten.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param path : "Source file path"
 @param new_path : "Destination file path"
 @param options : "Copy behavior"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, paths or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? copyfile(
	nova::Loop* loop,
	Op* op,
	String path,
	String new_path,
	CopyFileOptions options,
	Callback callback,
	void* userdata = null
)
{
	if (!path.len || !new_path.len) return nova::INVALID_STATE~;
	prepare_op(loop, op, FsKind.COPYFILE, callback)!;
	op.request.copyfile.path = copy_path(op, path)!;
	if (catch err = copyfile_new_path(op, new_path))
	{
		fs_cleanup(op);
		return err~;
	}
	op.request.copyfile.options = options;
	return queue_fs(loop, op, userdata);
}

<*
 Queue an async file-to-file transfer.

 `out_file` is written at its current native file offset. `in_offset` can be an
 absolute source offset or `CURRENT_OFFSET`. `Result.bytes` reports how many
 bytes were transferred, which can be lower than `length` on EOF.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param out_file : "Open output file to write to"
 @param in_file : "Open input file to read from"
 @param in_offset : "Absolute source offset or `CURRENT_OFFSET`"
 @param length : "Maximum number of bytes to transfer"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, files, offset or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? sendfile(
	nova::Loop* loop,
	Op* op,
	File out_file,
	File in_file,
	Offset in_offset,
	sz length,
	Callback callback,
	void* userdata = null
)
{
	if (!out_file.valid() || !in_file.valid() || in_offset < CURRENT_OFFSET || length < 0) return nova::INVALID_STATE~;
	prepare_op(loop, op, FsKind.SENDFILE, callback)!;
	op.request.sendfile = { .out_file = out_file, .in_file = in_file, .in_offset = in_offset, .length = length, };
	return queue_fs(loop, op, userdata);
}

<*
 Queue a filesystem operation that targets an open file.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param kind : "Filesystem operation kind"
 @param file : "Open file captured for the worker"
 @param offset : "Operation offset argument"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "File, loop, pool, operation or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? queue_file_op(
	nova::Loop* loop,
	Op* op,
	FsKind kind,
	File file,
	Offset offset,
	Callback callback,
	void* userdata
) @local
{
	if (!file.valid()) return nova::INVALID_STATE~;
	prepare_op(loop, op, kind, callback)!;
	op.request.file = { .file = file, .offset = offset };
	return queue_fs(loop, op, userdata);
}

<*
 Queue a filesystem operation that owns two paths.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param kind : "Filesystem operation kind"
 @param path : "First path copied into operation-owned storage"
 @param new_path : "Second path copied into operation-owned storage"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, paths or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? queue_path2_op(
	nova::Loop* loop,
	Op* op,
	FsKind kind,
	String path,
	String new_path,
	Callback callback,
	void* userdata
) @local
{
	if (!path.len || !new_path.len) return nova::INVALID_STATE~;
	prepare_op(loop, op, kind, callback)!;
	op.request.path2.path = copy_path(op, path)!;
	if (catch err = copy_second_path(op, new_path))
	{
		fs_cleanup(op);
		return err~;
	}
	return queue_fs(loop, op, userdata);
}

<*
 Queue a filesystem operation that reads a path into caller output storage.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param kind : "Filesystem operation kind"
 @param path : "Path copied into operation-owned storage"
 @param [out] out : "Borrowed caller output storage"
 @param callback : "Terminal callback on the loop owner thread"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Output, loop, pool, operation, path or callback state is invalid"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn op::Ref? queue_output_path_op(
	nova::Loop* loop,
	Op* op,
	FsKind kind,
	String path,
	char[] out,
	Callback callback,
	void* userdata
) @local
{
	if (!out.len) return nova::INVALID_STATE~;
	prepare_path_op(loop, op, kind, path, callback)!;
	op.request.output_path.out = out;
	return queue_fs(loop, op, userdata);
}

<*
 Prepare an operation whose request owns one path.

 @param loop : "Loop that will own the operation"
 @param op : "Initialized operation storage"
 @param kind : "Filesystem operation kind"
 @param path : "Path copied into operation-owned storage"
 @param callback : "Terminal callback"
 @return ? nova::INVALID_STATE : "Loop, pool, operation, path or callback state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn void? prepare_path_op(nova::Loop* loop, Op* op, FsKind kind, String path, Callback callback) @local
{
	if (!path.len) return nova::INVALID_STATE~;
	prepare_op(loop, op, kind, callback)!;
	op.request.path.path = copy_path(op, path)!;
}

<*
 Prepare common filesystem operation state before request-specific fields.

 @param loop : "Loop that will own the operation"
 @param op : "Initialized operation storage"
 @param kind : "Filesystem operation kind"
 @param callback : "Terminal callback"
 @return ? nova::INVALID_STATE : "Loop, pool, operation or callback state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
*>
fn void? prepare_op(nova::Loop* loop, Op* op, FsKind kind, Callback callback) @local
{
	if (!loop || !op || !callback) return nova::INVALID_STATE~;
	if (!op.initialized || op.work.active()) return nova::INVALID_STATE~;
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!loop.options.blocking_pool) return nova::INVALID_STATE~;

	op.kind = kind;
	op.result = { .kind = kind };
	op.callback = callback;
	op.allocator = loop.allocator;
	op.request = { };
}

<*
 Submit a prepared filesystem operation through the loop blocking pool.

 @param loop : "Loop with a blocking pool"
 @param op : "Prepared operation storage"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool or work callbacks are invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::BUSY : "Embedded work operation is already active"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
*>
fn op::Ref? queue_fs(nova::Loop* loop, Op* op, void* userdata) @local
{
	op::Ref? ref = work::queue(loop, &op.work, &fs_work, &fs_after, userdata);
	if (catch ref)
	{
		fs_cleanup(op);
		return ref;
	}
	return ref;
}

<*
 Execute the filesystem native operation on a worker thread.

 Any native failure is stored in `Result.error` and then rethrown so the
 generic worker completion path receives the same status.

 @param work : "Embedded worker operation whose storage is an `fs::Op`"
*>
fn void? fs_work(work::WorkOp* work) @local
{
	Op* op = (Op*)work;
	native_dispatch(op);
	if (op.result.error.status) return op.result.error.status~;
	return;
}

<*
 Finish filesystem work on the loop owner thread and invoke the user callback.

 This applies owner-thread state updates, snapshots the result, releases
 operation-owned request storage, and then calls user code.

 @param loop : "Loop dispatching completion"
 @param work : "Embedded worker operation whose storage is an `fs::Op`"
 @param status : "Worker status"
 @param userdata : "Opaque pointer delivered to callback"
*>
fn void fs_after(nova::Loop* loop, work::WorkOp* work, fault status, void* userdata) @local
{
	Op* op            = (Op*)work;
	Callback callback = op.callback;
	if (status) op.result.error.status = status;
	finish_dir(op, status);
	finish_close(op, status);
	Result result = op.result;
	if (kind_returns_owned_path(op.kind) && result.path.len)
	{
		@pool()
		{
			char[] callback_path = mem::temp_array(char, result.path.len);
			mem::copy(callback_path.ptr, result.path.ptr, result.path.len);
			result.path = callback_path;
			fs_cleanup(op);
			callback(loop, op, &result, userdata);
		};
		return;
	}
	fs_cleanup(op);
	callback(loop, op, &result, userdata);
}

<*
 Apply successful or failed close completion to caller file storage.

 @param op : "Completed close operation"
 @param status : "Worker status"
*>
fn void finish_close(Op* op, fault status) @local
{
	if (op.kind != FsKind.CLOSE) return;
	File* file = op.request.close.file;
	if (!file) return;
	if (!status && !op.result.error.status)
	{
		file.handle = (NativeHandle)-1;
		file.closing = false;
		file.open = false;
		return;
	}
	file.closing = false;
}

<*
 Apply read-directory or close-directory completion to caller directory storage.

 @param op : "Completed directory operation"
 @param status : "Worker status"
*>
fn void finish_dir(Op* op, fault status) @local
{
	if (op.kind != FsKind.READDIR && op.kind != FsKind.CLOSEDIR) return;
	Dir* dir = op.request.dir.dir;
	if (!dir) return;
	if (op.kind == FsKind.READDIR)
	{
		dir.busy = false;
		return;
	}
	if (!status && !op.result.error.status)
	{
		dir.open = false;
		dir.busy = false;
		dir.native = null;
		return;
	}
	dir.busy = false;
}

<*
 Copy a path into zero-terminated operation-owned storage.

 @param op : "Operation whose allocator owns the copy"
 @param path : "Path to copy"
 @return "Zero-terminated copied path"
 @return ? nova::INVALID_STATE : "Path is empty or length would overflow terminator allocation"
 @return ? mem::OUT_OF_MEMORY : "Path allocation failed"
*>
fn char*? copy_path(Op* op, String path) @local
{
	return copy_into_buffer(op.path_buf[..], path);
}

<*
 Copy and store the second path for two-path operations.

 @param op : "Operation owning the inline path storage"
 @param path : "Path to copy"
 @return ? nova::INVALID_STATE : "Path is empty or exceeds `FS_PATH_MAX`"
*>
fn void? copy_second_path(Op* op, String path) @local
{
	op.request.path2.new_path = copy_into_buffer(op.path2_buf[..], path)!;
}

<*
 Copy and store the destination path for copyfile.

 @param op : "Operation owning the inline path storage"
 @param path : "Path to copy"
 @return ? nova::INVALID_STATE : "Path is empty or exceeds `FS_PATH_MAX`"
*>
fn void? copyfile_new_path(Op* op, String path) @local
{
	op.request.copyfile.new_path = copy_into_buffer(op.path2_buf[..], path)!;
}

<*
 Copy a path into an operation-owned inline buffer as a NUL-terminated string.

 @param buffer : "Inline path buffer (`FS_PATH_MAX` bytes)"
 @param path : "Path to copy"
 @return "Pointer to the NUL-terminated copy inside `buffer`"
 @return ? nova::INVALID_STATE : "Path is empty or does not fit (`>= FS_PATH_MAX`)"
*>
fn char*? copy_into_buffer(char[] buffer, String path) @local
{
	if (path.len == 0 || path.len >= FS_PATH_MAX) return nova::INVALID_STATE~;
	mem::copy(buffer.ptr, path.ptr, path.len);
	buffer[path.len] = 0;
	return buffer.ptr;
}

<*
 Release operation-owned request storage and reset reusable fields.

 @param op : "Filesystem operation storage"
*>
fn void fs_cleanup(Op* op) @local
{
	bool initialized = op.initialized;
	op.kind = FsKind.NONE;
	op.result = { };
	op.callback = null;
	op.allocator = { };
	op.request = { };
	op.initialized = initialized;
}

<*
 Report whether an operation returns a generated path from owned request memory.

 @param kind : "Filesystem operation kind"
 @return "True when callback delivery needs a temporary path snapshot"
*>
fn bool kind_returns_owned_path(FsKind kind) @local
{
	return kind == FsKind.MKDTEMP || kind == FsKind.MKSTEMP;
}
