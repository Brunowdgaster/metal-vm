/* asm.c — montador de .fasm para bytecode, e desmontador.
 *
 * Gramática (uma instrução por linha):
 *
 *   ; comentário          também aceita #
 *   .entry main           opcional; default = rótulo "main", senão offset 0
 *   rotulo:               define um rótulo na posição atual
 *   PUSH 42               imediato de 64 bits (aceita 0x..)
 *   JZ fim                rótulo -> endereço absoluto de 32 bits
 *   LOAD 0                índice de slot
 *   CALL fib 1            rótulo + nargs
 *   ADD                   sem operando
 *
 * Estratégia: um passe único que emite bytecode com zeros nos lugares dos
 * rótulos ainda desconhecidos, registrando cada buraco numa lista de patches;
 * no fim, todos os patches são resolvidos. É o que compiladores reais fazem
 * (relocations) e evita manter o fonte inteiro na memória duas vezes.
 */
#include "fvm.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#define MAX_NAME 64

typedef struct {
    char     name[MAX_NAME];
    uint32_t addr;
} Symbol;

typedef struct {
    size_t offset;              /* posição no chunk a ser corrigida */
    char   name[MAX_NAME];
    int    line;
} Patch;

typedef struct {
    Symbol *syms;  size_t nsyms,  csyms;
    Patch  *pats;  size_t npats,  cpats;

    const char *filename;
    int line;
    int had_error;

    char entry_name[MAX_NAME];
} Asm;

static void as_error(Asm *a, const char *fmt, const char *arg)
{
    fprintf(stderr, "%s:%d: erro: ", a->filename, a->line);
    fprintf(stderr, fmt, arg);
    fputc('\n', stderr);
    a->had_error = 1;
}

/* snprintf em vez de strncpy: strncpy nao garante o terminador quando a
 * origem tem exatamente o tamanho do destino, e o gcc avisa com
 * -Wstringop-truncation. snprintf sempre termina a string. */
static void copy_name(char *dst, const char *src)
{
    snprintf(dst, MAX_NAME, "%s", src);
}

static void *grow(void *p, size_t *cap, size_t elem)
{
    size_t c = *cap < 16 ? 16 : *cap * 2;
    void *q = realloc(p, c * elem);
    if (!q) { fputs("fvm: sem memoria no montador\n", stderr); exit(70); }
    *cap = c;
    return q;
}

static void sym_define(Asm *a, const char *name, uint32_t addr)
{
    for (size_t i = 0; i < a->nsyms; i++) {
        if (strcmp(a->syms[i].name, name) == 0) {
            as_error(a, "rotulo '%s' definido duas vezes", name);
            return;
        }
    }
    if (a->nsyms == a->csyms) a->syms = (Symbol *)grow(a->syms, &a->csyms, sizeof(Symbol));
    copy_name(a->syms[a->nsyms].name, name);
    a->syms[a->nsyms].addr = addr;
    a->nsyms++;
}

static void patch_add(Asm *a, size_t offset, const char *name)
{
    if (a->npats == a->cpats) a->pats = (Patch *)grow(a->pats, &a->cpats, sizeof(Patch));
    a->pats[a->npats].offset = offset;
    a->pats[a->npats].line = a->line;
    copy_name(a->pats[a->npats].name, name);
    a->npats++;
}

/* ------------------------------------------------------------- tokenização */
static const char *skip_ws(const char *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\r') p++;
    return p;
}

static int is_tok_char(char c)
{
    return isalnum((unsigned char)c) || c == '_' || c == '.' || c == '-' || c == '$';
}

/* Copia o próximo token para `out`. Retorna NULL se a linha acabou. */
static const char *next_token(const char *p, char *out, size_t outsz)
{
    p = skip_ws(p);
    if (*p == '\0' || *p == '\n' || *p == ';' || *p == '#') return NULL;
    size_t n = 0;
    while (is_tok_char(*p)) {
        if (n + 1 < outsz) out[n++] = *p;
        p++;
    }
    out[n] = '\0';
    if (n == 0) return NULL;
    return p;
}

static int parse_int(const char *s, int64_t *out)
{
    char *end = NULL;
    long long v = strtoll(s, &end, 0);   /* base 0: aceita 0x / 0 / decimal */
    if (end == s || (end && *end != '\0')) return 0;
    *out = (int64_t)v;
    return 1;
}

/* ---------------------------------------------------------------- montagem */
int fvm_assemble(const char *source, const char *filename, Chunk *out)
{
    Asm a;
    memset(&a, 0, sizeof a);
    a.filename = filename ? filename : "<fonte>";
    a.line = 0;
    copy_name(a.entry_name, "main");

    chunk_init(out);

    const char *p = source;
    char tok[MAX_NAME];

    while (*p) {
        a.line++;
        const char *eol = strchr(p, '\n');
        size_t linelen = eol ? (size_t)(eol - p) : strlen(p);

        /* trabalha numa cópia da linha para poder usar strchr sem passar do fim */
        char buf[1024];
        size_t n = linelen < sizeof(buf) - 1 ? linelen : sizeof(buf) - 1;
        memcpy(buf, p, n);
        buf[n] = '\0';
        p = eol ? eol + 1 : p + linelen;

        const char *q = buf;
        while ((q = next_token(q, tok, sizeof tok)) != NULL) {
            /* rótulo? o próximo caractere não-branco é ':' */
            const char *after = skip_ws(q);
            if (*after == ':') {
                sym_define(&a, tok, (uint32_t)out->len);
                q = after + 1;
                continue;
            }

            /* diretiva */
            if (tok[0] == '.') {
                if (strcmp(tok, ".entry") == 0) {
                    const char *r = next_token(q, tok, sizeof tok);
                    if (!r) { as_error(&a, ".entry exige um rotulo%s", ""); break; }
                    copy_name(a.entry_name, tok);
                    q = r;
                    continue;
                }
                as_error(&a, "diretiva desconhecida '%s'", tok);
                break;
            }

            const OpInfo *info = fvm_op_lookup(tok);
            if (!info) { as_error(&a, "instrucao desconhecida '%s'", tok); break; }

            chunk_write_u8(out, (uint8_t)info->op);

            switch (info->kind) {
            case OPD_NONE:
                break;

            case OPD_I64: {
                const char *r = next_token(q, tok, sizeof tok);
                int64_t v = 0;
                if (!r || !parse_int(tok, &v)) {
                    as_error(&a, "%s exige um inteiro", info->name);
                    v = 0;
                } else {
                    q = r;
                }
                chunk_write_i64(out, v);
                break;
            }

            case OPD_SLOT: {
                const char *r = next_token(q, tok, sizeof tok);
                int64_t v = 0;
                if (!r || !parse_int(tok, &v)) {
                    as_error(&a, "%s exige um indice inteiro", info->name);
                    v = 0;
                } else {
                    q = r;
                }
                chunk_write_i32(out, (int32_t)v);
                break;
            }

            case OPD_LABEL: {
                const char *r = next_token(q, tok, sizeof tok);
                if (!r) {
                    as_error(&a, "%s exige um rotulo", info->name);
                    chunk_write_i32(out, 0);
                    break;
                }
                q = r;
                int64_t imm;
                if (parse_int(tok, &imm)) {      /* endereço literal também vale */
                    chunk_write_i32(out, (int32_t)imm);
                } else {
                    patch_add(&a, out->len, tok);
                    chunk_write_i32(out, 0);
                }
                break;
            }

            case OPD_CALL: {
                const char *r = next_token(q, tok, sizeof tok);
                if (!r) {
                    as_error(&a, "CALL exige rotulo e nargs%s", "");
                    chunk_write_i32(out, 0);
                    chunk_write_u8(out, 0);
                    break;
                }
                q = r;
                int64_t imm;
                if (parse_int(tok, &imm)) {
                    chunk_write_i32(out, (int32_t)imm);
                } else {
                    patch_add(&a, out->len, tok);
                    chunk_write_i32(out, 0);
                }
                r = next_token(q, tok, sizeof tok);
                int64_t nargs = 0;
                if (!r || !parse_int(tok, &nargs) || nargs < 0 || nargs > 255) {
                    as_error(&a, "CALL exige nargs entre 0 e 255%s", "");
                    nargs = 0;
                } else {
                    q = r;
                }
                chunk_write_u8(out, (uint8_t)nargs);
                break;
            }
            }
        }
    }

    /* resolve as relocations */
    for (size_t i = 0; i < a.npats; i++) {
        int found = 0;
        for (size_t j = 0; j < a.nsyms; j++) {
            if (strcmp(a.pats[i].name, a.syms[j].name) == 0) {
                int32_t addr = (int32_t)a.syms[j].addr;
                memcpy(out->code + a.pats[i].offset, &addr, 4);
                found = 1;
                break;
            }
        }
        if (!found) {
            fprintf(stderr, "%s:%d: erro: rotulo '%s' nao definido\n",
                    a.filename, a.pats[i].line, a.pats[i].name);
            a.had_error = 1;
        }
    }

    /* ponto de entrada */
    out->entry = 0;
    for (size_t j = 0; j < a.nsyms; j++) {
        if (strcmp(a.syms[j].name, a.entry_name) == 0) { out->entry = a.syms[j].addr; break; }
    }

    free(a.syms);
    free(a.pats);

    if (a.had_error) { chunk_free(out); return 0; }
    return 1;
}

int fvm_assemble_file(const char *path, Chunk *out)
{
    size_t len = 0;
    char *src = fvm_read_file(path, &len);
    if (!src) return 0;
    int ok = fvm_assemble(src, path, out);
    free(src);
    return ok;
}

/* ------------------------------------------------------------- desmontador */
void fvm_disassemble(FILE *out, const Chunk *c)
{
    const OpInfo *tbl = fvm_op_table();
    fprintf(out, "; entry = %u, %zu bytes\n", c->entry, c->len);

    size_t i = 0;
    while (i < c->len) {
        size_t at = i;
        uint8_t op = c->code[i++];
        if (op >= OP__COUNT) {
            fprintf(out, "%06zu  .byte 0x%02x        ; opcode invalido\n", at, op);
            continue;
        }
        const OpInfo *info = &tbl[op];
        fprintf(out, "%06zu  %-8s", at, info->name);

        switch (info->kind) {
        case OPD_NONE:
            break;
        case OPD_I64: {
            int64_t v;
            if (i + 8 > c->len) { fputs("  ; truncado", out); i = c->len; break; }
            memcpy(&v, c->code + i, 8);
            i += 8;
            fprintf(out, " %lld", (long long)v);
            break;
        }
        case OPD_SLOT:
        case OPD_LABEL: {
            int32_t v;
            if (i + 4 > c->len) { fputs("  ; truncado", out); i = c->len; break; }
            memcpy(&v, c->code + i, 4);
            i += 4;
            fprintf(out, " %d", v);
            break;
        }
        case OPD_CALL: {
            int32_t v;
            if (i + 5 > c->len) { fputs("  ; truncado", out); i = c->len; break; }
            memcpy(&v, c->code + i, 4);
            i += 4;
            uint8_t nargs = c->code[i++];
            fprintf(out, " %d %u", v, (unsigned)nargs);
            break;
        }
        }
        fputc('\n', out);
    }
}
