/// Counts the complete requests in the buffer and returns what comes after
/// the last one.
@external(erlang, "bench_ffi", "split_requests")
pub fn split_requests(buffer: BitArray) -> #(Int, BitArray)

/// The responses to `count` requests
@external(erlang, "bench_ffi", "response")
pub fn response(count: Int) -> BitArray

/// The head of one response
@external(erlang, "bench_ffi", "head")
pub fn head() -> BitArray

// and body of one response
@external(erlang, "bench_ffi", "body")
pub fn body() -> BitArray

/// `keepalive`, `close`, `split` or `sink` from `BENCH_MODE`.
@external(erlang, "bench_ffi", "mode")
pub fn mode() -> String

@external(erlang, "bench_ffi", "port")
pub fn port() -> Int

@external(erlang, "bench_ffi", "pool")
pub fn pool() -> Int

/// The read buffer in bytes from `BENCH_BUFFER`.
@external(erlang, "bench_ffi", "buffer")
pub fn buffer() -> Int
