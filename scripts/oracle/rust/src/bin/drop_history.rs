//! Scoped actual-source witness for original history across a coordinated drop.
#![forbid(unsafe_code)]
use fortress_rollback::{Config, DisconnectBehavior, FortressRequest, Frame, InputStatus, Message,
    NonBlockingSocket, P2PSession, PlayerHandle, PlayerType, ProtocolConfig, SessionBuilder, SyncConfig};
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::{Arc, Mutex}, time::Duration};

#[derive(Clone)]
struct Game { frame: i32, values: [i64; 3] }
impl Game {
    fn bytes(&self) -> Vec<u8> {
        let mut result = i64::from(self.frame).to_le_bytes().to_vec();
        for value in self.values { result.extend(value.to_le_bytes()); }
        result
    }
}
#[derive(Debug)]
struct Profile;
impl Config for Profile { type Input = [u8; 4]; type State = Game; type Address = String; }
#[derive(Default)]
struct Buffers { incoming: Vec<(String, Message)>, outgoing: Vec<(String, Message)>, received: Vec<(String, Message)> }
struct Socket(Arc<Mutex<Buffers>>);
impl NonBlockingSocket<String> for Socket {
    fn send_to(&mut self, message: &Message, address: &String) {
        self.0.lock().unwrap().outgoing.push((address.clone(), message.clone()));
    }
    fn receive_all_messages(&mut self) -> Vec<(String, Message)> {
        let mut queue = self.0.lock().unwrap();
        let messages = std::mem::take(&mut queue.incoming);
        queue.received.extend(messages.iter().cloned());
        messages
    }
}
fn sample(player: usize, frame: i32) -> [u8; 4] {
    std::array::from_fn(|index| ((frame as usize * 11 + player * 7 + index) % 251) as u8)
}
fn hex(bytes: &[u8]) -> String { bytes.iter().map(|byte| format!("{byte:02x}")).collect() }
fn advance(session: &mut P2PSession<Profile>, game: &mut Game, player: usize,
    states: &mut BTreeMap<i32, Value>) -> Result<(), String> {
    session.add_local_input(PlayerHandle::new(player), sample(player, game.frame)).map_err(|error| format!("{error:?}"))?;
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
fn route(buffers: &[Arc<Mutex<Buffers>>], missing: bool, silent: bool, control: &mut Vec<Value>) -> Result<bool, String> {
    let mut delivered = false;
    for (sender, queue) in buffers.iter().enumerate() {
        for (address, message) in std::mem::take(&mut queue.lock().unwrap().outgoing) {
            let recipient = address.parse::<usize>().map_err(|_| "address")?;
            if (missing && sender == 2 && recipient == 0) || (silent && (sender == 2 || recipient == 2)) { continue; }
            let raw = serde_json::to_value(&message).map_err(|error| error.to_string())?;
            if let Some(body) = raw["body"].as_object() {
                if body.keys().any(|kind| kind.starts_with("Drop")) {
                    control.push(json!({"from":sender,"to":recipient,"body":body}));
                }
            }
            buffers[recipient].lock().unwrap().incoming.push((sender.to_string(), message));
            delivered = true;
        }
    }
    Ok(delivered)
}
fn settle(sessions: &mut [P2PSession<Profile>], buffers: &[Arc<Mutex<Buffers>>], missing: bool,
    silent: bool, control: &mut Vec<Value>) -> Result<(), String> {
    for _ in 0..16 {
        for session in sessions.iter_mut().take(if silent { 2 } else { 3 }) { session.poll_remote_clients(); }
        if !route(buffers, missing, silent, control)? { return Ok(()); }
    }
    Err("unbounded settlement".into())
}
fn run() -> Result<Value, String> {
    let clock = Arc::new(Mutex::new(0_u64));
    let origin = web_time::Instant::now();
    let mut sessions = Vec::new();
    let mut buffers = Vec::new();
    let mut games = vec![Game { frame: 0, values: [0; 3] }; 3];
    let mut histories = vec![BTreeMap::new(); 3];
    for peer in 0..3 {
        let shared = clock.clone();
        let protocol = ProtocolConfig { clock: Some(Arc::new(move || origin + Duration::from_micros(*shared.lock().unwrap()))),
            protocol_rng_seed: Some(1701 + peer as u64), quality_report_interval: Duration::from_secs(100), ..Default::default() };
        let sync = SyncConfig { num_sync_packets: 1, keepalive_interval: Duration::from_secs(100), ..Default::default() };
        let mut builder = SessionBuilder::<Profile>::new().with_num_players(3).map_err(|error| format!("{error:?}"))?
            .with_max_prediction_window(8).with_disconnect_behavior(DisconnectBehavior::ContinueWithout)
            .with_protocol_config(protocol).with_sync_config(sync)
            .with_disconnect_timeout(Duration::from_secs(100)).with_disconnect_notify_delay(Duration::from_secs(50));
        for slot in 0..3 { builder = builder.add_player(if slot == peer { PlayerType::Local } else { PlayerType::Remote(slot.to_string()) },
            PlayerHandle::new(slot)).map_err(|error| format!("{error:?}"))?; }
        let queue = Arc::new(Mutex::new(Buffers::default()));
        sessions.push(builder.start_p2p_session(Socket(queue.clone())).map_err(|error| format!("{error:?}"))?);
        buffers.push(queue);
    }
    let mut control = Vec::new();
    settle(&mut sessions, &buffers, false, false, &mut control)?;
    for session in &mut sessions {
        if format!("{:?}", session.current_state()) != "Running" { return Err("bootstrap".into()); }
        session.events().for_each(drop);
    }
    for _ in 0..6 {
        *clock.lock().unwrap() += 1000;
        for player in 0..3 { advance(&mut sessions[player], &mut games[player], player, &mut histories[player])?; }
        settle(&mut sessions, &buffers, false, false, &mut control)?;
    }
    for frame in 6..9 {
        *clock.lock().unwrap() += 1000;
        advance(&mut sessions[2], &mut games[2], 2, &mut histories[2])?;
        settle(&mut sessions, &buffers, frame == 8, false, &mut control)?;
    }
    let before = (0..2).map(|peer| {
        let range = sessions[peer].diagnostic_player_retained_input_range(PlayerHandle::new(2));
        json!({"confirmed":sessions[peer].confirmed_frame().as_i32(),"target_first":range.map(|value|value.0.as_i32()),
            "target_last":range.map(|value|value.1.as_i32())})
    }).collect::<Vec<_>>();
    for session in sessions.iter_mut().take(2) { session.remove_player(PlayerHandle::new(2)).map_err(|error| format!("{error:?}"))?; }
    for _ in 0..40 {
        *clock.lock().unwrap() += 1000;
        settle(&mut sessions, &buffers, true, true, &mut control)?;
    }
    let mut dropped = Vec::new();
    for session in sessions.iter_mut().take(2) {
        dropped.push(session.events().filter(|event| matches!(event, fortress_rollback::FortressEvent::PeerDropped { .. })).count());
    }
    for _ in 0..16 {
        *clock.lock().unwrap() += 1000;
        for player in 0..2 { advance(&mut sessions[player], &mut games[player], player, &mut histories[player])?; }
        settle(&mut sessions, &buffers, true, true, &mut control)?;
    }
    let mut received_controls = Vec::new();
    for (recipient, queue) in buffers.iter().enumerate().take(2) {
        for (sender, message) in &queue.lock().unwrap().received {
            let raw = serde_json::to_value(message).map_err(|error| error.to_string())?;
            if let Some(body) = raw["body"].as_object() {
                if body.keys().any(|kind| kind.starts_with("Drop")) {
                    received_controls.push(json!({"from":sender.parse::<usize>().map_err(|_|"sender")?,"to":recipient,"body":body}));
                }
            }
        }
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
    Ok(json!({"format":1,"complete":true,"upstream_revision":"f13cd5c0f2815926785a395947e18da0dbea0dd8",
        "before":before,"dropped":dropped,"controls":control,"received_controls":received_controls,"survivors":survivors}))
}
fn main() {
    if std::env::args().len() != 1 { eprintln!("drop history: unexpected argument"); std::process::exit(2); }
    match run() { Ok(result) => println!("{result}"), Err(error) => { eprintln!("drop history: {error}"); std::process::exit(2); } } }
