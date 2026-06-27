module nova_tests;

import std::core::test;

import nova::op @public;
import nova @norecurse, nova::backend @public;

fn void test_attach_op_state_sets_fields_then_reset_clears() @test
{
	Header op;
	backend::OpState state;
	backend::Watcher watcher;

	backend::attach_op_state(&op, &state, (NativeHandle)7, &watcher, nova::READY_READABLE);
	test::@check(op.backend == &state);
	test::@check((int)state.handle == 7);
	test::@check(state.watcher == &watcher);
	test::eq(nova::READY_READABLE, state.interest);
	test::@check(!state.counted);

	backend::reset_op_state(&state);
	test::@check((int)state.handle == 0);
	test::@check(state.watcher == null);
	test::eq((uint)0, state.interest);
	test::@check(!state.counted);
}

fn void test_unregister_interest_without_backend_is_noop() @test
{
	Loop loop;
	Header op;

	loop.init()!!;
	op.backend = null;

	backend::unregister_interest(&loop, &op);
	test::@check(op.backend == null);
	test::eq((sz)0, loop.backend_active_count);

	loop.destroy();
}
