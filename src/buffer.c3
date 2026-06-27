module nova::buffer;

import std::core::mem::alloc;

import nova @norecurse;

<*
 Fixed-capacity pool of equal-size byte buffers.

 All memory is allocated by `Pool.init`. Lease acquisition and release use a
 preallocated free stack and never allocate.
*>
struct Pool
{
	Allocator allocator;
	char[] storage;
	sz[] free_stack;
	uint[] generations;
	bool[] leased;
	sz buffer_count;
	sz buffer_size;
	sz free_count;
	bool initialized;
}

<*
 Borrowed buffer lease returned by `acquire`.

 The lease owns no memory. It must be released before the pool is destroyed and
 only after no active IO operation references `bytes`. Successful release
 clears the lease and advances the slot generation so copied stale leases are
 rejected.
*>
struct Lease
{
	Pool* pool;
	char[] bytes;
	sz slot;
	uint generation;
}

<*
 Initialize a fixed-size buffer pool.

 @param [&inout] self : "Pool storage"
 @param buffer_count : "Number of buffers"
 @param buffer_size : "Bytes per buffer"
 @param allocator : "Allocator retained for backing memory until destroy; defaults to the heap allocator `mem`"
 @return "Initialized pool"
 @return ? nova::INVALID_STATE : "Pool is already initialized or sizes are invalid"
 @return ? mem::OUT_OF_MEMORY : "Backing allocation failed"
*>
fn Pool*? Pool.init(&self, sz buffer_count, sz buffer_size, Allocator allocator = mem)
{
	if (self.initialized) return nova::INVALID_STATE~;
	if (buffer_count <= 0 || buffer_size <= 0) return nova::INVALID_STATE~;
	sz? storage_len = buffer_count.overflow_mul(buffer_size);
	if (catch storage_len) return nova::INVALID_STATE~;
	if (catch sz::size.overflow_mul(buffer_count)) return nova::INVALID_STATE~;
	if (catch uint::size.overflow_mul(buffer_count)) return nova::INVALID_STATE~;

	char[] storage = alloc::new_array_try(allocator, char, storage_len)!;
	defer catch alloc::free(allocator, storage.ptr);
	sz[] free_stack = alloc::new_array_try(allocator, sz, buffer_count)!;
	defer catch alloc::free(allocator, free_stack.ptr);
	uint[] generations = alloc::new_array_try(allocator, uint, buffer_count)!;
	defer catch alloc::free(allocator, generations.ptr);
	bool[] leased = alloc::new_array_try(allocator, bool, buffer_count)!;
	defer catch alloc::free(allocator, leased.ptr);

	*self = { };
	self.allocator = allocator;
	self.storage = storage;
	self.free_stack = free_stack;
	self.generations = generations;
	self.leased = leased;
	self.buffer_count = buffer_count;
	self.buffer_size = buffer_size;
	self.free_count = buffer_count;
	self.initialized = true;

	for (sz i = 0; i < buffer_count; i++)
	{
		self.free_stack[i] = buffer_count - i - 1;
		self.generations[i] = 1;
	}

	return self;
}

<*
 Destroy the pool and release all backing memory.

 @param [&inout] self : "Initialized pool with no active leases"
 @require !self.initialized || self.free_count == self.buffer_count : "All leases must be released"
*>
fn void Pool.destroy(&self)
{
	if (self.initialized)
	{
		alloc::free(self.allocator, self.leased.ptr);
		alloc::free(self.allocator, self.generations.ptr);
		alloc::free(self.allocator, self.free_stack.ptr);
		alloc::free(self.allocator, self.storage.ptr);
		*self = { };
	}
}

<*
 Report whether pool storage is initialized.

 @param self : "Pool storage to inspect"
 @return "True after successful `Pool.init` and before `Pool.destroy`"
*>
fn bool Pool.is_initialized(&self) => self.initialized;

<*
 Return the fixed number of buffer slots in this pool.

 @param self : "Pool storage to inspect"
 @return "Total slot capacity"
*>
fn sz Pool.capacity(&self) => self.buffer_count;

<*
 Return the number of currently available buffer slots.

 @param self : "Pool storage to inspect"
 @return "Free slot count"
*>
fn sz Pool.available(&self) => self.free_count;

<*
 Acquire one buffer lease.

 @param pool : "Initialized pool"
 @return "Lease with stable bytes until release"
 @return ? nova::INVALID_STATE : "Pool is not initialized"
 @return ? CAPACITY_EXCEEDED : "No buffers are available"
 @require pool != null : "Pool pointer must not be null"
*>
fn Lease? acquire(Pool* pool)
{
	if (!pool.initialized) return nova::INVALID_STATE~;
	if (!pool.free_count) return CAPACITY_EXCEEDED~;

	pool.free_count--;
	sz slot = pool.free_stack[pool.free_count];
	pool.leased[slot] = true;
	return {
		.pool = pool,
		.bytes = pool_buffer_slice(pool, slot),
		.slot = slot,
		.generation = pool.generations[slot],
	};
}

<*
 Release a buffer lease back to its pool.

 On success, `lease` is cleared and any copied lease value for the same slot
 becomes stale.

 @param [&inout] lease : "Lease returned by `acquire`"
 @return ? NOT_FOUND : "Lease is stale, already released or does not belong to this pool"
 @require lease != null : "Lease pointer must not be null"
*>
fn void? release(Lease* lease)
{
	if (!lease_valid(lease)) return NOT_FOUND~;

	Pool* pool = lease.pool;
	sz slot    = lease.slot;
	pool.leased[slot] = false;
	pool.generations[slot] = next_generation(pool.generations[slot]);
	pool.free_stack[pool.free_count] = slot;
	pool.free_count++;
	*lease = { };
}

<*
 Report whether a lease currently owns a live buffer slot.

 Null lease pointers are treated as invalid and return false.

 @param lease : "Lease to validate"
 @return "True when the lease still owns a live slot"
*>
fn bool lease_valid(Lease* lease)
{
	if (!lease) return false;
	Pool* pool = lease.pool;
	if (!pool || !pool.initialized) return false;
	if (lease.slot < 0 || lease.slot >= pool.buffer_count) return false;
	if (!pool.leased[lease.slot]) return false;
	if (pool.generations[lease.slot] != lease.generation) return false;
	if (lease.bytes.len != pool.buffer_size) return false;
	return lease.bytes.ptr == pool_buffer_slice(pool, lease.slot).ptr;
}

<*
 Return the borrowed bytes for a live lease.

 Invalid or null leases return an empty slice.

 @param lease : "Lease to inspect"
 @return "Borrowed buffer bytes, or an empty slice"
*>
fn char[] lease_bytes(Lease* lease)
{
	if (!lease_valid(lease)) return { };
	return lease.bytes;
}

<*
 Return the byte slice for a pool slot.

 @param pool : "Initialized pool"
 @param slot : "Slot index"
 @return "Borrowed bytes for the slot"
 @require pool != null : "Pool pointer must not be null"
 @require pool.initialized : "Pool must be initialized"
 @require slot >= 0 && slot < pool.buffer_count : "Slot must be in range"
*>
fn char[] pool_buffer_slice(Pool* pool, sz slot) @local
{
	return (pool.storage.ptr + slot * pool.buffer_size)[:pool.buffer_size];
}

<*
 Advance a lease generation, skipping zero as an invalid generation.

 @param generation : "Current generation"
 @return "Next non-zero generation"
*>
fn uint next_generation(uint generation)
{
	generation++;
	if (generation == 0) generation = 1;
	return generation;
}
