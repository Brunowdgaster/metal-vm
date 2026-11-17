/* fvm.s — o laço de despacho da Forge VM em Assembly RISC-V 64 (RV64GC).
 *
 *     riscv64-linux-gnu-as -o fvm.o ports/asm/riscv64/fvm.s
 *     riscv64-linux-gnu-ld -o fvm_riscv64 fvm.o
 *     qemu-riscv64 ./fvm_riscv64 programa.fbc
 *
 * ## A terceira arquitetura, o mesmo subconjunto
 *
 * Executa o que os portes x86-64 e ARM64 executam, com a mesma saída byte a
 * byte. Comparar os três arquivos é o conteúdo deste diretório.
 *
 * ## A diferença que define o RISC-V: não há registrador de condição
 *
 * O x86-64 tem FLAGS, e o ARM64 tem NZCV. Uma comparação escreve ali, e o
 * salto ou o `setcc`/`cset` lê.
 *
 * **O RISC-V não tem nenhum dos dois.** Comparar é uma instrução que escreve
 * 0 ou 1 num registrador comum (`slt`, "set if less than"), e saltar é uma
 * instrução que compara dois registradores diretamente (`beq`, `blt`, ...).
 *
 * A consequência é visível nos opcodes de comparação:
 *
 *     x86-64   cmp + setcc + movzx     três instruções
 *     ARM64    cmp + cset              duas
 *     RISC-V   slt                     uma, para `<`
 *
 * E o preço aparece em `<=` e `>=`, que não têm instrução: são `slt` com os
 * operandos trocados mais um `xori` para inverter. O RISC-V escolheu ter
 * menos instruções e pagar nos casos derivados — que é a tese da arquitetura
 * inteira, visível em seis linhas.
 *
 * ## As outras três diferenças
 *
 * **Não há pós-indexação.** `ldrb w9, [x19], #1` do ARM64 lê e incrementa numa
 * instrução; aqui são `lbu` e `addi`, duas. Carregar e modificar o ponteiro
 * são operações distintas, e o RISC-V não as funde.
 *
 * **O endereço de um rótulo é `la`**, uma pseudo-instrução que o montador
 * expande para `auipc`+`addi` — o mesmo par de duas metades do `adrp`+`add` do
 * ARM64, com nome melhor.
 *
 * **`ecall` em vez de `svc`**, com o número em `a7`. A tabela de syscalls é a
 * mesma "genérica" do ARM64: `openat` 56, `read` 63, `write` 64, `exit` 93 —
 * e também aqui **não existe `open`**.
 *
 * ## A disciplina de registradores
 *
 * Declarada antes do código, como no porte ARM64, porque o porte x86-64 deu
 * segfault por não tê-la:
 *
 *     s1    ip        ponteiro de instrução
 *     s2    sp        topo da pilha de dados
 *     s3    base      início do código (arquivo + 12)
 *     s4    fim       fim do código
 *
 *     t0    opcode / endereço da tabela
 *     t1    operando do opcode corrente
 *     t2    a         primeiro operando da pilha
 *     t3    b         segundo
 *     t4    scratch
 *
 *     t6    RESERVADO às rotinas auxiliares
 *
 * `s1`–`s4` são *callee-saved* na ABI, e as auxiliares não os tocam. `t6`
 * existe para elas não precisarem de nenhum registrador que os opcodes usam.
 */

    .section .rodata
magic:
    .ascii "FVM1"
msg_uso:
    .ascii "uso: fvm_riscv64 <prog.fbc>\n"
    .equ len_uso, . - msg_uso
msg_abrir:
    .ascii "erro: nao consegui abrir o arquivo\n"
    .equ len_abrir, . - msg_abrir
msg_magic:
    .ascii "erro: magic invalido\n"
    .equ len_magic, . - msg_magic
msg_opcode:
    .ascii "erro: opcode nao suportado neste porte\n"
    .equ len_opcode, . - msg_opcode
msg_pilha:
    .ascii "erro: pilha vazia\n"
    .equ len_pilha, . - msg_pilha
msg_div0:
    .ascii "erro: divisao por zero\n"
    .equ len_div0, . - msg_div0

    .align 3
tabela:
    .quad op_halt, op_push, op_pop, op_dup, op_swap
    .quad op_add, op_sub, op_mul, op_div, op_mod, op_neg
    .quad op_lt, op_le, op_gt, op_ge, op_eq, op_ne
    .quad op_jmp, op_jz, op_jnz
    .quad op_load, op_store, op_reserve
    .quad op_nao_suportado          /* CALL   */
    .quad op_nao_suportado          /* RET    */
    .quad op_print
    .quad op_nao_suportado          /* NEWARR */
    .quad op_nao_suportado          /* AGET   */
    .quad op_nao_suportado          /* ASET   */
    .quad op_nao_suportado          /* ALEN   */
    .quad op_nao_suportado          /* GC     */
    .quad op_nao_suportado          /* CALLI  */

    .section .bss
    .align 4
    .equ TAM_ARQ, 1 << 20
arquivo:
    .skip TAM_ARQ

    .equ PILHA_MAX, 1 << 16
pilha:
    .skip PILHA_MAX * 8

buf_num:
    .skip 32

    .section .text
    .global _start

/* ---------------------------------------------------------------------------
 * O despacho, replicado em cada opcode.
 *
 * Seis instruções, contra cinco no ARM64 e quatro no x86-64 -- e a diferença é
 * exatamente a falta de pós-indexação e de salto indireto com índice
 * escalado.
 *
 * Replicá-lo em cada opcode é o que dá ao preditor uma entrada por instrução
 * da VM, que é o equivalente do `computed goto` do C.
 * --------------------------------------------------------------------------- */
.macro PROXIMO
    bgeu    s1, s4, erro_opcode
    lbu     t0, 0(s1)
    addi    s1, s1, 1
    li      t4, 32
    bgeu    t0, t4, erro_opcode
    la      t5, tabela
    slli    t0, t0, 3
    add     t5, t5, t0
    ld      t5, 0(t5)
    jr      t5
.endm

_start:
    /* argc em 0(sp), argv[1] em 16(sp) */
    ld      a0, 0(sp)
    li      t0, 2
    bne     a0, t0, erro_uso
    ld      a1, 16(sp)              /* caminho */

    /* openat(AT_FDCWD, caminho, O_RDONLY, 0)
     *
     * Como no ARM64, não existe `open`: a tabela genérica de syscalls só tem
     * a forma com diretório de referência. `AT_FDCWD` é -100. */
    li      a0, -100
    li      a2, 0                   /* O_RDONLY */
    li      a3, 0
    li      a7, 56                  /* openat */
    ecall
    bltz    a0, erro_abrir
    mv      s5, a0                  /* fd */

    /* read(fd, arquivo, TAM_ARQ) */
    mv      a0, s5
    la      a1, arquivo
    li      a2, TAM_ARQ
    li      a7, 63                  /* read */
    ecall
    bltz    a0, erro_abrir
    mv      s6, a0                  /* bytes lidos */

    /* close(fd) */
    mv      a0, s5
    li      a7, 57
    ecall

    li      t0, 12
    bltu    s6, t0, erro_magic

    /* O magic, como u32. O RV64 do Linux é little-endian, e o formato também.
     * Como nos outros dois portes, a dependência de arquitetura é declarada:
     * um arquivo em Assembly roda numa arquitetura só, e pode contar com ela. */
    la      a1, arquivo
    lw      t0, 0(a1)
    la      t1, magic
    lw      t1, 0(t1)
    bne     t0, t1, erro_magic

    lw      s7, 4(a1)               /* entry */
    lw      s8, 8(a1)               /* len   */

    addi    s3, a1, 12              /* base do código */
    add     s1, s3, s7              /* ip = base + entry */
    add     s4, s3, s8              /* fim do código */

    la      s2, pilha               /* sp */

    PROXIMO

/* --------------------------------------------------------------------------- */

op_halt:
    li      a0, 0
    j       sair

op_push:
    ld      t1, 0(s1)               /* i64 LE */
    addi    s1, s1, 8
    sd      t1, 0(s2)
    addi    s2, s2, 8
    PROXIMO

op_pop:
    call    checa1
    addi    s2, s2, -8
    PROXIMO

op_dup:
    call    checa1
    ld      t2, -8(s2)
    sd      t2, 0(s2)
    addi    s2, s2, 8
    PROXIMO

op_swap:
    call    checa2
    ld      t2, -8(s2)
    ld      t3, -16(s2)
    sd      t2, -16(s2)
    sd      t3, -8(s2)
    PROXIMO

/* `BINOP instr` — desempilha dois, aplica, empilha um. */
.macro BINOP instr
    call    checa2
    addi    s2, s2, -8
    ld      t2, -8(s2)
    ld      t3, 0(s2)
    \instr  t2, t2, t3
    sd      t2, -8(s2)
    PROXIMO
.endm

op_add: BINOP add
op_sub: BINOP sub
op_mul: BINOP mul

/* `div` e `rem` existem no RV64M, as duas -- ao contrário do ARM64, que tem
 * `sdiv` e precisa de `msub` para o resto. Aqui o conjunto base de
 * multiplicação já traz as quatro operações. */
op_div:
    call    checa2
    addi    s2, s2, -8
    ld      t3, 0(s2)
    beqz    t3, erro_div0
    ld      t2, -8(s2)
    div     t2, t2, t3
    sd      t2, -8(s2)
    PROXIMO

op_mod:
    call    checa2
    addi    s2, s2, -8
    ld      t3, 0(s2)
    beqz    t3, erro_div0
    ld      t2, -8(s2)
    rem     t2, t2, t3
    sd      t2, -8(s2)
    PROXIMO

op_neg:
    call    checa1
    ld      t2, -8(s2)
    neg     t2, t2
    sd      t2, -8(s2)
    PROXIMO

/* As comparações, e a tese do RISC-V em seis linhas.
 *
 * `slt rd, a, b` escreve 1 se a < b, e é UMA instrução -- menos que as três
 * do x86-64 e as duas do ARM64.
 *
 * `<=` e `>=` NÃO têm instrução: são `slt` com os operandos trocados mais um
 * `xori` para inverter. O RISC-V escolheu ter menos instruções e pagar nos
 * casos derivados, e é exatamente isso que se vê aqui. */
op_lt:
    call    checa2
    addi    s2, s2, -8
    ld      t2, -8(s2)
    ld      t3, 0(s2)
    slt     t2, t2, t3
    sd      t2, -8(s2)
    PROXIMO

op_le:
    call    checa2
    addi    s2, s2, -8
    ld      t2, -8(s2)
    ld      t3, 0(s2)
    slt     t2, t3, t2              /* b < a  */
    xori    t2, t2, 1               /* logo a <= b */
    sd      t2, -8(s2)
    PROXIMO

op_gt:
    call    checa2
    addi    s2, s2, -8
    ld      t2, -8(s2)
    ld      t3, 0(s2)
    slt     t2, t3, t2
    sd      t2, -8(s2)
    PROXIMO

op_ge:
    call    checa2
    addi    s2, s2, -8
    ld      t2, -8(s2)
    ld      t3, 0(s2)
    slt     t2, t2, t3
    xori    t2, t2, 1
    sd      t2, -8(s2)
    PROXIMO

op_eq:
    call    checa2
    addi    s2, s2, -8
    ld      t2, -8(s2)
    ld      t3, 0(s2)
    sub     t2, t2, t3
    seqz    t2, t2
    sd      t2, -8(s2)
    PROXIMO

op_ne:
    call    checa2
    addi    s2, s2, -8
    ld      t2, -8(s2)
    ld      t3, 0(s2)
    sub     t2, t2, t3
    snez    t2, t2
    sd      t2, -8(s2)
    PROXIMO

op_jmp:
    lw      t1, 0(s1)               /* destino absoluto, i32 LE */
    add     s1, s3, t1
    PROXIMO

op_jz:
    lw      t1, 0(s1)
    addi    s1, s1, 4
    call    checa1
    addi    s2, s2, -8
    ld      t2, 0(s2)
    bnez    t2, 1f
    add     s1, s3, t1
1:  PROXIMO

op_jnz:
    lw      t1, 0(s1)
    addi    s1, s1, 4
    call    checa1
    addi    s2, s2, -8
    ld      t2, 0(s2)
    beqz    t2, 1f
    add     s1, s3, t1
1:  PROXIMO

/* LOAD e STORE no frame raiz: `base` é zero, porque este porte não implementa
 * CALL. E não há endereçamento com índice escalado -- o deslocamento é
 * calculado com `slli` e `add`, duas instruções onde o x86-64 usa uma. */
op_load:
    lw      t1, 0(s1)
    addi    s1, s1, 4
    la      t4, pilha
    slli    t1, t1, 3
    add     t4, t4, t1
    ld      t2, 0(t4)
    sd      t2, 0(s2)
    addi    s2, s2, 8
    PROXIMO

op_store:
    lw      t1, 0(s1)
    addi    s1, s1, 4
    call    checa1
    addi    s2, s2, -8
    ld      t2, 0(s2)
    la      t4, pilha
    slli    t1, t1, 3
    add     t4, t4, t1
    sd      t2, 0(t4)
    PROXIMO

op_reserve:
    lw      t1, 0(s1)
    addi    s1, s1, 4
    blez    t1, 2f
1:  sd      zero, 0(s2)
    addi    s2, s2, 8
    addi    t1, t1, -1
    bnez    t1, 1b
2:  PROXIMO

op_print:
    call    checa1
    addi    s2, s2, -8
    ld      a0, 0(s2)
    call    escreve_i64
    PROXIMO

op_nao_suportado:
    j       erro_opcode

/* ---------------------------------------------------------------------------
 * As auxiliares usam SÓ t6, por regra -- a mesma disciplina do porte ARM64, e
 * a correção do bug que o x86-64 teve.
 *
 * `call` em RISC-V escreve o retorno em `ra`, então estas rotinas não podem
 * chamar nada sem salvá-lo. Nenhuma chama.
 * --------------------------------------------------------------------------- */
checa1:
    la      t6, pilha
    bleu    s2, t6, erro_pilha
    ret

checa2:
    la      t6, pilha
    addi    t6, t6, 8
    bleu    s2, t6, erro_pilha
    ret

/* ---------------------------------------------------------------------------
 * escreve_i64: o inteiro em a0, em decimal, seguido de \n.
 *
 * `ra` é salvo na pilha de hardware porque esta rotina é chamada de dentro de
 * um opcode, e um `call` interno o sobrescreveria. Não há `call` interno hoje;
 * o salvamento está aqui porque acrescentar um depois é o tipo de mudança que
 * ninguém revisa.
 * --------------------------------------------------------------------------- */
escreve_i64:
    addi    sp, sp, -16
    sd      ra, 8(sp)

    la      a1, buf_num
    addi    a1, a1, 31
    li      t0, 10                  /* \n */
    sb      t0, 0(a1)
    addi    a1, a1, -1

    li      t1, 0                   /* 1 se negativo */
    mv      t2, a0
    bgez    t2, 1f
    li      t1, 1
    neg     t2, t2                  /* para INT64_MIN isto envolve, e a
                                     * divisão SEM sinal abaixo trata a
                                     * magnitude certa */
1:
    li      t3, 10
2:
    divu    t4, t2, t3              /* SEM sinal, pelo motivo acima */
    remu    t5, t2, t3
    addi    t5, t5, 48              /* '0' */
    sb      t5, 0(a1)
    addi    a1, a1, -1
    mv      t2, t4
    bnez    t2, 2b

    beqz    t1, 3f
    li      t0, 45                  /* '-' */
    sb      t0, 0(a1)
    addi    a1, a1, -1
3:
    addi    a1, a1, 1               /* primeiro caractere */

    la      a2, buf_num
    addi    a2, a2, 32
    sub     a2, a2, a1              /* tamanho */

    li      a0, 1                   /* stdout */
    li      a7, 64                  /* write */
    ecall

    ld      ra, 8(sp)
    addi    sp, sp, 16
    ret

/* --------------------------------------------------------------------------- */

.macro ERRO rotulo, msg, tam, codigo
\rotulo:
    li      a0, 2                   /* stderr */
    la      a1, \msg
    li      a2, \tam
    li      a7, 64                  /* write */
    ecall
    li      a0, \codigo
    j       sair
.endm

ERRO erro_uso,    msg_uso,    len_uso,    64
ERRO erro_abrir,  msg_abrir,  len_abrir,  66
ERRO erro_magic,  msg_magic,  len_magic,  65
ERRO erro_opcode, msg_opcode, len_opcode, 70
ERRO erro_pilha,  msg_pilha,  len_pilha,  70
ERRO erro_div0,   msg_div0,   len_div0,   70

sair:
    li      a7, 93                  /* exit */
    ecall

    .section .note.GNU-stack,"",%progbits
