# neojack (njackd)

A Zig rewrite of the JACK Audio Connection Kit (jackd) daemon with hot-plug support.

## Goals

- Binary compatibility with libjack (protocol version 9)
- Linux only (Void Linux), ALSA + Dummy drivers
- Hot-plug architecture from the start (device monitor via libudev)
- Clean, modern Zig implementation

## Status

**In development** - Core server working, ALSA/Dummy drivers, protocol compatible, SHM registry, named futex semaphores for synchronization.

## Build

```bash
zig build
```

## Run

```bash
# Dummy driver (no hardware)
./zig-out/bin/njackd

# ALSA driver
./zig-out/bin/njackd -d alsa -r 44100 -p 128
```

## Test

```bash
# Direct protocol test
./zig-out/bin/test_client

# JACK client (requires libjack)
jack_lsp
```

## Architecture

- `src/main.zig` - CLI entry, driver selection, signal handling
- `src/server/` - Server, channel (Unix socket protocol), device monitor
- `src/engine/` - Engine process cycle, client table
- `src/graph/` - Port management, connection manager, buffer mixing
- `src/drivers/` - ALSA, Dummy, and threaded driver implementations
- `src/shm/` - Shared memory, registry, named futex semaphores
- `src/sync/` - Lock-free ring buffer, atomic state, activation counter

## Protocol

Compatible with JACK2 protocol version 9:
- Unix socket at `/dev/shm/jack_<name>_<uid>_0`
- POSIX SHM at `/dev/shm/jack_<name>_<pid>_<index>`
- Shared memory registry at `/dev/shm/jack-shm-registry`
- Named futex semaphores at `/dev/shm/jack_sem.<uid>_<server>_<client>`

## License

MIT