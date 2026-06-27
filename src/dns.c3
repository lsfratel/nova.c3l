module nova::dns;

import std::net::os;

import nova @norecurse;
import nova::net;
import nova::op @public;
import nova::work;

<*
 Callback invoked on the loop owner thread after a forward DNS lookup finishes.

 The result pointer is valid only during the callback. The same operation
 storage is reusable from inside this callback.

 @param loop : "Loop dispatching the completion"
 @param op : "Forward DNS operation storage"
 @param result : "Forward DNS result valid only during this callback"
 @param userdata : "Opaque pointer provided at submission"
*>
alias ResolveCallback = fn void(nova::Loop* loop, ResolveOp* op, ResolveResult* result, void* userdata);

<*
 Callback invoked on the loop owner thread after a reverse DNS lookup finishes.

 The result pointer is valid only during the callback. The same operation
 storage is reusable from inside this callback.

 @param loop : "Loop dispatching the completion"
 @param op : "Reverse DNS operation storage"
 @param result : "Reverse DNS result valid only during this callback"
 @param userdata : "Opaque pointer provided at submission"
*>
alias ReverseCallback = fn void(nova::Loop* loop, ReverseOp* op, ReverseResult* result, void* userdata);

<*
 `getnameinfo` numeric-only flags used for reverse DNS formatting.
*>
const CInt NI_NUMERICHOST = env::DARWIN ? 0x2 : 0x1;
const CInt NI_NUMERICSERV = env::DARWIN ? 0x8 : 0x2;

<*
 Internal socket type markers copied into native `addrinfo.ai_socktype`.
*>
const char DNS_RESOLVE_TCP = 1;
const char DNS_RESOLVE_UDP = 2;

<*
 Inline capacity for the copied forward-lookup host and service strings, including
 the NUL terminator. A host fits RFC 1035's 253-octet presentation limit (plus
 slack); services are short names or numeric ports. Inputs longer than these are
 rejected, keeping `resolve` allocation-free at runtime.
*>
const sz DNS_HOST_MAX    = 256;
const sz DNS_SERVICE_MAX = 64;

<*
 Socket type filter for forward DNS lookups.

 `ANY` leaves `addrinfo.ai_socktype` unspecified, `TCP` requests stream
 sockets and `UDP` requests datagram sockets.
*>
constdef ResolveSocketType : inline char
{
	ANY = 0,
	TCP = 1,
	UDP = 2,
}

<*
 Resolve a native socket address into numeric host and service text.
*>
extern fn CInt getnameinfo(
	os::SockAddrPtr address,
	os::Socklen_t address_len,
	char* host,
	os::Socklen_t host_len,
	char* service,
	os::Socklen_t service_len,
	CInt flags
);

<*
 Forward DNS lookup options.

 `family == UNSPEC` allows both IPv4 and IPv6. `passive` requests addresses
 suitable for bind-style use, and `canonical_name` requests native canonical
 name resolution when the platform supports it.
*>
struct ResolveOptions
{
	net::AddressFamily family;
	ResolveSocketType socket_type;
	bool passive;
	bool canonical_name;
}

<*
 Caller-provided output buffers for forward DNS lookup results.

 `endpoints` must contain at least one slot. `canonical_name` is optional and
 is used only when `ResolveOptions.canonical_name` is true.
*>
struct ResolveBuffers
{
	net::Endpoint[] endpoints;
	char[] canonical_name;
}

<*
 Forward DNS lookup result delivered on the loop owner thread.

 `endpoints[0:count]` contains the endpoints written into the caller-provided
 output buffer. `canonical_name` is a slice into the caller-provided canonical
 name buffer when requested and available. `error.status == null` means all
 available endpoints and requested output text fit.
*>
struct ResolveResult
{
	nova::ErrorInfo error;
	net::Endpoint[] endpoints;
	char[] canonical_name;
	sz count;
}

<*
 Reverse DNS lookup options.

 `numeric_host` and `numeric_service` request numeric output from
 `getnameinfo`, avoiding name database lookups for those fields.
*>
struct ReverseOptions
{
	bool numeric_host;
	bool numeric_service;
}

<*
 Reverse DNS lookup result delivered on the loop owner thread.

 `host` and `service` are slices into the caller-provided buffers and remain
 valid only while those buffers remain valid.
*>
struct ReverseResult
{
	nova::ErrorInfo error;
	char[] host;
	char[] service;
}

<*
 Caller-owned forward DNS operation storage.

 Call `init` before the first submission and keep this storage pointer-stable
 until the terminal callback starts. The operation may be reused from inside
 its terminal callback. `work` must remain the first field because worker
 callbacks recover `ResolveOp*` from the embedded `WorkOp*`.
*>
struct ResolveOp
{
	work::WorkOp work;
	bool initialized;
	ResolveResult result;
	net::Endpoint[] out;
	ResolveOptions options;
	ResolveCallback callback;
	char* host_storage;
	char* service_storage;
	char[] canonical_out;
	char[DNS_HOST_MAX] host_buffer;
	char[DNS_SERVICE_MAX] service_buffer;
}

<*
 Caller-owned reverse DNS operation storage.

 Call `init` before the first submission and keep this storage pointer-stable
 until the terminal callback starts. The operation may be reused from inside
 its terminal callback. `work` must remain the first field because worker
 callbacks recover `ReverseOp*` from the embedded `WorkOp*`.
*>
struct ReverseOp
{
	work::WorkOp work;
	bool initialized;
	ReverseResult result;
	net::Endpoint endpoint;
	char[] host_out;
	char[] service_out;
	ReverseOptions options;
	ReverseCallback callback;
}

<*
 Native forward DNS result copied into caller-provided endpoint storage.

 `count` is the number of endpoint slots filled before success or
 `BUFFER_FULL`.
*>
struct NativeResolveResult
{
	nova::ErrorInfo error;
	char[] canonical_name;
	sz count;
}

<*
 Native reverse DNS result copied into caller-provided text buffers.

 `host` and `service` are slices into the caller-provided output buffers.
*>
struct NativeReverseResult
{
	nova::ErrorInfo error;
	char[] host;
	char[] service;
}

<*
 Initialize forward DNS operation storage.

 @param [&inout] self : "Forward DNS operation storage"
 @return "Initialized operation storage"
 @ensure self.initialized : "Operation storage is initialized after init"
*>
fn ResolveOp* ResolveOp.init(&self)
{
	*self = { };
	self.work.init();
	self.initialized = true;
	return self;
}

<*
 Destroy inactive forward DNS operation storage.

 @param [&inout] self : "Forward DNS operation storage"
 @require self.initialized : "Operation storage must be initialized"
 @require !self.work.active() : "Operation must not be active"
 @ensure !self.initialized : "Operation storage is uninitialized after destroy"
*>
fn void ResolveOp.destroy(&self)
{
	resolve_cleanup(self);
	self.work.destroy();
	*self = { };
}

<*
 Initialize reverse DNS operation storage.

 @param [&inout] self : "Reverse DNS operation storage"
 @return "Initialized operation storage"
 @ensure self.initialized : "Operation storage is initialized after init"
*>
fn ReverseOp* ReverseOp.init(&self)
{
	*self = { };
	self.work.init();
	self.initialized = true;
	return self;
}

<*
 Destroy inactive reverse DNS operation storage.

 @param [&inout] self : "Reverse DNS operation storage"
 @require self.initialized : "Operation storage must be initialized"
 @require !self.work.active() : "Operation must not be active"
 @ensure !self.initialized : "Operation storage is uninitialized after destroy"
*>
fn void ReverseOp.destroy(&self)
{
	reverse_cleanup(self);
	self.work.destroy();
	*self = { };
}

<*
 Queue a forward DNS lookup on the loop blocking pool.

 `host` is copied before queueing. `out` is borrowed until the terminal
 callback starts and must contain at least one endpoint slot.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param host : "Host name or numeric address to resolve"
 @param port : "Service port to resolve"
 @param out : "Caller-owned endpoint output storage"
 @param callback : "Terminal callback on the loop owner thread"
 @param options : "Resolver filters"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation or output state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::UNSUPPORTED : "Requested address family or socket type is unsupported"
 @return ? nova::BUSY : "Operation is already active"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
*>
fn op::Ref? resolve(
	nova::Loop* loop,
	ResolveOp* op,
	String host,
	ushort port,
	net::Endpoint[] out,
	ResolveCallback callback,
	ResolveOptions options = { },
	void* userdata = null
)
{
	char[6] service;
	sz service_len        = port_to_service(port, service[0:6]);
	String service_string = (String)service[0:service_len];
	return resolve_service(loop, op, host, service_string, { .endpoints = out }, callback, options, userdata);
}

<*
 Queue a forward DNS lookup using a service string.

 `host` and `service` are copied before queueing. `buffers.endpoints` and
 `buffers.canonical_name` are borrowed until the terminal callback starts.
 `buffers.endpoints` must contain at least one endpoint slot.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param host : "Host name or numeric address to resolve"
 @param service : "Numeric or named service to resolve"
 @param buffers : "Caller-owned endpoint and optional canonical name buffers"
 @param callback : "Terminal callback on the loop owner thread"
 @param options : "Resolver filters"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool, operation or output state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::UNSUPPORTED : "Requested address family or socket type is unsupported"
 @return ? nova::BUSY : "Operation is already active"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
*>
fn op::Ref? resolve_service(
	nova::Loop* loop,
	ResolveOp* op,
	String host,
	String service,
	ResolveBuffers buffers,
	ResolveCallback callback,
	ResolveOptions options = { },
	void* userdata = null
)
{
	if (!loop || !op || !callback) return nova::INVALID_STATE~;
	if (!op.initialized || op.work.active()) return nova::INVALID_STATE~;
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!loop.options.blocking_pool) return nova::INVALID_STATE~;
	if (!resolve_family_supported(options.family)) return nova::UNSUPPORTED~;
	if (!resolve_socket_type_supported(options.socket_type)) return nova::UNSUPPORTED~;
	if (buffers.endpoints.len == 0 || service.len == 0) return nova::INVALID_STATE~;

	op.result = { };
	op.result.endpoints = buffers.endpoints;
	op.out = buffers.endpoints;
	op.canonical_out = buffers.canonical_name;
	op.options = options;
	op.callback = callback;
	if (catch status = resolve_copy_input(op, host, service))
	{
		resolve_cleanup(op);
		return status~;
	}

	op::Ref? ref = work::queue(loop, &op.work, &resolve_work, &resolve_after, userdata);
	if (catch ref)
	{
		resolve_cleanup(op);
		return ref;
	}
	return ref;
}

<*
 Queue a reverse DNS lookup on the loop blocking pool.

 `host_out` and `service_out` are borrowed until the terminal callback starts.
 Too-small output buffers complete with `BUFFER_FULL`.

 @param loop : "Loop that dispatches completion"
 @param op : "Initialized caller-owned operation storage"
 @param endpoint : "Endpoint to reverse-resolve"
 @param host_out : "Caller-owned host output storage"
 @param service_out : "Caller-owned service output storage"
 @param callback : "Terminal callback on the loop owner thread"
 @param options : "Resolver output options"
 @param userdata : "Opaque pointer delivered to callback"
 @return "Operation reference for cancellation"
 @return ? nova::INVALID_STATE : "Loop, pool or operation state is invalid"
 @return ? nova::NOT_OWNER : "Current thread does not own the loop"
 @return ? nova::UNSUPPORTED : "Endpoint family is unsupported"
 @return ? nova::BUSY : "Operation is already active"
 @return ? nova::CLOSED : "Blocking pool is shutting down"
 @return ? nova::BACKPRESSURE : "Blocking pool queue capacity has been reached"
*>
fn op::Ref? reverse_lookup(
	nova::Loop* loop,
	ReverseOp* op,
	net::Endpoint endpoint,
	char[] host_out,
	char[] service_out,
	ReverseCallback callback,
	ReverseOptions options = { },
	void* userdata = null
)
{
	if (!loop || !op || !callback) return nova::INVALID_STATE~;
	if (!op.initialized || op.work.active()) return nova::INVALID_STATE~;
	if (!loop.initialized) return nova::INVALID_STATE~;
	if (!loop.is_owner_thread()) return nova::NOT_OWNER~;
	if (!loop.options.blocking_pool) return nova::INVALID_STATE~;
	if (!endpoint.is_ipv4() && !endpoint.is_ipv6()) return nova::UNSUPPORTED~;

	op.result = { };
	op.endpoint = endpoint;
	op.host_out = host_out;
	op.service_out = service_out;
	op.options = options;
	op.callback = callback;

	op::Ref? ref = work::queue(loop, &op.work, &reverse_work, &reverse_after, userdata);
	if (catch ref)
	{
		reverse_cleanup(op);
		return ref;
	}
	return ref;
}

<*
 Run forward DNS on a worker thread.

 @param work : "Embedded work operation"
 @return "Resolver status; non-null faults are delivered to after-work callback"
*>
fn void? resolve_work(work::WorkOp* work) @local
{
	ResolveOp* op = (ResolveOp*)work;
	ZString host  = (ZString)null;
	if (op.host_storage) host = (ZString)op.host_storage;
	ZString service = (ZString)null;
	if (op.service_storage) service = (ZString)op.service_storage;
	NativeResolveResult result = native_resolve(
		host,
		service,
		op.options.family,
		(char)op.options.socket_type,
		op.options.passive,
		op.options.canonical_name,
		op.out,
		op.canonical_out
	);
	op.result.error = result.error;
	op.result.endpoints = op.out;
	op.result.canonical_name = result.canonical_name;
	op.result.count = result.count;
	if (op.result.error.status) return op.result.error.status~;
	return;
}

<*
 Dispatch forward DNS completion on the loop owner thread.

 The result is copied before cleanup so callback-originated reuse cannot
 overwrite the result currently being delivered.

 @param loop : "Loop that owns the completion"
 @param work : "Embedded work operation"
 @param status : "Cancellation or worker status"
 @param userdata : "Opaque pointer forwarded to user callback"
*>
fn void resolve_after(nova::Loop* loop, work::WorkOp* work, fault status, void* userdata) @local
{
	ResolveOp* op = (ResolveOp*)work;
	if (status) op.result.error.status = status;
	ResolveCallback callback = op.callback;
	ResolveResult result     = op.result;
	resolve_cleanup(op);
	callback(loop, op, &result, userdata);
}

<*
 Run reverse DNS on a worker thread.

 @param work : "Embedded work operation"
 @return "Resolver status; non-null faults are delivered to after-work callback"
*>
fn void? reverse_work(work::WorkOp* work) @local
{
	ReverseOp* op = (ReverseOp*)work;
	NativeReverseResult result = native_reverse(
		op.endpoint,
		op.host_out,
		op.service_out,
		op.options.numeric_host,
		op.options.numeric_service
	);
	op.result.error = result.error;
	op.result.host = result.host;
	op.result.service = result.service;
	if (op.result.error.status) return op.result.error.status~;
	return;
}

<*
 Dispatch reverse DNS completion on the loop owner thread.

 The result is copied before cleanup so callback-originated reuse cannot
 overwrite the result currently being delivered.

 @param loop : "Loop that owns the completion"
 @param work : "Embedded work operation"
 @param status : "Cancellation or worker status"
 @param userdata : "Opaque pointer forwarded to user callback"
*>
fn void reverse_after(nova::Loop* loop, work::WorkOp* work, fault status, void* userdata) @local
{
	ReverseOp* op = (ReverseOp*)work;
	if (status) op.result.error.status = status;
	ReverseCallback callback = op.callback;
	ReverseResult result     = op.result;
	reverse_cleanup(op);
	callback(loop, op, &result, userdata);
}

<*
 Validate supported forward DNS address families.

 @param family : "Requested address family filter"
 @return "True when the resolver can submit this family"
*>
fn bool resolve_family_supported(net::AddressFamily family) @local
{
	return family == net::AddressFamily.UNSPEC || family == net::AddressFamily.IPV4
		|| family == net::AddressFamily.IPV6;
}

<*
 Validate supported forward DNS socket filters.

 @param socket_type : "Requested socket type filter"
 @return "True when the resolver can submit this socket type"
*>
fn bool resolve_socket_type_supported(ResolveSocketType socket_type) @local
{
	return socket_type == ResolveSocketType.ANY || socket_type == ResolveSocketType.TCP
		|| socket_type == ResolveSocketType.UDP;
}

<*
 Copy the host and service strings into the operation's inline NUL-terminated
 buffers, keeping forward lookups allocation-free.

 `host_storage`/`service_storage` point into `host_buffer`/`service_buffer`. The
 host may be empty (numeric/passive lookups); the service is required. Inputs that
 do not fit the inline buffers are rejected — a valid hostname never exceeds them.

 @param op : "Forward DNS operation storage"
 @param host : "Host string to copy, may be empty"
 @param service : "Service string to copy, must be non-empty"
 @return ? nova::INVALID_STATE : "Service is empty, or host/service exceeds the inline buffer"
*>
fn void? resolve_copy_input(ResolveOp* op, String host, String service) @local
{
	if (service.len == 0 || service.len >= DNS_SERVICE_MAX) return nova::INVALID_STATE~;
	if (host.len >= DNS_HOST_MAX) return nova::INVALID_STATE~;
	if (host.len)
	{
		mem::copy(&op.host_buffer[0], host.ptr, host.len);
		op.host_buffer[host.len] = 0;
		op.host_storage = &op.host_buffer[0];
	}
	mem::copy(&op.service_buffer[0], service.ptr, service.len);
	op.service_buffer[service.len] = 0;
	op.service_storage = &op.service_buffer[0];
}

<*
 Clear forward DNS submission fields while preserving initialized state.

 @param op : "Forward DNS operation storage"
*>
fn void resolve_cleanup(ResolveOp* op) @local
{
	bool initialized = op.initialized;
	op.host_storage = null;
	op.service_storage = null;
	op.out = { };
	op.canonical_out = { };
	op.options = { };
	op.callback = null;
	op.initialized = initialized;
}

<*
 Clear reverse DNS submission fields while preserving initialized state.

 @param op : "Reverse DNS operation storage"
*>
fn void reverse_cleanup(ReverseOp* op) @local
{
	bool initialized = op.initialized;
	op.endpoint = { };
	op.host_out = { };
	op.service_out = { };
	op.options = { };
	op.callback = null;
	op.initialized = initialized;
}

<*
 Format a TCP/UDP port into a zero-terminated decimal service buffer.

 @param port : "Port in host byte order"
 @param out : "Output buffer with at least six bytes"
 @return "Number of decimal digits written, excluding the terminator"
 @require out.len >= 6 : "Service buffer must hold 65535 plus terminator"
*>
fn sz port_to_service(ushort port, char[] out) @local
{
	uint value = port;
	char[5] digits;
	sz count   = 0;
	do
	{
		digits[count] = (char)((uint)'0' + value % 10);
		value /= 10;
		count++;
	} while (value != 0);
	for (sz i = 0; i < count; i++)
	{
		out[i] = digits[count - i - 1];
	}
	out[count] = 0;
	return count;
}

<*
 Resolve a host/service pair with POSIX `getaddrinfo`.

 @param host : "Zero-terminated host string or null for passive lookups"
 @param service : "Zero-terminated decimal service string"
 @param family : "Address family filter"
 @param socket_type : "Socket type filter"
 @param passive : "Whether to request passive addresses"
 @param canonical_name : "Whether to request native canonical name resolution"
 @param out : "Endpoint output storage"
 @param canonical_out : "Optional canonical name output storage"
 @return "Native resolver result copied into `out`"
*>
fn NativeResolveResult native_resolve(
	ZString host,
	ZString service,
	net::AddressFamily family,
	char socket_type,
	bool passive,
	bool canonical_name,
	net::Endpoint[] out,
	char[] canonical_out
) @local
{
	NativeResolveResult result;
	os::AddrInfo hints;
	hints.ai_family = native_dns_family(family);
	hints.ai_socktype = native_dns_socktype(socket_type);
	if (passive) hints.ai_flags |= os::AI_PASSIVE;
	if (canonical_name) hints.ai_flags |= os::AI_CANONNAME;

	os::AddrInfo* infos = null;
	CInt status         = os::getaddrinfo(host, service, &hints, &infos);
	if (status != 0)
	{
		result.error = native_dns_error_info(status);
		return result;
	}
	defer os::freeaddrinfo(infos);

	os::AddrInfo* current = infos;
	while (current)
	{
		if (try endpoint = net::native_endpoint_from_sockaddr(current.ai_addr, current.ai_addrlen))
		{
			if (result.count >= out.len)
			{
				result.error.status = nova::BUFFER_FULL;
				return result;
			}
			out[result.count] = endpoint;
			result.count++;
		}
		current = current.ai_next;
	}

	if (canonical_name)
	{
		copy_native_canonical_name(&result, infos, canonical_out);
	}

	if (result.count == 0) result.error.status = nova::DNS_NOT_FOUND;
	return result;
}

<*
 Copy the first native canonical name into caller-provided storage.

 @param result : "Native resolve result to update"
 @param infos : "First native addrinfo result"
 @param out : "Caller-provided canonical name buffer"
 @require result != null : "Result pointer must not be null"
*>
fn void copy_native_canonical_name(NativeResolveResult* result, os::AddrInfo* infos, char[] out) @local
{
	if (!out.len) return;
	os::AddrInfo* current = infos;
	while (current)
	{
		if (current.ai_canonname)
		{
			ZString native_name = current.ai_canonname;
			sz len              = native_name.len();
			if (len == 0) return;
			if (len > out.len)
			{
				result.error.status = nova::BUFFER_FULL;
				return;
			}
			mem::copy(out.ptr, native_name, len);
			result.canonical_name = out[0:len];
			return;
		}
		current = current.ai_next;
	}
}

<*
 Resolve a numeric or named host/service pair with POSIX `getnameinfo`.

 @param endpoint : "Endpoint to reverse-resolve"
 @param host_out : "Host output buffer"
 @param service_out : "Service output buffer"
 @param numeric_host : "Whether to request numeric host output"
 @param numeric_service : "Whether to request numeric service output"
 @return "Native reverse lookup result copied into caller buffers"
*>
fn NativeReverseResult native_reverse(
	net::Endpoint endpoint,
	char[] host_out,
	char[] service_out,
	bool numeric_host,
	bool numeric_service
) @local
{
	NativeReverseResult result;
	if (host_out.len == 0 || service_out.len == 0)
	{
		result.error.status = nova::BUFFER_FULL;
		return result;
	}

	net::SockAddrAny address;
	os::Socklen_t address_len = 0;
	if (catch err = net::native_sockaddr_from_endpoint(endpoint, &address, &address_len))
	{
		result.error.status = err;
		return result;
	}

	CInt flags = 0;
	if (numeric_host) flags |= NI_NUMERICHOST;
	if (numeric_service) flags |= NI_NUMERICSERV;
	CInt status = getnameinfo(
		(os::SockAddrPtr)&address,
		address_len,
		host_out.ptr,
		(os::Socklen_t)host_out.len,
		service_out.ptr,
		(os::Socklen_t)service_out.len,
		flags
	);
	if (status != 0)
	{
		result.error = native_dns_error_info(status);
		return result;
	}

	result.host = host_out[0:((ZString)host_out.ptr).len()];
	result.service = service_out[0:((ZString)service_out.ptr).len()];
	return result;
}

<*
 Convert public address family filters into native resolver families.

 @param family : "Public DNS address family filter"
 @return "Native addrinfo family"
*>
fn os::AIFamily native_dns_family(net::AddressFamily family) @local
{
	switch (family)
	{
		case net::AddressFamily.IPV4: return os::AF_INET;
		case net::AddressFamily.IPV6: return os::AF_INET6;
		default: return os::AF_UNSPEC;
	}
}

<*
 Convert public socket type filters into native resolver socktypes.

 @param socket_type : "Public DNS socket type filter"
 @return "Native addrinfo socket type"
*>
fn os::AISockType native_dns_socktype(char socket_type) @local
{
	switch (socket_type)
	{
		case DNS_RESOLVE_TCP: return os::SOCK_STREAM;
		case DNS_RESOLVE_UDP: return os::SOCK_DGRAM;
		default: return (os::AISockType)0;
	}
}

<*
 Convert native resolver status into portable semantic error information.

 @param status : "Native resolver status code"
 @return "Portable semantic fault plus native diagnostic code"
*>
fn nova::ErrorInfo native_dns_error_info(CInt status) @local
{
	nova::ErrorInfo error;
	error.status = native_dns_fault_from_status(status);
	error.platform.domain = nova::ErrorDomain.GETADDRINFO;
	error.platform.code = status;
	return error;
}

<*
 Map POSIX resolver status values into public nova faults.

 @param status : "Native resolver status code"
 @return "Portable semantic DNS fault"
*>
fn fault native_dns_fault_from_status(CInt status) @local
{
	if (status == EAI_NONAME || status == EAI_NODATA || status == EAI_ADDRFAMILY) return nova::DNS_NOT_FOUND;
	if (status == EAI_AGAIN) return nova::DNS_TEMPORARY_FAILURE;
	if (status == EAI_MEMORY) return mem::OUT_OF_MEMORY;
	if (status == EAI_OVERFLOW) return nova::BUFFER_FULL;
	if (status == EAI_FAMILY || status == EAI_SOCKTYPE || status == EAI_SERVICE) return nova::UNSUPPORTED;
	return nova::DNS_FAILED;
}

module nova::dns @if(env::LINUX);

<*
 Linux `getaddrinfo` status values normalized into nova DNS faults.
*>
const CInt EAI_NONAME     = -2;
const CInt EAI_AGAIN      = -3;
const CInt EAI_NODATA     = -5;
const CInt EAI_FAMILY     = -6;
const CInt EAI_SOCKTYPE   = -7;
const CInt EAI_SERVICE    = -8;
const CInt EAI_ADDRFAMILY = -9;
const CInt EAI_MEMORY     = -10;
const CInt EAI_OVERFLOW   = -12;

module nova::dns @if(env::DARWIN);

<*
 macOS `getaddrinfo` status values normalized into nova DNS faults.
*>
const CInt EAI_ADDRFAMILY = 1;
const CInt EAI_AGAIN      = 2;
const CInt EAI_FAMILY     = 5;
const CInt EAI_MEMORY     = 6;
const CInt EAI_NODATA     = 7;
const CInt EAI_NONAME     = 8;
const CInt EAI_SERVICE    = 9;
const CInt EAI_SOCKTYPE   = 10;
const CInt EAI_OVERFLOW   = 14;
