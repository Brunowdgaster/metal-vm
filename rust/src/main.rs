//! CLI da Forge VM (porte em Rust).
//!
//! A interface é byte a byte igual à da implementação em C, inclusive o
//! formato do bloco `--stats`. Não é capricho: `tests/run_tests.sh` e
//! `bench/run_bench.sh` recebem qualquer um dos dois binários como argumento
//! e comparam os resultados sem nenhum caso especial. Se a interface
//! divergisse, a comparação entre linguagens exigiria dois harnesses — e dois
//! harnesses medem duas coisas diferentes.

mod asm;
mod chunk;
mod gc;
mod stack;
mod value;
mod vm;

use std::io::{self, Write};
use std::path::Path;
use std::process::ExitCode;
use std::time::Instant;

const VERSION: &str = env!("CARGO_PKG_VERSION");

const DISPATCH: &str = "match (Rust seguro nao tem computed goto)";

#[cfg(feature = "stats")]
const STATS_ON: bool = true;
#[cfg(not(feature = "stats"))]
const STATS_ON: bool = false;

fn usage() -> ExitCode {
    eprint!(
        "fvm {VERSION} - Forge VM (Rust)\n\
         \n\
         uso:\n\
         \u{20} fvm run  <prog.fasm> [--stats] [--trace]   monta e executa\n\
         \u{20} fvm asm  <prog.fasm> -o <prog.fbc>         so monta\n\
         \u{20} fvm exec <prog.fbc>  [--stats] [--trace]   executa bytecode\n\
         \u{20} fvm dis  <prog.fasm|prog.fbc>              desmonta\n\
         \u{20} fvm version                                versao e opcoes de build\n"
    );
    ExitCode::from(64)
}

/// Um `.fbc` começa com "FVM1"; qualquer outra coisa é tratada como fonte.
/// Decidir pelo conteúdo, e não pela extensão, é o que faz `fvm dis` aceitar
/// os dois sem flag.
fn looks_like_bytecode(path: &Path) -> bool {
    match std::fs::File::open(path) {
        Ok(mut f) => {
            let mut magic = [0u8; 4];
            use std::io::Read;
            matches!(f.read_exact(&mut magic), Ok(())) && &magic == b"FVM1"
        }
        Err(_) => false,
    }
}

fn print_stats(vm: &vm::Vm, elapsed: f64) {
    let mut e = io::stderr();
    let _ = writeln!(e, "\n--- estatisticas ---");
    if STATS_ON {
        let mops = if elapsed > 0.0 {
            vm.ins_count as f64 / elapsed / 1e6
        } else {
            0.0
        };
        let _ = writeln!(e, "instrucoes      : {}", vm.ins_count);
        let _ = writeln!(e, "tempo           : {elapsed:.6} s");
        let _ = writeln!(e, "throughput      : {mops:.2} Mops/s");
    } else {
        let _ = writeln!(e, "tempo           : {elapsed:.6} s");
        let _ = writeln!(e, "(compilado sem a feature stats: contagem desativada)");
    }
    let _ = writeln!(e, "coletas de GC   : {}", vm.heap.runs);
    let _ = writeln!(e, "bytes liberados : {}", vm.heap.freed);
    let _ = writeln!(e, "pico de heap    : {} bytes", vm.heap.peak);
    let _ = writeln!(e, "dispatch        : {DISPATCH}");
    let _ = writeln!(e, "pilha           : {}", crate::stack::stack_impl_name());
}

fn run_chunk(chunk: &chunk::Chunk, stats: bool, trace: bool) -> ExitCode {
    let mut vm = vm::Vm::new();
    vm.trace = trace;

    // stdout com buffer explícito: sem isso, cada PRINT viraria uma syscall
    // write(), e o benchmark mediria o kernel. A versão em C recebe isso de
    // graça do buffer do FILE* da libc.
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    let t0 = Instant::now();
    let result = vm.run(chunk, &mut out);
    let elapsed = t0.elapsed().as_secs_f64();

    let _ = out.flush();
    drop(out);

    if stats {
        print_stats(&vm, elapsed);
    }

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("fvm: {msg}");
            ExitCode::from(70)
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        return usage();
    }

    let flag = |name: &str| args.iter().skip(2).any(|a| a == name);
    let stats = flag("--stats");
    let trace = flag("--trace");

    match args[1].as_str() {
        "version" => {
            println!("fvm {VERSION}");
            println!("dispatch: {DISPATCH}");
            println!("stats   : {}", if STATS_ON { "on" } else { "off" });
            println!("pilha   : {}", crate::stack::stack_impl_name());
            ExitCode::SUCCESS
        }

        "run" => {
            if args.len() < 3 {
                return usage();
            }
            match asm::assemble_file(Path::new(&args[2])) {
                Ok(chunk) => run_chunk(&chunk, stats, trace),
                Err(e) => {
                    eprintln!("{e}");
                    ExitCode::from(65)
                }
            }
        }

        "exec" => {
            if args.len() < 3 {
                return usage();
            }
            match chunk::Chunk::load(Path::new(&args[2])) {
                Ok(chunk) => run_chunk(&chunk, stats, trace),
                Err(e) => {
                    eprintln!("fvm: {e}");
                    ExitCode::from(65)
                }
            }
        }

        "asm" => {
            if args.len() < 5 || args[3] != "-o" {
                return usage();
            }
            match asm::assemble_file(Path::new(&args[2])) {
                Ok(chunk) => {
                    let path = Path::new(&args[4]);
                    match chunk.save(path) {
                        Ok(()) => {
                            eprintln!(
                                "fvm: {} bytes de bytecode, entry={} -> {}",
                                chunk.code.len(),
                                chunk.entry,
                                args[4]
                            );
                            ExitCode::SUCCESS
                        }
                        Err(e) => {
                            eprintln!("fvm: falha ao gravar '{}': {e}", args[4]);
                            ExitCode::from(74)
                        }
                    }
                }
                Err(e) => {
                    eprintln!("{e}");
                    ExitCode::from(65)
                }
            }
        }

        "dis" => {
            if args.len() < 3 {
                return usage();
            }
            let path = Path::new(&args[2]);
            let loaded = if looks_like_bytecode(path) {
                chunk::Chunk::load(path)
            } else {
                asm::assemble_file(path)
            };
            match loaded {
                Ok(chunk) => {
                    print!("{}", asm::disassemble(&chunk));
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("{e}");
                    ExitCode::from(65)
                }
            }
        }

        _ => usage(),
    }
}
