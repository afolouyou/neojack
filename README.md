# njackd — NeoJack Daemon

A Zig rewrite of the JACK Audio Connection Kit (jackd) daemon, binary-compatible with `libjack.so`.

## Status

**Functional**

| Ferramenta | Status |
|------------|--------|
| `jack_lsp` | ✅ Lista portas e conexões |
| `jack_connect` | ✅ Conecta portas (processo trava no close — bug da libjack) |
| `jack_disconnect` | ✅ Desconecta portas (processo trava no close — bug da libjack) |
| Driver dummy | ✅ 2 canais |
| Driver ALSA | ✅ (SND_PCM_ACCESS_RW_INTERLEAVED) |
| Hotplug udev | ✅ Detecção de placas de som |

## Build

```bash
zig build
```

## Run

```bash
# Dummy driver (sem hardware)
./zig-out/bin/njackd

# ALSA driver
./zig-out/bin/njackd -d alsa -r 44100 -p 128

# Verbose (debug logs)
./zig-out/bin/njackd -d dummy -v
```

## Test

```bash
jack_lsp
jack_lsp -c
jack_connect system:capture_1 system:playback_1   # timeout 1 esperado
jack_disconnect system:capture_1 system:playback_1 # timeout 1 esperado
```

> **Nota**: `jack_connect`/`jack_disconnect` travam no `jack_client_close` (bug na libjack do sistema). A operação é realizada antes do travamento. Use `timeout 1` ou `Ctrl+C`.

## Architecture

```
src/
├── main.zig           CLI, driver selection, signal handling
├── log.zig            Sistema de log (estilo Pipewire, com cores)
├── protocol/
│   └── request.zig    Wire format (40 tipos de request)
├── server/
│   ├── server.zig     Núcleo, RT thread, drivers
│   ├── channel.zig    Socket Unix, handlers de clientes
│   └── device_monitor.zig  Hotplug udev
├── engine/
│   └── engine.zig     Ciclo de áudio, processNext/Current, XRun
├── graph/
│   ├── graph_manager.zig     Portas, conexões, ordenação topológica
│   ├── connection_manager.zig Matriz de conexões, lock-free
│   └── port.zig             Layout de porta de áudio
├── shm/
│   ├── layouts.zig    Structs SHM compatíveis com JACK2
│   ├── registry.zig   SHM registry (/jack-shm-registry)
│   ├── mem.zig        POSIX shm_open / mmap
│   └── named_futex.zig Sincronização entre processos
├── drivers/
│   ├── driver.zig     Interface genérica (vtable)
│   ├── audio_driver.zig Estado compartilhado
│   ├── dummy.zig      Driver dummy
│   ├── alsa.zig       Driver ALSA
│   └── threaded_driver.zig Wrapper multi-thread
└── sync/
    ├── atomic_state.zig    Double-buffering CAS lock-free
    ├── synchro.zig         Futex simples
    └── activation_counter.zig Contador de ativação
```

## Protocol

Compatível com JACK2 protocol version 9:
- Unix socket em `/dev/shm/jack_<name>_<uid>_0`
- POSIX SHM em `/dev/shm/jack_<name>_<pid>_<index>`
- Shared memory registry em `/dev/shm/jack-shm-registry`
- Named futex em `/dev/shm/jack_sem.<uid>_<server>_<client>`

## Implementação vs JACK2

### Implementado
- Protocolo wire completo (40 tipos de request)
- SHM Registry compatível com libjack
- JackGraphManager com offsets verificados contra binário
- ConnectionManager (FixedArray, FixedMatrix, LoopFeedback)
- Port allocation/release/connect/disconnect
- Lock-free graph switching (CAS double-buffer)
- Motor de áudio com ordenação topológica
- Detecção de XRun
- Drivers Dummy e ALSA

### Não implementado
- Processamento real de callbacks de cliente (jack_process_callback)
- Transporte JACK
- MIDI
- Internal clients (dlopen)
- Freewheel driver
- NetJack2

## License

MIT