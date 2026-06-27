module nova_tests @if(env::LINUX);

import std::core::test;

import nova @norecurse;
import nova::backend::uring;

<*
 AUTO resolves to io_uring when the kernel supports it, otherwise to the epoll
 reactor. Either way init succeeds and reports a concrete engine (never AUTO).
*>
fn void test_backend_auto_resolves() @test
{
	Loop loop;
	loop.init()!!;
	defer loop.destroy();

	BackendKind expected = uring::probe_capabilities().usable() ? BackendKind.IO_URING : BackendKind.EPOLL;
	test::@check(loop.backend() == expected);
}

<*
 EPOLL forces the epoll reactor even when io_uring is available.
*>
fn void test_backend_force_epoll() @test
{
	Loop loop;
	loop.init({ .max_events = 16, .backend = nova::BACKEND_EPOLL })!!;
	defer loop.destroy();
	test::@check(loop.backend() == BackendKind.EPOLL);
}

<*
 IO_URING forces io_uring when usable; on a kernel without it, init fails with
 `UNSUPPORTED` rather than silently falling back.
*>
fn void test_backend_force_io_uring() @test
{
	if (!uring::probe_capabilities().usable())
	{
		Loop unavailable;
		test::@error(unavailable.init({ .backend = nova::BACKEND_IO_URING }), nova::UNSUPPORTED);
		return;
	}

	Loop loop;
	loop.init({ .backend = nova::BACKEND_IO_URING })!!;
	defer loop.destroy();
	test::@check(loop.backend() == BackendKind.IO_URING);
}

<*
 An out-of-range backend value is rejected before any allocation.
*>
fn void test_backend_invalid_value_rejected() @test
{
	Loop loop;
	test::@error(loop.init({ .backend = (BackendKind)99 }), nova::INVALID_STATE);
}

<*
 A no-argument `Loop.init()` keeps working (default `AUTO`) and yields a usable,
 concrete backend.
*>
fn void test_backend_default_init_usable() @test
{
	Loop loop;
	loop.init()!!;
	defer loop.destroy();
	test::@check(loop.is_initialized());
	test::@check(loop.backend() == BackendKind.IO_URING || loop.backend() == BackendKind.EPOLL);
}
