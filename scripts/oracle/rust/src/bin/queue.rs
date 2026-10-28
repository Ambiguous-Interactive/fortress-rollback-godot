//! Development-only calls to the pinned queue; no queue algorithm is translated.
#![forbid(unsafe_code)]
use fortress_rollback::{__internal::{InputQueue, PlayerInput}, Config, Frame, InputStatus};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{self, Read};

const REVISION: &str = "d124c89080004d96971a629bb0427056ee1805e3";
#[derive(Debug)]
struct QueueConfig;
impl Config for QueueConfig {
    type Input = [u8; 32];
    type State = ();
    type Address = String;
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Bundle { format: u32, upstream_revision: String, cases: Vec<Case> }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Case { name: String, capacity: usize, input_width: usize, player: usize, operations: Vec<Operation> }
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Operation {
    Add { frame: i32, bytes: String },
    AddReclaim { frame: i32, bytes: String, floor: i32 },
    DelayReclaim { value: usize, floor: i32 },
    Retained { frame: i32 },
    Read { frame: i32 },
    Confirmed { frame: i32 },
    Discard { frame: i32 },
    Delay { value: usize },
    Reset {},
}
fn bytes(text: &str, width: usize) -> Result<[u8; 32], String> {
    if text.len() != width * 2 || !text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err("invalid input bytes".into());
    }
    let mut result = [0; 32];
    for (index, byte) in result.iter_mut().take(width).enumerate() {
        *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).map_err(|e| e.to_string())?;
    }
    Ok(result)
}
fn hex(bytes: &[u8]) -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() }
fn run(original: Value) -> Result<Value, String> {
    let bundle: Bundle = serde_json::from_value(original.clone()).map_err(|e| e.to_string())?;
    if bundle.format != 1 || bundle.upstream_revision != REVISION || bundle.cases.is_empty() || bundle.cases.len() > 1000 {
        return Err("unsupported bundle format, revision or case count".into());
    }
    let mut names = std::collections::BTreeSet::new();
    for case in &bundle.cases {
        if case.name.is_empty() || !names.insert(&case.name) || !(2..=128).contains(&case.capacity)
            || !(1..=32).contains(&case.input_width) || case.player > 7 || case.operations.is_empty() || case.operations.len() > 10000 {
            return Err("invalid queue case".into());
        }
        for operation in &case.operations {
            match operation {
                Operation::Add { frame, bytes: text } => { if !(0..=100000).contains(frame) { return Err("frame out of oracle bounds".into()); } bytes(text, case.input_width)?; },
                Operation::Read { frame } | Operation::Confirmed { frame } | Operation::Retained { frame } | Operation::Discard { frame } => {
                    if !(0..=100000).contains(frame) { return Err("frame out of oracle bounds".into()); }
                },
                Operation::AddReclaim { frame, bytes: text, floor } => {
                    if !(0..=100000).contains(frame) || !(0..=100000).contains(floor) { return Err("frame out of oracle bounds".into()); }
                    bytes(text, case.input_width)?;
                },
                Operation::DelayReclaim { value, floor } => {
                    if *value > 128 || !(0..=100000).contains(floor) { return Err("delay or floor out of oracle bounds".into()); }
                },
                Operation::Delay { value } => { if *value > 128 { return Err("delay out of oracle bounds".into()); } },
                Operation::Reset {} => {},
            }
        }
    }
    let mut cases = Vec::new();
    for case in bundle.cases {
        let mut queue = InputQueue::<QueueConfig>::with_queue_length(case.player, case.capacity).ok_or("queue construction failed")?;
        let mut records = Vec::new();
        for (index, operation) in case.operations.iter().enumerate() {
            let mut frame = -1;
            let mut payload = String::new();
            let mut status = "none";
            let (kind, accepted) = match operation {
                Operation::Add { frame: sample, bytes: text } => {
                    frame = queue.add_input(PlayerInput::new(Frame::new(*sample), bytes(text, case.input_width)?)).as_i32();
                    ("add", frame >= 0)
                },
                Operation::AddReclaim { frame: sample, bytes: text, floor } => {
                    frame = queue.oracle_add_reclaim(PlayerInput::new(Frame::new(*sample), bytes(text, case.input_width)?), Frame::new(*floor)).as_i32();
                    ("add_reclaim", frame >= 0)
                },
                Operation::DelayReclaim { value, floor } => ("delay_reclaim", queue.oracle_delay_reclaim(*value, Frame::new(*floor)).is_ok()),
                Operation::Retained { frame: target } => {
                    let value = queue.oracle_retained(Frame::new(*target));
                    if let Some(input) = &value { frame = input.frame.as_i32(); payload = hex(&input.input[..case.input_width]); status = "confirmed"; }
                    ("retained", value.is_some())
                },
                Operation::Delay { value } => ("delay", queue.set_frame_delay(*value).is_ok()),
                Operation::Reset {} => { queue.reset_prediction(); ("reset", true) },
                Operation::Discard { frame: target } => { queue.discard_confirmed_frames(Frame::new(*target)); ("discard", true) },
                Operation::Read { frame: target } => {
                    let value = queue.input(Frame::new(*target));
                    if let Some((input, input_status)) = value {
                        frame = *target; payload = hex(&input[..case.input_width]);
                        status = match input_status { InputStatus::Confirmed => "confirmed", InputStatus::Predicted => "predicted", InputStatus::Disconnected => "disconnected" };
                    }
                    ("read", value.is_some())
                },
                Operation::Confirmed { frame: target } => {
                    let value = queue.confirmed_input(Frame::new(*target));
                    if let Ok(input) = &value { frame = input.frame.as_i32(); payload = hex(&input.input[..case.input_width]); status = "confirmed"; }
                    ("confirmed", value.is_ok())
                },
            };
            records.push(json!({"index":index,"kind":kind,"accepted":accepted,"frame":frame,"bytes":payload,"status":status,
                "first_incorrect":queue.first_incorrect_frame().as_i32(),"delay":queue.frame_delay()}));
        }
        cases.push(json!({"name":case.name,"records":records}));
    }
    Ok(json!({"format":1,"upstream_revision":REVISION,"cases":cases,"complete":true}))
}
fn main() {
    let result = (|| {
        let mut input = String::new();
        io::stdin().take(8000001).read_to_string(&mut input).map_err(|e| e.to_string())?;
        if input.len() > 8000000 { return Err("bundle too large".into()); }
        run(serde_json::from_str(&input).map_err(|e| e.to_string())?)
    })();
    match result {
        Ok(value) => println!("{}", value),
        Err(error) => { eprintln!("queue oracle: {error}"); std::process::exit(2); },
    }
}
