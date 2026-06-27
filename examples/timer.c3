<*
 Periodic and one-shot timers driven by the `nova::timer` op layer.

 Demonstrates the two `timer::start` modes from a single event loop: a periodic
 timer configured with `{ .interval, .repeat }` fires repeatedly (`repeat`
 counts fires after the first, so `repeat=3` yields 4 ticks), and a `{ .delay }`
 one-shot fires once. Each timer pre-allocates a `TimerOp` (initialized with
 `op.init()`), and `TimerResult.expirations` reports how many expirations a tick
 coalesced. `nova::run` in `RunMode.UNTIL_STOPPED` returns once both timers have
 fired their last expiration and the loop drains. Durations are microseconds.
*>
module nova_examples::timer_example;

import std::io;

import nova @norecurse, nova::timer;
import nova_examples::common;

// Durations are microseconds. 100ms repeating tick, 250ms one-shot.
const Duration TICK_INTERVAL = (Duration)100_000;
const Duration ONESHOT_DELAY = (Duration)250_000;
const uint TICK_REPEATS      = 3;

struct App
{
	int ticks;
	fault status;
}

fn int main(String[] args)
{
	(void)args;
	Loop loop;
	timer::TimerOp periodic;
	timer::TimerOp oneshot;
	App app;

	if (catch err = run(&loop, &periodic, &oneshot, &app))
	{
		(void)io::eprintfn("timer example failed: %s", err.description);
		return 1;
	}
	if (app.status) return 1;
	return 0;
}

fn void? run(Loop* loop, timer::TimerOp* periodic, timer::TimerOp* oneshot, App* app)
{
	common::init_loop(loop, { .max_events = 4 })!;
	defer loop.destroy();

	periodic.init();
	oneshot.init();

	// `repeat` counts repeats after the first fire, so repeat=3 fires 4 times.
	(void)io::printfn("starting periodic timer (100ms, %d fires) and a 250ms one-shot", TICK_REPEATS + 1);
	timer::start(loop, periodic, { .interval = TICK_INTERVAL, .repeat = TICK_REPEATS }, &on_tick, app)!;
	timer::start(loop, oneshot, { .delay = ONESHOT_DELAY }, &on_oneshot, app)!;

	// Runs until both timers have fired their last expiration and the loop drains.
	nova::run(loop, RunMode.UNTIL_STOPPED)!;
}

fn void on_tick(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	App* app = (App*)userdata;
	if (result.error.status)
	{
		app.status = result.error.status;
		return;
	}
	app.ticks++;
	(void)io::printfn("tick %d (expirations=%d)", app.ticks, result.expirations);
}

fn void on_oneshot(Loop* loop, timer::TimerOp* op, timer::TimerResult* result, void* userdata)
{
	(void)loop;
	(void)op;
	App* app = (App*)userdata;
	if (result.error.status)
	{
		app.status = result.error.status;
		return;
	}
	(void)io::printn("one-shot fired");
}
