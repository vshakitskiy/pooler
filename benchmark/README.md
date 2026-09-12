# Benchmarks

Compares tup against [glisten](https://hex.pm/packages/glisten). Both run the
same minimal HTTP/1.1 server, which answers every request with `hello`, so
standard HTTP load tools can drive them. The request handling lives in
`src/bench_ffi.erl` and is shared, so what differs is the pool itself.

```sh
./bench.sh                  # everything, about 8 minutes
./bench.sh keepalive churn  # only the workloads you name
REPEATS=5 DURATION=20 ./bench.sh many
```

Needs Linux, `gleam`, Erlang, `h2load` (nghttp2), `wrk` and `taskset`.

## Files

| File | |
|---|---|
| `bench.sh` | Builds the project, runs the workloads, prints one line per run. Its header lists the workloads and settings. |
| `src/tup_server.gleam`, `src/glisten_server.gleam` | The two servers. |
| `src/bench_ffi.erl`, `src/shared.gleam` | The shared request handling and its bindings. |
| `hold_connections.erl` | The idle client for the memory workload. |

## Workloads

| Workload | Tool | Measures |
|---|---|---|
| `keepalive` | h2load, 50 connections | Requests per second, one request at a time per connection. Mostly the cost of the connection loop. |
| `many` | h2load, 1000 connections | The same, with many connections competing for schedulers. |
| `split` | h2load, 50 connections | Each response is written in two sends. Shows the effect of `TCP_NODELAY`. |
| `churn` | wrk, 50 connections | The server closes after every response. Connections accepted per second. |
| `uploads` | 8 × `dd`, 1 GiB each | How fast the server reads incoming data. |
| `memory` | `hold_connections.erl`, 10,000 connections | Server memory growth per idle connection. |

`uploads` and `memory` also run tup with `buffer_size(131_072)`, the read
buffer glisten uses. That setting trades memory for upload speed.

## Method

- Every run starts a fresh VM, and the servers take turns.
- The server runs on the first half of the CPUs and the load on the second
  half.
- h2load and wrk warm up for 3 seconds before measuring.
- Differences of a few percent are noise. Raise `REPEATS` before trusting a
  small gap.

## Limitations

- Loopback on one machine, with no real network.
- A handler that does almost nothing, so real work would dominate.
- No TLS and no pipelining.
- `churn` leaves about 20k sockets in TIME_WAIT for a minute.

To compare against a local glisten checkout, change the dependency in
`gleam.toml` to a `path`.
