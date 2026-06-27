module nova_tests @if(env::LINUX);

import std::core::test;

import nova::backend::uring;

<*
 On a kernel with io_uring, probing must report availability, POLL_ADD support
 and the EXT_ARG feature (the timeout mechanism this backend relies on). On a
 kernel without io_uring, `available` is false and the rest is simply ignored —
 either way the probe must not crash and must leave no ring fd behind.
*>
fn void test_uring_probe_capabilities() @test
{
	uring::Caps caps = uring::probe_capabilities();
	if (!caps.available) return;
	test::@check(caps.poll_add);
	test::@check(caps.ext_arg);
}

<*
 Guard the on-wire ABI struct sizes against accidental field/type drift.
*>
fn void test_uring_abi_sizes() @test
{
	test::@check(uring::IoUringSqe::size == 64);
	test::@check(uring::IoUringCqe::size == 16);
	test::@check(uring::IoUringParams::size == 120);
}
