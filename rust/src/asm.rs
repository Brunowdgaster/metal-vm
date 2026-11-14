//! Montador de `.fasm` e desmontador.
//!
//! Mesma gramática e mesma estratégia da versão em C: um passe único que emite
//! zeros nos operandos de rótulo ainda desconhecidos e registra cada buraco
//! numa lista de patches, resolvida no fim (relocations).
//!
//! Diferença de engenharia em relação ao C: os erros são **acumulados** num
//! `Vec<String>` e devolvidos juntos, em vez de impressos em stderr de dentro
//! da função. Montar um arquivo com 5 erros reporta os 5 de uma vez, e a
//! função não tem efeito colateral de I/O — o que a torna testável.

use crate::chunk::{op_info, op_lookup, Chunk, OperandKind};
use std::fmt::Write as _;

struct Patch {
    offset: usize,
    name: String,
    line: usize,
    /// 4 para saltos e `CALL`, 8 para `PUSH <rotulo>`.
    width: usize,
}

/// Quebra uma linha em tokens. `:` é token próprio, para que `rotulo:` seja
/// reconhecido sem olhar o caractere seguinte. `;` e `#` iniciam comentário.
fn tokenize(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();

    for c in line.chars() {
        if c == ';' || c == '#' {
            break;
        }
        if c == ':' {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            out.push(":".to_string());
            continue;
        }
        if c.is_alphanumeric() || c == '_' || c == '.' || c == '-' || c == '$' {
            cur.push(c);
        } else if !cur.is_empty() {
            // qualquer outro caractere (espaço, tabulação, vírgula) encerra o
            // token corrente
            out.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Aceita decimal, `0x...` hexadecimal e sinal negativo — igual ao `strtoll`
/// com base 0 usado em C.
fn parse_int(s: &str) -> Option<i64> {
    let (neg, body) = match s.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, s),
    };
    let v = if let Some(hex) = body.strip_prefix("0x").or_else(|| body.strip_prefix("0X")) {
        i64::from_str_radix(hex, 16).ok()?
    } else {
        body.parse::<i64>().ok()?
    };
    Some(if neg { -v } else { v })
}

pub fn assemble(source: &str, filename: &str) -> Result<Chunk, String> {
    let mut chunk = Chunk::new();
    let mut symbols: Vec<(String, u32)> = Vec::new();
    let mut patches: Vec<Patch> = Vec::new();
    let mut errors: Vec<String> = Vec::new();
    let mut entry_name = String::from("main");

    for (lineno0, line) in source.lines().enumerate() {
        let lineno = lineno0 + 1;
        let toks = tokenize(line);
        let mut i = 0;

        while i < toks.len() {
            let tok = &toks[i];

            // rótulo: próximo token é ':'
            if toks.get(i + 1).map(|t| t.as_str()) == Some(":") {
                if symbols.iter().any(|(n, _)| n == tok) {
                    errors.push(format!(
                        "{filename}:{lineno}: erro: rotulo '{tok}' definido duas vezes"
                    ));
                } else {
                    symbols.push((tok.clone(), chunk.code.len() as u32));
                }
                i += 2;
                continue;
            }

            // diretiva
            if tok.starts_with('.') {
                if tok == ".entry" {
                    match toks.get(i + 1) {
                        Some(name) => {
                            entry_name = name.clone();
                            i += 2;
                        }
                        None => {
                            errors
                                .push(format!("{filename}:{lineno}: erro: .entry exige um rotulo"));
                            break;
                        }
                    }
                    continue;
                }
                errors.push(format!(
                    "{filename}:{lineno}: erro: diretiva desconhecida '{tok}'"
                ));
                break;
            }

            let info = match op_lookup(tok) {
                Some(info) => info,
                None => {
                    errors.push(format!(
                        "{filename}:{lineno}: erro: instrucao desconhecida '{tok}'"
                    ));
                    break;
                }
            };

            chunk.write_u8(info.op);
            i += 1;

            match info.kind {
                OperandKind::None => {}

                OperandKind::Nargs => match toks.get(i).and_then(|t| parse_int(t)) {
                    Some(n) if (0..=255).contains(&n) => {
                        chunk.write_u8(n as u8);
                        i += 1;
                    }
                    _ => {
                        errors.push(format!(
                            "{filename}:{lineno}: erro: {} exige nargs entre 0 e 255",
                            info.name
                        ));
                        chunk.write_u8(0);
                    }
                },

                OperandKind::I64 | OperandKind::Slot => {
                    let want_i64 = info.kind == OperandKind::I64;
                    match toks.get(i) {
                        None => {
                            errors.push(format!(
                                "{filename}:{lineno}: erro: {} exige um operando",
                                info.name
                            ));
                            if want_i64 {
                                chunk.write_i64(0);
                            } else {
                                chunk.write_i32(0);
                            }
                        }
                        Some(t) => {
                            match parse_int(t) {
                                Some(v) if want_i64 => chunk.write_i64(v),
                                Some(v) => chunk.write_i32(v as i32),
                                // `PUSH <rotulo>` empurra o ENDERECO do rotulo
                                // como inteiro: e o que permite montar uma
                                // closure sem instrucao nova. So vale para
                                // operando de 64 bits; um slot nao e endereco.
                                None if want_i64 => {
                                    patches.push(Patch {
                                        offset: chunk.code.len(),
                                        name: t.clone(),
                                        line: lineno,
                                        width: 8,
                                    });
                                    chunk.write_i64(0);
                                }
                                None => {
                                    errors.push(format!(
                                        "{filename}:{lineno}: erro: {} exige um indice inteiro",
                                        info.name
                                    ));
                                    chunk.write_i32(0);
                                }
                            }
                            i += 1;
                        }
                    }
                }

                OperandKind::Label => match toks.get(i) {
                    Some(t) => {
                        match parse_int(t) {
                            Some(v) => chunk.write_i32(v as i32),
                            None => {
                                patches.push(Patch {
                                    offset: chunk.code.len(),
                                    name: t.clone(),
                                    line: lineno,
                                    width: 4,
                                });
                                chunk.write_i32(0);
                            }
                        }
                        i += 1;
                    }
                    None => {
                        errors.push(format!(
                            "{filename}:{lineno}: erro: {} exige um rotulo",
                            info.name
                        ));
                        chunk.write_i32(0);
                    }
                },

                OperandKind::Call => {
                    match toks.get(i) {
                        Some(t) => {
                            match parse_int(t) {
                                Some(v) => chunk.write_i32(v as i32),
                                None => {
                                    patches.push(Patch {
                                        offset: chunk.code.len(),
                                        name: t.clone(),
                                        line: lineno,
                                        width: 4,
                                    });
                                    chunk.write_i32(0);
                                }
                            }
                            i += 1;
                        }
                        None => {
                            errors.push(format!(
                                "{filename}:{lineno}: erro: CALL exige rotulo e nargs"
                            ));
                            chunk.write_i32(0);
                            chunk.write_u8(0);
                            continue;
                        }
                    }
                    match toks.get(i).and_then(|t| parse_int(t)) {
                        Some(n) if (0..=255).contains(&n) => {
                            chunk.write_u8(n as u8);
                            i += 1;
                        }
                        _ => {
                            errors.push(format!(
                                "{filename}:{lineno}: erro: CALL exige nargs entre 0 e 255"
                            ));
                            chunk.write_u8(0);
                        }
                    }
                }
            }
        }
    }

    // relocations
    for p in &patches {
        match symbols.iter().find(|(n, _)| *n == p.name) {
            Some((_, addr)) if p.width == 8 => chunk.patch_i64(p.offset, *addr as i64),
            Some((_, addr)) => chunk.patch_i32(p.offset, *addr as i32),
            None => errors.push(format!(
                "{filename}:{}: erro: rotulo '{}' nao definido",
                p.line, p.name
            )),
        }
    }

    chunk.entry = symbols
        .iter()
        .find(|(n, _)| *n == entry_name)
        .map(|(_, a)| *a)
        .unwrap_or(0);

    if errors.is_empty() {
        Ok(chunk)
    } else {
        Err(errors.join("\n"))
    }
}

pub fn assemble_file(path: &std::path::Path) -> Result<Chunk, String> {
    let src = std::fs::read_to_string(path)
        .map_err(|e| format!("nao consegui abrir '{}': {e}", path.display()))?;
    assemble(&src, &path.display().to_string())
}

pub fn disassemble(chunk: &Chunk) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "; entry = {}, {} bytes", chunk.entry, chunk.code.len());

    let code = &chunk.code;
    let mut i = 0usize;

    while i < code.len() {
        let at = i;
        let op = code[i];
        i += 1;

        let info = match op_info(op) {
            Some(info) => info,
            None => {
                let _ = writeln!(out, "{at:06}  .byte 0x{op:02x}        ; opcode invalido");
                continue;
            }
        };

        let _ = write!(out, "{at:06}  {:<8}", info.name);

        match info.kind {
            OperandKind::None => {}
            OperandKind::Nargs => {
                if i + 1 > code.len() {
                    let _ = write!(out, "  ; truncado");
                    i = code.len();
                } else {
                    let _ = write!(out, " {}", code[i]);
                    i += 1;
                }
            }
            OperandKind::I64 => {
                if i + 8 > code.len() {
                    let _ = write!(out, "  ; truncado");
                    i = code.len();
                } else {
                    let v = i64::from_le_bytes(code[i..i + 8].try_into().unwrap());
                    i += 8;
                    let _ = write!(out, " {v}");
                }
            }
            OperandKind::Slot | OperandKind::Label => {
                if i + 4 > code.len() {
                    let _ = write!(out, "  ; truncado");
                    i = code.len();
                } else {
                    let v = i32::from_le_bytes(code[i..i + 4].try_into().unwrap());
                    i += 4;
                    let _ = write!(out, " {v}");
                }
            }
            OperandKind::Call => {
                if i + 5 > code.len() {
                    let _ = write!(out, "  ; truncado");
                    i = code.len();
                } else {
                    let v = i32::from_le_bytes(code[i..i + 4].try_into().unwrap());
                    let nargs = code[i + 4];
                    i += 5;
                    let _ = write!(out, " {v} {nargs}");
                }
            }
        }
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Possível porque `assemble` devolve erros em vez de imprimi-los: a mesma
    // função em C não é testável sem capturar stderr.
    #[test]
    fn rotulo_para_frente_e_resolvido() {
        let src = ".entry main\nmain:\n  JMP fim\n  PUSH 1\nfim:\n  HALT\n";
        let c = assemble(src, "<teste>").expect("deveria montar");
        assert_eq!(c.code[0], crate::chunk::OP_JMP);
        let target = i32::from_le_bytes(c.code[1..5].try_into().unwrap());
        assert_eq!(target as usize, c.code.len() - 1); // rótulo `fim` -> HALT
    }

    #[test]
    fn erros_sao_acumulados() {
        let src = "FOO\nBAR\n";
        let err = assemble(src, "<teste>").unwrap_err();
        assert_eq!(err.lines().count(), 2);
    }

    #[test]
    fn hexadecimal_e_negativo() {
        assert_eq!(parse_int("0x10"), Some(16));
        assert_eq!(parse_int("-5"), Some(-5));
        assert_eq!(parse_int("abc"), None);
    }
}
