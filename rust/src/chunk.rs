//! Opcodes, tabela de instruções e o chunk de bytecode.
//!
//! Espelha `c/include/fvm.h` byte a byte: o mesmo arquivo `.fbc` é lido e
//! executado pelas duas implementações, e `tests/` prova isso.

use std::fs;
use std::io;
use std::path::Path;

pub const OP_HALT: u8 = 0;
pub const OP_PUSH: u8 = 1;
pub const OP_POP: u8 = 2;
pub const OP_DUP: u8 = 3;
pub const OP_SWAP: u8 = 4;
pub const OP_ADD: u8 = 5;
pub const OP_SUB: u8 = 6;
pub const OP_MUL: u8 = 7;
pub const OP_DIV: u8 = 8;
pub const OP_MOD: u8 = 9;
pub const OP_NEG: u8 = 10;
pub const OP_LT: u8 = 11;
pub const OP_LE: u8 = 12;
pub const OP_GT: u8 = 13;
pub const OP_GE: u8 = 14;
pub const OP_EQ: u8 = 15;
pub const OP_NE: u8 = 16;
pub const OP_JMP: u8 = 17;
pub const OP_JZ: u8 = 18;
pub const OP_JNZ: u8 = 19;
pub const OP_LOAD: u8 = 20;
pub const OP_STORE: u8 = 21;
pub const OP_RESERVE: u8 = 22;
pub const OP_CALL: u8 = 23;
pub const OP_RET: u8 = 24;
pub const OP_PRINT: u8 = 25;
pub const OP_NEWARR: u8 = 26;
pub const OP_AGET: u8 = 27;
pub const OP_ASET: u8 = 28;
pub const OP_ALEN: u8 = 29;
pub const OP_GC: u8 = 30;
pub const OP_COUNT: usize = 31;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OperandKind {
    None,
    I64,
    Label,
    Slot,
    Call,
}

pub struct OpInfo {
    pub name: &'static str,
    pub op: u8,
    pub kind: OperandKind,
}

/// Fonte única de verdade para montador e desmontador. Em C isso é um array
/// `static const`; aqui é um `const` — mesma garantia, custo zero em runtime.
/// A ordem segue os opcodes, e `debug_assert` em `op_table()` protege isso.
pub const OPS: [OpInfo; OP_COUNT] = [
    OpInfo {
        name: "HALT",
        op: OP_HALT,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "PUSH",
        op: OP_PUSH,
        kind: OperandKind::I64,
    },
    OpInfo {
        name: "POP",
        op: OP_POP,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "DUP",
        op: OP_DUP,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "SWAP",
        op: OP_SWAP,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "ADD",
        op: OP_ADD,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "SUB",
        op: OP_SUB,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "MUL",
        op: OP_MUL,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "DIV",
        op: OP_DIV,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "MOD",
        op: OP_MOD,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "NEG",
        op: OP_NEG,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "LT",
        op: OP_LT,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "LE",
        op: OP_LE,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "GT",
        op: OP_GT,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "GE",
        op: OP_GE,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "EQ",
        op: OP_EQ,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "NE",
        op: OP_NE,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "JMP",
        op: OP_JMP,
        kind: OperandKind::Label,
    },
    OpInfo {
        name: "JZ",
        op: OP_JZ,
        kind: OperandKind::Label,
    },
    OpInfo {
        name: "JNZ",
        op: OP_JNZ,
        kind: OperandKind::Label,
    },
    OpInfo {
        name: "LOAD",
        op: OP_LOAD,
        kind: OperandKind::Slot,
    },
    OpInfo {
        name: "STORE",
        op: OP_STORE,
        kind: OperandKind::Slot,
    },
    OpInfo {
        name: "RESERVE",
        op: OP_RESERVE,
        kind: OperandKind::Slot,
    },
    OpInfo {
        name: "CALL",
        op: OP_CALL,
        kind: OperandKind::Call,
    },
    OpInfo {
        name: "RET",
        op: OP_RET,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "PRINT",
        op: OP_PRINT,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "NEWARR",
        op: OP_NEWARR,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "AGET",
        op: OP_AGET,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "ASET",
        op: OP_ASET,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "ALEN",
        op: OP_ALEN,
        kind: OperandKind::None,
    },
    OpInfo {
        name: "GC",
        op: OP_GC,
        kind: OperandKind::None,
    },
];

pub fn op_info(op: u8) -> Option<&'static OpInfo> {
    let info = OPS.get(op as usize)?;
    debug_assert_eq!(info.op, op, "tabela OPS fora de ordem");
    Some(info)
}

pub fn op_lookup(name: &str) -> Option<&'static OpInfo> {
    OPS.iter().find(|i| i.name.eq_ignore_ascii_case(name))
}

/// Bytecode: opcode de 1 byte seguido do operando em little-endian.
#[derive(Default, Debug)]
pub struct Chunk {
    pub code: Vec<u8>,
    pub entry: u32,
}

impl Chunk {
    pub fn new() -> Self {
        Chunk {
            code: Vec::new(),
            entry: 0,
        }
    }

    pub fn write_u8(&mut self, b: u8) {
        self.code.push(b);
    }

    pub fn write_i32(&mut self, v: i32) {
        self.code.extend_from_slice(&v.to_le_bytes());
    }

    pub fn write_i64(&mut self, v: i64) {
        self.code.extend_from_slice(&v.to_le_bytes());
    }

    /// Corrige um operando de 4 bytes já emitido (resolução de rótulo).
    pub fn patch_i32(&mut self, at: usize, v: i32) {
        self.code[at..at + 4].copy_from_slice(&v.to_le_bytes());
    }

    /// `"FVM1" | u32 entry | u32 len | code[len]`, igual à implementação em C.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let mut out = Vec::with_capacity(12 + self.code.len());
        out.extend_from_slice(b"FVM1");
        out.extend_from_slice(&self.entry.to_le_bytes());
        out.extend_from_slice(&(self.code.len() as u32).to_le_bytes());
        out.extend_from_slice(&self.code);
        fs::write(path, out)
    }

    pub fn load(path: &Path) -> Result<Chunk, String> {
        let raw =
            fs::read(path).map_err(|e| format!("nao consegui abrir '{}': {e}", path.display()))?;
        if raw.len() < 12 || &raw[0..4] != b"FVM1" {
            return Err(format!("'{}' nao e um .fbc valido", path.display()));
        }
        let entry = u32::from_le_bytes(raw[4..8].try_into().unwrap());
        let len = u32::from_le_bytes(raw[8..12].try_into().unwrap()) as usize;
        if 12 + len > raw.len() {
            return Err(format!("'{}' truncado", path.display()));
        }
        Ok(Chunk {
            code: raw[12..12 + len].to_vec(),
            entry,
        })
    }
}
