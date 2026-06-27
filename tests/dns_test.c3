module nova_tests;

import std::core::test;
import std::core::mem::allocators;
import std::thread;

import nova @norecurse, nova::dns, nova::net, nova::work;
import nova::op @public;

struct DnsResolveSeen
{
	int calls;
	fault status;
	sz count;
	bool owner_thread;
	bool op_active;
	net::Endpoint[] endpoints;
	char[] canonical_name;
}

struct DnsReverseSeen
{
	int calls;
	fault status;
	bool owner_thread;
	bool op_active;
	char[] host;
	char[] service;
}

struct DnsCancelCtx
{
	int blocker_calls;
	int after_calls;
	int dns_calls;
	fault dns_status;
	sz resolve_endpoint_capacity;
}

struct DnsResolveReuseCtx
{
	int calls;
	fault status;
	sz first_count_after_resubmit;
	net::Endpoint[4] endpoints;
}

struct DnsReverseReuseCtx
{
	int calls;
	fault status;
	bool first_result_survived_resubmit;
	char[64] host;
	char[16] service;
	net::Endpoint endpoint;
}

struct DnsReverseBufferCtx
{
	int calls;
	int buffer_full_calls;
}

fn void on_resolve_seen(Loop* loop, dns::ResolveOp* op, dns::ResolveResult* result, void* userdata)
{
	DnsResolveSeen* seen = (DnsResolveSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.count = result.count;
	seen.owner_thread = loop.is_owner_thread();
	seen.op_active = op.work.header.active();
	seen.endpoints = result.endpoints;
	seen.canonical_name = result.canonical_name;
	loop.stop();
}

fn void on_reverse_seen(Loop* loop, dns::ReverseOp* op, dns::ReverseResult* result, void* userdata)
{
	DnsReverseSeen* seen = (DnsReverseSeen*)userdata;
	seen.calls++;
	seen.status = result.error.status;
	seen.owner_thread = loop.is_owner_thread();
	seen.op_active = op.work.header.active();
	seen.host = result.host;
	seen.service = result.service;
	loop.stop();
}

fn void? dns_blocker_work(WorkOp* op)
{
	DnsCancelCtx* ctx = (DnsCancelCtx*)op.header.userdata;
	ctx.blocker_calls++;
	thread::sleep_ms(80);
}

fn void after_dns_cancel_blocker(Loop* loop, WorkOp* op, fault status, void* userdata)
{
	(void)op;
	(void)status;
	DnsCancelCtx* ctx = (DnsCancelCtx*)userdata;
	ctx.after_calls++;
	if (ctx.after_calls == 2) loop.stop();
}

fn void on_resolve_cancelled(Loop* loop, dns::ResolveOp* op, dns::ResolveResult* result, void* userdata)
{
	(void)op;
	DnsCancelCtx* ctx = (DnsCancelCtx*)userdata;
	ctx.after_calls++;
	ctx.dns_calls++;
	ctx.dns_status = result.error.status;
	ctx.resolve_endpoint_capacity = result.endpoints.len;
	if (ctx.after_calls == 2) loop.stop();
}

fn void on_reverse_cancelled(Loop* loop, dns::ReverseOp* op, dns::ReverseResult* result, void* userdata)
{
	(void)op;
	DnsCancelCtx* ctx = (DnsCancelCtx*)userdata;
	ctx.after_calls++;
	ctx.dns_calls++;
	ctx.dns_status = result.error.status;
	if (ctx.after_calls == 2) loop.stop();
}

fn void on_resolve_reuse(Loop* loop, dns::ResolveOp* op, dns::ResolveResult* result, void* userdata)
{
	DnsResolveReuseCtx* ctx = (DnsResolveReuseCtx*)userdata;
	ctx.calls++;
	ctx.status = result.error.status;
	if (ctx.calls == 1)
	{
		dns::resolve(
			loop,
			op,
			"::1",
			80,
			ctx.endpoints[0:4],
			&on_resolve_reuse,
			{ .family = net::AddressFamily.IPV6, .socket_type = dns::ResolveSocketType.TCP },
			ctx
		)!!;
		ctx.first_count_after_resubmit = result.count;
		return;
	}
	loop.stop();
}

fn void on_reverse_reuse(Loop* loop, dns::ReverseOp* op, dns::ReverseResult* result, void* userdata)
{
	DnsReverseReuseCtx* ctx = (DnsReverseReuseCtx*)userdata;
	ctx.calls++;
	ctx.status = result.error.status;
	if (ctx.calls == 1)
	{
		dns::reverse_lookup(
			loop,
			op,
			ctx.endpoint,
			ctx.host[0:64],
			ctx.service[0:16],
			&on_reverse_reuse,
			{ .numeric_host = true, .numeric_service = true },
			ctx
		)!!;
		ctx.first_result_survived_resubmit = string_equals(
			"127.0.0.1",
			result.host
		) && string_equals("80", result.service);
		return;
	}
	loop.stop();
}

fn void on_reverse_buffer_full(Loop* loop, dns::ReverseOp* op, dns::ReverseResult* result, void* userdata)
{
	(void)op;
	DnsReverseBufferCtx* ctx = (DnsReverseBufferCtx*)userdata;
	ctx.calls++;
	if (result.error.status == nova::BUFFER_FULL) ctx.buffer_full_calls++;
	if (ctx.calls == 2) loop.stop();
}

fn bool string_equals(String expected, char[] actual)
{
	return expected.len == actual.len && mem::equals(expected.ptr, actual.ptr, expected.len);
}

fn void test_dns_resolve_numeric_ipv4() @test
{
	work::Pool pool;
	Loop loop;
	dns::ResolveOp op;
	net::Endpoint[4] results;
	DnsResolveSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::resolve(
		&loop,
		&op,
		"127.0.0.1",
		80,
		results[0:4],
		&on_resolve_seen,
		{ .family = net::AddressFamily.IPV4, .socket_type = dns::ResolveSocketType.TCP },
		&seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.count >= 1);
	test::@check(seen.owner_thread);
	test::@check(!seen.op_active);
	test::eq(net::AddressFamily.IPV4, results[0].family);
	test::eq((ushort)80, results[0].port);
	test::eq((char)127, results[0].storage[0]);
	test::eq((char)1, results[0].storage[3]);

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_resolve_numeric_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();
	Allocator allocator = &tracker;

	work::Pool pool;
	Loop loop;
	dns::ResolveOp op;
	net::Endpoint[4] results;
	DnsResolveSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 }, allocator)!!;
	loop.init({ .blocking_pool = &pool }, allocator)!!;
	op.init();
	sz allocation_count = tracker.total_allocation_count();

	dns::resolve(
		&loop,
		&op,
		"127.0.0.1",
		80,
		results[0:4],
		&on_resolve_seen,
		{ .family = net::AddressFamily.IPV4, .socket_type = dns::ResolveSocketType.TCP },
		&seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::eq(allocation_count, tracker.total_allocation_count());

	op.destroy();
	loop.destroy();
	pool.destroy();
	test::@check(!tracker.has_leaks());
}

fn void test_dns_resolve_numeric_ipv6() @test
{
	work::Pool pool;
	Loop loop;
	dns::ResolveOp op;
	net::Endpoint[4] results;
	DnsResolveSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::resolve(
		&loop,
		&op,
		"::1",
		80,
		results[0:4],
		&on_resolve_seen,
		{ .family = net::AddressFamily.IPV6, .socket_type = dns::ResolveSocketType.TCP },
		&seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.count >= 1);
	test::eq(net::AddressFamily.IPV6, results[0].family);
	test::eq((ushort)80, results[0].port);
	test::eq((char)1, results[0].storage[15]);

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_resolve_service_name_and_canonical_name() @test
{
	work::Pool pool;
	Loop loop;
	dns::ResolveOp op;
	net::Endpoint[8] results;
	char[64] canonical;
	DnsResolveSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::resolve_service(
		&loop,
		&op,
		"localhost",
		"http",
		{ .endpoints = results[0:8], .canonical_name = canonical[0:64] },
		&on_resolve_seen,
		{ .family = net::AddressFamily.IPV4, .socket_type = dns::ResolveSocketType.TCP, .canonical_name = true },
		&seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.count >= 1);
	test::eq(net::AddressFamily.IPV4, results[0].family);
	test::eq((ushort)80, results[0].port);
	test::@check(seen.canonical_name.len > 0);

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_resolve_canonical_name_small_buffer_reports_buffer_full() @test
{
	work::Pool pool;
	Loop loop;
	dns::ResolveOp op;
	net::Endpoint[8] results;
	char[1] canonical;
	DnsResolveSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::resolve_service(
		&loop,
		&op,
		"localhost",
		"80",
		{ .endpoints = results[0:8], .canonical_name = canonical[0:1] },
		&on_resolve_seen,
		{ .family = net::AddressFamily.IPV4, .socket_type = dns::ResolveSocketType.TCP, .canonical_name = true },
		&seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::eq(nova::BUFFER_FULL, seen.status);
	test::@check(seen.count >= 1);
	test::eq(net::AddressFamily.IPV4, results[0].family);
	test::eq((ushort)80, results[0].port);
	test::eq((sz)0, seen.canonical_name.len);

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_resolve_requires_blocking_pool() @test
{
	Loop loop;
	dns::ResolveOp op;
	net::Endpoint[1] results;

	loop.init()!!;
	op.init();

	test::@error(
		dns::resolve(&loop, &op, "127.0.0.1", 80, results[0:1], &on_resolve_seen, { }, null),
		nova::INVALID_STATE
	);
	test::@check(!op.work.header.active());

	op.destroy();
	loop.destroy();
}

fn void test_dns_resolve_rejects_null_arguments() @test
{
	Loop loop;
	dns::ResolveOp op;
	net::Endpoint[1] results;

	loop.init()!!;
	op.init();

	test::@error(dns::resolve(null, &op, "127.0.0.1", 80, results[0:1], &on_resolve_seen), nova::INVALID_STATE);
	test::@error(dns::resolve(&loop, null, "127.0.0.1", 80, results[0:1], &on_resolve_seen), nova::INVALID_STATE);
	test::@error(dns::resolve(&loop, &op, "127.0.0.1", 80, results[0:1], null), nova::INVALID_STATE);
	test::@check(!op.work.header.active());

	op.destroy();
	loop.destroy();
}

fn void test_dns_resolve_too_small_buffer_reports_buffer_full() @test
{
	work::Pool pool;
	Loop loop;
	dns::ResolveOp op;
	net::Endpoint[1] results;
	DnsResolveSeen seen;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::resolve(
		&loop,
		&op,
		"127.0.0.1",
		80,
		results[0:1],
		&on_resolve_seen,
		{ .family = net::AddressFamily.IPV4, .socket_type = dns::ResolveSocketType.ANY },
		&seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(seen.status == nova::BUFFER_FULL || !seen.status);
	test::@check(seen.count >= 1);

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_resolve_queued_cancel_completes_cancelled() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp blocker;
	dns::ResolveOp op;
	net::Endpoint[4] results;
	DnsCancelCtx ctx;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	blocker.init();
	op.init();

	work::queue(&loop, &blocker, &dns_blocker_work, &after_dns_cancel_blocker, &ctx)!!;
	Ref ref = dns::resolve(
		&loop,
		&op,
		"127.0.0.1",
		80,
		results[0:4],
		&on_resolve_cancelled,
		{ .family = net::AddressFamily.IPV4 },
		&ctx
	)!!;
	op::cancel_ref(&loop, ref)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, ctx.blocker_calls);
	test::eq(1, ctx.dns_calls);
	test::eq(2, ctx.after_calls);
	test::@check(ctx.dns_status == nova::CANCELLED);
	test::eq((sz)4, ctx.resolve_endpoint_capacity);
	test::@check(!op.work.header.active());

	op.destroy();
	blocker.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_resolve_can_reuse_same_op_inside_callback() @test
{
	work::Pool pool;
	Loop loop;
	dns::ResolveOp op;
	DnsResolveReuseCtx ctx;

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::resolve(
		&loop,
		&op,
		"127.0.0.1",
		80,
		ctx.endpoints[0:4],
		&on_resolve_reuse,
		{ .family = net::AddressFamily.IPV4, .socket_type = dns::ResolveSocketType.TCP },
		&ctx
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.calls);
	test::@check(!ctx.status);
	test::@check(ctx.first_count_after_resubmit >= 1);
	test::@check(!op.work.header.active());

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_reverse_numeric_ipv4() @test
{
	work::Pool pool;
	Loop loop;
	dns::ReverseOp op;
	char[64] host;
	char[16] service;
	DnsReverseSeen seen;
	net::Endpoint endpoint = ipv4_loopback_endpoint(80);

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::reverse_lookup(
		&loop,
		&op,
		endpoint,
		host[0:64],
		service[0:16],
		&on_reverse_seen,
		{ .numeric_host = true, .numeric_service = true },
		&seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(seen.owner_thread);
	test::@check(!seen.op_active);
	test::@check(string_equals("127.0.0.1", seen.host));
	test::@check(string_equals("80", seen.service));

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_reverse_numeric_ipv6() @test
{
	work::Pool pool;
	Loop loop;
	dns::ReverseOp op;
	char[64] host;
	char[16] service;
	DnsReverseSeen seen;
	net::Endpoint endpoint = ipv6_loopback_endpoint(80);

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::reverse_lookup(
		&loop,
		&op,
		endpoint,
		host[0:64],
		service[0:16],
		&on_reverse_seen,
		{ .numeric_host = true, .numeric_service = true },
		&seen
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, seen.calls);
	test::@check(!seen.status);
	test::@check(string_equals("::1", seen.host));
	test::@check(string_equals("80", seen.service));

	op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_reverse_too_small_buffers_report_buffer_full() @test
{
	work::Pool pool;
	Loop loop;
	dns::ReverseOp host_op;
	dns::ReverseOp service_op;
	char[2] host;
	char[16] service;
	char[64] host_ok;
	char[1] service_small;
	DnsReverseBufferCtx ctx;
	net::Endpoint endpoint = ipv4_loopback_endpoint(80);

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	host_op.init();
	service_op.init();

	dns::reverse_lookup(
		&loop,
		&host_op,
		endpoint,
		host[0:2],
		service[0:16],
		&on_reverse_buffer_full,
		{ .numeric_host = true, .numeric_service = true },
		&ctx
	)!!;
	dns::reverse_lookup(
		&loop,
		&service_op,
		endpoint,
		host_ok[0:64],
		service_small[0:1],
		&on_reverse_buffer_full,
		{ .numeric_host = true, .numeric_service = true },
		&ctx
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.calls);
	test::eq(2, ctx.buffer_full_calls);

	host_op.destroy();
	service_op.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_reverse_requires_blocking_pool() @test
{
	Loop loop;
	dns::ReverseOp op;
	char[64] host;
	char[16] service;
	net::Endpoint endpoint = ipv4_loopback_endpoint(80);

	loop.init()!!;
	op.init();

	test::@error(
		dns::reverse_lookup(
			&loop,
			&op,
			endpoint,
			host[0:64],
			service[0:16],
			&on_reverse_seen,
			{ .numeric_host = true, .numeric_service = true },
			null
		),
		nova::INVALID_STATE
	);
	test::@check(!op.work.header.active());

	op.destroy();
	loop.destroy();
}

fn void test_dns_reverse_rejects_null_arguments() @test
{
	Loop loop;
	dns::ReverseOp op;
	char[64] host;
	char[16] service;
	net::Endpoint endpoint = ipv4_loopback_endpoint(80);

	loop.init()!!;
	op.init();

	test::@error(
		dns::reverse_lookup(null, &op, endpoint, host[0:64], service[0:16], &on_reverse_seen),
		nova::INVALID_STATE
	);
	test::@error(
		dns::reverse_lookup(&loop, null, endpoint, host[0:64], service[0:16], &on_reverse_seen),
		nova::INVALID_STATE
	);
	test::@error(dns::reverse_lookup(&loop, &op, endpoint, host[0:64], service[0:16], null), nova::INVALID_STATE);
	test::@check(!op.work.header.active());

	op.destroy();
	loop.destroy();
}

fn void test_dns_reverse_queued_cancel_completes_cancelled() @test
{
	work::Pool pool;
	Loop loop;
	WorkOp blocker;
	dns::ReverseOp op;
	char[64] host;
	char[16] service;
	DnsCancelCtx ctx;
	net::Endpoint endpoint = ipv4_loopback_endpoint(80);

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	blocker.init();
	op.init();

	work::queue(&loop, &blocker, &dns_blocker_work, &after_dns_cancel_blocker, &ctx)!!;
	Ref ref = dns::reverse_lookup(
		&loop,
		&op,
		endpoint,
		host[0:64],
		service[0:16],
		&on_reverse_cancelled,
		{ .numeric_host = true, .numeric_service = true },
		&ctx
	)!!;
	op::cancel_ref(&loop, ref)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(1, ctx.blocker_calls);
	test::eq(1, ctx.dns_calls);
	test::eq(2, ctx.after_calls);
	test::@check(ctx.dns_status == nova::CANCELLED);
	test::@check(!op.work.header.active());

	op.destroy();
	blocker.destroy();
	loop.destroy();
	pool.destroy();
}

fn void test_dns_reverse_can_reuse_same_op_inside_callback() @test
{
	work::Pool pool;
	Loop loop;
	dns::ReverseOp op;
	DnsReverseReuseCtx ctx;
	ctx.endpoint = ipv4_loopback_endpoint(80);

	pool.init({ .workers = 1, .queue_capacity = 4 })!!;
	loop.init({ .blocking_pool = &pool })!!;
	op.init();

	dns::reverse_lookup(
		&loop,
		&op,
		ctx.endpoint,
		ctx.host[0:64],
		ctx.service[0:16],
		&on_reverse_reuse,
		{ .numeric_host = true, .numeric_service = true },
		&ctx
	)!!;
	nova::run(&loop, RunMode.UNTIL_STOPPED)!!;

	test::eq(2, ctx.calls);
	test::@check(!ctx.status);
	test::@check(ctx.first_result_survived_resubmit);
	test::@check(!op.work.header.active());

	op.destroy();
	loop.destroy();
	pool.destroy();
}
