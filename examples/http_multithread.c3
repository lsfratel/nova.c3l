<*
 Multi-threaded "hello world" HTTP server: the worker-pool variant of `http.c3`.

 Unlike the single-loop `http` example, this spawns one `std::thread::Thread` per
 worker (worker 0 runs on the main thread, the rest are detached) and gives each
 worker its own independent `Loop`, `tcp::Listener`, and slot pool. Every listener
 binds the same port with `reuse_port`, so the kernel load-balances incoming
 connections across the per-worker loops with no shared state between threads. The
 `NOVA_HTTP_CONNECTION` / `NOVA_BACKEND` env vars and the responses are shared with
 the other HTTP examples via `nova_examples::common`.
*>
module nova_examples::http_multithread;

import std::io;
import std::core::mem::alloc;
import std::thread;

import nova @norecurse, nova::net, nova::net::tcp;
import nova_examples::common;

const ushort DEFAULT_PORT    = 8080;
const sz WORKER_COUNT        = 8;
const sz CAPACITY_PER_WORKER = 1024;

struct Worker
{
	thread::Thread thread;
	ushort port;
	sz id;
	bool close_after_response;
	fault status;
}

struct Server
{
	Loop loop;
	tcp::Listener listener;
	ConnectionSlot[] slots;
	sz worker_id;
	sz accept_window;
	bool close_after_response;
}

struct ConnectionSlot
{
	Server* server;
	tcp::Stream stream;
	tcp::AcceptOp accept_op;
	tcp::ReadOp read_op;
	tcp::WriteOp write_op;
	char[common::READ_BUFFER_SIZE] read_buffer;
	bool initialized;
}

fn int main(String[] args)
{
	(void)args;
	if (catch err = run_server(common::close_after_response()))
	{
		(void)io::eprintfn("server failed: %s", err.description);
		return 1;
	}
	return 0;
}

fn void? run_server(bool close_after_response)
{
	Worker[WORKER_COUNT] workers;
	for (sz i = 0; i < WORKER_COUNT; i++)
	{
		workers[i].port = DEFAULT_PORT;
		workers[i].id = i;
		workers[i].close_after_response = close_after_response;
	}

	String mode = close_after_response ? "close" : "keep-alive";
	(void)io::printfn(
		"nova http multithread listening on 0.0.0.0:%d workers=%d capacity_per_worker=%d total_capacity=%d connection=%s",
		DEFAULT_PORT,
		WORKER_COUNT,
		CAPACITY_PER_WORKER,
		WORKER_COUNT * CAPACITY_PER_WORKER,
		mode
	);

	// Spawn workers 1..N on their own threads; worker 0 runs on this (main) thread.
	for (sz i = 1; i < WORKER_COUNT; i++)
	{
		workers[i].thread.create(&worker_main, &workers[i])!;
		workers[i].thread.detach()!;
	}

	run_worker(&workers[0])!;
}

fn int worker_main(void* raw)
{
	Worker* worker = (Worker*)raw;
	worker.status = @catch(run_worker(worker));
	if (worker.status)
	{
		(void)io::eprintfn("worker %d failed: %s", worker.id, worker.status.description);
		return 1;
	}
	return 0;
}

fn void? run_worker(Worker* worker)
{
	Server server;
	server.worker_id = worker.id;
	server.close_after_response = worker.close_after_response;
	server.accept_window = CAPACITY_PER_WORKER;
	server.slots = alloc::new_array_try(mem, ConnectionSlot, CAPACITY_PER_WORKER)!;
	defer alloc::free(mem, server.slots.ptr);

	common::init_loop(
		&server.loop,
		{ .max_events = CAPACITY_PER_WORKER + 1, .dispatch_budget = 0, .io_progress_budget = 0 }
	)!;

	// reuse_port lets every worker bind the same port; the kernel spreads
	// connections across the per-worker listeners.
	server.listener.init({ .reuse_addr = true, .reuse_port = true, .nodelay = true })!;
	tcp::bind(&server.listener, common::ipv4_any_endpoint(worker.port))!;
	tcp::listen(&server.listener)!;

	for (sz i = 0; i < CAPACITY_PER_WORKER; i++)
	{
		ConnectionSlot* slot = &server.slots[i];
		slot.server = &server;
		slot.stream.init()!;
		slot.initialized = true;
	}

	(void)io::printfn(
		"worker=%d listening on 0.0.0.0:%d capacity=%d accept_window=%d owner_thread=%s",
		server.worker_id,
		server.listener.local.port,
		CAPACITY_PER_WORKER,
		server.accept_window,
		server.loop.is_owner_thread() ? "yes" : "no"
	);

	for (sz i = 0; i < server.accept_window; i++)
	{
		slot_accept(&server.slots[i])!;
	}

	nova::run(&server.loop, RunMode.UNTIL_STOPPED)!;

	for (sz i = 0; i < CAPACITY_PER_WORKER; i++)
	{
		ConnectionSlot* slot = &server.slots[i];
		if (slot.stream.open) (void)tcp::stream_close_now(&slot.stream);
		if (slot.initialized) slot.stream.destroy();
	}
	if (server.listener.open) (void)tcp::listener_close_now(&server.listener);
	server.listener.destroy();
	server.loop.destroy();
}

fn void? slot_accept(ConnectionSlot* slot)
{
	Server* server = slot.server;
	tcp::accept(&server.loop, &server.listener, &slot.stream, &slot.accept_op, &on_accept, slot)!;
}

fn void? slot_read(Loop* loop, ConnectionSlot* slot)
{
	tcp::read(loop, &slot.stream, slot.read_buffer[0:common::READ_BUFFER_SIZE], &slot.read_op, { }, &on_read, slot)!;
}

fn void? slot_write(Loop* loop, ConnectionSlot* slot, String response)
{
	tcp::write(loop, &slot.stream, response, &slot.write_op, { }, &on_write, slot)!;
}

fn void read_or_close(Loop* loop, ConnectionSlot* slot)
{
	if (catch slot_read(loop, slot)) close_and_accept(slot);
}

fn void write_or_close(Loop* loop, ConnectionSlot* slot, String response)
{
	if (catch slot_write(loop, slot, response)) close_and_accept(slot);
}

fn void on_accept(Loop* loop, tcp::Listener* listener, tcp::AcceptOp* op, tcp::AcceptResult* result, void* userdata)
{
	(void)listener;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (result.error.status)
	{
		(void)slot_accept(slot);
		return;
	}

	read_or_close(loop, slot);
}

fn void on_read(Loop* loop, tcp::Stream* stream, tcp::ReadOp* op, tcp::ReadResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (result.error.status || result.eof || result.bytes <= 0)
	{
		close_and_accept(slot);
		return;
	}

	String response = slot.server.close_after_response ? common::RESPONSE_CLOSE : common::RESPONSE_KEEP_ALIVE;
	write_or_close(loop, slot, response);
}

fn void on_write(Loop* loop, tcp::Stream* stream, tcp::WriteOp* op, tcp::WriteResult* result, void* userdata)
{
	(void)stream;
	(void)op;
	ConnectionSlot* slot = (ConnectionSlot*)userdata;
	if (result.error.status || slot.server.close_after_response)
	{
		close_and_accept(slot);
		return;
	}

	read_or_close(loop, slot);
}

fn void close_and_accept(ConnectionSlot* slot)
{
	if (slot.stream.open) (void)tcp::stream_close_now(&slot.stream);
	(void)slot_accept(slot);
}
