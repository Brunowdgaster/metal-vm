/* vm.c — o loop de execução.
 *
 * O arquivo existe para responder a uma pergunta medível: quanto custa o
 * *dispatch* de uma instrução? Por isso o mesmo corpo de instruções é
 * compilado de duas formas, escolhidas em tempo de compilação:
 *
 *   switch (default)        — portável, funciona no MSVC;
 *   computed goto (-DFVM_USE_GOTO) — uma tabela de rótulos; cada instrução
 *                             salta direto para a próxima, o que dá ao
 *                             preditor de saltos um alvo por opcode em vez
 *                             de um único salto indireto compartilhado.
 *
 * Os três macros VM_BEGIN / VM_CASE / VM_NEXT escondem a diferença, de modo
 * que o corpo das instruções é escrito UMA vez. Sem isso, as duas variantes
 * divergiriam na primeira correção de bug — foi exatamente o que aconteceu
 * na primeira tentativa deste projeto.
 *
 * computed goto é uma extensão GNU: só compila em GCC e Clang.
 */
#include "fvm.h"

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#if defined(FVM_USE_GOTO) && !defined(__GNUC__)
#  error "FVM_USE_GOTO exige GCC ou Clang (computed goto e extensao GNU)"
#endif

/* ------------------------------------------------------- leitura do código */
static inline int32_t rd_i32(const uint8_t *p) { int32_t v; memcpy(&v, p, 4); return v; }
static inline int64_t rd_i64(const uint8_t *p) { int64_t v; memcpy(&v, p, 8); return v; }

#define READ_U8()  (*ip++)
#define READ_I32() (ip += 4, rd_i32(ip - 4))
#define READ_I64() (ip += 8, rd_i64(ip - 8))

/* ------------------------------------------------------------------- pilha */
/* O valor é avaliado para um temporário ANTES de vm->sp ser incrementado.
 * A versão ingênua, `vm->stack[vm->sp++] = (v)`, é comportamento indefinido
 * sempre que `v` também lê vm->sp — exatamente o caso de PUSH(PEEK(0)) no
 * DUP: ler e modificar o mesmo objeto entre dois pontos de sequência.
 * O gcc aponta isso com -Wsequence-point; o MSVC compila calado. Foi o
 * segundo bug real do projeto e a razão de o CI rodar os dois compiladores. */
#define PUSH(v)                                                  \
    do {                                                         \
        Value tmp_ = (v);                                        \
        if (vm->sp >= FVM_STACK_MAX) return vm_err(vm, ip, "estouro da pilha de operandos"); \
        vm->stack[vm->sp++] = tmp_;                              \
    } while (0)

#define POP()   (vm->stack[--vm->sp])
#define PEEK(n) (vm->stack[vm->sp - 1 - (n)])

#define NEED(n)                                                  \
    do {                                                         \
        if (vm->sp < (n)) return vm_err(vm, ip, "pilha insuficiente"); \
    } while (0)

#ifdef FVM_STATS
#  define COUNT() (vm->ins_count++)
#else
#  define COUNT() ((void)0)
#endif

/* --------------------------------------------------------------- erros */
static VMResult vm_err(VM *vm, const uint8_t *ip, const char *msg)
{
    size_t at = vm->chunk && ip ? (size_t)(ip - vm->chunk->code) : 0;
    fprintf(stderr, "fvm: erro em tempo de execucao @%06zu: %s\n", at, msg);
    return FVM_ERR_RUNTIME;
}

static void trace_one(const VM *vm, const uint8_t *ip)
{
    const OpInfo *tbl = fvm_op_table();
    uint8_t op = *ip;
    fprintf(stderr, "[%06zu] %-8s sp=%d fp=%d\n",
            (size_t)(ip - vm->chunk->code),
            op < OP__COUNT ? tbl[op].name : "???",
            vm->sp, vm->fp);
}

/* ------------------------------------------------------- ciclo de vida da VM */
void vm_init(VM *vm, FILE *out)
{
    memset(vm, 0, sizeof *vm);
    vm->next_gc = 256u * 1024u;
    vm->out = out ? out : stdout;
}

void vm_free(VM *vm)
{
    gc_free_all(vm);
}

/* ------------------------------------------------------- macros de dispatch */
#ifdef FVM_USE_GOTO
#  define VM_DISPATCH()                                                   \
      do {                                                                \
          COUNT();                                                         \
          if (vm->trace) trace_one(vm, ip);                                \
          goto *dtable[*ip++];                                             \
      } while (0)
#  define VM_BEGIN   VM_DISPATCH();
#  define VM_CASE(o) L_##o:
#  define VM_NEXT()  VM_DISPATCH()
#  define VM_END
#else
#  define VM_BEGIN                                                        \
      for (;;) {                                                           \
          COUNT();                                                         \
          if (vm->trace) trace_one(vm, ip);                                \
          switch (READ_U8()) {
#  define VM_CASE(o) case o:
#  define VM_NEXT()  break
#  define VM_END                                                          \
          default:                                                         \
              return vm_err(vm, ip, "opcode invalido");                    \
          }                                                                \
      }
#endif

/* Operações binárias de inteiro. O teste de tipo é o preço de ter valores
 * tagueados; a alternativa (NaN boxing) está listada no README como a
 * otimização seguinte. */
#define BINOP_INT(expr)                                                    \
    do {                                                                   \
        NEED(2);                                                           \
        Value b = POP(); Value a = POP();                                  \
        if (!IS_INT(a) || !IS_INT(b))                                      \
            return vm_err(vm, ip, "operando nao inteiro em operacao aritmetica"); \
        int64_t x = AS_INT(a), y = AS_INT(b); (void)x; (void)y;             \
        PUSH(INT_VAL(expr));                                               \
    } while (0)

/* computed goto é extensão GNU: `&&rotulo` e `goto *expr` violam o ISO C, e
 * -Wpedantic reclama de cada ocorrência. O aviso é correto e esperado, então
 * é silenciado aqui — de forma localizada, não no CMakeLists, para que o
 * resto do arquivo continue sob -Wpedantic. */
#ifdef FVM_USE_GOTO
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wpedantic"
#endif

VMResult vm_run(VM *vm, Chunk *chunk)
{
    vm->chunk = chunk;
    if (chunk->len == 0) return FVM_HALT;
    if (chunk->entry >= chunk->len) return vm_err(vm, NULL, "entry fora do codigo");

    uint8_t *ip = chunk->code + chunk->entry;

    /* Frame raiz: faz com que LOAD/STORE e RET funcionem no nível de topo sem
     * nenhum caso especial no loop quente. */
    vm->fp = 0;
    vm->frames[vm->fp].ret_ip = NULL;
    vm->frames[vm->fp].base = 0;
    vm->fp = 1;
    int base = 0;

#ifdef FVM_USE_GOTO
    /* A ordem desta tabela TEM de seguir o enum Op. */
    static void *const dtable[OP__COUNT] = {
        &&L_OP_HALT, &&L_OP_PUSH, &&L_OP_POP, &&L_OP_DUP, &&L_OP_SWAP,
        &&L_OP_ADD, &&L_OP_SUB, &&L_OP_MUL, &&L_OP_DIV, &&L_OP_MOD, &&L_OP_NEG,
        &&L_OP_LT, &&L_OP_LE, &&L_OP_GT, &&L_OP_GE, &&L_OP_EQ, &&L_OP_NE,
        &&L_OP_JMP, &&L_OP_JZ, &&L_OP_JNZ,
        &&L_OP_LOAD, &&L_OP_STORE, &&L_OP_RESERVE,
        &&L_OP_CALL, &&L_OP_RET, &&L_OP_PRINT,
        &&L_OP_NEWARR, &&L_OP_AGET, &&L_OP_ASET, &&L_OP_ALEN, &&L_OP_GC,
    };
#endif

    VM_BEGIN

    VM_CASE(OP_HALT)
        return FVM_HALT;

    VM_CASE(OP_PUSH)
        PUSH(INT_VAL(READ_I64()));
        VM_NEXT();

    VM_CASE(OP_POP)
        NEED(1);
        vm->sp--;
        VM_NEXT();

    VM_CASE(OP_DUP)
        NEED(1);
        PUSH(PEEK(0));
        VM_NEXT();

    VM_CASE(OP_SWAP) {
        NEED(2);
        Value t = PEEK(0);
        PEEK(0) = PEEK(1);
        PEEK(1) = t;
        VM_NEXT();
    }

    VM_CASE(OP_ADD) BINOP_INT(x + y); VM_NEXT();
    VM_CASE(OP_SUB) BINOP_INT(x - y); VM_NEXT();
    VM_CASE(OP_MUL) BINOP_INT(x * y); VM_NEXT();

    VM_CASE(OP_DIV) {
        NEED(2);
        Value b = POP(), a = POP();
        if (!IS_INT(a) || !IS_INT(b)) return vm_err(vm, ip, "DIV com operando nao inteiro");
        if (AS_INT(b) == 0) return vm_err(vm, ip, "divisao por zero");
        PUSH(INT_VAL(AS_INT(a) / AS_INT(b)));
        VM_NEXT();
    }

    VM_CASE(OP_MOD) {
        NEED(2);
        Value b = POP(), a = POP();
        if (!IS_INT(a) || !IS_INT(b)) return vm_err(vm, ip, "MOD com operando nao inteiro");
        if (AS_INT(b) == 0) return vm_err(vm, ip, "modulo por zero");
        PUSH(INT_VAL(AS_INT(a) % AS_INT(b)));
        VM_NEXT();
    }

    VM_CASE(OP_NEG) {
        NEED(1);
        Value a = POP();
        if (!IS_INT(a)) return vm_err(vm, ip, "NEG com operando nao inteiro");
        PUSH(INT_VAL(-AS_INT(a)));
        VM_NEXT();
    }

    VM_CASE(OP_LT) BINOP_INT(x <  y ? 1 : 0); VM_NEXT();
    VM_CASE(OP_LE) BINOP_INT(x <= y ? 1 : 0); VM_NEXT();
    VM_CASE(OP_GT) BINOP_INT(x >  y ? 1 : 0); VM_NEXT();
    VM_CASE(OP_GE) BINOP_INT(x >= y ? 1 : 0); VM_NEXT();

    VM_CASE(OP_EQ) {
        NEED(2);
        Value b = POP(), a = POP();
        PUSH(INT_VAL(value_equal(a, b) ? 1 : 0));
        VM_NEXT();
    }

    VM_CASE(OP_NE) {
        NEED(2);
        Value b = POP(), a = POP();
        PUSH(INT_VAL(value_equal(a, b) ? 0 : 1));
        VM_NEXT();
    }

    VM_CASE(OP_JMP) {
        int32_t t = READ_I32();
        if (t < 0 || (size_t)t >= chunk->len) return vm_err(vm, ip, "JMP fora do codigo");
        ip = chunk->code + t;
        VM_NEXT();
    }

    VM_CASE(OP_JZ) {
        int32_t t = READ_I32();
        NEED(1);
        Value c = POP();
        if (IS_INT(c) && AS_INT(c) == 0) {
            if (t < 0 || (size_t)t >= chunk->len) return vm_err(vm, ip, "JZ fora do codigo");
            ip = chunk->code + t;
        }
        VM_NEXT();
    }

    VM_CASE(OP_JNZ) {
        int32_t t = READ_I32();
        NEED(1);
        Value c = POP();
        int truthy = !(IS_INT(c) && AS_INT(c) == 0);
        if (truthy) {
            if (t < 0 || (size_t)t >= chunk->len) return vm_err(vm, ip, "JNZ fora do codigo");
            ip = chunk->code + t;
        }
        VM_NEXT();
    }

    VM_CASE(OP_LOAD) {
        int32_t slot = READ_I32();
        int idx = base + slot;
        if (slot < 0 || idx >= vm->sp) return vm_err(vm, ip, "LOAD de slot inexistente");
        PUSH(vm->stack[idx]);
        VM_NEXT();
    }

    VM_CASE(OP_STORE) {
        int32_t slot = READ_I32();
        int idx = base + slot;
        NEED(1);
        if (slot < 0 || idx >= vm->sp) return vm_err(vm, ip, "STORE em slot inexistente");
        vm->stack[idx] = POP();
        VM_NEXT();
    }

    VM_CASE(OP_RESERVE) {
        int32_t n = READ_I32();
        if (n < 0) return vm_err(vm, ip, "RESERVE negativo");
        for (int32_t i = 0; i < n; i++) PUSH(INT_VAL(0));
        VM_NEXT();
    }

    VM_CASE(OP_CALL) {
        int32_t target = READ_I32();
        uint8_t nargs = READ_U8();
        if (target < 0 || (size_t)target >= chunk->len)
            return vm_err(vm, ip, "CALL para endereco invalido");
        if (vm->sp < nargs) return vm_err(vm, ip, "CALL sem argumentos suficientes");
        if (vm->fp >= FVM_FRAMES_MAX) return vm_err(vm, ip, "estouro da pilha de chamadas");

        vm->frames[vm->fp].ret_ip = ip;
        vm->frames[vm->fp].base = vm->sp - nargs;
        vm->fp++;
        base = vm->sp - nargs;
        ip = chunk->code + target;
        VM_NEXT();
    }

    VM_CASE(OP_RET) {
        NEED(1);
        Value v = POP();
        vm->fp--;
        Frame *f = &vm->frames[vm->fp];
        vm->sp = f->base;              /* descarta args e locais do frame */
        if (vm->fp == 0) {             /* RET no frame raiz encerra o programa */
            PUSH(v);
            return FVM_HALT;
        }
        PUSH(v);
        base = vm->frames[vm->fp - 1].base;
        ip = f->ret_ip;
        VM_NEXT();
    }

    VM_CASE(OP_PRINT) {
        NEED(1);
        value_print(vm->out, POP());
        fputc('\n', vm->out);
        VM_NEXT();
    }

    VM_CASE(OP_NEWARR) {
        NEED(1);
        Value n = POP();
        if (!IS_INT(n) || AS_INT(n) < 0) return vm_err(vm, ip, "NEWARR exige tamanho inteiro >= 0");
        ObjArray *a = gc_new_array(vm, (size_t)AS_INT(n));
        if (!a) return vm_err(vm, ip, "sem memoria para o array");
        PUSH(OBJ_VAL(a));
        VM_NEXT();
    }

    VM_CASE(OP_AGET) {
        NEED(2);
        Value iv = POP(), av = POP();
        if (!IS_OBJ(av) || AS_OBJ(av)->type != OBJ_ARRAY) return vm_err(vm, ip, "AGET sem array");
        if (!IS_INT(iv)) return vm_err(vm, ip, "AGET com indice nao inteiro");
        ObjArray *a = (ObjArray *)AS_OBJ(av);
        int64_t i = AS_INT(iv);
        if (i < 0 || (size_t)i >= a->len) return vm_err(vm, ip, "AGET fora dos limites");
        PUSH(a->items[i]);
        VM_NEXT();
    }

    VM_CASE(OP_ASET) {
        NEED(3);
        Value val = POP(), iv = POP(), av = POP();
        if (!IS_OBJ(av) || AS_OBJ(av)->type != OBJ_ARRAY) return vm_err(vm, ip, "ASET sem array");
        if (!IS_INT(iv)) return vm_err(vm, ip, "ASET com indice nao inteiro");
        ObjArray *a = (ObjArray *)AS_OBJ(av);
        int64_t i = AS_INT(iv);
        if (i < 0 || (size_t)i >= a->len) return vm_err(vm, ip, "ASET fora dos limites");
        a->items[i] = val;
        VM_NEXT();
    }

    VM_CASE(OP_ALEN) {
        NEED(1);
        Value av = POP();
        if (!IS_OBJ(av) || AS_OBJ(av)->type != OBJ_ARRAY) return vm_err(vm, ip, "ALEN sem array");
        PUSH(INT_VAL((int64_t)((ObjArray *)AS_OBJ(av))->len));
        VM_NEXT();
    }

    VM_CASE(OP_GC)
        gc_collect(vm);
        VM_NEXT();

    VM_END

#ifdef FVM_USE_GOTO
    return vm_err(vm, ip, "fim do codigo sem HALT");
#endif
}

#ifdef FVM_USE_GOTO
#  pragma GCC diagnostic pop
#endif
