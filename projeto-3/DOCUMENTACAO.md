# Documentacao do Projeto - Controlador DRAM (Checkpoint Semana 2)

## 1. Ponto de partida: o que o enunciado pede

O projeto exige construir um controlador SDRAM simplificado para o chip **IS42S16320D** na placa **DE1-SoC**. O checkpoint da semana 2 pede:

- `dram_iface` implementado, testado por simulacao e na placa (usando KEY como ready, LEDs para req/wEn)
- `dram_controller` com pelo menos um fluxo (INIT, READ, WRITE ou REFRESH) implementado e testado por simulacao

---

## 2. Divisao em modulos

O primeiro passo foi identificar a separacao natural do sistema em camadas:

```
+------------------+       +-------------------+       +----------+
|   Usuario        | <---> |   dram_iface      | <---> | dram_    |  <---> SDRAM
|   (SW, KEY,      |       |   (FSM alto       |       | controller|       (chip)
|    HEX, LED)     |       |    nivel)         |       | (FSM     |
+------------------+       +-------------------+       | protocolo)|
                                                        +----------+
```

- **hex_decoder**: componente auxiliar, converte 4 bits para 7-segmentos
- **dram_iface**: interpreta switches/botoes, gera sinais `req`, `wEn`, `address`, `data`
- **dram_controller**: recebe esses sinais e executa o protocolo SDRAM (comandos, timings)
- **top_dram_debug**: integra tudo e adiciona modo debug para teste na placa

---

## 3. hex_decoder - o componente mais simples

**Arquivo:** `src/hex_decoder.vhd`

**O que faz:** Recebe um valor de 4 bits e produz o padrao de 7 segmentos correspondente (0-F).

**Como foi construido:**
- A DE1-SoC usa displays 7-segmentos **ativos em nivel baixo** (bit = '0' acende o segmento)
- Entao "1000000" acende apenas os 6 segmentos de baixo = digito "0"
- Usamos `with ... select` (equivalente a um MUX) para mapear cada valor hex

**Decisao de projeto:** Criar como entidade separada porque o `dram_iface` precisa de 4 instancias (HEX0, HEX1, HEX4, HEX5).

---

## 4. dram_iface - a interface do usuario

**Arquivo:** `src/dram_iface.vhd`

### 4.1 Mapeamento de enderecos e dados

O enunciado define que os 10 switches mapeiam para um endereco de 26 bits:

```
SW(9)           -> address(25)           -- seleciona banco
SW(8 downto 6)  -> address(23 downto 21) -- bits de linha (row)
SW(5 downto 4)  -> address(1 downto 0)   -- bits de coluna
Todos os outros -> '0'

SW(3 downto 0)  -> data(3 downto 0)      -- dado a escrever (4 bits)
data(7 downto 4) = "0000"
```

Isso e implementado com atribuicoes combinacionais diretas:
```vhdl
mapped_address(25)           <= SW(9);
mapped_address(23 downto 21) <= SW(8 downto 6);
mapped_address(1 downto 0)   <= SW(5 downto 4);
-- demais bits <= '0'
```

### 4.2 A maquina de estados

A FSM tem 5 estados. O raciocinio por tras de cada transicao:

```
                    KEY(3) pressionado
                    e ready = '1'
         READY -----------------------> REQ_WRITE
           |                               |
           | endereco mudou                | (1 ciclo: req=1, wEn=1)
           | e ready = '1'                v
           |                          WAIT_WRITE
           |                               |
           v                               | ready = '1'
        REQ_READ <-------------------------+
           |                    (leitura de confirmacao automatica)
           | (1 ciclo: req=1, wEn=0)
           v
        WAIT_READ
           |
           | ready = '1'
           v
         READY (atualiza display com dado lido)
```

**Por que essa sequencia?**

1. **READY**: Fica parado esperando. Dois eventos podem tira-lo daqui:
   - Pressionar KEY(3) -> usuario quer escrever -> vai para REQ_WRITE
   - Mudar os switches de endereco -> quer ver o conteudo -> vai para REQ_READ

2. **REQ_WRITE**: Dura exatamente **1 ciclo de clock**. Nesse ciclo, ativa `req='1'` e `wEn='1'` para o controlador saber que e uma escrita. No proximo ciclo ja desativa.

3. **WAIT_WRITE**: Espera o controlador terminar (sinal `ready='1'`). Quando termina, **nao volta para READY** -- vai para REQ_READ. Por que? Para fazer uma **leitura de confirmacao**: escrevi um dado, agora leio de volta para mostrar no display e confirmar que gravou.

4. **REQ_READ**: Igual ao REQ_WRITE mas com `wEn='0'`. Dura 1 ciclo.

5. **WAIT_READ**: Espera o controlador terminar a leitura. Quando `ready='1'`, captura o dado em `read_data_reg` e volta para READY.

### 4.3 Deteccao de borda do botao

Os botoes da DE1-SoC ficam em '0' quando pressionados e '1' quando soltos. Mas no nosso modulo recebemos o KEY ja invertido pelo top-level.

O problema e: se o usuario segura o botao, nao queremos disparar multiplas escritas. Solucao: **detectar a borda de subida**:

```vhdl
process(clk, rst)
begin
    if rst = '1' then
        key3_prev <= '0';
    elsif rising_edge(clk) then
        key3_prev <= KEY(3);
    end if;
end process;
key3_pulse <= KEY(3) and (not key3_prev);
```

`key3_pulse` so fica '1' por **um unico ciclo** -- no exato ciclo em que KEY(3) muda de '0' para '1'.

### 4.4 Deteccao de mudanca de endereco

Para saber se o usuario mudou os switches:

```vhdl
addr_changed <= '1' when mapped_address /= prev_address else '0';
```

`prev_address` e atualizado todo ciclo com o valor atual. Se diferem, `addr_changed = '1'` e a FSM inicia uma leitura automatica.

### 4.5 Displays 7-segmentos

4 instancias do `hex_decoder`:
- **HEX0**: mostra o ultimo dado escrito (`write_data_reg`)
- **HEX1**: mostra o ultimo dado lido da memoria (`read_data_reg(3 downto 0)`)
- **HEX4**: mostra os bits de coluna do endereco (`SW(5 downto 4)`)
- **HEX5**: mostra os bits de banco/linha (`SW(9 downto 6)`)

---

## 5. dram_controller - o controlador SDRAM

**Arquivo:** `src/dram_controller.vhd`

Este e o modulo mais complexo. Ele traduz as requisicoes de alto nivel (`req`, `wEn`, `address`, `data`) em comandos fisicos para o chip SDRAM.

### 5.1 Constantes de temporização

Todos os tempos vem do datasheet do IS42S16320D-7TL (variante de 143 MHz, tCK = 7 ns):

```vhdl
constant TRCD             : integer := 3;     -- ACTIVATE -> READ/WRITE: 15ns / 7ns = 3 ciclos
constant TCAS             : integer := 3;     -- CAS Latency programado no mode register
constant TRP              : integer := 3;     -- PRECHARGE -> proximo comando: 15ns / 7ns = 3 ciclos
constant TRC              : integer := 9;     -- ciclo completo de refresh: 60ns / 7ns = 9 ciclos
constant TDPL             : integer := 2;     -- ultimo dado escrito -> PRECHARGE: 14ns / 7ns = 2 ciclos
constant TMRD             : integer := 2;     -- apos LOAD MODE REGISTER: 2 ciclos
constant INIT_WAIT        : integer := 30000; -- 200us de espera inicial: 200000ns / 7ns ~ 28571
constant REFRESH_INTERVAL : integer := 1100;  -- refresh a cada 7.8us: 7812ns / 7ns ~ 1116 ciclos
constant INIT_REFRESH_COUNT : integer := 8;   -- datasheet exige minimo 8 auto-refreshes na init
```

### 5.2 Codificacao dos comandos SDRAM

Do datasheet pagina 9, cada comando e codificado pelos 4 sinais {CS_N, RAS_N, CAS_N, WE_N}:

```vhdl
constant CMD_NOP       : std_logic_vector(3 downto 0) := "0111";  -- nenhuma operacao
constant CMD_ACTIVATE  : std_logic_vector(3 downto 0) := "0011";  -- abrir uma linha
constant CMD_READ      : std_logic_vector(3 downto 0) := "0101";  -- ler coluna
constant CMD_WRITE     : std_logic_vector(3 downto 0) := "0100";  -- escrever coluna
constant CMD_PRECHARGE : std_logic_vector(3 downto 0) := "0010";  -- fechar linha
constant CMD_REFRESH   : std_logic_vector(3 downto 0) := "0001";  -- auto refresh
constant CMD_LMR       : std_logic_vector(3 downto 0) := "0000";  -- carregar mode register
constant CMD_INHIBIT   : std_logic_vector(3 downto 0) := "1111";  -- desativar chip
```

No codigo, um sinal interno `cmd` recebe o comando desejado, e e mapeado diretamente para os pinos de saida:

```vhdl
DRAM_CS_N  <= cmd(3);
DRAM_RAS_N <= cmd(2);
DRAM_CAS_N <= cmd(1);
DRAM_WE_N  <= cmd(0);
```

### 5.3 Mode Register

O valor carregado no mode register configura o comportamento da SDRAM:

```
A[12:10] = "000"  -- reservado
A[9]     = '1'    -- Write Burst Mode = Single Location (1 palavra por escrita)
A[8:7]   = "00"   -- Operating Mode = Standard
A[6:4]   = "011"  -- CAS Latency = 3
A[3]     = '0'    -- Burst Type = Sequential
A[2:0]   = "000"  -- Burst Length = 1
```

Resultado: `"0001000110000"`

### 5.4 Decomposicao do endereco de 26 bits

Quando o controlador recebe um endereco de 26 bits, ele precisa separar em:

```
address(25 downto 24) -> banco (BA[1:0])     -- seleciona 1 dos 4 bancos
address(23 downto 11) -> linha (A[12:0])      -- durante ACTIVATE
address(10 downto 1)  -> coluna (A[9:0])      -- durante READ/WRITE
address(0)            -> byte select           -- controla DQML/DQMH
```

O bit 0 do endereco seleciona se estamos acessando o byte inferior (DQ[7:0]) ou superior (DQ[15:8]) da palavra de 16 bits da SDRAM.

### 5.5 A maquina de estados

A FSM tem 19 estados, divididos em blocos logicos:

#### Bloco INIT (inicializacao)

```
ST_INIT_WAIT ──(30000 ciclos)──> ST_INIT_PRECHARGE ──> ST_INIT_WAIT_RP
                                                            |
                                                      (3 ciclos tRP)
                                                            v
ST_INIT_LMR <──(8 refreshes)── ST_INIT_WAIT_RC <── ST_INIT_REFRESH
     |                              ^                    |
     v                              └────────────────────┘
ST_INIT_WAIT_MRD ──(2 ciclos)──> ST_READY
```

**O que acontece e por que:**
1. **ST_INIT_WAIT**: Apos power-on, a SDRAM precisa de pelo menos 200us para estabilizar internamente. Ficamos emitindo INHIBIT (chip desabilitado) por 30000 ciclos.
2. **ST_INIT_PRECHARGE**: Emitimos PRECHARGE ALL (A10='1') para fechar todas as linhas de todos os bancos.
3. **ST_INIT_WAIT_RP**: Esperamos tRP (3 ciclos) para o precharge completar.
4. **ST_INIT_REFRESH + ST_INIT_WAIT_RC**: Emitimos AUTO REFRESH e esperamos tRC (9 ciclos). Repetimos isso 8 vezes (exigencia do datasheet).
5. **ST_INIT_LMR**: Carregamos o Mode Register com nossa configuracao.
6. **ST_INIT_WAIT_MRD**: Esperamos tMRD (2 ciclos). Depois disso, `ready <= '1'`.

#### Bloco READ (leitura)

```
ST_READY ──(req=1, wEn=0)──> ST_ACTIVATE ──> ST_WAIT_TRCD ──(3 ciclos)──> ST_READ
                                                                              |
                                                                        (cmd READ)
                                                                              v
ST_READY <──(3 ciclos tRP)── ST_WAIT_TRP <── ST_PRECHARGE <── ST_READ_CAPTURE
                                                                    ^
                                                              (3 ciclos CAS)
                                                                    |
                                                              ST_WAIT_CAS
```

**Passo a passo:**
1. Em ST_READY, quando `req='1'`, o controlador **trava** (latch) o endereco, dado e tipo de operacao em registradores internos (`latched_addr`, `latched_data`, `op_is_write`). Isso e importante porque o `dram_iface` pode mudar esses sinais no proximo ciclo.
2. **ST_ACTIVATE**: Emite o comando ACTIVATE com o endereco de linha nos pinos `DRAM_ADDR` e o banco em `DRAM_BA`. Isso "abre" a linha na SDRAM.
3. **ST_WAIT_TRCD**: Espera 3 ciclos (tRCD). A SDRAM precisa desse tempo para transferir os dados da linha para o buffer interno.
4. **ST_READ**: Emite o comando READ com o endereco de coluna. Configura as mascaras DQM conforme o byte selecionado.
5. **ST_WAIT_CAS**: Espera 3 ciclos (CAS Latency). A SDRAM precisa desse tempo para buscar o dado da coluna.
6. **ST_READ_CAPTURE**: O dado esta disponivel em DRAM_DQ. Capturamos o byte correto (superior ou inferior) em `data_out_i`.
7. **ST_PRECHARGE**: Fecha a linha com PRECHARGE ALL.
8. **ST_WAIT_TRP**: Espera 3 ciclos (tRP). Depois, `ready <= '1'`.

#### Bloco WRITE (escrita)

Identico ao READ ate ST_WAIT_TRCD. A diferenca:

1. **ST_WRITE**: Emite comando WRITE, **e ao mesmo tempo** coloca o dado no barramento DQ (`dq_oe <= '1'`). O dado fica disponivel por exatamente 1 ciclo (Burst Length = 1).
2. **ST_WAIT_TDPL**: Espera 2 ciclos (tDPL). A SDRAM precisa desse tempo para gravar o dado antes de podermos fechar a linha.
3. Depois segue para PRECHARGE -> WAIT_TRP -> READY, igual ao READ.

#### Bloco REFRESH

```
ST_READY ──(refresh_needed=1)──> ST_REFRESH ──> ST_WAIT_TRC ──(9 ciclos)──> ST_READY
```

O refresh e simples: emite AUTO REFRESH e espera tRC (9 ciclos).

**Prioridade:** No estado READY, se `refresh_needed='1'` E `req='1'` ao mesmo tempo, o refresh tem prioridade. Isso e essencial: se nao fizermos refresh a tempo, a SDRAM perde dados.

### 5.6 O timer de refresh

Um contador independente (`refresh_counter`) conta ate 1100 ciclos. Quando atinge o limite:
- Zera o contador
- Levanta `refresh_needed <= '1'`

Quando a FSM entra em ST_REFRESH, `refresh_needed` e limpo.

Durante a inicializacao, o timer fica desabilitado (nao faz sentido contar refresh enquanto a memoria ainda nao esta pronta).

### 5.7 Controle do barramento bidirecional DQ

O DRAM_DQ e bidirecional: as vezes o controlador escreve nele (WRITE), as vezes a SDRAM escreve e o controlador le (READ).

```vhdl
DRAM_DQ <= dq_out when dq_oe = '1' else (others => 'Z');
```

- `dq_oe = '1'` apenas durante ST_WRITE: o controlador "empurra" o dado no barramento
- Em todos os outros estados: alta impedancia ('Z'), permitindo que a SDRAM use o barramento

---

## 6. top_dram_debug - integracao e modo debug

**Arquivo:** `src/top_dram_debug.vhd`

### 6.1 Por que um modo debug?

O checkpoint pede testar o `dram_iface` na placa **sem depender do controlador**. O problema e: o `dram_iface` precisa do sinal `ready` para funcionar. Sem controlador, quem gera esse sinal?

Solucao: criar dois modos controlados por SW(9):

- **SW(9) = '0' -> Modo DEBUG**: O sinal `ready` vem de KEY(1). O usuario pressiona o botao para simular a resposta do controlador. As requisicoes nao chegam ao `dram_controller` (ficam bloqueadas).
- **SW(9) = '1' -> Modo FULL**: O `ready` vem do `dram_controller` real.

### 6.2 Inversao dos botoes

A DE1-SoC tem botoes **ativos em nivel baixo** (pressionado = '0'). Mas internamente, queremos logica positiva. O top-level faz a inversao:

```vhdl
rst        <= not KEY(0);          -- KEY(0) pressionado -> reset ativo
debug_ready <= not KEY(1);          -- KEY(1) pressionado -> ready = '1'
iface_key  <= (not KEY(3)) & "000"; -- KEY(3) pressionado -> dispara escrita
```

### 6.3 LEDs de depuracao

```
LEDR(0) = req              -- acende quando dram_iface emite requisicao
LEDR(1) = wEn              -- acende quando a requisicao e de escrita
LEDR(2) = effective_ready   -- mostra o ready que o dram_iface esta recebendo
LEDR(3) = controller_ready  -- mostra o ready real do controlador
LEDR(4) = debug_mode        -- '1' quando em modo debug
```

### 6.4 Como testar na placa (procedimento do checkpoint)

1. Colocar **SW(9) = '0'** (modo debug)
2. Resetar com **KEY(0)**
3. Definir endereco com SW(8:4) e dado com SW(3:0)
4. Observar displays HEX mostrando endereco e dado
5. Pressionar **KEY(3)** -> LEDR(0) e LEDR(1) piscam (req e wEn)
6. Pressionar **KEY(1)** -> simula ready, FSM avanca
7. Observar que LEDR(0) pisca novamente sozinho (leitura de confirmacao)
8. Pressionar **KEY(1)** novamente -> FSM volta a READY

---

## 7. Testbenches

### 7.1 tb_dram_iface

**Arquivo:** `tb/tb_dram_iface.vhd`

Testa 3 cenarios:
1. **Escrita**: configura switches, pulsa KEY(3), verifica que req e wEn ativam corretamente, simula ready, verifica leitura de confirmacao automatica
2. **Mudanca de endereco**: muda SW e verifica que a FSM detecta a mudanca
3. **Reset durante operacao**: inicia uma escrita, aplica reset no meio, verifica que a FSM volta a READY

### 7.2 tb_dram_controller

**Arquivo:** `tb/tb_dram_controller.vhd`

Inclui um **modelo comportamental simples da SDRAM**: quando detecta um comando READ (via cmd = "0101"), espera 3 ciclos (CAS latency) e entao drive dados no barramento DQ.

Testa 5 cenarios:
1. **INIT**: espera o `ready` subir apos a sequencia de inicializacao completa
2. **WRITE**: envia dado 0x5A para endereco 0, verifica que o comando WRITE aparece nos sinais SDRAM
3. **READ**: le do endereco 0, verifica que `data_out` recebe o dado do modelo de memoria
4. **REFRESH**: espera tempo suficiente (~10000 ns) para o refresh automatico disparar
5. **Back-to-back**: escrita seguida de leitura em endereco diferente

O monitor de comandos imprime cada comando SDRAM emitido, permitindo verificar a sequencia e os timings na forma de onda.

---

## 8. Resumo das decisoes de projeto

| Decisao | Justificativa |
|---------|---------------|
| FSM com 19 estados no controlador | Cada estado corresponde a exatamente 1 acao ou espera, facilitando contagem de ciclos |
| Latch de endereco/dado no ST_READY | O dram_iface pode mudar os sinais enquanto o controlador esta operando |
| Refresh com prioridade sobre req | Evita perda de dados por falta de refresh |
| Modo debug com KEY como ready | Permite testar dram_iface isoladamente na placa, sem controlador funcional |
| Byte select via address(0) | Usa a palavra de 16 bits da SDRAM para 2 enderecos de 8 bits |
| Burst Length = 1, sem Auto Precharge | Simplifica a FSM: cada acesso e uma sequencia completa ACTIVATE-cmd-PRECHARGE |
| Contador de 15 bits para delays | Comporta o maior delay (30000 ciclos da init) em um unico contador |
