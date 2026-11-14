# Medições

## Ambiente

| | |
|---|---|
| CPU | Intel Core i5-8250U @ 1.60 GHz (4 núcleos / 8 threads, classe U, com throttling) |
| SO | Ubuntu 26.04 sob WSL2, em Windows 11 Home |
| Compiladores | gcc 15.2.0 (`-O3`), rustc 1.93.1 (`opt-level=3`, sem LTO) |
| Data | 2026-11-13 |
| Carga | `load average` entre 0,9 e 1,0 nas rodadas reportadas |

As quatro configurações medidas:

| rótulo | o que é |
|---|---|
| `build-linux-switch` | C, dispatch por `switch` |
| `build-linux-goto` | C, dispatch por computed goto |
| `fvm-rust-vec` | Rust, pilha de operandos em `Vec<Value>` (padrão) |
| `fvm-rust-boxed` | Rust, pilha em `Box<[Value]>` + `sp` explícito (`--features boxed-stack`) |

## Metodologia

- `REPS=15` a `REPS=21` execuções por combinação, mais uma rodada de
  aquecimento descartada.
- **Melhor** tempo, não a média.
- Execuções **intercaladas** (rodada externa = repetição, interna = binário):
  medir 15× o binário A e depois 15× o B atribui a cada um a deriva de
  frequência que ocorra no meio.
- `disp_pct` = (pior − melhor) / melhor, reportado em toda tabela.

Reproduzir:

```bash
bash build.sh switch
bash build.sh goto
cargo build --release --manifest-path rust/Cargo.toml --target-dir rust/target-vec
cargo build --release --manifest-path rust/Cargo.toml --features boxed-stack --target-dir rust/target-boxed
REPS=15 bash bench/run_bench.sh build-switch/fvm build-goto/fvm \
    rust/target-vec/release/fvm rust/target-boxed/release/fvm
```

### Por que o mínimo, com evidência

A dispersão deste ambiente é brutal: 120 % a 220 %. Isso faz a média inútil.
O mínimo, porém, **reproduz**. Três sessões independentes do mesmo programa
(`loop`, 390 M instruções), melhor tempo em segundos:

| configuração | sessão 1 | sessão 2 | sessão 3 | variação do mínimo |
|---|---|---|---|---|
| C switch | 0,976776 | 0,978438 | 0,979730 | **0,3 %** |
| Rust boxed | 1,770221 | 1,782587 | 1,739665 | **2,5 %** |
| Rust vec | 2,151671 | 1,858531 | 1,832222 | 17 % |

O mínimo do C variou 0,3 % entre sessões enquanto o máximo variava 2–3×. É a
justificativa empírica de usar o mínimo, e não um argumento de autoridade.

A linha do `Rust vec` mostra o limite do método: a sessão 1 rodou com
`load average 4,87` (logo após o boot do Windows) e contaminou até o mínimo.
As sessões 2 e 3, com carga ~1,0, concordam dentro de 1,5 %. **Só as rodadas
com carga baixa entram nas tabelas abaixo.**

## Resultado 1: dispatch (`loop`, 390 M instruções)

| configuração | tempo (s) | Mops/s | relativo ao C switch |
|---|---|---|---|
| C, computed goto | 0,875731 | **445,3** | +11,8 % |
| C, switch | 0,979730 | 398,1 | — |
| Rust, boxed stack | 1,739665 | 224,2 | −43,7 % |
| Rust, Vec stack | 1,832222 | 212,9 | −46,5 % |

> ⚠️ **A linha do computed goto só vale para esta máquina.** Em outras duas o
> resultado foi −10,3 % e +3,1 %: o sinal muda com a CPU. Ver
> [As medições no CI](#as-medições-no-ci-e-o-que-elas-fizeram-com-a-conclusão).
> A comparação Rust × C, por ser uma razão entre dois binários medidos juntos
> na mesma máquina, não é afetada por isso.

## Resultado 2: chamadas de função (`fib(30)`, 26,9 M instruções)

| configuração | tempo (s) | Mops/s | relativo ao C switch |
|---|---|---|---|
| C, computed goto | 0,071814 | **374,9** | +6,0 % |
| C, switch | 0,076134 | 353,7 | — |
| Rust, boxed stack | 0,152036 | 177,1 | −49,9 % |
| Rust, Vec stack | 0,162359 | 165,8 | −53,1 % |

## Resultado 3: alocação e GC (`alloc`, 3 M arrays descartados)

| configuração | tempo (s) | Mops/s | relativo ao C switch |
|---|---|---|---|
| Rust, boxed stack | 0,285437 | 126,1 | +5,3 % |
| Rust, Vec stack | 0,290089 | 124,1 | +3,7 % |
| C, computed goto | 0,292738 | 123,0 | +2,8 % |
| C, switch | 0,300645 | 119,7 | — |

Aqui a desvantagem do Rust no dispatch desaparece: as quatro configurações
ficam dentro de 5 %.

A explicação estrutural é que a versão em C faz `malloc` e `free` por objeto,
enquanto a versão em Rust mantém uma arena de slots com lista de livres —
reciclar um objeto é um `pop` num `Vec<usize>`. Com 1.831 coletas e 3 M de
objetos, a diferença entre "chamar o alocador do sistema" e "reaproveitar um
índice" compensa o que o Rust perde no dispatch.

> ⚠️ **Corrigido depois:** a versão anterior desta seção afirmava que o Rust
> "fica na frente". No runner #2 ele ficou 4,3 % **atrás** (143,7 contra
> 150,2 Mops/s). Com as duas máquinas, a conclusão defensável é **empate dentro
> de ±5 %**: a arena iguala `malloc`/`free` por objeto, não o supera. O ponto de
> engenharia permanece — a arena compensa inteiramente a desvantagem de 41 % que
> o Rust tem no dispatch no mesmo hardware.

## As medições no CI, e o que elas fizeram com a conclusão

O CI roda o mesmo `bench/run_bench.sh` em runners `ubuntu-latest`. Duas
execuções, e **duas CPUs diferentes** — o GitHub não garante modelo de
máquina:

### Runner #1 (CPU não identificada)

A execução anterior ao passo de identificação de máquina, que só existe a
partir do segundo commit. Dispersão de 0,2 % a 2,6 %.

| configuração | programa | tempo (s) | Mops/s |
|---|---|---|---|
| C, switch | loop | 0,617553 | **631,5** |
| C, computed goto | loop | 0,688374 | 566,6 |
| C, switch | fib | 0,044805 | 600,9 |
| C, computed goto | fib | 0,045106 | 596,9 |
| C, switch | alloc | 0,151957 | 236,9 |
| C, computed goto | alloc | 0,147816 | **243,5** |

Só C: nesta execução o harness pulou o binário do Rust **em silêncio**, porque
`[ -x "$exe" ] || continue` escondia a ausência. A tabela saiu plausível com
uma linha a menos. Corrigido — hoje o script falha com exit 2 e mensagem
explícita, e o job imprime `ls -l` dos binários.

### Runner #2 (AMD EPYC 9V74 80-Core, 4 vCPU, gcc 13.3, rustc 1.100)

Dispersão de 0,5 % a 9,9 %.

| configuração | programa | tempo (s) | Mops/s |
|---|---|---|---|
| C, switch | loop | 0,949686 | 410,7 |
| C, computed goto | loop | 0,921202 | **423,4** |
| C, switch | fib | 0,067331 | 399,9 |
| C, computed goto | fib | 0,063358 | **425,0** |
| C, switch | alloc | 0,239659 | 150,2 |
| C, computed goto | alloc | 0,230384 | **156,3** |
| Rust, Vec | loop | 1,605792 | 242,9 |
| Rust, Vec | fib | 0,123437 | 218,1 |
| Rust, Vec | alloc | 0,250576 | 143,7 |

### Runner compartilhado não é linha de base

Os dois runners executaram **binários idênticos** e deram 631,5 e 410,7 Mops/s
no `loop`: **54 % de diferença**. A dispersão *dentro* de cada execução é
excelente (0,2 % e 0,5 %), mas *entre* execuções não existe comparabilidade,
porque o modelo de CPU muda.

Consequência prática: o job de benchmark do CI serve para detectar que o
harness ainda roda, não para comparar commits. É por isso que ele mede e
**não** falha por regressão. Quem quiser comparar duas versões tem de rodar as
duas na mesma máquina, na mesma sessão — o que o `run_bench.sh` já força, por
receber vários binários e intercalar as execuções.

### Consolidado das três máquinas

Ganho do computed goto sobre o `switch`, mesma origem de código:

| programa | i5-8250U | runner #1 | runner #2 | reproduz? |
|---|---|---|---|---|
| `loop` | **+11,8 %** | **−10,3 %** | **+3,1 %** | ❌ o sinal muda |
| `fib(30)` | +6,0 % | −0,7 % | +6,3 % | 🟡 positivo em 2 de 3 |
| `alloc` | +2,8 % | +2,8 % | +4,1 % | ✅ +3–4 % nas três |

Rust seguro contra o `switch` do C, na mesma máquina:

| programa | i5-8250U | runner #2 | reproduz? |
|---|---|---|---|
| `loop` | −46,5 % | −40,9 % | ✅ 41–47 % |
| `fib(30)` | −53,1 % | −45,5 % | ✅ 45–53 % |
| `alloc` | +3,7 % | −4,3 % | ❌ empate, ±5 % |

**O que o projeto pode afirmar:**

1. O custo do Rust seguro no dispatch é de 41–47 %, e em código com muita
   chamada 45–53 %. Dois hardwares, mesma ordem de grandeza.
2. O computed goto rende 3–4 % quando a carga é dominada por alocação.
3. **No laço apertado, o efeito do computed goto não está determinado.** Varia
   de −10 % a +12 % conforme a CPU.
4. A arena com handles do Rust **empata** com `malloc`/`free` por objeto; a
   afirmação anterior de que ganhava valia para uma máquina só.

**O que não pode:** publicar um número único para o ganho do computed goto. A
pergunta original do projeto — "quanto se ganha?" — tem como resposta medida
"depende da CPU, e menos do que o folclore diz".

### Histórico das conclusões

| versão | base | conclusão sobre o `loop` |
|---|---|---|
| v1 | i5-8250U, 3 sessões | +11,8 %, "confiável porque o mínimo variou 0,3 %" |
| v2 | + runner #1 | −10,3 %, "e esta é a medição confiável" |
| v3 | + runner #2 | **não determinado**, −10 % a +12 % |

As três estão no `git log`. Nenhuma correção veio de mudança de opinião: cada
uma veio de uma máquina nova. O erro da v1 não foi a medição — foi apresentar
uma máquina como se fosse o mundo. O da v2 foi repetir o mesmo erro com uma
máquina mais limpa.

## Reprodução independente (no notebook)

Sessão posterior, depois de `cargo fmt` e das correções do `clippy` (nenhuma
delas no caminho quente), com `load average 1,17`:

| configuração | `loop` | `fib(30)` | `alloc` |
|---|---|---|---|
| C, computed goto | 434,7 | 369,2 | 121,8 |
| C, switch | 393,9 | 324,3 | 116,6 |
| Rust, boxed | 220,3 | 173,4 | **126,1** |
| Rust, Vec | 205,9 | 164,6 | 123,7 |

Todos os valores caem dentro de 1–8 % das tabelas acima, **com a ordenação
preservada em todas as três cargas**, incluindo a inversão no `alloc`. É o que
dá confiança nas conclusões apesar da dispersão por execução.

## Paridade de contabilidade do GC

As duas implementações, rodando `bench/alloc.fasm`:

```
C (computed goto):  coletas: 1831  bytes liberados: 479868480  pico: 262080
Rust (boxed):       coletas: 1831  bytes liberados: 479868480  pico: 262080
```

Idênticos nos três números. Não é coincidência: `rust/src/gc.rs` usa
deliberadamente a **fórmula de bytes do layout C** (`32 + len * 16`) em vez do
`size_of` real das structs Rust, para que as duas disparem coletas nos mesmos
pontos. Sem isso, o layout menor do Rust daria menos coletas e uma vantagem
que não teria nada a ver com desempenho.

> **480 MB de lixo reciclados mantendo o heap vivo em 256 KB**, nas duas
> implementações.

E o contrateste, `tests/cases/gc_live.fasm` (100 arrays alcançáveis, `GC`
forçado): `coletas: 1, bytes liberados: 0`. Zero bytes é o resultado correto —
nada do que estava alcançável foi coletado. Um GC que libera 1 byte aqui está
errado, e o teste falha.

## A hipótese que a medição refutou (duas vezes)

Vale registrar porque é o método em funcionamento, não a conclusão.

**Hipótese:** trocar a pilha de `Vec<Value>` por `Box<[Value]>` + `sp`
explícito deixaria o Rust próximo do C, porque o `Vec` pode realocar e obriga
o compilador a reler o ponteiro base.

**Primeira medição (sessões diferentes):** `boxed` apareceu 30 % **mais
lento** (162 contra 230 Mops/s). Conclusão aparente: hipótese errada, o teste
de limite do slice custa mais do que o `Vec` economiza.

**Segunda medição (mesma sessão, lado a lado):** `boxed` ficou 5 % mais
rápido, consistentemente, em três rodadas.

**O que estava errado era a primeira comparação**, não a hipótese: números de
sessões diferentes não são comparáveis nesta máquina. O efeito real existe mas
é pequeno (~5 %), muito menor que os 40 % que a primeira leitura sugeria em
qualquer das direções.

A consequência de engenharia foi manter **as duas** implementações atrás da
mesma interface (`rust/src/stack.rs`, feature `boxed-stack`), para que a
comparação seja reproduzível por qualquer pessoa, numa sessão só.

## Por que o Rust seguro perdeu ~44 % no dispatch

Hipóteses, em ordem de suspeita, **não medidas individualmente** — separá-las
exige `perf` contando ciclos e *branch misses*, que é o próximo item do
roadmap. Listadas para que ninguém confunda hipótese com resultado:

1. **Teste de limite por indexação.** Cada leitura de bytecode (`code.get(ip)`,
   `code[ip..ip+8]`) e cada acesso à pilha carrega uma verificação que o C não
   paga. O compilador não consegue eliminá-la porque não sabe que
   `stack.len() == STACK_MAX`.
2. **Propagação de erro com `?`.** Cada operação devolve `Result`, e o `?`
   insere um desvio após cada chamada auxiliar. Em C, o erro é um `return`
   direto de dentro do macro.
3. **Ausência de computed goto.** O C tem essa variante; o Rust seguro não tem
   equivalente. Mas como a variante só ganha em parte do hardware (ver acima),
   isso deixou de ser desvantagem relevante do Rust: a comparação justa sempre
   foi contra o `switch`, e é dela que vêm os ~44 %.

O que **não** foi tentado, e provavelmente fecharia parte da diferença, sem
`unsafe`: manter `ip` como iterador em vez de índice, usar `chunks_exact` para
os operandos, e trocar `Result<_, String>` por um enum de erro sem alocação.
Afirmar "Rust é 44 % mais lento" sem essas tentativas seria desonesto — o
medido é **esta** implementação em Rust seguro contra **esta** em C.

Fechar o resto exigiria `get_unchecked`, isto é, `unsafe` — e aí se perde a
propriedade pela qual se escolheu Rust. Esse é o trade-off que o projeto mede.

## Compilação e tamanho

| | C (gcc, CMake) | Rust (cargo) |
|---|---|---|
| configure (uma vez) | 8,67 s | — |
| build limpo | 2,33 s | 7,52 s |
| rebuild de 1 arquivo | 3,15 s | 7,46 s |
| binário | 34.672 bytes | 619.616 bytes (488.280 com `strip`) |

Dois pontos:

- **O Rust não tem rebuild incremental útil aqui.** A unidade de compilação é
  a crate inteira: tocar um arquivo recompila tudo (7,46 s contra 7,52 s do
  build limpo). Em C, cada `.c` é uma unidade independente — mas com só 5
  arquivos e `-j`, o ganho prático também desaparece (3,15 s contra 2,33 s).
  A diferença aparece em projetos grandes, nas duas direções.
- **O binário Rust é 18× maior** porque linka estaticamente a biblioteca padrão,
  incluindo formatação, *backtrace* e maquinário de pânico. `opt-level="z"`,
  `panic="abort"` e `strip` reduziriam muito; não foram usados porque mudariam
  o código gerado e invalidariam a comparação de desempenho.

## Linhas de código

Contagem sem comentários, linhas vazias nem módulos de teste:

| | C | Rust |
|---|---|---|
| total do projeto | 1.158 | 1.205 |
| descontando a segunda implementação de pilha (sem equivalente em C) | 1.158 | **1.053** |

Rust escreveu **9 % menos código** para a mesma funcionalidade — com todos os
erros tratados como valores, zero `unsafe` e uma camada extra de abstração na
pilha. O enum `Value` substitui a dupla `struct`+`union` manual do C, o
`Result` substitui a convenção de código de retorno, e o `Vec` substitui as
rotinas de crescimento de buffer escritas à mão em `value.c`.

## Throughput em perspectiva

Comparar com CPython, Lua ou LuaJIT exigiria rodar os três na **mesma**
máquina, com programas equivalentes. Qualquer número citado de memória aqui
seria chute, e chute em README de benchmark é pior que silêncio. Essa
comparação está no roadmap como item próprio.

O que separa esta VM de um interpretador de produção são três técnicas que ela
ainda não usa:

1. **NaN boxing** — valores de 8 bytes em vez de 16, teste de tipo por expoente;
2. **superinstruções** para pares frequentes (`LOAD`+`PUSH`+`ADD`);
3. **cache do topo da pilha em registrador**, evitando ida e volta à memória.
