//! Development-only upstream sync-test adapter. Session decisions come from Fortress.
#![forbid(unsafe_code)]

use fortress_rollback::{Config, FortressRequest, InputStatus, PlayerHandle, SessionBuilder};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{self, Read};

const REVISION: &str = "f13cd5c0f2815926785a395947e18da0dbea0dd8";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scenario {
    format: u32,
    upstream_revision: String,
    players: usize,
    input_width: usize,
    check_distance: usize,
    input_delay: usize,
    operations: Vec<Operation>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Operation {
    Input { player: usize, bytes: String },
    Advance {},
    Events {},
}

#[derive(Clone)]
struct Game {
    frame: i32,
    accumulators: Vec<u32>,
}

impl Game {
    fn bytes(&self) -> Vec<u8> {
        let mut bytes = self.frame.to_le_bytes().to_vec();
        for value in &self.accumulators {
            bytes.extend(value.to_le_bytes());
        }
        bytes
    }

    fn checksum(&self) -> u128 {
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in self.bytes() {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
        (u128::from(!hash) << 64) | u128::from(hash)
    }
}

#[derive(Debug)]
struct OracleConfig;
impl Config for OracleConfig {
    type Input = [u8; 4];
    type State = Game;
    type Address = String;
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn input_bytes(text: &str) -> Result<[u8; 4], String> {
    if text.len() != 8 || !text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)) {
        return Err("input bytes must be exactly eight lowercase hexadecimal digits".into());
    }
    let mut bytes = [0; 4];
    for (index, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).map_err(|error| error.to_string())?;
    }
    Ok(bytes)
}

fn state_fields(kind: &str, frame: i32, game: &Game, inputs: Value) -> Value {
    json!({"kind":kind,"frame":frame,"state_bytes":hex(&game.bytes()),
        "checksum":format!("{:032x}",game.checksum()),"inputs":inputs})
}

fn run(original: Value) -> Result<Value, String> {
    let scenario: Scenario = serde_json::from_value(original.clone()).map_err(|error| error.to_string())?;
    if scenario.format != 1 || scenario.upstream_revision != REVISION {
        return Err("unsupported format or upstream revision".into());
    }
    if !(2..=8).contains(&scenario.players) || scenario.input_width != 4 || scenario.check_distance > 7 || scenario.input_delay > 7 {
        return Err("configuration outside supported oracle bounds".into());
    }
    if scenario.operations.is_empty() || scenario.operations.len() > 10_000 {
        return Err("scenario requires 1..10000 operations".into());
    }
    // Validate the entire scenario before invoking any upstream API.
    for operation in &scenario.operations {
        if let Operation::Input { player, bytes } = operation {
            if *player > 255 {
                return Err("player handle exceeds 255".into());
            }
            input_bytes(bytes)?;
        }
    }
    let mut session = SessionBuilder::<OracleConfig>::new()
        .with_num_players(scenario.players).map_err(|error| format!("{error:?}"))?
        .with_check_distance(scenario.check_distance)
        .with_input_delay(scenario.input_delay).map_err(|error| format!("{error:?}"))?
        .start_synctest_session().map_err(|error| format!("{error:?}"))?;
    let mut game = Game { frame: 0, accumulators: vec![0; scenario.players] };
    let mut records = Vec::new();
    for (index, operation) in scenario.operations.iter().enumerate() {
        let before = session.current_frame().as_i32();
        let mut requests = Vec::new();
        let mut events = Vec::new();
        let (kind, error) = match operation {
            Operation::Input { player, bytes } => (
                "input", session.add_local_input(PlayerHandle::new(*player), input_bytes(bytes)?)
                    .err().map(|error| format!("{error:?}"))),
            Operation::Events {} => {
                events.extend(session.events().map(|event| format!("{event:?}")));
                ("events", None)
            }
            Operation::Advance {} => {
                let error = match session.advance_frame() {
                    Err(error) => Some(format!("{error:?}")),
                    Ok(batch) => {
                        for request in batch {
                            match request {
                                FortressRequest::SaveGameState { cell, frame } => {
                                    if game.frame != frame.as_i32() || !cell.save(frame, Some(game.clone()), Some(game.checksum())) {
                                        return Err("upstream requested invalid save boundary".into());
                                    }
                                    requests.push(state_fields("save", frame.as_i32(), &game, json!([])));
                                }
                                FortressRequest::LoadGameState { cell, frame } => {
                                    game = cell.load().ok_or("upstream load boundary has no saved state")?;
                                    if game.frame != frame.as_i32() {
                                        return Err("upstream requested invalid load boundary".into());
                                    }
                                    requests.push(state_fields("load", frame.as_i32(), &game, json!([])));
                                }
                                FortressRequest::AdvanceFrame { inputs } => {
                                    let frame = game.frame;
                                    let mut traced_inputs = Vec::new();
                                    for (player, (input, status)) in inputs.iter().enumerate() {
                                        let status_text = match status {
                                            InputStatus::Confirmed => "confirmed",
                                            InputStatus::Predicted => "predicted",
                                            InputStatus::Disconnected => "disconnected",
                                        };
                                        traced_inputs.push(json!({"player":player,"bytes":hex(input),"status":status_text}));
                                        game.accumulators[player] = game.accumulators[player].wrapping_add(u32::from_le_bytes(*input));
                                    }
                                    game.frame = game.frame.checked_add(1).ok_or("game frame exhausted")?;
                                    requests.push(state_fields("advance", frame, &game, json!(traced_inputs)));
                                }
                            }
                        }
                        None
                    }
                };
                ("advance", error)
            }
        };
        records.push(json!({"index":index,"kind":kind,"result":if error.is_some(){"error"}else{"ok"},"error":error,
            "frame_before":before,"frame_after":session.current_frame().as_i32(),"confirmed_frame":null,"requests":requests,"events":events}));
    }
    Ok(json!({"format":1,"upstream_revision":REVISION,"scenario":original,"operations":records,
        "final_state":{"frame":game.frame,"bytes":hex(&game.bytes()),"checksum":format!("{:032x}",game.checksum())}}))
}

fn main() {
    let result = (|| {
        let mut input = String::new();
        io::stdin().take(4_000_001).read_to_string(&mut input).map_err(|error| error.to_string())?;
        if input.len() > 4_000_000 {
            return Err("scenario exceeds four million bytes".into());
        }
        let original = serde_json::from_str(&input).map_err(|error| error.to_string())?;
        run(original)
    })();
    match result {
        Ok(trace) => println!("{}", serde_json::to_string(&trace).expect("trace serialization")),
        Err(error) => {
            eprintln!("oracle: {error}");
            std::process::exit(2);
        }
    }
}
