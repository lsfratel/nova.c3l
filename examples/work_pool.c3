<*
 Offloading blocking work and cancelling a queued job, built on `nova::work`.

 Demonstrates the worker pool: a `work::Pool` (here a single worker) is wired into
 the loop as its `blocking_pool`, and `work::queue` submits jobs that run a
 `WorkOp` body on a worker thread, then resume on the owner thread via an `after`
 callback carrying the job's `fault` status. The single worker forces the second
 job to wait behind the first, so its `Ref` (returned by `work::queue`) can be
 cancelled with `op::cancel_ref` before it runs; that job's after-callback then
 observes `nova::CANCELLED`. The loop stops once both after-callbacks have fired.
*>
module nova_examples::work_pool_example;

import std::io;
import std::thread;

import nova @norecurse, nova::op, nova::work;
import nova_examples::common;

const ulong SUM_LIMIT = 1_000;

struct Ctx
{
	ulong sum;
	int after_count;
	fault blocker_status;
	fault target_status;
	bool target_cancelled;
}

fn int main(String[] args)
{
	(void)args;
	if (catch err = run())
	{
		(void)io::eprintfn("work pool failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void? run()
{
	work::Pool pool;
	Loop loop;
	work::WorkOp blocker;
	work::WorkOp target;
	Ctx ctx;

	// One worker, so the second job stays queued behind the first and can be
	// cancelled before it ever runs.
	pool.init({ .workers = 1, .queue_capacity = 4 })!;
	defer pool.destroy();

	common::init_loop(&loop, { .blocking_pool = &pool })!;
	defer loop.destroy();

	blocker.init();
	target.init();

	work::queue(&loop, &blocker, &compute_sum, &after_blocker, &ctx)!;
	Ref target_ref = work::queue(&loop, &target, &never_runs, &after_target, &ctx)!;

	(void)io::printfn("queued sum(1..%d) job and a second job; cancelling the second", SUM_LIMIT);
	op::cancel_ref(&loop, target_ref)!;

	nova::run(&loop, RunMode.UNTIL_STOPPED)!;

	if (ctx.blocker_status) return ctx.blocker_status~;
}

// Runs on a worker thread. Keeps the single worker busy long enough for the
// queued cancel to land while the second job is still waiting.
fn void? compute_sum(work::WorkOp* op)
{
	Ctx* ctx  = (Ctx*)op.header.userdata;
	ulong sum = 0;
	for (ulong i = 1; i <= SUM_LIMIT; i++) sum += i;
	ctx.sum = sum;
	thread::sleep_ms(30);
}

fn void? never_runs(work::WorkOp* op)
{
	(void)op;
}

fn void after_blocker(Loop* loop, work::WorkOp* op, fault status, void* userdata)
{
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	ctx.blocker_status = status;
	if (!status) (void)io::printfn("sum job finished on owner thread: sum=%d", ctx.sum);
	finish(loop, ctx);
}

fn void after_target(Loop* loop, work::WorkOp* op, fault status, void* userdata)
{
	(void)op;
	Ctx* ctx = (Ctx*)userdata;
	ctx.target_status = status;
	ctx.target_cancelled = status == nova::CANCELLED;
	if (ctx.target_cancelled) (void)io::printn("second job was cancelled before running");
	finish(loop, ctx);
}

fn void finish(Loop* loop, Ctx* ctx)
{
	ctx.after_count++;
	if (ctx.after_count == 2) loop.stop();
}
