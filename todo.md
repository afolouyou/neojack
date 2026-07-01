# njackd — Plano de Implementação

## Status atual (Julho 2026)

### Funcional
- Socket Unix + protocolo wire (40 tipos de request, 24 structs)
- SHM Registry compatível com `libjack.so.0.1.0`
- `JackGraphManager` com offsets verificados contra binário
- `ConnectionManager` completo (FixedArray, FixedMatrix, LoopFeedback)
- Port allocation/release
- Port connect/disconnect (por índice e por nome)
- Client open/close/activate/deactivate
- Driver interface (vtable)
- Driver dummy (2 canais) e ALSA (RW_INTERLEAVED)
- Hotplug udev
- Lock-free graph switching (AtomicState com CAS duplo-buffer)
- Named futex (`jack_sem.*`)
- `jack_lsp` (lista portas e conexões)
- `jack_connect` / `jack_disconnect` (conexão funciona, cliente trava no close — bug da libjack)

### Constantes (verificadas contra libjack instalada)
- `CLIENT_NUM = 256`, `PORT_NUM_FOR_CLIENT = 2048`, `CONNECTION_NUM_FOR_PORT = 2048`

---

## Fase 1: Motor de Áudio (Engine)

**Prioridade**: Crítica
**Dependências**: Nenhuma
**Arquivos**: `src/engine/engine.zig`, `src/graph/graph_manager.zig`, `src/sync/synchro.zig`, `src/server/channel.zig`, `src/server/server.zig`

### O que falta
O `Engine.process()` atual só troca estado do grafo (`runNextGraph`/`runCurrentGraph`), mas nunca invoca callbacks de cliente (`jack_process_callback`). Sem isso, nenhum áudio é processado.

### Tarefas

#### 1.1. Implementar `TopologicalSort` no GraphManager
- **Descrição**: Ordenar clientes topologicamente baseado nas conexões do grafo. Necessário para saber a ordem de execução dos callbacks.
- **Arquivo**: `src/graph/graph_manager.zig`
- **Referência JACK2**: `JackGraphManager::TopologicalSort` em `common/JackGraphManager.cpp`
- **Detalhes**:
  - Implementar DFS topológico no `ConnectionManager.fConnectionRef` (matriz de adjacência CLIENT_NUM×CLIENT_NUM)
  - Ordenar drivers primeiro (refnum 0=audio, 1=freewheel), depois clientes por dependência
  - Ignorar ciclos (feedback)
  - Retornar array de refnums ordenados

#### 1.2. Implementar ciclo de processamento completo no Engine
- **Descrição**: Substituir o `process()` atual (que só chama `runNextGraph`) por um ciclo real que invoca callbacks.
- **Arquivo**: `src/engine/engine.zig`
- **Referência JACK2**: `JackEngine::Process` em `common/JackEngine.cpp`
- **Detalhes**:
  - `cycleBegin()`: medir tempo de início, preparar frame timer
  - `processNext()` / `processCurrent()`: para cada cliente na ordem topológica:
    1. Chamar `JackClient::ProcessCallback` (via named futex: sinalizar cliente, esperar execução)
    2. Atualizar `JackClientTiming` (fSignaledAt, fAwakeAt, fFinishedAt, fStatus)
    3. Chamar `ResumeRefNum` para agendar próximos clientes
  - `cycleEnd()`: calcular CPU load, detectar XRun, atualizar `fPrevCycleTime`

#### 1.3. Implementar `ResumeRefNum` / `SuspendRefNum`
- **Descrição**: Agendar execução de clientes baseado nas conexões do grafo.
- **Arquivo**: `src/graph/graph_manager.zig`
- **Referência JACK2**: `JackGraphManager::ResumeRefNum` em `common/JackGraphManager.cpp`
- **Detalhes**:
  - Quando um cliente termina (`Finished`), encontrar os clientes que dependem dele (via `fConnectionRef.getOutputTable`)
  - Sinalizar esses clientes via `fInputCounter[].signal()` + `Synchro.signal()`
  - Atualizar `fClientTiming` para `Triggered`

#### 1.4. Implementar ProcessCallback no lado do servidor
- **Descrição**: O servidor precisa de um mecanismo para invocar o callback de processamento do cliente. Em JACK2, isso é feito via named futex: o servidor sinaliza o cliente, o cliente executa o callback, e sinaliza de volta.
- **Arquivo**: `src/sync/synchro.zig`, `src/server/server.zig`
- **Referência JACK2**: `JackClient::ProcessCallback` em `common/JackClient.cpp`
- **Detalhes**:
  - O named futex (`jack_sem.{uid}_{server}_{client}`) já é alocado em `handleClientOpen`
  - Usar `Synchro.signal()` + `Synchro.wait()` para sincronização bidirecional
  - O servidor escreve `nframes` no SHM do cliente (`JackClientControl.fBufferSize` ou campo similar)
  - Cliente lê `nframes`, executa callback, escreve saída no buffer, sinaliza servidor

#### 1.5. Implementar detecção de XRun
- **Descrição**: Detectar quando um cliente não completa o processamento a tempo.
- **Arquivo**: `src/engine/engine.zig`, `src/shm/layouts.zig`
- **Referência JACK2**: `JackEngine::CheckXRun` em `common/JackEngine.cpp`
- **Detalhes**:
  - Verificar `fFinishedAt` vs timeout
  - Se cliente exceder `fTimeOutUsecs`, incrementar contador de XRun
  - Notificar cliente com `kXRunCallback`
  - Usar `JackFrameTimer` do SHM para timing

#### 1.6. Remover `process()` sempre chamando `processNext`
- **Descrição**: Restaurar a lógica condicional de `processNext` vs `processCurrent` agora que o ciclo real está implementado.
- **Arquivo**: `src/engine/engine.zig`
- **Detalhes**:
  - Se `isFinishedGraph()`: chamar `processNext` (novo grafo)
  - Se não: chamar `processCurrent` (grafo atual, processar clientes pendentes)
  - Timeout de 500ms para forçar switch mesmo sem gráfico finished

---

## Fase 2: Completar Handlers de Request

**Prioridade**: Alta
**Dependências**: Nenhuma
**Arquivos**: `src/server/channel.zig`, `src/graph/graph_manager.zig`

### O que falta
Vários tipos de request estão enumerados em `request.zig` mas não têm handler em `channel.zig`.

### Tarefas

#### 2.1. `kSetBufferSize` (type 20)
- **Descrição**: Alterar tamanho do buffer de áudio em runtime.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Ler `JackSetBufferSizeRequest.fBufferSize`
  - Atualizar `engine_control.fBufferSize`
  - Chamar `graph_manager.setBufferSize()` para realocar buffers nas portas
  - Notificar todos os clientes com `kBufferSizeCallback`

#### 2.2. `kSetFreeWheel` (type 21)
- **Descrição**: Ativar/desativar modo freewheel.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Ler `JackSetFreeWheelRequest.fOnOff`
  - Ativar/desativar freewheel driver
  - Notificar clientes com `kStartFreewheelCallback` / `kStopFreewheelCallback`

#### 2.3. `kPortRename` (type 31)
- **Descrição**: Renomear porta existente.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Ler `JackPortRenameRequest` (fRefNum, fPort, fName)
  - Validar nome
  - Atualizar `port.fName` e `port.fAlias1`
  - Notificar clientes com `kPortRenameCallback`

#### 2.4. `kGetPortConnections` (type 10) e `kGetPortNConnections` (type 11)
- **Descrição**: Retornar conexões de uma porta (usado por `jack_lsp -c` internamente).
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Para `kGetPortConnections`: retornar array de nomes de portas conectadas
  - Para `kGetPortNConnections`: retornar número de conexões
  - Estrutura de resposta precisa ser adicionada em `request.zig`

#### 2.5. `kComputeTotalLatencies` (type 39)
- **Descrição**: Recalcular latências de todas as portas.
- **Arquivo**: `src/graph/graph_manager.zig`
- **Detalhes**:
  - Implementar `ComputeTotalLatency` no GraphManager
  - Percorrer grafo, acumular latências de cada conexão
  - Atualizar `fLatency` e `fTotalLatency` em cada porta
  - Notificar clientes com `kLatencyCallback`

#### 2.6. `kDisconnectPort` (type 8)
- **Descrição**: Desconectar porta específica de todas as suas conexões.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Similar a `handleDisconnectPorts` mas com apenas uma porta
  - Chamar `graph_manager.disconnectAllPort()` para desconectar todas as conexões da porta

#### 2.7. `kReserveClientName` (type 36)
- **Descrição**: Reservar nome de cliente (evitar conflitos).
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Verificar se nome está disponível no `client_table`
  - Reservar slot

#### 2.8. Handlers UUID (`kGetClientByUUID`, `kGetUUIDByClient`, `kClientHasSessionCallback`)
- **Descrição**: Gerenciamento de UUID de clientes.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Implementar `ClientTable` com suporte a UUID
  - `kGetClientByUUID`: retornar nome do cliente dado UUID
  - `kGetUUIDByClient`: retornar UUID dado nome do cliente

#### 2.9. `kSetTimeBaseClient` / `kReleaseTimebase` (types 5, 12)
- **Descrição**: Definir/liberar cliente como timebase master do transporte.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Marcar/desmarcar cliente como timebase master no `JackTransportEngine`
  - (Integração com transporte será feita na Fase 5)

#### 2.10. Melhoramento de mensagens/log
- **Descrição**: Reformular sistema de log do servidor para mensagens claras e consistentes.
- **Arquivo**: `src/main.zig`, `src/server/`, `src/graph/`, `src/engine/`, `src/shm/`
- **Detalhes**:
  - Separar logs por nível: `info` (operações), `debug` (detalhado), `err` (erros)
  - Mensagens padronizadas: `[ação] [entidade]: [resultado]` (ex: `[connect] system:capture_1 → system:playback_1: ok`)
  - Substituir `std.log.info`/`std.log.debug` por funções próprias de log
  - Adicionar timestamp relativo ao inicio do servidor
  - Arquivo de log configurável via argumento (`--log-file`)
  - Suprimir logs de debug por padrão (ativo apenas com `-v`)

---

## Fase 3: Freewheel + Timed Drivers

**Prioridade**: Alta
**Dependências**: Fase 1
**Arquivos**: `src/drivers/driver.zig`, `src/drivers/`, `src/server/server.zig`

### O que falta
Sem `JackTimedDriver` e `JackFreewheelDriver`, o driver dummy não tem temporização real e não há suporte a modo freewheel.

### Tarefas

#### 3.1. Implementar `TimedDriver`
- **Descrição**: Driver base que adiciona temporização de ciclo ao driver. Em JACK2, `JackTimedDriver` estende `JackAudioDriver` e gerencia o ciclo de sleep baseado no sample rate / buffer size.
- **Arquivo**: `src/drivers/timed_driver.zig` (novo)
- **Referência JACK2**: `common/JackTimedDriver.cpp`
- **Detalhes**:
  - `fTimedDriver`: wrapper que adiciona `wait()` com sleep temporizado
  - `fTime`: timing interno baseado em `clock_gettime`
  - `fSleepTime`: calculado de `fBufferSize / fSampleRate` (ex: 256/48000 = 5.33ms)
  - `wait()`: `clock_nanosleep` até o próximo ciclo
  - `start()`/`stop()`: gerenciar thread de temporização

#### 3.2. Implementar `FreewheelDriver`
- **Descrição**: Driver especial para modo freewheel (processamento sem áudio em tempo real, usado para exportação offline).
- **Arquivo**: `src/drivers/freewheel_driver.zig` (novo)
- **Referência JACK2**: `common/JackFreewheelDriver.cpp`
- **Detalhes**:
  - `wait()` retorna imediatamente (sem sleep)
  - Processa o máximo de ciclos possível
  - Usado para `jack_export` ou quando áudio não está rodando

#### 3.3. Atualizar `DummyDriver` para usar `TimedDriver`
- **Descrição**: Refatorar `DummyDriver` para usar `TimedDriver` como base.
- **Arquivo**: `src/drivers/dummy.zig`
- **Detalhes**:
  - Envolver com `TimedDriver` para timing realista
  - `wait()` passa a dormir `buffer_size / sample_rate` segundos

#### 3.4. Integrar `FreewheelDriver` no servidor
- **Descrição**: Quando `kSetFreeWheel` é recebido, alternar entre driver normal e freewheel.
- **Arquivo**: `src/server/server.zig`
- **Detalhes**:
  - Adicionar `freewheel_driver` ao servidor (já existe campo `freewheel_driver` em `Server`)
  - Em `kSetFreeWheel`, parar driver atual e iniciar freewheel driver
  - No `rtThread`, alternar entre drivers baseado no modo

#### 3.5. SIMD no MixBuffers (SSE/AVX)
- **Descrição**: Implementar mixing de buffers com instruções SIMD (SSE2/AVX) para redução de latência em portas com múltiplas conexões.
- **Arquivo**: `src/graph/port.zig`, `src/graph/graph_manager.zig`
- **Referência JACK2**: `JackAudioPort.cpp` (MixAudioBuffer com `_mm_add_ps` / `vaddq_f32`)
- **Detalhes**:
  - Substituir loop escalar em `Port.mixBuffers()` por `_mm_load_ps` + `_mm_add_ps` + `_mm_store_ps`
  - Portas já têm alinhamento de 32 bytes (`GetBuffer()` em `layouts.zig:200-203`)
  - Fallback escalar para CPUs sem SSE
  - Benefício: mixing de N fontes passa de O(N×buffer_size) ciclos para O(N×buffer_size/4)

---

## Fase 4: Suporte a Transporte

**Prioridade**: Média
**Dependências**: Fase 1
**Arquivos**: `src/engine/engine.zig`, `src/server/channel.zig`, `src/shm/layouts.zig`

### O que falta
`JackTransportEngine` existe no SHM (`layouts.zig:104-117`) mas nunca é usado. O transporte JACK permite controle de playback (start/stop/seek) sincronizado entre clientes.

### Tarefas

#### 4.1. Implementar estado de transporte
- **Descrição**: Gerenciar máquina de estados do transporte (Stopped → Rolling → Starting → etc.).
- **Arquivo**: `src/engine/engine.zig`
- **Referência JACK2**: `JackTransportEngine.h`
- **Detalhes**:
  - Implementar `TransportStart`, `TransportStop`, `TransportLocate`, `TransportReposition`
  - Usar double-buffering similar ao `GraphManager` para estados de transporte (já tem `fState[3]`)
  - Atualizar `fTransportState` no SHM

#### 4.2. Implementar handlers de transporte
- **Descrição**: Handlers para `kSetTimeBaseClient` e `kReleaseTimebase`.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - `kSetTimeBaseClient`: definir cliente como timebase master
  - `kReleaseTimebase`: liberar timebase master
  - Atualizar `fTimeBaseMaster` no `JackTransportEngine`

#### 4.3. Integrar transporte com ciclo de áudio
- **Descrição**: Atualizar posição do transporte a cada ciclo de áudio.
- **Arquivo**: `src/engine/engine.zig`
- **Detalhes**:
  - A cada ciclo, incrementar `frame` baseado no `buffer_size`
  - Se timebase master definido, chamar seu callback para atualizar BBT
  - Notificar clientes sobre mudanças de estado

#### 4.4. Notificações de transporte
- **Descrição**: Enviar `kTransportCallback` para clientes quando o estado muda.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Quando `kTransportStart`/`kTransportStop` for recebido, notificar todos os clientes
  - Usar `notifyClients` com `kTransportCallback`

---

## Fase 5: MIDI

**Prioridade**: Média
**Dependências**: Fase 1
**Arquivos**: `src/shm/layouts.zig`, `src/graph/port.zig`, `src/drivers/`

### O que falta
`JACK_DEFAULT_MIDI_TYPE = "8 bit raw midi"` existe em `audio_driver.zig:154` mas sem implementação.

### Tarefas

#### 5.1. Implementar `JackMidiPort` no SHM
- **Descrição**: Adicionar struct de porta MIDI ao SHM, compatível com `JackMidiPort.h`.
- **Arquivo**: `src/shm/layouts.zig`
- **Referência JACK2**: `common/JackMidiPort.h`
- **Detalhes**:
  - `JackMidiBuffer`: ring buffer de eventos MIDI
  - `jack_midi_event_t`: timed MIDI event
  - `fBuffer` tipo `u8` (não `f32` como áudio)
  - Tamanho de buffer MIDI: 4096 bytes (configurável)

#### 5.2. Suporte a tipo de porta MIDI em `allocatePort`
- **Descrição**: Quando uma porta é criada com tipo MIDI, alocar buffer MIDI em vez de buffer de áudio.
- **Arquivo**: `src/graph/port.zig`, `src/graph/graph_manager.zig`
- **Detalhes**:
  - Verificar `port_type` em `allocatePort` (comparar com `JACK_DEFAULT_MIDI_TYPE`)
  - Se MIDI: `fTypeId` = tipo MIDI, buffer de tamanho diferente
  - Se áudio: comportamento atual

#### 5.3. Implementar driver ALSA RawMIDI
- **Descrição**: Driver MIDI usando ALSA sequencer ou rawmidi.
- **Arquivo**: `src/drivers/alsa_midi.zig` (novo)
- **Referência JACK2**: `linux/alsarawmidi/JackAlsaRawMidiDriver.cpp`
- **Detalhes**:
  - Abrir porta MIDI ALSA via `snd_rawmidi_open`
  - Ler/escrever eventos MIDI
  - Converter para formato JACK MIDI (timestamps, etc.)

#### 5.4. Portas MIDI no driver dummy
- **Descrição**: Adicionar portas MIDI ao driver dummy para testes.
- **Arquivo**: `src/drivers/dummy.zig`
- **Detalhes**:
  - `midi_in`, `midi_out` portas adicionais
  - `capture_1/2` (áudio) + `midi_in` + `midi_out` (MIDI)

---

## Fase 6: Internal Clients e Session

**Prioridade**: Baixa
**Dependências**: Fase 1
**Arquivos**: `src/server/channel.zig`, `src/engine/engine.zig`

### O que falta
Internal clients (plugins carregados via `dlopen`) e session management não têm suporte.

### Tarefas

#### 6.1. Implementar `kInternalClientLoad` / `kInternalClientUnload`
- **Descrição**: Carregar/descarregar internal clients (plugins de áudio compilados como shared libraries).
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - `kInternalClientLoad`: receber nome do cliente, nome da DLL, load init string
  - Usar `dlopen`/`dlsym` para carregar a shared library
  - Chamar função `jack_initialize` do internal client
  - `kInternalClientUnload`: `dlclose` + cleanup

#### 6.2. Implementar `kSessionNotify` / `kSessionReply`
- **Descrição**: Suporte a sessão JACK (salvar/restaurar estado).
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - `kSessionNotify`: notificar cliente sobre evento de sessão
  - `kSessionReply`: cliente responde com seu estado serializado
  - Armazenar estado em formato opaco

#### 6.3. Implementar `kPropertyChangeNotify`
- **Descrição**: Suporte a metadata/propriedades (nomes descritivos, ícones, etc.).
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Propriedades são pares chave/valor associados a portas ou clientes
  - Implementar tabela de propriedades no `JackPort` ou global
  - Notificar clientes sobre mudanças

---

## Fase 7: Performance, Estabilidade e Tooling

**Prioridade**: Média
**Dependências**: Fase 1
**Arquivos**: Vários

### Tarefas

#### 7.1. `mlockall()` para travar memória
- **Descrição**: Impedir que páginas de memória do servidor sejam swapadas.
- **Arquivo**: `src/main.zig`
- **Detalhes**:
  - Chamar `mlockall(MCL_CURRENT | MCL_FUTURE)` após alocar SHM
  - Isso garante que o servidor não sofra page faults durante processamento de áudio

#### 7.2. `SCHED_FIFO` para thread RT
- **Descrição**: Prioridade de tempo real para thread de áudio.
- **Arquivo**: `src/server/server.zig`
- **Detalhes**:
  - Usar `sched_setscheduler` na thread RT
  - Prioridade `fServerPriority` (default 10)
  - Prevenir que outras threads atrapalhem o ciclo de áudio

#### 7.3. Tratar `jack_client_close` travando
- **Descrição**: O `jack_client_close` do sistema não envia requests. Solução: detectar socket morto e fazer cleanup forçado.
- **Arquivo**: `src/server/channel.zig`
- **Detalhes**:
  - Adicionar heartbeat/timeout no socket do cliente
  - Se cliente não enviar dados por N segundos, considerar morto e fazer cleanup
  - Alternativa: fechar socket do servidor após resposta (força cliente a detectar EOF)

#### 7.4. Testes com `jack_simple_client`
- **Descrição**: Verificar se clientes reais de áudio conseguem se conectar e processar.
- **Comando**: `jack_simple_client` (se disponível) ou implementar cliente de teste em Zig
- **Detalhes**:
  - Cliente abre conexão, ativa, recebe callback de processamento
  - Verificar latência, XRun, etc.

#### 7.5. Benchmark de performance
- **Descrição**: Medir latência e throughput do servidor.
- **Ferramentas**: `jack_iodelay`, `jack_metro`, `jack_test`
- **Detalhes**:
  - Latência de ida e volta (round-trip)
  - Número máximo de clientes/portas antes de XRun
  - Uso de CPU e memória

#### 7.6. Suporte a `jackd` argumentos
- **Descrição**: Adicionar mais argumentos de linha de comando compatíveis com `jackd`.
- **Arquivo**: `src/main.zig`
- **Detalhes**:
  - `-d alsa --device hw:0` — especificar dispositivo ALSA
  - `-p 1024` — buffer size
  - `-r 44100` — sample rate
  - `-n name` — nome do servidor
  - `-P 20` — prioridade RT
  - `-t 2000` — timeout (ms)

#### 7.7. Migrar SHM de `shm_open` para `memfd_create`
- **Descrição**: Substituir POSIX SHM (`shm_open`) por `memfd_create` + selagem (`F_SEAL_SHRINK`). Mais seguro (não polui `/dev/shm`), funciona em containers e ambientes restritos (AppArmor/SELinux).
- **Arquivo**: `src/shm/mem.zig`, `src/shm/registry.zig`
- **Referência JACK2**: não implementado (usa `shm_open` ou SysV SHM)
- **Detalhes**:
  - `memfd_create()` cria fd anônimo → `ftruncate()` → `mmap()` → `fcntl(F_ADD_SEALS, F_SEAL_SHRINK)`
  - Nome do segmento muda de `/jack_{server}_{pid}_shm_{name}` para apenas descritivo interno
  - Registro no SHM registry precisa ser adaptado (registry usa `shm_open` global)
  - Benefício: sem arquivos em `/dev/shm`, sem vazamento de SHM se servidor crashar

#### 7.8. Garantir zero-alocação na RT path
- **Descrição**: Assegurar que a thread RT nunca aloca memória dinamicamente. Em JACK2 isso é crítico; em Zig, alocações implícitas são raras, mas precisamos garantir.
- **Arquivo**: `src/engine/engine.zig`, `src/graph/graph_manager.zig`
- **Detalhes**:
  - Revisar `processCurrent()` para eliminar qualquer slice dinâmico ou array temporário na stack
  - Substituir `var active: [c.CLIENT_NUM]u16` por arrays estáticos já existentes
  - Garantir que `TopologicalSort` usa apenas arrays pré-alocados (já faz isso)
  - Adicionar assert/verificação em debug mode: se alguma alocação ocorrer, panico
  - Benefício: previsibilidade de latência, sem page faults na RT thread

---

## Resumo de Prioridades

| Fase | Título | Prioridade | Esforço | Depende de |
|------|--------|-----------|---------|------------|
| 1 | Motor de Áudio | 🔴 Crítica | 2-3 semanas | — |
| 2 | Handlers de Request | 🟡 Alta | 1 semana | — |
| 3 | Freewheel + Timed | 🟡 Alta | 1 semana | Fase 1 |
| 4 | Transporte | 🟢 Média | 2 semanas | Fase 1 |
| 5 | MIDI | 🟢 Média | 2 semanas | Fase 1 |
| 6 | Internal Clients | 🔵 Baixa | 1-2 semanas | Fase 1 |
| 7 | Performance/Tooling | 🟡 Alta | Contínuo | Fase 1 |
