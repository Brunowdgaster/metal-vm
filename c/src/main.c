/* main.c — CLI da Forge VM.
 *
 *   fvm run  prog.fasm [--stats] [--trace]
 *   fvm asm  prog.fasm -o prog.fbc
 *   fvm exec prog.fbc  [--stats] [--trace]
 *   fvm dis  prog.fasm | prog.fbc
 *   fvm version
 */
#include "fvm.h"

#include <stdlib.h>
#include <string.h>

static int usage(void)
{
    fputs(
        "fvm " FVM_VERSION " - Forge VM\n"
        "\n"
        "uso:\n"
        "  fvm run  <prog.fasm> [--stats] [--trace]   monta e executa\n"
        "  fvm asm  <prog.fasm> -o <prog.fbc>         so monta\n"
        "  fvm exec <prog.fbc>  [--stats] [--trace]   executa bytecode\n"
        "  fvm dis  <prog.fasm|prog.fbc>              desmonta\n"
        "  fvm version                                versao e opcoes de build\n",
        stderr);
    return 64;
}

static int has_flag(int argc, char **argv, const char *flag)
{
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], flag) == 0) return 1;
    }
    return 0;
}

/* Um .fbc começa com "FVM1"; qualquer outra coisa é tratada como fonte. */
static int looks_like_bytecode(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    char magic[4] = { 0 };
    size_t got = fread(magic, 1, 4, f);
    fclose(f);
    return got == 4 && memcmp(magic, "FVM1", 4) == 0;
}

static void print_stats(const VM *vm, double elapsed)
{
    fprintf(stderr, "\n--- estatisticas ---\n");
#ifdef FVM_STATS
    double mops = elapsed > 0.0 ? (double)vm->ins_count / elapsed / 1e6 : 0.0;
    fprintf(stderr, "instrucoes      : %llu\n", (unsigned long long)vm->ins_count);
    fprintf(stderr, "tempo           : %.6f s\n", elapsed);
    fprintf(stderr, "throughput      : %.2f Mops/s\n", mops);
#else
    fprintf(stderr, "tempo           : %.6f s\n", elapsed);
    fprintf(stderr, "(compilado sem FVM_STATS: contagem de instrucoes desativada)\n");
#endif
    fprintf(stderr, "coletas de GC   : %llu\n", (unsigned long long)vm->gc_runs);
    fprintf(stderr, "bytes liberados : %zu\n", vm->gc_bytes_freed);
    fprintf(stderr, "pico de heap    : %zu bytes\n", vm->peak_bytes);
    fprintf(stderr, "dispatch        : %s\n",
#ifdef FVM_USE_GOTO
            "computed goto"
#else
            "switch"
#endif
    );
}

/* A VM vai no heap, não na pilha nativa: sizeof(VM) passa de 1 MB
 * (65536 valores de 16 bytes + 4096 frames), e a thread principal do Windows
 * tem 1 MB de pilha por padrão. Como variável local isso dá stack overflow
 * (0xC00000FD) antes da primeira instrução executar — foi o primeiro bug
 * real deste projeto, e o motivo pelo qual pilhas grandes de VM nunca ficam
 * em memória automática. */
static int run_chunk(Chunk *chunk, int stats, int trace)
{
    VM *vm = (VM *)malloc(sizeof(VM));
    if (!vm) { fputs("fvm: sem memoria para a VM\n", stderr); return 70; }

    vm_init(vm, stdout);
    vm->trace = trace;

    double t0 = fvm_now_sec();
    VMResult r = vm_run(vm, chunk);
    double elapsed = fvm_now_sec() - t0;

    if (stats) print_stats(vm, elapsed);

    vm_free(vm);
    free(vm);
    return r == FVM_ERR_RUNTIME ? 70 : 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) return usage();
    const char *cmd = argv[1];

    if (strcmp(cmd, "version") == 0) {
        printf("fvm %s\n", FVM_VERSION);
        printf("dispatch: %s\n",
#ifdef FVM_USE_GOTO
               "computed goto"
#else
               "switch"
#endif
        );
        printf("stats   : %s\n",
#ifdef FVM_STATS
               "on"
#else
               "off"
#endif
        );
        return 0;
    }

    if (strcmp(cmd, "run") == 0) {
        if (argc < 3) return usage();
        Chunk c;
        if (!fvm_assemble_file(argv[2], &c)) return 65;
        int code = run_chunk(&c, has_flag(argc, argv, "--stats"), has_flag(argc, argv, "--trace"));
        chunk_free(&c);
        return code;
    }

    if (strcmp(cmd, "exec") == 0) {
        if (argc < 3) return usage();
        Chunk c;
        if (!fvm_chunk_load(&c, argv[2])) return 65;
        int code = run_chunk(&c, has_flag(argc, argv, "--stats"), has_flag(argc, argv, "--trace"));
        chunk_free(&c);
        return code;
    }

    if (strcmp(cmd, "asm") == 0) {
        if (argc < 5 || strcmp(argv[3], "-o") != 0) return usage();
        Chunk c;
        if (!fvm_assemble_file(argv[2], &c)) return 65;
        int ok = fvm_chunk_save(&c, argv[4]);
        fprintf(stderr, "fvm: %zu bytes de bytecode, entry=%u -> %s\n", c.len, c.entry, argv[4]);
        chunk_free(&c);
        return ok ? 0 : 74;
    }

    if (strcmp(cmd, "dis") == 0) {
        if (argc < 3) return usage();
        Chunk c;
        int ok = looks_like_bytecode(argv[2]) ? fvm_chunk_load(&c, argv[2])
                                              : fvm_assemble_file(argv[2], &c);
        if (!ok) return 65;
        fvm_disassemble(stdout, &c);
        chunk_free(&c);
        return 0;
    }

    return usage();
}
