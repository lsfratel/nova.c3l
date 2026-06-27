module nova_tests @if(env::LINUX);

import std::core::mem;
import std::core::test;
import libc;

import nova::backend::uring;

<*
 Pop one completion from the ring's completion queue with the acquire/release
 ordering the ring relies on. Test-local helper: production drains completions
 inline in the io_uring poll loop, so the ring core exposes no single-CQE pop.
*>
fn bool pop_cqe(uring::UringState* ring, uring::IoUringCqe* out) @local
{
	uint head = *ring.cq_head;
	uint tail = @atomic_load(*ring.cq_tail, mem::AtomicOrdering.ACQUIRE);
	if (head == tail) return false;

	*out = ring.cqes[head & ring.cq_mask];
	@atomic_store(*ring.cq_head, head + 1, mem::AtomicOrdering.RELEASE);
	return true;
}

<*
 Drive one POLL_ADD through the ring core: set up + map the ring, poll a readable
 eventfd, submit and wait via io_uring_enter, then pop the completion. Exercises
 the acquire/release ring barriers and the mmap lifecycle end to end.
*>
fn void test_uring_ring_poll_roundtrip() @test
{
	uring::UringState ring;
	if (!ring.init(8)) return;
	defer ring.destroy();

	int efd = uring::eventfd(1, 0);
	test::@check(efd >= 0);
	if (efd < 0) return;
	defer (void)libc::close(efd);

	bool staged = ring.push_poll(efd, 0x1, 0xCAFE, false);
	test::@check(staged);

	long ret = ring.flush(1, uring::IORING_ENTER_GETEVENTS, null, 0);
	test::@check(ret >= 0);

	uring::IoUringCqe cqe;
	bool got = pop_cqe(&ring, &cqe);
	test::@check(got);
	if (got)
	{
		test::@check(cqe.user_data == 0xCAFE);
		test::@check(((uint)cqe.res & 0x1) != 0);
	}
}
