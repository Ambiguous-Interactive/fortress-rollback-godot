//! Development-only upstream SyncLayer harness for the global-floor schedule.
//!
//! Drives the pinned `SyncLayer` through the `tests/unit/test_rollback.gd::global_floor`
//! schedule with the upstream P2P facade's EveryFrame advance sequence minus protocol
//! polling (p2p_session.rs `advance_frame` + `adjust_gamestate`): optional frame-0 save,
//! consistency check plus repair, always-save, confirmed-frame discard, then the
//! synchronized-input advance, and the Session's completion trim of every queue to the
//! committed floor. The two identical frame-0 saves upstream writes collapse to
//! one: both write the same cell at the same frame with no simulation in between. The
//! confirmed frontier is the receipt minimum including staged local samples, the Session's
//! documented external-input boundary; the receive path adds the documented sequential and
//! retained-repeat dedup the protocol layer owns in upstream sessions. Floor, occupancy and
//! retained-row observations come from access-only wrappers appended to an isolated copy of
//! the pinned tree; nothing here reimplements queue or rollback internals.
#![forbid(unsafe_code)]

use fortress_rollback::__internal::SyncLayer;
use fortress_rollback::network::messages::ConnectionStatus;
use fortress_rollback::{Config, Frame, FortressRequest, PlayerHandle};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{self, Read};

const REVISION: &str = "d124c89080004d96971a629bb0427056ee1805e3";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scenario {
    format: u32,
    upstream_revision: String,
    players: usize,
    max_prediction: usize,
    queue_capacity: usize,
    input_width: usize,
    input_delay: usize,
    operations: Vec<Operation>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Operation {
    Receive { player: usize, frame: i32, bytes: String },
    Submit { player: usize, frame: i32, bytes: String },
    Delay { player: usize, value: usize },
    Advance {},
    Observe {},
}

#[derive(Clone)]
struct Game {
    frame: u32,
    rng: u32,
    pending: u32,
    total: u32,
}

impl Game {
    fn new() -> Self {
        Self { frame: 0, rng: 8173, pending: 0, total: 0 }
    }

    fn bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(16);
        bytes.extend(self.frame.to_le_bytes());
        bytes.extend(self.rng.to_le_bytes());
        bytes.extend(self.pending.to_le_bytes());
        bytes.extend(self.total.to_le_bytes());
        bytes
    }

    fn checksum(&self) -> u128 {
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in self.bytes() {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
        (u128::from(!hash) << 64) | u128::from(hash)
    }

    fn checksum_hex(&self) -> String {
        format!("{:032x}", self.checksum())
    }

    fn simulate(&mut self, values: &[[u8; 1]]) -> Result<(), String> {
        self.rng = self.rng.wrapping_mul(1664525).wrapping_add(1013904223);
        self.total = self.total.wrapping_add(self.pending).wrapping_add(self.rng & 255);
        self.pending = 0;
        for (player, value) in values.iter().enumerate() {
            self.pending = self
                .pending
                .wrapping_add((player as u32 + 1).wrapping_mul(u32::from(value[0])));
        }
        self.frame = self.frame.checked_add(1).ok_or("game frame exhausted")?;
        Ok(())
    }
}

#[derive(Clone)]
struct OracleConfig;
impl Config for OracleConfig {
    type Input = [u8; 1];
    type State = Game;
    type Address = u32;
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn hex_decode(text: &str) -> Result<Vec<u8>, String> {
    if text.len() != 2 || !text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)) {
        return Err("input bytes must be two lowercase hexadecimal digits".into());
    }
    Ok(vec![u8::from_str_radix(&text[0..2], 16).map_err(|error| error.to_string())?])
}

fn input_byte(text: &str) -> Result<[u8; 1], String> {
    Ok(hex_decode(text)?[0..1].try_into().expect("one byte"))
}

fn status_text(status: u8) -> &'static str {
    match status {
        0 => "confirmed",
        1 => "predicted",
        _ => "disconnected",
    }
}

/// Records one executed save against the game, mirroring the consumer side of the
/// upstream request stream: the save binds the current state into the pinned cell.
fn save_request(
    layer: &mut SyncLayer<OracleConfig>,
    game: &mut Game,
    requests: &mut Vec<Value>,
) -> Result<(), String> {
    match layer.save_current_state() {
        FortressRequest::SaveGameState { cell, frame } => {
            let recorded = frame.as_i32();
            if game.frame as i32 != recorded
                || !cell.save(frame, Some(game.clone()), Some(game.checksum()))
            {
                return Err("upstream requested an invalid save boundary".into());
            }
            requests.push(json!({"kind":"save","frame":recorded,"state_bytes":hex(&game.bytes()),
                "checksum":game.checksum_hex(),"inputs":[]}));
            Ok(())
        },
        _ => Err("save slot carried a non-save request".into()),
    }
}

fn load_request(
    layer: &mut SyncLayer<OracleConfig>,
    game: &mut Game,
    target: i32,
    requests: &mut Vec<Value>,
) -> Result<(), String> {
    match layer
        .load_frame(Frame::new(target))
        .map_err(|error| format!("{error:?}"))?
    {
        FortressRequest::LoadGameState { cell, frame } => {
            let restored = cell.load().ok_or("upstream load boundary has no saved state")?;
            if restored.frame as i32 != frame.as_i32() {
                return Err("upstream load boundary has a stale frame".into());
            }
            *game = restored;
            requests.push(json!({"kind":"load","frame":frame.as_i32(),"state_bytes":hex(&game.bytes()),
                "checksum":game.checksum_hex(),"inputs":[]}));
            Ok(())
        },
        _ => Err("load slot carried a non-load request".into()),
    }
}

fn synchronized_advance(
    layer: &mut SyncLayer<OracleConfig>,
    game: &mut Game,
    connect: &[ConnectionStatus],
    requests: &mut Vec<Value>,
) -> Result<(), String> {
    let inputs = layer
        .oracle_synchronized(connect)
        .ok_or("synchronized inputs were unavailable for the advance")?;
    let frame = layer.current_frame().as_i32();
    layer.advance_frame();
    let rows: Vec<[u8; 1]> = inputs.iter().map(|(input, _)| *input).collect();
    game.simulate(&rows)?;
    let traced: Vec<Value> = inputs
        .iter()
        .enumerate()
        .map(|(player, (input, status))| {
            json!({"player":player,"bytes":hex(input),"status":status_text(*status)})
        })
        .collect();
    requests.push(json!({"kind":"advance","frame":frame,"state_bytes":hex(&game.bytes()),
        "checksum":game.checksum_hex(),"inputs":traced}));
    Ok(())
}

/// Mirror of the pinned P2P `adjust_gamestate` repair loop in EveryFrame save mode.
fn adjust_gamestate(
    layer: &mut SyncLayer<OracleConfig>,
    game: &mut Game,
    connect: &[ConnectionStatus],
    first_incorrect: i32,
    requests: &mut Vec<Value>,
    prediction: usize,
) -> Result<(), String> {
    let current = layer.current_frame().as_i32();
    let window_floor = (current - prediction as i32).max(0);
    let load_target = first_incorrect.max(window_floor);
    if load_target >= current {
        layer.reset_prediction();
        return Ok(());
    }
    load_request(layer, game, load_target, requests)?;
    layer.reset_prediction();
    let count = current - load_target;
    for index in 0..count {
        if index > 0 {
            save_request(layer, game, requests)?;
        }
        synchronized_advance(layer, game, connect, requests)?;
    }
    Ok(())
}

fn observe(layer: &SyncLayer<OracleConfig>, players: usize) -> Value {
    let floor = layer.oracle_floor();
    let observed: Vec<Value> = (0..players)
        .map(|player| {
            let range = match layer.oracle_range(player) {
                Some((first, last)) => json!([first, last]),
                None => Value::Null,
            };
            let confirmed = match layer.oracle_confirmed(player, floor) {
                Some(row) => Value::String(hex(&row)),
                None => Value::Null,
            };
            let retained = match layer.oracle_retained(player, floor) {
                Some(row) => Value::String(hex(&row)),
                None => Value::Null,
            };
            json!({"range":range,"confirmed_floor":confirmed,"retained_floor":retained})
        })
        .collect();
    json!({"kind":"observe","floor":floor,"players":observed})
}

fn frontier(connect: &[ConnectionStatus]) -> i32 {
    connect.iter().map(|status| status.last_frame.as_i32()).min().unwrap_or(-1)
}

fn run(original: Value) -> Result<Value, String> {
    let scenario: Scenario = serde_json::from_value(original).map_err(|error| error.to_string())?;
    if scenario.format != 1 || scenario.upstream_revision != REVISION {
        return Err("unsupported format or upstream revision".into());
    }
    if !(2..=8).contains(&scenario.players)
        || !(1..=128).contains(&scenario.max_prediction)
        || !(2..=65536).contains(&scenario.queue_capacity)
        || scenario.input_width != 1
        || scenario.input_delay != 0
        || scenario.operations.is_empty()
        || scenario.operations.len() > 10_000
    {
        return Err("configuration outside supported oracle bounds".into());
    }
    // Remote receipts carry scheduled frames, exact while every remote delay is zero.
    for operation in &scenario.operations {
        if let Operation::Receive { bytes, .. } | Operation::Submit { bytes, .. } = operation {
            hex_decode(bytes)?;
        }
    }
    let mut layer = SyncLayer::<OracleConfig>::with_queue_length(
        scenario.players,
        scenario.max_prediction,
        scenario.queue_capacity,
    );
    let mut game = Game::new();
    let mut connect: Vec<ConnectionStatus> =
        (0..scenario.players).map(|_| ConnectionStatus::default()).collect();
    let mut records = Vec::new();
    for (index, operation) in scenario.operations.iter().enumerate() {
        let record = match operation {
            Operation::Receive { player, frame, bytes } => {
                let input = input_byte(bytes)?;
                let staged = connect[*player].last_frame.as_i32();
                // The documented receive boundary: retained repeats dedup, sequential
                // scheduled frames add through the crate's own reclamation path.
                let accepted = if *frame <= staged {
                    layer
                        .oracle_retained(*player, *frame)
                        .map(|row| row == input)
                        .unwrap_or(false)
                } else {
                    let added = layer.oracle_add_remote(*player, *frame, input);
                    if added {
                        connect[*player].last_frame = Frame::new(*frame);
                    }
                    added
                };
                json!({"index":index,"kind":"receive","player":player,"frame":frame,
                    "bytes":bytes,"accepted":accepted})
            },
            Operation::Submit { player, frame, bytes } => {
                let input = input_byte(bytes)?;
                let scheduled = layer.oracle_add_local(*player, *frame, input);
                let accepted = scheduled != -1;
                if accepted {
                    connect[*player].last_frame = Frame::new(scheduled);
                }
                json!({"index":index,"kind":"submit","player":player,"frame":frame,
                    "bytes":bytes,"accepted":accepted,"scheduled":scheduled})
            },
            Operation::Delay { player, value } => {
                let staged = connect[*player].last_frame.as_i32();
                let before = layer
                    .frame_delay(PlayerHandle::new(*player))
                    .map_err(|error| format!("{error:?}"))?;
                let mut record = json!({"index":index,"kind":"delay","player":player,
                    "value":value,"ok":false});
                match layer.set_frame_delay(PlayerHandle::new(*player), *value) {
                    Err(error) => return Err(format!("{error:?}")),
                    Ok(()) => {
                        let frame_delay = layer
                            .frame_delay(PlayerHandle::new(*player))
                            .map_err(|error| format!("{error:?}"))?;
                        let last_added = layer
                            .oracle_last_added(*player)
                            .map_err(|error| format!("{error:?}"))?;
                        // The staged frontier moves with the inserted repeat rows, exactly
                        // like the Session's documented set_input_delay bookkeeping.
                        if staged != -1 {
                            connect[*player].last_frame = Frame::new(staged + (*value as i32 - before as i32));
                        }
                        record["ok"] = json!(true);
                        record["frame_delay"] = json!(frame_delay);
                        record["last_added"] = json!(last_added);
                    },
                }
                record
            },
            Operation::Advance {} => {
                let mut requests = Vec::new();
                let executed = advance_cycle(&mut layer, &mut game, &connect, &mut requests, scenario.max_prediction);
                json!({"index":index,"kind":"advance","advanced":executed.is_ok(),
                    "confirmed_frame":frontier(&connect),"requests":requests})
            },
            Operation::Observe {} => {
                let mut record = observe(&layer, scenario.players);
                record["index"] = json!(index);
                record
            },
        };
        records.push(record);
    }
    Ok(json!({"format":1,"operations":records}))
}

/// One upstream advance cycle: frame-0 save, consistency repair, always-save,
/// confirmed-frame discard and the synchronized-input advance.
fn advance_cycle(
    layer: &mut SyncLayer<OracleConfig>,
    game: &mut Game,
    connect: &[ConnectionStatus],
    requests: &mut Vec<Value>,
    prediction: usize,
) -> Result<(), String> {
    // Upstream writes the frame-0 save and then the unconditional post-check save;
    // both write the same cell at the same frame with no simulation between, so the
    // harness records the single equivalent save.
    let mut saved_current = false;
    if layer.current_frame().as_i32() == 0 {
        save_request(layer, game, requests)?;
        saved_current = true;
    }
    let first_incorrect = layer.oracle_consistency();
    if first_incorrect >= 0 {
        adjust_gamestate(layer, game, connect, first_incorrect, requests, prediction)?;
    }
    if !saved_current {
        save_request(layer, game, requests)?;
    }
    let confirmed = frontier(connect);
    layer.oracle_confirm(confirmed);
    let current = layer.current_frame().as_i32();
    let ahead = if confirmed < 0 { current } else { current - confirmed };
    if ahead >= prediction as i32 {
        return Err("prediction window full".into());
    }
    synchronized_advance(layer, game, connect, requests)?;
    // The session engine trims every queue to the committed floor when the batch
    // completes, so the retained rows and the floor side slot match the Session's
    // documented completion bookkeeping rather than the facade's pre-advance pass.
    layer.oracle_discard_floor((current + 1 - prediction as i32).max(0));
    Ok(())
}

fn main() {
    let result = (|| {
        let mut input = String::new();
        io::stdin().take(4_000_001).read_to_string(&mut input).map_err(|error| error.to_string())?;
        if input.len() > 4_000_000 {
            return Err("scenario exceeds four million bytes".into());
        }
        let original: Value = serde_json::from_str(&input).map_err(|error| error.to_string())?;
        run(original)
    })();
    match result {
        Ok(trace) => println!("{}", serde_json::to_string(&trace).expect("trace serialization")),
        Err(error) => {
            eprintln!("oracle: {error}");
            std::process::exit(2);
        },
    }
}

