<*
 Shared helpers for the example programs.

 Centralizes the bits every example repeats:
  - `backend_from_env` / `init_loop`: pick the event-loop backend from the
    `NOVA_BACKEND` environment variable, so the same binary can be A/B'd across
    backends without rebuilding.
  - the canned HTTP "hello world" responses, read-buffer size, CLI connection-mode
    selection and IPv4 wildcard endpoint used by the `http*` examples.
*>
module nova_examples::common;

import std::core::mem;
import std::os::env;

import nova @norecurse, nova::net;

const sz READ_BUFFER_SIZE = 1024;

const String RESPONSE_KEEP_ALIVE = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: keep-alive\r\n\r\nhello world";
const String RESPONSE_CLOSE      = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world";

<*
 Select the event-loop backend from the `NOVA_BACKEND` env var ("epoll" or
 "io_uring"), defaulting to `AUTO` (io_uring when the kernel supports it, else
 epoll; `kqueue` on macOS).
*>
fn nova::BackendKind backend_from_env()
{
	// Spawned threads (e.g. the http_multithread workers) get no implicit temp
	// allocator, and env reads use one. Scope a temp allocator here so init_loop
	// works on any thread, not just the main thread.
	@pool_init(mem, 64 * 1024)
	{
		if (try value = env::tget_var("NOVA_BACKEND"))
		{
			if (!value.compare_to("epoll")) return nova::BACKEND_EPOLL;
			if (!value.compare_to("io_uring")) return nova::BACKEND_IO_URING;
		}
	};
	return nova::BACKEND_AUTO;
}

<*
 Initialize `loop` with `options`, forcing the backend to the `NOVA_BACKEND`
 selection so every example honours the env var without each one wiring it up.
*>
fn Loop*? init_loop(Loop* loop, Options options = { })
{
	options.backend = backend_from_env();
	return loop.init(options);
}

<*
 Select close (`true`) vs keep-alive (`false`) for the HTTP examples from the
 `NOVA_HTTP_CONNECTION` env var ("close" or "keep-alive"), defaulting to keep-alive.
*>
fn bool close_after_response()
{
	@pool_init(mem, 64 * 1024)
	{
		if (try value = env::tget_var("NOVA_HTTP_CONNECTION"))
		{
			if (!value.compare_to("close")) return true;
		}
	};
	return false;
}

<*
 Build an IPv4 wildcard (`0.0.0.0`) endpoint bound to `port`.
*>
fn Endpoint ipv4_any_endpoint(ushort port)
{
	return { .family = AddressFamily.IPV4, .port = port };
}
