/* gc.c — coletor mark & sweep.
 *
 * Por que mark & sweep e não contagem de referências:
 *   - ciclos (um array que contém a si mesmo) são coletados sem truque extra;
 *   - o custo não aparece no caminho quente do interpretador — nenhuma
 *     instrução precisa incrementar/decrementar contadores;
 *   - a implementação cabe em ~100 linhas, o que mantém o foco do projeto
 *     na comparação entre linguagens, e não na sofisticação do GC.
 *
 * Trade-off aceito: pausas stop-the-world proporcionais ao heap vivo. Está
 * documentado em README.md > Limites conhecidos.
 *
 * Raízes: a pilha de operandos inteira (stack[0..sp)). Como locais vivem na
 * própria pilha (ver vm.c), não existe um conjunto de raízes separado — é a
 * principal razão pela qual os frames foram desenhados assim.
 */
#include "fvm.h"

#include <stdlib.h>
#include <string.h>

#define GC_INITIAL_THRESHOLD (256u * 1024u)
#define GC_GROWTH_FACTOR     2

static size_t array_bytes(size_t len)
{
    return sizeof(ObjArray) + len * sizeof(Value);
}

ObjArray *gc_new_array(VM *vm, size_t len)
{
    if (vm->bytes_allocated + array_bytes(len) > vm->next_gc) {
        gc_collect(vm);
    }

    ObjArray *a = (ObjArray *)malloc(sizeof(ObjArray));
    if (!a) return NULL;
    a->items = len ? (Value *)malloc(len * sizeof(Value)) : NULL;
    if (len && !a->items) { free(a); return NULL; }

    for (size_t i = 0; i < len; i++) a->items[i] = INT_VAL(0);
    a->len = len;
    a->header.type = OBJ_ARRAY;
    a->header.marked = 0;
    a->header.next = vm->objects;
    vm->objects = (Obj *)a;

    vm->bytes_allocated += array_bytes(len);
    if (vm->bytes_allocated > vm->peak_bytes) vm->peak_bytes = vm->bytes_allocated;
    return a;
}

/* ------------------------------------------------------------------- mark */
/* Marcação iterativa com pilha explícita. Recursão aqui seria mais curta,
 * mas um array profundamente aninhado estouraria a pilha nativa — e um GC
 * que quebra sob dados do usuário não é um GC. */
typedef struct {
    Obj  **items;
    size_t len, cap;
} GrayStack;

static void gray_push(GrayStack *g, Obj *o)
{
    if (o == NULL || o->marked) return;
    o->marked = 1;
    if (g->len == g->cap) {
        size_t cap = g->cap < 32 ? 32 : g->cap * 2;
        Obj **p = (Obj **)realloc(g->items, cap * sizeof(Obj *));
        if (!p) return; /* sem memória durante o GC: o objeto fica marcado mas
                         * não é varrido em busca de filhos. Documentado como
                         * limite conhecido. */
        g->items = p;
        g->cap = cap;
    }
    g->items[g->len++] = o;
}

static void mark_roots(VM *vm, GrayStack *g)
{
    for (int i = 0; i < vm->sp; i++) {
        if (IS_OBJ(vm->stack[i])) gray_push(g, AS_OBJ(vm->stack[i]));
    }
}

static void trace_references(GrayStack *g)
{
    while (g->len > 0) {
        Obj *o = g->items[--g->len];
        if (o->type == OBJ_ARRAY) {
            ObjArray *a = (ObjArray *)o;
            for (size_t i = 0; i < a->len; i++) {
                if (IS_OBJ(a->items[i])) gray_push(g, AS_OBJ(a->items[i]));
            }
        }
    }
}

/* ------------------------------------------------------------------ sweep */
static size_t sweep(VM *vm)
{
    size_t freed = 0;
    Obj **link = &vm->objects;
    while (*link) {
        Obj *o = *link;
        if (o->marked) {
            o->marked = 0;        /* limpa para o próximo ciclo */
            link = &o->next;
        } else {
            *link = o->next;
            if (o->type == OBJ_ARRAY) {
                ObjArray *a = (ObjArray *)o;
                freed += array_bytes(a->len);
                free(a->items);
            }
            free(o);
        }
    }
    return freed;
}

void gc_collect(VM *vm)
{
    GrayStack gray = { NULL, 0, 0 };

    mark_roots(vm, &gray);
    trace_references(&gray);
    free(gray.items);

    size_t freed = sweep(vm);

    vm->bytes_allocated -= freed;
    vm->gc_bytes_freed += freed;
    vm->gc_runs++;

    /* Heurística de crescimento: o próximo ciclo só dispara quando o heap
     * vivo dobrar. Simples e suficiente; evita o patológico de coletar a cada
     * alocação quando o heap vivo já é grande. */
    vm->next_gc = vm->bytes_allocated * GC_GROWTH_FACTOR;
    if (vm->next_gc < GC_INITIAL_THRESHOLD) vm->next_gc = GC_INITIAL_THRESHOLD;
}

void gc_free_all(VM *vm)
{
    Obj *o = vm->objects;
    while (o) {
        Obj *next = o->next;
        if (o->type == OBJ_ARRAY) free(((ObjArray *)o)->items);
        free(o);
        o = next;
    }
    vm->objects = NULL;
    vm->bytes_allocated = 0;
}
