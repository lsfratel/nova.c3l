<*
 Forward and reverse DNS resolution built on `nova::dns`.

 Demonstrates how nova performs blocking name resolution off the event loop: a
 `work::Pool` is wired into the loop as its `blocking_pool`, then `dns::resolve`
 (host:port -> endpoints) and `dns::reverse_lookup` (endpoint -> host/service)
 run on worker threads and report back through loop callbacks. The `-r/--reverse`
 path chains both operations: it first resolves the target, then reverse-resolves
 the first endpoint.
*>
module nova_examples::dns_example;

import std::io;

import nova @norecurse, nova::dns, nova::net, nova::work;
import nova_examples::common;

const String DEFAULT_HOST         = "localhost";
const ushort DEFAULT_PORT         = 80;
const sz DEFAULT_WORKERS          = 4;
const sz RESULT_CAPACITY          = 32;
const sz REVERSE_HOST_CAPACITY    = 1025;
const sz REVERSE_SERVICE_CAPACITY = 32;
const String REVERSE_PREFIX       = "--reverse=";

struct Config
{
	String host;
	ushort port;
	bool reverse;
	String reverse_host;
	ushort reverse_port;
}

struct ReverseTarget
{
	String host;
	ushort port;
}

struct App
{
	dns::ResolveOp resolve_op;
	dns::ReverseOp reverse_op;
	net::Endpoint[RESULT_CAPACITY] endpoints;
	char[REVERSE_HOST_CAPACITY] reverse_host_buffer;
	char[REVERSE_SERVICE_CAPACITY] reverse_service_buffer;
	fault status;
}

fn int main(String[] args)
{
	String program = args.len ? args[0] : "dns";
	Config config  = { .host = DEFAULT_HOST, .port = DEFAULT_PORT };
	if (catch parse_config(args, &config))
	{
		print_usage(program);
		return 2;
	}

	if (catch err = run_dns(config))
	{
		(void)io::eprintfn("dns failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void print_usage(String program)
{
	(void)io::printfn("usage: %s [host] [port]", program);
	(void)io::printfn("example: %s localhost 80", program);
	(void)io::printfn("reverse: %s --reverse=127.0.0.1:80", program);
	(void)io::printfn("reverse IPv6: %s --reverse=[::1]:80", program);
}

fn void? parse_config(String[] args, Config* config)
{
	sz positional = 0;
	for (sz i = 1; i < args.len; i++)
	{
		String arg = args[i];
		if (arg == "-r" || arg == "--reverse")
		{
			if (i + 1 >= args.len)
			{
				(void)io::eprintfn("missing value for %s", arg);
				return nova::INVALID_STATE~;
			}
			i++;
			set_reverse(config, args[i])!;
			continue;
		}
		if (arg.starts_with(REVERSE_PREFIX))
		{
			set_reverse(config, arg[REVERSE_PREFIX.len..])!;
			continue;
		}
		switch (positional++)
		{
			case 0: config.host = arg;
			case 1: config.port = parse_port(arg)!;
			default:
				(void)io::eprintfn("unexpected argument: %s", arg);
				return nova::INVALID_STATE~;
		}
	}
}

fn void? set_reverse(Config* config, String value)
{
	ReverseTarget target = parse_reverse_target(value)!;
	config.reverse = true;
	config.reverse_host = target.host;
	config.reverse_port = target.port;
}

fn ushort? parse_port(String value)
{
	ushort? parsed = value.to_ushort();
	if (catch parsed)
	{
		(void)io::eprintfn("invalid port: %s", value);
		return nova::INVALID_STATE~;
	}
	return parsed;
}

fn ReverseTarget? parse_reverse_target(String value)
{
	if (!value.len)
	{
		(void)io::eprintfn("invalid reverse target: %s", value);
		return nova::INVALID_STATE~;
	}

	if (value[0] == '[')
	{
		ReverseTarget target = parse_bracketed_reverse_target(value)!;
		return target;
	}

	if (count_char(value, ':') != 1)
	{
		(void)io::eprintfn("invalid reverse target: %s (use host:port or [ipv6]:port)", value);
		return nova::INVALID_STATE~;
	}

	sz colon = last_colon(value)!;
	return reverse_target_from_parts(value[0:colon], value[colon + 1..]);
}

fn ReverseTarget? parse_bracketed_reverse_target(String value)
{
	sz? close = value.index_of_char(']');
	if (catch close)
	{
		(void)io::eprintfn("invalid reverse target: %s", value);
		return nova::INVALID_STATE~;
	}
	if (close <= 1 || close + 1 >= value.len || value[close + 1] != ':')
	{
		(void)io::eprintfn("invalid reverse target: %s", value);
		return nova::INVALID_STATE~;
	}
	return reverse_target_from_parts(value[1:close - 1], value[close + 2..]);
}

fn ReverseTarget? reverse_target_from_parts(String host, String port_text)
{
	if (!host.len || !port_text.len)
	{
		(void)io::eprintfn("invalid reverse target");
		return nova::INVALID_STATE~;
	}
	return { .host = host, .port = parse_port(port_text)! };
}

fn int count_char(String value, char needle)
{
	int count;
	for (sz i = 0; i < value.len; i++)
	{
		if (value[i] == needle) count++;
	}
	return count;
}

fn sz? last_colon(String value)
{
	for (sz i = value.len; i > 0; i--)
	{
		sz index = i - 1;
		if (value[index] == ':') return index;
	}
	return NOT_FOUND~;
}

fn void? run_dns(Config config)
{
	work::Pool pool;
	Loop loop;
	App app;

	// The resolver blocks, so it runs on a worker pool; wiring the pool in as the
	// loop's blocking_pool lets dns::resolve offload work and resume via callbacks.
	pool.init({ .workers = DEFAULT_WORKERS, .queue_capacity = 8 })!;
	defer pool.destroy();
	common::init_loop(&loop, { .blocking_pool = &pool })!;
	defer loop.destroy();

	app.resolve_op.init();
	defer app.resolve_op.destroy();
	app.reverse_op.init();
	defer app.reverse_op.destroy();

	dns::ResolveOptions options = { .family = net::AddressFamily.UNSPEC, .socket_type = dns::ResolveSocketType.ANY };
	if (config.reverse)
	{
		(void)io::printfn("reverse resolving %s:%d", config.reverse_host, config.reverse_port);
		dns::resolve(
			&loop,
			&app.resolve_op,
			config.reverse_host,
			config.reverse_port,
			app.endpoints[0:RESULT_CAPACITY],
			&on_reverse_resolve,
			options,
			&app
		)!;
	}
	else
	{
		(void)io::printfn("resolving %s:%d", config.host, config.port);
		dns::resolve(
			&loop,
			&app.resolve_op,
			config.host,
			config.port,
			app.endpoints[0:RESULT_CAPACITY],
			&on_resolve,
			options,
			&app
		)!;
	}

	nova::run(&loop, RunMode.UNTIL_STOPPED)!;
	if (app.status) return app.status~;
}

fn void on_resolve(Loop* loop, dns::ResolveOp* op, dns::ResolveResult* result, void* userdata)
{
	(void)op;
	App* app = (App*)userdata;
	if (result.error.status && result.error.status != nova::BUFFER_FULL)
	{
		print_error_info("resolve", result.error);
		app.status = result.error.status;
		loop.stop();
		return;
	}
	// BUFFER_FULL is non-fatal: there were more endpoints than RESULT_CAPACITY, so
	// the buffer holds a truncated-but-usable result.
	if (result.error.status == nova::BUFFER_FULL) print_error_info("resolve", result.error);
	(void)io::printfn("resolved %d endpoint(s)", result.count);
	for (sz i = 0; i < result.count; i++) print_endpoint(result.endpoints[i]);
	loop.stop();
}

fn void on_reverse_resolve(Loop* loop, dns::ResolveOp* op, dns::ResolveResult* result, void* userdata)
{
	(void)op;
	App* app = (App*)userdata;
	if (result.error.status && result.error.status != nova::BUFFER_FULL)
	{
		print_error_info("resolve", result.error);
		app.status = result.error.status;
		loop.stop();
		return;
	}
	if (result.count == 0)
	{
		app.status = nova::DNS_NOT_FOUND;
		loop.stop();
		return;
	}

	// Reverse path: take the first resolved endpoint and chain a reverse lookup
	// that maps it back to a host/service name.
	net::Endpoint endpoint = result.endpoints[0];
	(void)io::printn("selected endpoint:");
	print_endpoint(endpoint);
	if (catch err = dns::reverse_lookup(
		loop,
		&app.reverse_op,
		endpoint,
		app.reverse_host_buffer[0:REVERSE_HOST_CAPACITY],
		app.reverse_service_buffer[0:REVERSE_SERVICE_CAPACITY],
		&on_reverse,
		{ .numeric_host = true, .numeric_service = true },
		app
	))
	{
		app.status = err;
		loop.stop();
	}
}

fn void on_reverse(Loop* loop, dns::ReverseOp* op, dns::ReverseResult* result, void* userdata)
{
	(void)op;
	App* app = (App*)userdata;
	if (result.error.status)
	{
		print_error_info("reverse", result.error);
		app.status = result.error.status;
		loop.stop();
		return;
	}
	String host    = (String)result.host;
	String service = (String)result.service;
	(void)io::printfn("reverse result: %s:%s", host, service);
	loop.stop();
}

fn void print_endpoint(net::Endpoint endpoint)
{
	if (endpoint.family == net::AddressFamily.IPV4)
	{
		(void)io::printfn(
			"  %d.%d.%d.%d:%d",
			byte_value(endpoint.storage[0]),
			byte_value(endpoint.storage[1]),
			byte_value(endpoint.storage[2]),
			byte_value(endpoint.storage[3]),
			endpoint.port
		);
		return;
	}
	if (endpoint.family == net::AddressFamily.IPV6)
	{
		(void)io::printfn(
			"  [%x:%x:%x:%x:%x:%x:%x:%x]:%d",
			ipv6_group(endpoint, 0),
			ipv6_group(endpoint, 1),
			ipv6_group(endpoint, 2),
			ipv6_group(endpoint, 3),
			ipv6_group(endpoint, 4),
			ipv6_group(endpoint, 5),
			ipv6_group(endpoint, 6),
			ipv6_group(endpoint, 7),
			endpoint.port
		);
		return;
	}
	(void)io::printfn("  <unsupported family %d>:%d", endpoint.family, endpoint.port);
}

fn uint ipv6_group(net::Endpoint endpoint, sz group)
{
	sz offset = group * 2;
	return (byte_value(endpoint.storage[offset]) << 8) | byte_value(endpoint.storage[offset + 1]);
}

fn uint byte_value(char value)
{
	return ((uint)value) & 0xff;
}

fn void print_error_info(String label, ErrorInfo error)
{
	if (!error.status) return;
	if (error.platform.domain == ErrorDomain.NONE)
	{
		(void)io::eprintfn("%s failed: %s", label, error.status.description);
		return;
	}
	(void)io::eprintfn(
		"%s failed: %s (domain=%d code=%d)",
		label,
		error.status.description,
		error.platform.domain,
		error.platform.code
	);
}
