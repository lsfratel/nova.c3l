module nova;

<*
 Semantic recoverable failures reported by synchronous setup APIs and async
 result structs.

 Cancellation, close and busy faults describe runtime state transitions.
 Socket, backend and network faults summarize platform errors into portable
 categories for user control flow.
*>
faultdef
	CANCELLED,
	CLOSED,
	BACKPRESSURE,
	BUSY,
	BUFFER_FULL,
	INVALID_STATE,
	NOT_OWNER,
	INVALID_SOCKET,
	UNSUPPORTED,
	BACKEND_FAILED,
	ADDRESS_IN_USE,
	CONNECTION_REFUSED,
	CONNECTION_RESET,
	CONNECTION_TIMED_OUT,
	NETWORK_UNREACHABLE,
	DNS_NOT_FOUND,
	DNS_TEMPORARY_FAILURE,
	DNS_FAILED;

<*
 Native diagnostic namespace captured at the syscall boundary.

 `NONE` means no native diagnostic was attached. `POSIX_ERRNO` stores an errno
 value, `WIN32_WSA` stores a Winsock error code, `GETADDRINFO` stores
 `getaddrinfo` or `getnameinfo` resolver status, and `BACKEND` is reserved
 for event backend diagnostics.
*>
enum ErrorDomain : char
{
	NONE,
	POSIX_ERRNO,
	WIN32_WSA,
	GETADDRINFO,
	BACKEND,
}

<*
 Platform-specific diagnostic code.

 Public control flow should use semantic faults, not this raw code.
 Interpret `code` using `domain`; `domain == NONE` means no platform diagnostic
 was attached.
*>
struct PlatformError
{
	ErrorDomain domain;
	int code;
}

<*
 Async operation status and optional platform diagnostic.

 `status == null` means success. Callback code should branch on `status`;
 `platform` is supplemental diagnostic storage and may remain zeroed.
*>
struct ErrorInfo
{
	fault status;
	PlatformError platform;
}

<*
 Common async close result.

 Close callbacks receive this status after the native handle has been closed or
 a close attempt has failed. `error.status == null` means the close completion
 reached the callback without a semantic or native close fault.
*>
struct CloseResult
{
	ErrorInfo error;
}
