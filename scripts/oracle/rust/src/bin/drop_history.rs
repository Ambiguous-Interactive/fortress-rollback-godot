//! Scoped actual-source witness for original history across a coordinated drop.
#![forbid(unsafe_code)]
use fortress_rollback::{Config, DisconnectBehavior, FortressRequest, Frame, InputStatus, Message,
    NonBlockingSocket, P2PSession, PlayerHandle, PlayerType, ProtocolConfig, SessionBuilder, SyncConfig};
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::{Arc, Mutex}, time::Duration};

#[derive(Clone)]
struct Game { frame: i32, values: Vec<i64> }
impl Game {
    fn bytes(&self) -> Vec<u8> {
        let mut result = i64::from(self.frame).to_le_bytes().to_vec();
        for value in &self.values { result.extend(value.to_le_bytes()); }
        result
    }
}
#[derive(Debug)]
struct Profile;
impl Config for Profile { type Input = [u8; 4]; type State = Game; type Address = String; }
#[derive(Default)]
struct Buffers { incoming: Vec<(String, Message, Option<Value>)>, outgoing: Vec<(String, Message)>, received: Vec<Value> }
struct Socket(Arc<Mutex<Buffers>>);
impl NonBlockingSocket<String> for Socket {
    fn send_to(&mut self, message: &Message, address: &String) {
        self.0.lock().unwrap().outgoing.push((address.clone(), message.clone()));
    }
    fn receive_all_messages(&mut self) -> Vec<(String, Message)> {
        let mut queue = self.0.lock().unwrap();
        let messages = std::mem::take(&mut queue.incoming);
        queue.received.extend(messages.iter().filter_map(|(_, message, control)| control.as_ref().map(|record| {
            let mut received = record.clone();
            received["body"] = serde_json::to_value(message).unwrap()["body"].clone();
            received
        })));
        messages.into_iter().map(|(sender, message, _)| (sender, message)).collect()
    }
}
fn sample(player: usize, frame: i32) -> [u8; 4] {
    std::array::from_fn(|index| ((frame as usize * 11 + player * 7 + index) % 251) as u8)
}
fn hex(bytes: &[u8]) -> String { bytes.iter().map(|byte| format!("{byte:02x}")).collect() }
fn advance(session: &mut P2PSession<Profile>, game: &mut Game, player: usize,
    states: &mut BTreeMap<i32, Value>) -> Result<(), String> {
    let slots = game.values.len() / 3;
    for slot in player * slots..(player + 1) * slots {
        session.add_local_input(PlayerHandle::new(slot), sample(slot, game.frame)).map_err(|error| format!("{error:?}"))?;
    }
    for request in session.advance_frame().map_err(|error| format!("{error:?}"))? {
        match request {
            FortressRequest::SaveGameState { cell, frame } => {
                if frame.as_i32() != game.frame || !cell.save(frame, Some(game.clone()), Some(0)) { return Err("save boundary".into()); }
            },
            FortressRequest::LoadGameState { cell, frame } => {
                *game = cell.load().ok_or("missing state")?;
                if frame.as_i32() != game.frame { return Err("load boundary".into()); }
            },
            FortressRequest::AdvanceFrame { inputs } => {
                let at = game.frame;
                let mut rows = Vec::new();
                for (slot, (bytes, status)) in inputs.iter().enumerate() {
                    game.values[slot] += bytes.iter().map(|byte| i64::from(*byte)).sum::<i64>();
                    rows.push(json!({"bytes":hex(bytes), "status":match status {
                        InputStatus::Confirmed => "confirmed", InputStatus::Predicted => "predicted", InputStatus::Disconnected => "disconnected" }}));
                }
                game.frame += 1;
                states.insert(at, json!({"frame":at,"bytes":hex(&game.bytes()),"inputs":rows}));
            },
        }
    }
    Ok(())
}
#[derive(Default)]
struct Fault {
    enabled: bool, dropped: Vec<Value>, commit_enabled: bool, dropped_commit: Vec<Value>, ack_enabled: bool, ack_participant: usize, dropped_ack: Vec<Value>
}
fn route(buffers: &[Arc<Mutex<Buffers>>], missing: bool, silent: bool, control: &mut Vec<Value>, fault: &mut Fault) -> Result<bool, String> {
    let mut delivered = false;
    for (sender, queue) in buffers.iter().enumerate() {
        for (address, message) in std::mem::take(&mut queue.lock().unwrap().outgoing) {
            let recipient = address.parse::<usize>().map_err(|_| "address")?;
            if (missing && sender == 2 && recipient == 0) || (silent && (sender == 2 || recipient == 2)) { continue; }
            let raw = serde_json::to_value(&message).map_err(|error| error.to_string())?;
            let mut emitted_control = None;
            if let Some(body) = raw["body"].as_object() {
                if body.keys().any(|kind| kind.starts_with("Drop")) {
                    let packet = json!({"from":sender,"to":recipient,"body":body,"emission":control.len()});
                    emitted_control = Some(packet.clone());
                    control.push(packet.clone());
                    if fault.ack_enabled && fault.dropped_ack.is_empty() && sender == 1 && recipient == 0
                        && body.get("DropReport").and_then(|value| value.get("stage")).and_then(Value::as_str) == Some("Committed")
                        && body["DropReport"]["participant"].as_u64() == Some(fault.ack_participant as u64) {
                        fault.dropped_ack.push(packet);
                        continue;
                    }
                    if fault.commit_enabled && fault.dropped_commit.is_empty() && sender == 0 && recipient == 1 && body.contains_key("DropCommit") {
                        fault.dropped_commit.push(packet);
                        continue;
                    }
                    if fault.enabled && fault.dropped.is_empty() && sender == 1 && recipient == 0 && body.contains_key("DropBackfill") {
                        fault.dropped.push(packet);
                        continue;
                    }
                }
            }
            buffers[recipient].lock().unwrap().incoming.push((sender.to_string(), message, emitted_control));
            delivered = true;
        }
    }
    Ok(delivered)
}
fn settle(sessions: &mut [P2PSession<Profile>], buffers: &[Arc<Mutex<Buffers>>], missing: bool,
    silent: bool, control: &mut Vec<Value>, fault: &mut Fault) -> Result<(), String> {
    for _ in 0..16 {
        for session in sessions.iter_mut().take(if silent { 2 } else { 3 }) { session.poll_remote_clients(); }
        if !route(buffers, missing, silent, control, fault)? { return Ok(()); }
    }
    Err("unbounded settlement".into())
}
fn run(loss: bool, missing_rows: i32, target_slots: usize, unequal: bool, commit_loss: bool, ack_loss: bool) -> Result<Value, String> {
    let clock = Arc::new(Mutex::new(0_u64));
    let origin = web_time::Instant::now();
    let mut sessions = Vec::new();
    let mut buffers = Vec::new();
    let mut games = vec![Game { frame: 0, values: vec![0; 3 * target_slots] }; 3];
    let mut histories = vec![BTreeMap::new(); 3];
    for peer in 0..3 {
        let shared = clock.clone();
        let protocol = ProtocolConfig { clock: Some(Arc::new(move || origin + Duration::from_micros(*shared.lock().unwrap()))),
            protocol_rng_seed: Some(1701 + peer as u64), quality_report_interval: Duration::from_secs(100), ..Default::default() };
        let sync = SyncConfig { num_sync_packets: 1, keepalive_interval: Duration::from_secs(100), ..Default::default() };
        let mut builder = SessionBuilder::<Profile>::new().with_num_players(3 * target_slots).map_err(|error| format!("{error:?}"))?
            .with_max_prediction_window(8).with_disconnect_behavior(DisconnectBehavior::ContinueWithout)
            .with_protocol_config(protocol).with_sync_config(sync)
            .with_disconnect_timeout(Duration::from_secs(100)).with_disconnect_notify_delay(Duration::from_secs(50));
        for slot in 0..3 * target_slots {
            let kind = if slot / target_slots == peer { PlayerType::Local } else { PlayerType::Remote((slot / target_slots).to_string()) };
            builder = builder.add_player(kind, PlayerHandle::new(slot)).map_err(|error| format!("{error:?}"))?;
        }
        let queue = Arc::new(Mutex::new(Buffers::default()));
        sessions.push(builder.start_p2p_session(Socket(queue.clone())).map_err(|error| format!("{error:?}"))?);
        buffers.push(queue);
    }
    let mut control = Vec::new();
    let mut fault = Fault { enabled: loss, commit_enabled: commit_loss, ack_enabled: ack_loss, ack_participant: target_slots, ..Default::default() };
    settle(&mut sessions, &buffers, false, false, &mut control, &mut fault)?;
    for session in &mut sessions {
        if format!("{:?}", session.current_state()) != "Running" { return Err("bootstrap".into()); }
        session.events().for_each(drop);
    }
    for _ in 0..6 {
        *clock.lock().unwrap() += 1000;
        for player in 0..3 { advance(&mut sessions[player], &mut games[player], player, &mut histories[player])?; }
        settle(&mut sessions, &buffers, false, false, &mut control, &mut fault)?;
    }
    for frame in 6..(8 + missing_rows) {
        *clock.lock().unwrap() += 1000;
        advance(&mut sessions[2], &mut games[2], 2, &mut histories[2])?;
        settle(&mut sessions, &buffers, frame >= 8, false, &mut control, &mut fault)?;
    }
    if unequal {
        *clock.lock().unwrap() += 1000;
        advance(&mut sessions[0], &mut games[0], 0, &mut histories[0])?;
        settle(&mut sessions, &buffers, true, false, &mut control, &mut fault)?;
    }
    let before = (0..2).map(|peer| {
        let ranges = (2 * target_slots..3 * target_slots).map(|slot| {
            let range = sessions[peer].diagnostic_player_retained_input_range(PlayerHandle::new(slot));
            json!({"slot":slot,"first":range.map(|value|value.0.as_i32()),"last":range.map(|value|value.1.as_i32())})
        }).collect::<Vec<_>>();
        json!({"confirmed":sessions[peer].confirmed_frame().as_i32(),"targets":ranges})
    }).collect::<Vec<_>>();
    for session in sessions.iter_mut().take(2) { session.remove_player(PlayerHandle::new(2 * target_slots)).map_err(|error| format!("{error:?}"))?; }
    for _ in 0..160 {
        *clock.lock().unwrap() += 1000;
        settle(&mut sessions, &buffers, true, true, &mut control, &mut fault)?;
    }
    let mut dropped = Vec::new();
    for session in sessions.iter_mut().take(2) {
        dropped.push(session.events().filter(|event| matches!(event, fortress_rollback::FortressEvent::PeerDropped { .. })).count());
    }
    for _ in 0..16 {
        *clock.lock().unwrap() += 1000;
        for player in 0..2 { advance(&mut sessions[player], &mut games[player], player, &mut histories[player])?; }
        settle(&mut sessions, &buffers, true, true, &mut control, &mut fault)?;
    }
    let mut received_controls = Vec::new();
    for queue in buffers.iter().take(2) {
        received_controls.extend(queue.lock().unwrap().received.iter().cloned());
    }
    let mut survivors = Vec::new();
    for peer in 0..2 {
        let mut rows = Vec::new();
        for frame in 0..20 {
            let inputs = sessions[peer].confirmed_inputs_for_frame(Frame::new(frame)).map_err(|error| format!("confirmed row {peer}/{frame}: {error:?}"))?;
            rows.push(json!({"frame":frame,"inputs":inputs.iter().map(|bytes|hex(bytes)).collect::<Vec<_>>(),
                "state":histories[peer].get(&frame).ok_or("missing corrected state")?}));
        }
        survivors.push(json!({"peer":peer,"current_frame":sessions[peer].current_frame().as_i32(),
            "confirmed_frame":sessions[peer].confirmed_frame().as_i32(),"rows":rows}));
    }
    Ok(json!({"format":4,"complete":true,"upstream_revision":"d124c89080004d96971a629bb0427056ee1805e3",
        "missing_rows":missing_rows,"target_slots":target_slots,"before":before,"dropped":dropped,
        "lost_history":fault.dropped,"lost_commit":fault.dropped_commit,"lost_ack":fault.dropped_ack,
        "controls":control,"received_controls":received_controls,"survivors":survivors}))
}
fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let loss = arguments.contains(&"--drop-first-history".into());
    let multi = arguments.contains(&"--multi-row-history".into());
    let grouped = arguments.contains(&"--multiple-target-slots".into());
    let commit_loss = arguments.contains(&"--drop-first-commit".into());
    let ack_loss = arguments.contains(&"--drop-first-ack".into());
    let unequal = arguments.contains(&"--unequal-exposure".into());
    if arguments.len() != usize::from(ack_loss) + usize::from(commit_loss) + usize::from(unequal) + usize::from(loss) + usize::from(multi) + usize::from(grouped) {
        eprintln!("drop history: unexpected argument"); std::process::exit(2);
    }
    match run(loss, if multi { 4 } else { 1 }, if grouped { 2 } else { 1 }, unequal, commit_loss, ack_loss) {
        Ok(result) => println!("{result}"),
        Err(error) => { eprintln!("drop history: {error}"); std::process::exit(2); }
    }
}
