//! Independent development-only oracle. Compile with pinned rustc 1.94.0.
//! Integer values are JSON strings: neither Godot JSON nor browsers may round them.
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn main() {
    let mut arithmetic = Vec::new();
    let pairs = [
        (0_i64, 0_i64), (-1, 1), (i64::MAX, 1), (i64::MIN, -1),
        (i64::MAX, i64::MAX), (i64::MIN, i64::MIN), (7, -3), (-7, 3), (-7, -3),
        (9007199254740993, 3), (i64::MIN, 3), (i64::MAX, -3),
    ];
    for (a, b) in pairs {
        for (op, value) in [("add", a.wrapping_add(b)), ("sub", a.wrapping_sub(b)), ("mul", a.wrapping_mul(b))] {
            arithmetic.push(format!(r#"{{"op":"{op}","a":"{a}","b":"{b}","value":"{value}"}}"#));
        }
        if b != 0 && !(a == i64::MIN && b == -1) {
            for (op, value) in [("div", a / b), ("rem", a % b)] {
                arithmetic.push(format!(r#"{{"op":"{op}","a":"{a}","b":"{b}","value":"{value}"}}"#));
            }
        }
    }
    for a in [0_i64, -1, 1, i64::MIN, i64::MAX, 0x123456789abcdef] {
        for b in [0_u32, 1, 31, 32, 63] {
            for (op, value) in [("shl", a.wrapping_shl(b)), ("shr", a >> b)] {
                arithmetic.push(format!(r#"{{"op":"{op}","a":"{a}","b":"{b}","value":"{value}"}}"#));
            }
        }
    }
    let mut binary = Vec::new();
    for value in [0_u16, 1, 0x7fff, 0x8000, u16::MAX] {
        let bytes = hex(&value.to_le_bytes());
        binary.push(format!(r#"{{"kind":"u16","limbs":["{value}"],"bytes":"{bytes}"}}"#));
    }
    for value in [0_u32, 1, 0x7fffffff, 0x80000000, u32::MAX, 0x12345678] {
        let bytes = hex(&value.to_le_bytes());
        binary.push(format!(r#"{{"kind":"u32","limbs":["{value}"],"bytes":"{bytes}"}}"#));
    }
    for value in [0_u64, 1, 0x7fffffffffffffff, 0x8000000000000000, u64::MAX, 0x0123456789abcdef] {
        let bytes = hex(&value.to_le_bytes());
        let (low, high) = (value as u32, (value >> 32) as u32);
        binary.push(format!(r#"{{"kind":"u64","limbs":["{low}","{high}"],"bytes":"{bytes}"}}"#));
    }
    for value in [i32::MIN, -1, 0, 1, i32::MAX] {
        let bytes = hex(&value.to_le_bytes());
        binary.push(format!(r#"{{"kind":"i32","value":"{value}","bytes":"{bytes}"}}"#));
    }
    for value in [0_u128, 1, (1_u128 << 127) - 1, 1_u128 << 127, u128::MAX, 0x0123456789abcdef_fedcba9876543210] {
        let bytes = hex(&value.to_le_bytes());
        let limbs: Vec<String> = (0..4).map(|i| format!("\"{}\"", (value >> (i * 32)) as u32)).collect();
        binary.push(format!(r#"{{"kind":"u128","limbs":[{}],"bytes":"{bytes}"}}"#, limbs.join(",")));
    }
    let mut checksums = Vec::new();
    for data in [b"".as_slice(), b"hello", b"a", b"foobar", &[0xff], &[0; 8], &[0xff; 8], &i64::MIN.to_le_bytes()] {
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in data { hash = (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3); }
        checksums.push(format!(r#"{{"input":"{}","digest":"{}","bytes":"{}"}}"#, hex(data), hash as i64, hex(&hash.to_le_bytes())));
    }
    println!("{{\n  \"schema_version\": 1,\n  \"arithmetic\": [\n    {}\n  ],", arithmetic.join(",\n    "));
    println!("  \"binary\": [\n    {}\n  ],\n  \"checksums\": [\n    {}\n  ]\n}}", binary.join(",\n    "), checksums.join(",\n    "));
}
