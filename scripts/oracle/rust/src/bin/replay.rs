//! Development-only observation of the unchanged pinned ReplaySession public API.
#![forbid(unsafe_code)]

use fortress_rollback::replay::{Replay, ReplayMetadata};
use fortress_rollback::sessions::replay_session::ReplaySession;
use fortress_rollback::{Config, FortressEvent, FortressRequest, InputStatus};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{self, Read};

#[derive(Debug)]
struct Cfg;
impl Config for Cfg {
    type Input = u32;
    type State = [u32; 4];
    type Address = String;
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    name: String,
    players: usize,
    seed: u32,
    validate: bool,
    frames: Vec<Vec<u32>>,
    checksums: Vec<Option<String>>,
}

fn bytes(state: &[u32; 4]) -> Vec<u8> {
    state.iter().flat_map(|value| value.to_le_bytes()).collect()
}

fn hex(data: &[u8]) -> String {
    data.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn checksum(text: &str) -> Result<u128, String> {
    if text.len() != 32 || !text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err("invalid checksum".into());
    }
    let mut result = [0; 16];
    for (index, byte) in result.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).map_err(|e| e.to_string())?;
    }
    Ok(u128::from_le_bytes(result))
}

fn run(case: Case) -> Result<Value, String> {
    if !(2..=8).contains(&case.players) || case.frames.len() > 64 || case.frames.len() != case.checksums.len()
        || case.frames.iter().any(|row| row.len() != case.players) {
        return Err("invalid replay dimensions".into());
    }
    let checksums = case.checksums.iter().map(|value| value.as_deref().map(checksum).transpose()).collect::<Result<Vec<_>, _>>()?;
    let replay = Replay { num_players: case.players, frames: case.frames, checksums,
        metadata: ReplayMetadata { library_version: "oracle".into(), num_players: case.players,
            total_frames: case.checksums.len(), skipped_frames: 0 } };
    let mut session = if case.validate { ReplaySession::<Cfg>::new_with_validation(replay) } else { ReplaySession::<Cfg>::new(replay) }
        .map_err(|e| e.to_string())?;
    let initial = session.current_frame().as_i32();
    let mut state = [0, case.seed, case.seed, 0];
    let mut records = Vec::new();
    let mut events = Vec::new();
    while !session.is_complete() {
        let requests = session.advance_frame().map_err(|e| e.to_string())?;
        for request in requests {
            match request {
                FortressRequest::SaveGameState { cell, frame } => {
                    records.push(json!({"kind":"save", "frame":frame.as_i32(), "bytes":hex(&bytes(&state)), "inputs":[]}));
                    cell.save(frame, Some(state), Some(u128::from_le_bytes(bytes(&state).try_into().map_err(|_| "state width")?)));
                }
                FortressRequest::AdvanceFrame { inputs } => {
                    let observed: Vec<_> = inputs.iter().map(|(input, status)| json!({"value":input,
                        "status":if *status == InputStatus::Confirmed { "confirmed" } else { "unexpected" }})).collect();
                    for (slot, (input, _)) in inputs.iter().enumerate() {
                        state[1] = state[1].wrapping_mul(33).wrapping_add(*input).wrapping_add(slot as u32);
                        state[2] = state[2].wrapping_mul(1664525).wrapping_add(1013904223);
                        state[3] = state[3].wrapping_add(state[1]) ^ state[2];
                    }
                    let frame = state[0];
                    state[0] += 1;
                    records.push(json!({"kind":"advance", "frame":frame, "bytes":hex(&bytes(&state)), "inputs":observed}));
                }
                _ => return Err("unexpected replay request".into()),
            }
        }
        // Includes final-frame validation without an extra advance, as a real completion loop does.
        for event in session.events() {
            match event {
                FortressEvent::ReplayDesync { frame, expected_checksum, actual_checksum } => events.push(json!({
                    "frame":frame.as_i32(), "expected":hex(&expected_checksum.to_le_bytes()), "actual":hex(&actual_checksum.to_le_bytes())})),
                _ => return Err("unexpected replay event".into()),
            }
        }
    }
    let exhausted = session.advance_frame().is_err();
    Ok(json!({"name":case.name, "initial_frame":initial, "current_frame":session.current_frame().as_i32(),
        "complete":session.is_complete(), "exhausted":exhausted, "records":records, "events":events, "bytes":hex(&bytes(&state))}))
}

fn main() -> Result<(), String> {
    let mut input = String::new();
    io::stdin().take(2_097_153).read_to_string(&mut input).map_err(|e| e.to_string())?;
    if input.len() > 2_097_152 { return Err("bundle exceeds byte limit".into()); }
    let cases: Vec<Case> = serde_json::from_str(&input).map_err(|e| e.to_string())?;
    if cases.is_empty() || cases.len() > 64 { return Err("invalid case count".into()); }
    let results = cases.into_iter().map(run).collect::<Result<Vec<_>, _>>()?;
    println!("{}", json!({"format":1, "cases":results}));
    Ok(())
}
