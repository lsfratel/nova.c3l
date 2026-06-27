module nova::net;

import nova @norecurse;

<*
 Portable socket address family.

 TCP and UDP APIs accept IPv4 and IPv6 endpoints. `UNSPEC` is used for optional
 interface fields such as multicast defaults and is rejected where a concrete
 socket peer or bind address is required.
*>
constdef AddressFamily : inline char
{
	UNSPEC = 0,
	IPV4   = 4,
	IPV6   = 6,
}

<*
 Portable endpoint storage.

 For `AddressFamily.IPV4`, the first four `storage` bytes are the address
 octets in network order. For `AddressFamily.IPV6`, the first sixteen
 `storage` bytes are the address octets in network order and bytes 16-19 store
 an optional IPv6 scope id in host byte order. `port` is stored in host byte
 order and converted at syscall boundaries. For `UNSPEC`, `storage` and `port`
 are ignored by APIs that accept unspecified endpoints.
*>
struct Endpoint
{
	AddressFamily family;
	ushort port;
	char[28] storage;
}

<*
 Multicast group and interface address pair.

 `group` is the IPv4 or IPv6 multicast address to join or leave.
 `interface_addr` may use `AddressFamily.UNSPEC` to request the platform
 default interface. For IPv4, `interface_addr` may be a local IPv4 address. For
 IPv6, `interface_addr` may be an IPv6 endpoint whose scope id is used as the
 interface index. Ports in both endpoints are ignored by multicast membership
 operations.
*>
struct MulticastGroup
{
	Endpoint group;
	Endpoint interface_addr;
}

<*
 Source-specific multicast group, interface and source address.

 `group` and `source` must use the same address family. IPv4 source-specific
 multicast uses a local IPv4 `interface_addr` or `UNSPEC`. IPv6
 source-specific multicast, where the platform supports RFC 3678 socket
 options, uses `interface_addr`'s scope id as the interface index. Ports in all
 endpoints are ignored by source-specific multicast membership operations.
*>
struct SourceMulticastGroup
{
	Endpoint group;
	Endpoint interface_addr;
	Endpoint source;
}

<*
 Socket-level options captured when a handle is initialized.

 Zero numeric values leave the native socket default unchanged. `reuse_addr`,
 `reuse_port`, `send_buffer_size` and `recv_buffer_size` apply to TCP and UDP
 handles. `nodelay`, `keepalive`, `keepalive_idle`, `keepalive_interval` and
 `keepalive_count` are TCP-only; UDP setup rejects them as unsupported.
 Keepalive tuning beyond enabling `keepalive` depends on platform support.
 Negative keepalive durations are invalid. Non-zero buffer sizes and
 `keepalive_count` must fit the native signed socket-option ABI.
*>
struct SocketOptions
{
	Duration keepalive_idle;
	Duration keepalive_interval;
	uint keepalive_count;
	uint send_buffer_size;
	uint recv_buffer_size;
	bool reuse_addr;
	bool reuse_port;
	bool nodelay;
	bool keepalive;
}

<*
 Per-read operation options.

 `min_bytes` controls terminal success for TCP reads: `0` requests at least one
 byte, and non-zero values must not exceed the submitted read buffer length.
 `wait_readiness` skips the bounded non-blocking read attempt at submission and waits for
 readiness first; the default tries immediate progress before waiting.
 To bound a read, arm a `timer` and cancel the read by its `Ref`.
*>
struct ReadOptions
{
	sz min_bytes;
	bool wait_readiness;
}

<*
 Per-write operation options.

 `wait_readiness` skips the bounded non-blocking write attempt at submission and waits
 for writable readiness first; the default tries immediate progress before
 waiting. To bound a write, arm a `timer` and cancel the write by its `Ref`.
*>
struct WriteOptions
{
	bool wait_readiness;
}

<*
 Async close behavior.

 `abortive` requests immediate native TCP stream close through `SO_LINGER`
 where supported. Listener and UDP close APIs accept this shared options
 struct but ignore `abortive`.
*>
struct CloseOptions
{
	bool abortive;
}

<*
 Result of starting a non-blocking TCP connect.

 `complete` means the operation should be queued immediately. `status == null`
 means success; otherwise the callback receives the semantic connect error.
*>
struct NativeTcpConnectStart
{
	NativeHandle handle;
	bool complete;
	fault status;
}

<*
 Result of one non-blocking UDP datagram receive.
*>
struct NativeUdpRecvResult
{
	sz bytes;
	Endpoint peer;
	bool truncated;
}

<*
 Report whether this endpoint stores an IPv4 address.

 @param self : "Endpoint to inspect"
 @return "True when `family == AddressFamily.IPV4`"
*>
fn bool Endpoint.is_ipv4(&self) => self.family == AddressFamily.IPV4;

<*
 Report whether this endpoint stores an IPv6 address.

 @param self : "Endpoint to inspect"
 @return "True when `family == AddressFamily.IPV6`"
*>
fn bool Endpoint.is_ipv6(&self) => self.family == AddressFamily.IPV6;

<*
 Build an IPv4 endpoint from network-order address bytes.

 @param port : "Endpoint port in host byte order"
 @param address : "At least four IPv4 address bytes in network order"
 @return "IPv4 endpoint"
 @require address.len >= 4 : "IPv4 address requires four bytes"
*>
fn Endpoint endpoint_from_ipv4(ushort port, char[] address)
{
	Endpoint endpoint = { .family = AddressFamily.IPV4, .port = port };
	mem::copy(&endpoint.storage, address.ptr, 4);
	return endpoint;
}

<*
 Build an IPv6 endpoint from network-order address bytes.

 @param port : "Endpoint port in host byte order"
 @param address : "At least sixteen IPv6 address bytes in network order"
 @return "IPv6 endpoint"
 @require address.len >= 16 : "IPv6 address requires sixteen bytes"
*>
fn Endpoint endpoint_from_ipv6(ushort port, char[] address)
{
	Endpoint endpoint = { .family = AddressFamily.IPV6, .port = port };
	mem::copy(&endpoint.storage, address.ptr, 16);
	return endpoint;
}

<*
 Build an IPv6 endpoint with a native scope id.

 The scope id is used as the interface index for scoped IPv6 socket addresses
 and IPv6 multicast membership operations.

 @param port : "Endpoint port in host byte order"
 @param address : "At least sixteen IPv6 address bytes in network order"
 @param scope_id : "Native IPv6 scope/interface id"
 @return "IPv6 endpoint"
 @require address.len >= 16 : "IPv6 address requires sixteen bytes"
*>
fn Endpoint endpoint_from_ipv6_scoped(ushort port, char[] address, uint scope_id)
{
	Endpoint endpoint = endpoint_from_ipv6(port, address);
	endpoint.set_ipv6_scope_id(scope_id);
	return endpoint;
}

<*
 Return the stored IPv6 scope id.

 @param self : "Endpoint to inspect"
 @return "IPv6 scope id, or zero for non-IPv6 endpoints"
*>
fn uint Endpoint.ipv6_scope_id(&self)
{
	if (self.family != AddressFamily.IPV6) return 0;
	uint scope_id;
	mem::copy(&scope_id, &self.storage[16], uint::size);
	return scope_id;
}

<*
 Store an IPv6 scope id in this endpoint.

 @param [&inout] self : "IPv6 endpoint to update"
 @param scope_id : "Native IPv6 scope/interface id"
 @require self.family == AddressFamily.IPV6 : "Scope ids apply only to IPv6 endpoints"
*>
fn void Endpoint.set_ipv6_scope_id(&self, uint scope_id)
{
	mem::copy(&self.storage[16], &scope_id, uint::size);
}
