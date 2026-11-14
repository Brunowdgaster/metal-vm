/* fvm.h — Forge VM: máquina virtual de pilha, implementação de referência em C.
 *
 * Este header é a fronteira pública entre os 5 módulos do projeto:
 *   value.c  - representação de valores e objetos
 *   gc.c     - coletor mark & sweep
 *   asm.c    - montador (texto .fasm -> bytecode) e desmontador
 *   vm.c     - loop de execução
 *   main.c   - CLI
 */
#ifndef FVM_H
#define FVM_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define FVM_VERSION "0.1.0"

#define FVM_STACK_MAX  65536
#define FVM_FRAMES_MAX 4096

/* ---------------------------------------------------------------- opcodes */
/* O conjunto é deliberadamente pequeno (31 instruções): o objetivo é comparar
 * estratégias de dispatch e de gerenciamento de memória, não ter um ISA rico. */
typedef enum {
    OP_HALT = 0,
    OP_PUSH,      /* i64 imediato                          */
    OP_POP,
    OP_DUP,
    OP_SWAP,
    OP_ADD,
    OP_SUB,
    OP_MUL,
    OP_DIV,
    OP_MOD,
    OP_NEG,
    OP_LT,
    OP_LE,
    OP_GT,
    OP_GE,
    OP_EQ,
    OP_NE,
    OP_JMP,       /* i32 endereço absoluto                 */
    OP_JZ,
    OP_JNZ,
    OP_LOAD,      /* i32 slot relativo à base do frame     */
    OP_STORE,
    OP_RESERVE,   /* i32 n — empurra n zeros (locais extra) */
    OP_CALL,      /* i32 endereço + u8 nargs               */
    OP_RET,
    OP_PRINT,
    OP_NEWARR,
    OP_AGET,
    OP_ASET,
    OP_ALEN,
    OP_GC,        /* força uma coleta (para testes)        */
    OP__COUNT
} Op;

/* Formato do operando de cada instrução. Usado pelo montador E pelo
 * desmontador — uma única fonte de verdade evita o clássico bug de
 * montador e desmontador discordarem. */
typedef enum {
    OPD_NONE = 0,
    OPD_I64,    /* imediato de 64 bits   */
    OPD_LABEL,  /* rótulo -> endereço i32 */
    OPD_SLOT,   /* índice i32            */
    OPD_CALL    /* rótulo i32 + nargs u8 */
} OperandKind;

typedef struct {
    const char *name;
    Op          op;
    OperandKind kind;
} OpInfo;

const OpInfo *fvm_op_table(void);   /* indexado por Op, tamanho OP__COUNT */
const OpInfo *fvm_op_lookup(const char *name);

/* ----------------------------------------------------------------- valores */
typedef enum { VAL_INT, VAL_OBJ } ValType;

typedef struct Obj Obj;

typedef struct {
    ValType t;
    union {
        int64_t i;
        Obj    *o;
    } as;
} Value;

#define INT_VAL(x)  ((Value){ VAL_INT, { .i = (int64_t)(x) } })
#define OBJ_VAL(p)  ((Value){ VAL_OBJ, { .o = (Obj *)(p) } })
#define IS_INT(v)   ((v).t == VAL_INT)
#define IS_OBJ(v)   ((v).t == VAL_OBJ)
#define AS_INT(v)   ((v).as.i)
#define AS_OBJ(v)   ((v).as.o)

typedef enum { OBJ_ARRAY } ObjType;

/* Cabeçalho comum a todo objeto do heap. `next` encadeia TODOS os objetos
 * vivos — é a lista que o sweep percorre. */
struct Obj {
    ObjType type;
    int     marked;
    Obj    *next;
};

typedef struct {
    Obj    header;
    size_t len;
    Value *items;
} ObjArray;

void value_print(FILE *out, Value v);
int  value_equal(Value a, Value b);

/* ---------------------------------------------------------------- bytecode */
typedef struct {
    uint8_t *code;
    size_t   len;
    size_t   cap;
    uint32_t entry;
} Chunk;

void chunk_init(Chunk *c);
void chunk_free(Chunk *c);
void chunk_write_u8(Chunk *c, uint8_t b);
void chunk_write_i32(Chunk *c, int32_t v);
void chunk_write_i64(Chunk *c, int64_t v);

/* ---------------------------------------------------------------------- VM */
typedef struct {
    uint8_t *ret_ip;
    int      base;   /* índice na pilha onde começam os locais deste frame */
} Frame;

typedef struct {
    Value    stack[FVM_STACK_MAX];
    int      sp;
    Frame    frames[FVM_FRAMES_MAX];
    int      fp;

    Chunk   *chunk;

    /* heap gerenciado */
    Obj     *objects;
    size_t   bytes_allocated;
    size_t   next_gc;

    /* instrumentação */
    uint64_t ins_count;
    uint64_t gc_runs;
    size_t   gc_bytes_freed;
    size_t   peak_bytes;

    int      trace;
    FILE    *out;
} VM;

typedef enum { FVM_OK = 0, FVM_HALT, FVM_ERR_RUNTIME } VMResult;

void     vm_init(VM *vm, FILE *out);
void     vm_free(VM *vm);
VMResult vm_run(VM *vm, Chunk *chunk);

/* ---------------------------------------------------------------------- GC */
ObjArray *gc_new_array(VM *vm, size_t len);
void      gc_collect(VM *vm);
void      gc_free_all(VM *vm);

/* -------------------------------------------------- montador/desmontador */
/* Retorna 1 em sucesso. Em erro, escreve a mensagem em stderr. */
int fvm_assemble(const char *source, const char *filename, Chunk *out);
int fvm_assemble_file(const char *path, Chunk *out);
void fvm_disassemble(FILE *out, const Chunk *c);

/* ------------------------------------------------------------- utilidades */
char  *fvm_read_file(const char *path, size_t *out_len);
int    fvm_chunk_save(const Chunk *c, const char *path);
int    fvm_chunk_load(Chunk *c, const char *path);
double fvm_now_sec(void);   /* relógio monotônico, em segundos */

#endif /* FVM_H */
