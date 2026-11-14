/* value.c — valores, chunk de bytecode, tabela de opcodes e utilidades de I/O. */
#include "fvm.h"

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#else
#  include <time.h>
#endif

/* ---------------------------------------------------------- tabela de ops */
/* A ordem TEM de seguir o enum Op. O assert em fvm_op_table() protege isso. */
static const OpInfo g_ops[OP__COUNT] = {
    { "HALT",    OP_HALT,    OPD_NONE  },
    { "PUSH",    OP_PUSH,    OPD_I64   },
    { "POP",     OP_POP,     OPD_NONE  },
    { "DUP",     OP_DUP,     OPD_NONE  },
    { "SWAP",    OP_SWAP,    OPD_NONE  },
    { "ADD",     OP_ADD,     OPD_NONE  },
    { "SUB",     OP_SUB,     OPD_NONE  },
    { "MUL",     OP_MUL,     OPD_NONE  },
    { "DIV",     OP_DIV,     OPD_NONE  },
    { "MOD",     OP_MOD,     OPD_NONE  },
    { "NEG",     OP_NEG,     OPD_NONE  },
    { "LT",      OP_LT,      OPD_NONE  },
    { "LE",      OP_LE,      OPD_NONE  },
    { "GT",      OP_GT,      OPD_NONE  },
    { "GE",      OP_GE,      OPD_NONE  },
    { "EQ",      OP_EQ,      OPD_NONE  },
    { "NE",      OP_NE,      OPD_NONE  },
    { "JMP",     OP_JMP,     OPD_LABEL },
    { "JZ",      OP_JZ,      OPD_LABEL },
    { "JNZ",     OP_JNZ,     OPD_LABEL },
    { "LOAD",    OP_LOAD,    OPD_SLOT  },
    { "STORE",   OP_STORE,   OPD_SLOT  },
    { "RESERVE", OP_RESERVE, OPD_SLOT  },
    { "CALL",    OP_CALL,    OPD_CALL  },
    { "RET",     OP_RET,     OPD_NONE  },
    { "PRINT",   OP_PRINT,   OPD_NONE  },
    { "NEWARR",  OP_NEWARR,  OPD_NONE  },
    { "AGET",    OP_AGET,    OPD_NONE  },
    { "ASET",    OP_ASET,    OPD_NONE  },
    { "ALEN",    OP_ALEN,    OPD_NONE  },
    { "GC",      OP_GC,      OPD_NONE  },
};

const OpInfo *fvm_op_table(void) { return g_ops; }

const OpInfo *fvm_op_lookup(const char *name)
{
    for (int i = 0; i < OP__COUNT; i++) {
        const char *a = g_ops[i].name, *b = name;
        while (*a && *b) {
            char ca = *a, cb = *b;
            if (cb >= 'a' && cb <= 'z') cb = (char)(cb - 'a' + 'A');
            if (ca != cb) break;
            a++; b++;
        }
        if (*a == '\0' && *b == '\0') return &g_ops[i];
    }
    return NULL;
}

/* ----------------------------------------------------------------- valores */
void value_print(FILE *out, Value v)
{
    switch (v.t) {
    case VAL_INT:
        fprintf(out, "%" PRId64, AS_INT(v));
        break;
    case VAL_OBJ: {
        Obj *o = AS_OBJ(v);
        if (o == NULL) { fputs("nil", out); break; }
        if (o->type == OBJ_ARRAY) {
            ObjArray *a = (ObjArray *)o;
            fputc('[', out);
            for (size_t i = 0; i < a->len; i++) {
                if (i) fputs(", ", out);
                value_print(out, a->items[i]);
            }
            fputc(']', out);
        } else {
            fputs("<obj>", out);
        }
        break;
    }
    }
}

int value_equal(Value a, Value b)
{
    if (a.t != b.t) return 0;
    if (a.t == VAL_INT) return AS_INT(a) == AS_INT(b);
    return AS_OBJ(a) == AS_OBJ(b);
}

/* ------------------------------------------------------------------ chunk */
void chunk_init(Chunk *c)
{
    c->code = NULL;
    c->len = c->cap = 0;
    c->entry = 0;
}

void chunk_free(Chunk *c)
{
    free(c->code);
    chunk_init(c);
}

static void chunk_reserve(Chunk *c, size_t extra)
{
    if (c->len + extra <= c->cap) return;
    size_t cap = c->cap < 64 ? 64 : c->cap;
    while (cap < c->len + extra) cap *= 2;
    uint8_t *p = (uint8_t *)realloc(c->code, cap);
    if (!p) { fputs("fvm: sem memoria ao crescer o chunk\n", stderr); exit(70); }
    c->code = p;
    c->cap = cap;
}

void chunk_write_u8(Chunk *c, uint8_t b)
{
    chunk_reserve(c, 1);
    c->code[c->len++] = b;
}

/* Operandos são gravados em little-endian explícito via memcpy: nada de
 * ponteiro desalinhado (UB) e o .fbc fica portável entre máquinas LE. */
void chunk_write_i32(Chunk *c, int32_t v)
{
    chunk_reserve(c, 4);
    memcpy(c->code + c->len, &v, 4);
    c->len += 4;
}

void chunk_write_i64(Chunk *c, int64_t v)
{
    chunk_reserve(c, 8);
    memcpy(c->code + c->len, &v, 8);
    c->len += 8;
}

/* -------------------------------------------------------------- utilidades */
char *fvm_read_file(const char *path, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "fvm: nao consegui abrir '%s'\n", path); return NULL; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    rewind(f);
    char *buf = (char *)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    buf[got] = '\0';
    fclose(f);
    if (out_len) *out_len = got;
    return buf;
}

/* .fbc: "FVM1" | u32 entry | u32 len | code[len] */
int fvm_chunk_save(const Chunk *c, const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "fvm: nao consegui escrever '%s'\n", path); return 0; }
    uint32_t len = (uint32_t)c->len;
    uint32_t entry = c->entry;
    int ok = fwrite("FVM1", 1, 4, f) == 4
          && fwrite(&entry, 4, 1, f) == 1
          && fwrite(&len, 4, 1, f) == 1
          && (len == 0 || fwrite(c->code, 1, len, f) == len);
    fclose(f);
    if (!ok) fprintf(stderr, "fvm: falha ao gravar '%s'\n", path);
    return ok;
}

int fvm_chunk_load(Chunk *c, const char *path)
{
    size_t n = 0;
    char *raw = fvm_read_file(path, &n);
    if (!raw) return 0;
    if (n < 12 || memcmp(raw, "FVM1", 4) != 0) {
        fprintf(stderr, "fvm: '%s' nao e um .fbc valido\n", path);
        free(raw);
        return 0;
    }
    uint32_t entry, len;
    memcpy(&entry, raw + 4, 4);
    memcpy(&len, raw + 8, 4);
    if (12 + (size_t)len > n) {
        fprintf(stderr, "fvm: '%s' truncado\n", path);
        free(raw);
        return 0;
    }
    chunk_init(c);
    chunk_reserve(c, len);
    memcpy(c->code, raw + 12, len);
    c->len = len;
    c->entry = entry;
    free(raw);
    return 1;
}

double fvm_now_sec(void)
{
#if defined(_WIN32)
    static LARGE_INTEGER freq;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)freq.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
#endif
}
