//! Development-only observation of the unchanged pinned ReplaySession public API.
#![forbid(unsafe_code)]

use fortress_rollback::replay::{Replay, ReplayMetadata};
use fortress_rollback::sessions::replay_session::ReplaySession;
use fortress_rollback::{Config, FortressEvent, FortressRequest, InputStatus, Message, NonBlockingSocket, PlayerType, SessionBuilder};
use fortress_rollback::{FortressError, InvalidRequestKind};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{self, Read};
#[path = "replay/remote.rs"]
mod remote;

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

fn run(case: Case, limit: usize) -> Result<Value, String> {
    if !(2..=8).contains(&case.players) || case.frames.len() > limit || case.frames.len() != case.checksums.len()
        || case.frames.iter().any(|row| row.len() != case.players) {
        return Err("invalid replay dimensions".into());
    }
    let checksums = case.checksums.iter().map(|value| value.as_deref().map(checksum).transpose()).collect::<Result<Vec<_>, _>>()?;
    let replay = Replay { num_players: case.players, frames: case.frames, checksums,
        metadata: ReplayMetadata { library_version: "oracle".into(), num_players: case.players,
            total_frames: case.checksums.len(), skipped_frames: 0 } };
    play_replay(case.name, case.seed, case.validate, replay)
}

fn play_replay(name: String, seed: u32, validate: bool, replay: Replay<u32>) -> Result<Value, String> {
    let mut session = if validate { ReplaySession::<Cfg>::new_with_validation(replay) } else { ReplaySession::<Cfg>::new(replay) }
        .map_err(|e| e.to_string())?;
    let initial = session.current_frame().as_i32();
    let mut state = [0, seed, seed, 0];
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
    Ok(json!({"name":name, "initial_frame":initial, "current_frame":session.current_frame().as_i32(),
        "complete":session.is_complete(), "exhausted":exhausted, "records":records, "events":events, "bytes":hex(&bytes(&state))}))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RecordingCase { name: String, players: usize, count: usize, delay: usize, prediction: usize, seed: u32 }
struct NoNetwork;
impl NonBlockingSocket<String> for NoNetwork {
    fn send_to(&mut self, _: &Message, _: &String) { panic!("all-local recording sent a packet"); }
    fn receive_all_messages(&mut self) -> Vec<(String, Message)> { Vec::new() }
}

fn recording(case: RecordingCase, extract: bool) -> Result<Value, String> {
    if !(2..=8).contains(&case.players) || case.count > 64 || case.delay > 2 || ![0, 2].contains(&case.prediction) {
        return Err("invalid recording dimensions".into());
    }
    let mut builder = SessionBuilder::<Cfg>::new().with_num_players(case.players).map_err(|e| e.to_string())?
        .with_max_prediction_window(case.prediction).with_input_delay(case.delay).map_err(|e| e.to_string())?.with_recording(true);
    for slot in 0..case.players { builder = builder.add_player(PlayerType::Local, slot.into()).map_err(|e| e.to_string())?; }
    let mut session = builder.start_p2p_session(NoNetwork).map_err(|e| e.to_string())?;
    let mut state = [0, case.seed, case.seed, 0];
    let mut records = Vec::new();
    let mut advances = Vec::new();
    let mut saves = Vec::new();
    let mut services = Vec::new();
    let extraction_frame = std::cmp::max(1, case.count / 2);
    let mut extracted = None;
    let mut extracted_bytes = Vec::new();
    let mut extracted_decoded = None;
    for _ in 0..case.count * 2 {
        if state[0] as usize == case.count { break; }
        let frame = state[0];
        let first_record = records.len();
        for slot in 0..case.players {
            let value = case.seed.wrapping_add((frame as u32).wrapping_mul(1234567)).wrapping_add((slot as u32).wrapping_mul(0x1020304));
            session.add_local_input(slot.into(), value).map_err(|e| e.to_string())?;
        }
        for request in session.advance_frame().map_err(|e| e.to_string())? {
            match request {
                FortressRequest::SaveGameState { cell, frame } => {
                    records.push(json!({"kind":"save", "frame":frame.as_i32(), "bytes":hex(&bytes(&state)), "inputs":[]}));
                    saves.push(frame.as_i32());
                    if !cell.save(frame, Some(state), Some(u128::from_le_bytes(bytes(&state).try_into().map_err(|_| "state width")?))) {
                        return Err("recording save refused".into());
                    }
                },
                FortressRequest::AdvanceFrame { inputs } => {
                    let observed: Vec<_> = inputs.iter().map(|(input, status)| json!({"value":input,
                        "status":status.to_string().to_lowercase()})).collect();
                    let frame = state[0];
                    for (slot, (input, _)) in inputs.iter().enumerate() {
                        state[1] = state[1].wrapping_mul(33).wrapping_add(*input).wrapping_add(slot as u32);
                        state[2] = state[2].wrapping_mul(1664525).wrapping_add(1013904223);
                        state[3] = state[3].wrapping_add(state[1]) ^ state[2];
                    }
                    state[0] += 1;
                    records.push(json!({"kind":"advance", "frame":frame, "bytes":hex(&bytes(&state)), "inputs":observed}));
                    advances.push(hex(&bytes(&state)));
                },
                _ => return Err("unexpected recording request".into()),
            }
        }
        let requests: Vec<_> = records[first_record..].iter().map(|record| record["kind"].clone()).collect();
        services.push(json!({"before":frame, "after":state[0], "requests":requests}));
        if extract && state[0] as usize == extraction_frame && extracted.is_none() {
            let replay = session.take_replay().map_err(|e| e.to_string())?;
            extracted_bytes = replay.to_bytes().map_err(|e| e.to_string())?;
            extracted_decoded = Some(Replay::<u32>::from_bytes(&extracted_bytes).map_err(|e| e.to_string())?);
            extracted = Some(replay);
        }
    }
    if state[0] as usize != case.count { return Err("recording did not reach target frame".into()); }
    let second_refused = extract && matches!(session.take_replay(),
        Err(FortressError::InvalidRequestStructured { kind: InvalidRequestKind::NotSupported { .. } }));
    let replay = if extract { extracted.ok_or("extraction boundary not reached")? }
        else { session.into_replay().map_err(|e| e.to_string())? };
    let encoded = replay.to_bytes().map_err(|e| e.to_string())?;
    let decoded = if extract { extracted_decoded.ok_or("missing retained decoded recording")? }
        else { Replay::<u32>::from_bytes(&encoded).map_err(|e| e.to_string())? };
    if replay != decoded { return Err("recording roundtrip changed history".into()); }
    let checksums: Vec<_> = decoded.checksums.iter().map(|value| value.map(|n| hex(&n.to_le_bytes()))).collect();
    let played = play_replay(case.name.clone(), case.seed, true, decoded.clone())?;
    let mut result = json!({"name":case.name, "frames":decoded.frames, "checksums":checksums,
        "skipped":decoded.metadata.skipped_frames, "players":decoded.num_players,
        "total_frames":decoded.metadata.total_frames, "records":records, "advances":advances, "saves":saves, "services":services, "playback":played});
    if extract {
        result["extraction"] = json!({"at":extraction_frame, "final_frame":state[0],
            "early_unchanged":encoded == extracted_bytes
                && decoded.to_bytes().map_err(|e| e.to_string())? == extracted_bytes, "second_extraction_refused":second_refused,
            "later_frames":-1, "later_rows":[], "later_checksums":[], "later_playback":null});
    }
    Ok(result)
}

fn main() -> Result<(), String> {
    let arguments: Vec<_> = std::env::args().skip(1).collect();
    if arguments.len() == 1 && ["--remote-recording", "--remote-recording-withhold", "--remote-recording-neutral",
        "--remote-recording-long", "--remote-recording-neutral-long", "--remote-recording-asymmetric",
        "--remote-recording-pressure", "--remote-recording-pressure-neutral", "--remote-recording-pressure-withhold",
        "--remote-recording-asymmetric-neutral", "--remote-recording-asymmetric-withhold"].contains(&arguments[0].as_str()) {
        println!("{}", remote::run(&arguments[0])?);
        return Ok(());
    }
    let mut input = String::new();
    io::stdin().take(2_097_153).read_to_string(&mut input).map_err(|e| e.to_string())?;
    if input.len() > 2_097_152 { return Err("bundle exceeds byte limit".into()); }
    let extract = arguments == ["--recording-extraction"];
    if arguments == ["--recording"] || extract {
        let cases: Vec<RecordingCase> = serde_json::from_str(&input).map_err(|e| e.to_string())?;
        if cases.is_empty() || cases.len() > 64 { return Err("invalid recording case count".into()); }
        let results = cases.into_iter().map(|case| recording(case, extract)).collect::<Result<Vec<_>, _>>()?;
        println!("{}", json!({"format":1, "cases":results}));
        return Ok(());
    }
    let cases: Vec<Case> = serde_json::from_str(&input).map_err(|e| e.to_string())?;
    if cases.is_empty() || cases.len() > 64 { return Err("invalid case count".into()); }
    let results = cases.into_iter().map(|case| run(case, 64)).collect::<Result<Vec<_>, _>>()?;
    println!("{}", json!({"format":1, "cases":results}));
    Ok(())
}


#[cfg(test)]
mod tests {
    use super::*;

    // Value: protects=the decoded recording's metadata reaches source validation; fails_when=the observer repairs metadata before playback; seam=none
    #[test]
    fn decoded_metadata_reaches_playback_validation() {
        let replay = Replay { num_players: 2, frames: vec![vec![1u32, 2]], checksums: vec![None],
            metadata: ReplayMetadata { library_version: "retained-recording".into(), num_players: 2, total_frames: 1, skipped_frames: 0 } };
        let encoded = replay.to_bytes().expect("valid recording encodes");
        let decoded = Replay::<u32>::from_bytes(&encoded).expect("recording decodes");
        assert!(play_replay("control".into(), 0, true, decoded.clone()).is_ok());
        for field in ["num_players", "total_frames"] {
            let mut malformed = decoded.clone();
            if field == "num_players" { malformed.metadata.num_players = 3; }
            else { malformed.metadata.total_frames = 2; }
            let error = play_replay("malformed".into(), 0, true, malformed).expect_err("source must reject malformed metadata");
            assert!(error.contains(field), "wrong metadata rejection: {error}");
        }
    }
}
