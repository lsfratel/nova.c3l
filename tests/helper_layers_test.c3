module nova_tests;

import std::core::test;
import std::core::mem::allocators;

import nova::op @public;
import nova @norecurse, nova::buffer, nova::op::pool @public, nova::timer;

alias op_pool = module nova::op::pool;

fn void test_buffer_pool_acquire_release_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	buffer::Pool pool;

	test::@error(buffer::acquire(&pool), nova::INVALID_STATE);
	test::@error(pool.init(0, 8, allocator), nova::INVALID_STATE);
	pool.init(3, 8, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	test::@check(pool.is_initialized());
	test::eq((sz)3, pool.capacity());
	test::eq((sz)3, pool.available());

	buffer::Lease first  = buffer::acquire(&pool)!!;
	buffer::Lease second = buffer::acquire(&pool)!!;
	buffer::Lease third  = buffer::acquire(&pool)!!;
	char* second_ptr     = second.bytes.ptr;

	test::@check(buffer::lease_valid(&first));
	test::@check(buffer::lease_valid(&second));
	test::@check(buffer::lease_valid(&third));
	test::eq((sz)8, buffer::lease_bytes(&first).len);
	test::eq((sz)0, pool.available());
	test::@error(buffer::acquire(&pool), CAPACITY_EXCEEDED);

	first.bytes[0] = 'a';
	second.bytes[0] = 'b';
	third.bytes[0] = 'c';

	buffer::release(&second)!!;
	test::@check(!buffer::lease_valid(&second));
	test::@error(buffer::release(&second), NOT_FOUND);
	test::eq((sz)1, pool.available());

	buffer::Lease reused = buffer::acquire(&pool)!!;
	test::@check(reused.bytes.ptr == second_ptr);
	test::eq((sz)0, pool.available());

	buffer::release(&first)!!;
	buffer::release(&third)!!;
	buffer::release(&reused)!!;
	test::eq((sz)3, pool.available());
	test::eq(allocation_count, tracker.total_allocation_count());

	pool.destroy();
	test::@check(!pool.is_initialized());
	test::@check(!tracker.has_leaks());
}

fn void test_buffer_pool_rejects_stale_lease() @test
{
	buffer::Pool pool;

	pool.init(1, 4)!!;

	buffer::Lease lease = buffer::acquire(&pool)!!;
	buffer::Lease stale = lease;
	buffer::release(&lease)!!;

	buffer::Lease next = buffer::acquire(&pool)!!;
	test::@error(buffer::release(&stale), NOT_FOUND);
	buffer::release(&next)!!;

	pool.destroy();
}

fn void test_buffer_pool_rejects_tampered_lease_slice() @test
{
	buffer::Pool pool;

	pool.init(1, 4)!!;

	buffer::Lease lease    = buffer::acquire(&pool)!!;
	buffer::Lease original = lease;
	lease.bytes = lease.bytes[0:2];

	test::@check(!buffer::lease_valid(&lease));
	test::eq((sz)0, buffer::lease_bytes(&lease).len);
	test::@error(buffer::release(&lease), NOT_FOUND);
	test::eq((sz)0, pool.available());

	buffer::release(&original)!!;
	pool.destroy();
}

fn void test_buffer_pool_rejects_metadata_size_overflow() @test
{
	buffer::Pool pool;

	test::@error(pool.init(sz::max / sz::size + 1, 1), nova::INVALID_STATE);
	test::@check(!pool.is_initialized());
}

fn void test_operation_pool_acquire_release_zero_allocates() @test
{
	allocators::TrackingAllocator tracker;
	tracker.init(mem);
	defer tracker.free();

	Allocator allocator = &tracker;
	op_pool::Pool{timer::TimerOp} pool;

	test::@error(op_pool::acquire{timer::TimerOp}(&pool), nova::INVALID_STATE);
	test::@error(pool.init(0, allocator), nova::INVALID_STATE);
	pool.init(2, allocator)!!;
	sz allocation_count = tracker.total_allocation_count();

	test::@check(pool.is_initialized());
	test::eq((sz)2, pool.capacity());
	test::eq((sz)2, pool.available());

	op_pool::Lease{timer::TimerOp} first  = op_pool::acquire{timer::TimerOp}(&pool)!!;
	op_pool::Lease{timer::TimerOp} second = op_pool::acquire{timer::TimerOp}(&pool)!!;

	test::@check(op_pool::lease_valid{timer::TimerOp}(&first));
	test::@check(op_pool::lease_valid{timer::TimerOp}(&second));
	test::@check(op_pool::lease_op{timer::TimerOp}(&first) == first.op);
	test::eq((sz)0, pool.available());
	test::@error(op_pool::acquire{timer::TimerOp}(&pool), CAPACITY_EXCEEDED);

	first.op.init();
	first.op.result.expirations = 7;
	first.op.header.state = State.OP_ACTIVE;
	test::@error(op_pool::release{timer::TimerOp}(&first), nova::BUSY);

	first.op.header.state = State.OP_FREE;
	op_pool::release{timer::TimerOp}(&first)!!;
	test::@check(!op_pool::lease_valid{timer::TimerOp}(&first));
	test::@error(op_pool::release{timer::TimerOp}(&first), NOT_FOUND);
	test::eq((sz)1, pool.available());

	op_pool::Lease{timer::TimerOp} reused = op_pool::acquire{timer::TimerOp}(&pool)!!;
	test::eq((ulong)0, reused.op.result.expirations);

	op_pool::release{timer::TimerOp}(&second)!!;
	op_pool::release{timer::TimerOp}(&reused)!!;
	test::eq((sz)2, pool.available());
	test::eq(allocation_count, tracker.total_allocation_count());

	pool.destroy();
	test::@check(!pool.is_initialized());
	test::@check(!tracker.has_leaks());
}

fn void test_operation_pool_rejects_stale_lease() @test
{
	op_pool::Pool{timer::TimerOp} pool;

	pool.init(1)!!;

	op_pool::Lease{timer::TimerOp} lease = op_pool::acquire{timer::TimerOp}(&pool)!!;
	op_pool::Lease{timer::TimerOp} stale = lease;
	op_pool::release{timer::TimerOp}(&lease)!!;

	op_pool::Lease{timer::TimerOp} next = op_pool::acquire{timer::TimerOp}(&pool)!!;
	test::@error(op_pool::release{timer::TimerOp}(&stale), NOT_FOUND);
	op_pool::release{timer::TimerOp}(&next)!!;

	pool.destroy();
}
fn void test_operation_pool_rejects_metadata_size_overflow() @test
{
	op_pool::Pool{char} pool;

	test::@error(pool.init(sz::max / sz::size + 1), nova::INVALID_STATE);
	test::@check(!pool.is_initialized());
}
fn void test_operation_pool_accepts_type_without_operation_field() @test
{
	op_pool::Pool{char} pool;

	pool.init(1)!!;
	op_pool::Lease{char} lease = op_pool::acquire{char}(&pool)!!;
	*lease.op = 'x';

	op_pool::release{char}(&lease)!!;
	test::@check(!op_pool::lease_valid{char}(&lease));

	pool.destroy();
}
