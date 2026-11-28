//! Scoped actual-source witness for original history across a coordinated drop.
#![forbid(unsafe_code)]
use fortress_rollback::{Config, DisconnectBehavior, FortressError, FortressEvent, FortressRequest, Frame, InputStatus, Message,
    NonBlockingSocket, P2PSession, PlayerHandle, PlayerType, ProtocolConfig, RequestVec, SessionBuilder, SyncConfig};
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::{Arc, Mutex}, time::Duration};

#[cfg(feature = "coordinator-failover")]
#[path = "drop_history/failover.rs"]
mod failover;

#[path = "drop_history/donor_departure.rs"]
mod donor_departure;

const REVISION: &str = match option_env!("FORTRESS_DROP_ORACLE_REVISION") {
    Some(revision) => revision,
    None => "d124c89080004d96971a629bb0427056ee1805e3",
};
const OBSERVE_CHECKSUMS: bool = fortress_rollback::PROTOCOL_VERSION == 6;

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
struct Buffers {
    incoming: Vec<(String, Message, Option<Value>)>, outgoing: Vec<(String, Message, Option<usize>)>,
    received: Vec<Value>, checksums: Vec<Value>, timed_publications: Vec<(usize, u64)>, order: Arc<Mutex<usize>>
}
fn next_order(order: &Arc<Mutex<usize>>, limit: usize) -> usize {
    let mut value = order.lock().unwrap();
    assert!(*value < limit, "bounded control observation order");
    *value += 1;
    *value
}
struct Socket {
    buffers: Arc<Mutex<Buffers>>,
    publication_clock: Option<Arc<Mutex<u64>>>,
    receipt_clock: Option<Arc<Mutex<u64>>>,
    order_limit: usize,
}
impl Socket {
    fn new(buffers: Arc<Mutex<Buffers>>, order_limit: usize) -> Self {
        Self { buffers, publication_clock: None, receipt_clock: None, order_limit }
    }
}
impl NonBlockingSocket<String> for Socket {
    fn send_to(&mut self, message: &Message, address: &String) {
        let mut queue = self.buffers.lock().unwrap();
        let raw = serde_json::to_value(message).unwrap();
        if OBSERVE_CHECKSUMS && raw["body"].get("ChecksumReport").is_some() {
            assert!(queue.checksums.len() < 4096, "bounded checksum observations");
            queue.checksums.push(json!({"to":address,"raw":raw}));
        }
        let control = raw["body"].as_object().is_some_and(|body| body.keys().any(|kind| kind.starts_with("Drop")));
        let order = control.then(|| next_order(&queue.order, self.order_limit));
        if let (Some(clock), Some(order)) = (&self.publication_clock, order) {
            if raw["body"].get("DropBackfill").is_some() || raw["body"].get("DropAbort").is_some() {
                queue.timed_publications.push((order, *clock.lock().unwrap()));
            }
        }
        queue.outgoing.push((address.clone(), message.clone(), order));
    }
    fn receive_all_messages(&mut self) -> Vec<(String, Message)> {
        let mut queue = self.buffers.lock().unwrap();
        let messages = std::mem::take(&mut queue.incoming);
        let order = queue.order.clone();
        queue.received.extend(messages.iter().filter_map(|(_, message, control)| control.as_ref().map(|record| {
            let mut received = record.clone();
            received["order"] = json!(next_order(&order, self.order_limit));
            received["body"] = serde_json::to_value(message).unwrap()["body"].clone();
            if let Some(clock) = &self.receipt_clock {
                received["received_at"] = json!(*clock.lock().unwrap());
            }
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
    apply_requests(session.advance_frame().map_err(|error| format!("{error:?}"))?, game, states)
}
fn apply_requests(requests: RequestVec<Profile>, game: &mut Game, states: &mut BTreeMap<i32, Value>) -> Result<(), String> {
    for request in requests {
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
    enabled: bool, drop_all_history: bool, dropped: Vec<Value>, commit_enabled: bool, dropped_commit: Vec<Value>, ack_enabled: bool, ack_participant: usize,
    dropped_ack: Vec<Value>, inventory_enabled: bool, dropped_inventory: Vec<Value>, prepare_enabled: bool, dropped_prepare: Vec<Value>,
    hold_decision: bool, held_ready: Option<(String, Message, Value)>, held_commit: Option<(String, Message, Value)>,
}
fn route(buffers: &[Arc<Mutex<Buffers>>], missing: bool, silent: bool, control: &mut Vec<Value>, fault: &mut Fault) -> Result<bool, String> {
    let mut delivered = false;
    for (sender, queue) in buffers.iter().enumerate() {
        for (address, message, order) in std::mem::take(&mut queue.lock().unwrap().outgoing) {
            let recipient = address.parse::<usize>().map_err(|_| "address")?;
            if (missing && sender == 2 && recipient == 0) || (silent && (sender == 2 || recipient == 2)) { continue; }
            let raw = serde_json::to_value(&message).map_err(|error| error.to_string())?;
            let mut emitted_control = None;
            if let Some(body) = raw["body"].as_object() {
                if body.keys().any(|kind| kind.starts_with("Drop")) {
                    let packet = json!({"from":sender,"to":recipient,"body":body,"emission":control.len(),"order":order.ok_or("missing control emission order")?});
                    emitted_control = Some(packet.clone());
                    control.push(packet.clone());
                    if fault.hold_decision && sender == 0 && recipient == 1 {
                        // All READY reports or one COMMITTED report can convey the decision without a COMMIT.
                        let stage = body.get("DropReport").and_then(|report| report.get("stage")).and_then(Value::as_str);
                        if body.contains_key("DropCommit") {
                            fault.held_commit.get_or_insert_with(|| (sender.to_string(), message, packet));
                            continue;
                        }
                        if stage == Some("Ready") && body["DropReport"]["participant"] == 0 {
                            fault.held_ready.get_or_insert_with(|| (sender.to_string(), message, packet));
                            continue;
                        }
                        if stage == Some("Committed") {
                            continue;
                        }
                    }
                    if fault.prepare_enabled && fault.dropped_prepare.is_empty() && sender == 0 && recipient == 1
                        && body.contains_key("DropPrepare") {
                        fault.dropped_prepare.push(packet);
                        continue;
                    }
                    if fault.inventory_enabled && fault.dropped_inventory.is_empty() && sender == 1 && recipient == 0
                        && body.get("DropReport").and_then(|value| value.get("stage")).and_then(Value::as_str) == Some("Inventory")
                        && body["DropReport"]["participant"].as_u64() == Some(fault.ack_participant as u64) {
                        fault.dropped_inventory.push(packet);
                        continue;
                    }
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
                    if (fault.drop_all_history || (fault.enabled && fault.dropped.is_empty())) && sender == 1 && recipient == 0
                        && body.contains_key("DropBackfill") {
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
fn run(loss: bool, missing_rows: i32, target_slots: usize, unequal: bool, commit_loss: bool, ack_loss: bool, inventory_loss: bool,
    prepare_loss: bool, warmup: i32, deadline_offset: Option<i64>, drop_all_history: bool) -> Result<Value, String> {
    let clock = Arc::new(Mutex::new(0_u64));
    let origin = web_time::Instant::now();
    let order = Arc::new(Mutex::new(0_usize));
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
        if OBSERVE_CHECKSUMS && deadline_offset.is_none() && !drop_all_history {
            builder = builder.with_desync_detection_mode(fortress_rollback::DesyncDetection::On { interval: 1 });
        }
        for slot in 0..3 * target_slots {
            let kind = if slot / target_slots == peer { PlayerType::Local } else { PlayerType::Remote((slot / target_slots).to_string()) };
            builder = builder.add_player(kind, PlayerHandle::new(slot)).map_err(|error| format!("{error:?}"))?;
        }
        let queue = Arc::new(Mutex::new(Buffers { order: order.clone(), ..Default::default() }));
        let mut socket = Socket::new(queue.clone(), 8192);
        socket.publication_clock = drop_all_history.then(|| clock.clone());
        sessions.push(builder.start_p2p_session(socket)
            .map_err(|error| format!("{error:?}"))?);
        buffers.push(queue);
    }
    let mut control = Vec::new();
    let mut fault = Fault { enabled: loss, drop_all_history, commit_enabled: commit_loss, ack_enabled: ack_loss, ack_participant: target_slots,
        inventory_enabled: inventory_loss, prepare_enabled: prepare_loss, hold_decision: deadline_offset.is_some(), ..Default::default() };
    settle(&mut sessions, &buffers, false, false, &mut control, &mut fault)?;
    for session in &mut sessions {
        if format!("{:?}", session.current_state()) != "Running" { return Err("bootstrap".into()); }
        session.events().for_each(drop);
    }
    for _ in 0..(6 + warmup) {
        *clock.lock().unwrap() += 1000;
        for player in 0..3 { advance(&mut sessions[player], &mut games[player], player, &mut histories[player])?; }
        settle(&mut sessions, &buffers, false, false, &mut control, &mut fault)?;
    }
    for frame in (6 + warmup)..(8 + missing_rows + warmup) {
        *clock.lock().unwrap() += 1000;
        advance(&mut sessions[2], &mut games[2], 2, &mut histories[2])?;
        settle(&mut sessions, &buffers, frame >= 8 + warmup, false, &mut control, &mut fault)?;
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
    let expired_original_rows = (0..2).map(|peer|
        sessions[peer].confirmed_inputs_for_frame(Frame::new(0)).is_err()).collect::<Vec<_>>();
    if drop_all_history {
        return donor_timeout(&mut sessions, &mut games, &mut histories, &buffers, &clock, &mut control, &mut fault, before);
    }
    let started_at = *clock.lock().unwrap();
    let target = PlayerHandle::new(2 * target_slots);
    for session in sessions.iter_mut().take(2) { session.remove_player(target).map_err(|error| format!("{error:?}"))?; }
    let negotiation_rounds = if deadline_offset.is_some() { 16 } else { 160 };
    for _ in 0..negotiation_rounds {
        *clock.lock().unwrap() += 1000;
        if deadline_offset.is_some() {
            // The pending follower retransmits every poll, so this schedule does not settle to an empty outbox.
            for session in sessions.iter_mut().take(2) { session.poll_remote_clients(); }
            route(&buffers, true, true, &mut control, &mut fault)?;
        } else {
            settle(&mut sessions, &buffers, true, true, &mut control, &mut fault)?;
        }
    }
    if let Some(offset) = deadline_offset {
        let (sender, original, emitted) = fault.held_commit.take().ok_or("coordinator did not send held COMMIT")?;
        let (ready_sender, ready, ready_emitted) = fault.held_ready.take().ok_or("coordinator did not send held READY")?;
        let follower = &mut sessions[1];
        let frontier = follower.confirmed_frame();
        let confirmed = |session: &P2PSession<Profile>| -> Result<Vec<String>, String> {
            session.confirmed_inputs_for_frame(frontier)
                .map(|row| row.iter().map(|bytes| hex(bytes)).collect())
                .map_err(|error| format!("confirmed prefix: {error:?}"))
        };
        let original_row = confirmed(follower)?;
        let dropped_before = peer_dropped(follower);
        let target_connected_before = follower.diagnostic_player_connected(target);
        let release = (started_at + 2_000_000).checked_add_signed(offset).ok_or("deadline overflow")?;
        *clock.lock().unwrap() = release;
        buffers[1].lock().unwrap().incoming.extend([
            (ready_sender, ready, Some(ready_emitted.clone())), (sender, original, Some(emitted.clone()))
        ]);
        follower.poll_remote_clients();
        route(&buffers, true, true, &mut control, &mut fault)?;
        let observations = buffers[1].lock().unwrap();
        let received = |original: &Value| observations.received.iter()
            .find(|observation| observation["emission"] == original["emission"]).cloned().ok_or("original decision packet was not read");
        let ready_received = received(&ready_emitted)?;
        let commit_received = received(&emitted)?;
        drop(observations);
        let abort = control.iter().find(|packet| packet["from"] == 1 && packet["to"] == 0 && packet["body"].get("DropAbort").is_some());
        let frame_before = follower.current_frame().as_i32();
        follower.add_local_input(PlayerHandle::new(target_slots), sample(target_slots, frame_before))
            .map_err(|error| format!("deadline input: {error:?}"))?;
        let advance = match follower.advance_frame() {
            Ok(requests) => {
                apply_requests(requests, &mut games[1], &mut histories[1])?;
                "ok"
            },
            Err(FortressError::NotSynchronized) => "not_synchronized",
            Err(error) => return Err(format!("deadline advance: {error:?}")),
        };
        let final_row = confirmed(follower)?;
        let dropped = peer_dropped(follower);
        let target_connected_after = follower.diagnostic_player_connected(target);
        let target_receipt_after = follower.diagnostic_player_receipt_frame(target).map(Frame::as_i32);
        return Ok(json!({"upstream_revision":REVISION, "offset_us":offset,
            "started_us":started_at, "release_us":release, "ready":ready_emitted, "ready_received":ready_received,
            "commit":emitted, "commit_received":commit_received, "abort":abort,
            "state":follower.current_state().to_string(), "dropped_before":dropped_before, "dropped":dropped, "frontier":frontier.as_i32(),
            "row_before":original_row, "row_after":final_row, "advance":advance, "frame_before":frame_before,
            "frame_after":follower.current_frame().as_i32(), "game_frame_after":games[1].frame, "advanced_row":histories[1].get(&frame_before),
            "target_connected_before":target_connected_before, "target_connected_after":target_connected_after,
            "target_receipt_after":target_receipt_after}));
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
        for frame in warmup..(warmup + 20) {
            let inputs = sessions[peer].confirmed_inputs_for_frame(Frame::new(frame)).map_err(|error| format!("confirmed row {peer}/{frame}: {error:?}"))?;
            rows.push(json!({"frame":frame,"inputs":inputs.iter().map(|bytes|hex(bytes)).collect::<Vec<_>>(),
                "state":histories[peer].get(&frame).ok_or("missing corrected state")?}));
        }
        survivors.push(json!({"peer":peer,"current_frame":sessions[peer].current_frame().as_i32(),
            "confirmed_frame":sessions[peer].confirmed_frame().as_i32(),"rows":rows}));
    }
    let mut result = json!({"format":6,"complete":true,"upstream_revision":REVISION,
        "missing_rows":missing_rows,"target_slots":target_slots,"before":before,"dropped":dropped,
        "lost_inventory":fault.dropped_inventory,"lost_prepare":fault.dropped_prepare,"lost_history":fault.dropped,"lost_commit":fault.dropped_commit,"lost_ack":fault.dropped_ack,
        "controls":control,"received_controls":received_controls,"survivors":survivors});
    if warmup > 0 {
        result["warmup"] = json!(warmup);
        result["expired_original_rows"] = json!(expired_original_rows);
    }
    if OBSERVE_CHECKSUMS {
        let mut checksums = Vec::new();
        for (from, buffer) in buffers.iter().enumerate() {
            for mut packet in std::mem::take(&mut buffer.lock().unwrap().checksums) {
                packet["from"] = json!(from);
                checksums.push(packet);
            }
        }
        result["checksums"] = json!(checksums);
    }
    Ok(result)
}
fn exposed_rows(session: &P2PSession<Profile>, first: i32, frontier: i32) -> Result<Vec<Value>, String> {
    (first..=frontier).map(|frame| {
        let inputs = session.confirmed_inputs_for_frame(Frame::new(frame))
            .map_err(|error| format!("confirmed row {frame}: {error:?}"))?;
        Ok(json!({"frame":frame,"inputs":inputs.iter().map(|bytes| hex(bytes)).collect::<Vec<_>>()}))
    }).collect()
}

fn donor_timeout(sessions: &mut [P2PSession<Profile>], games: &mut [Game], histories: &mut [BTreeMap<i32, Value>],
    buffers: &[Arc<Mutex<Buffers>>], clock: &Arc<Mutex<u64>>, control: &mut Vec<Value>, fault: &mut Fault, before: Vec<Value>) -> Result<Value, String> {
    let target = PlayerHandle::new(4);
    let started_us = *clock.lock().unwrap();
    let mut survivors = Vec::new();
    for (peer, session) in sessions.iter_mut().take(2).enumerate() {
        let frontier = session.confirmed_frame().as_i32();
        let first = 3 - peer as i32;
        survivors.push(json!({"peer":peer, "rows_before":exposed_rows(session, first, frontier)?,
            "frame_before":session.current_frame().as_i32(), "game_before":hex(&games[peer].bytes())}));
        session.remove_player(target).map_err(|error| format!("{error:?}"))?;
    }
    // Advance only the protocol clock and deliver survivors' control traffic through the normal socket.
    for _ in 0..=40 {
        for session in sessions.iter_mut().take(2) { session.poll_remote_clients(); }
        route(buffers, true, true, control, fault)?;
        *clock.lock().unwrap() += 50_000;
    }
    for (peer, session) in sessions.iter_mut().take(2).enumerate() {
        let frame = session.current_frame().as_i32();
        for slot in peer * 2..(peer + 1) * 2 {
            session.add_local_input(PlayerHandle::new(slot), sample(slot, frame)).map_err(|error| format!("timeout input: {error:?}"))?;
        }
        let advance = match session.advance_frame() {
            Ok(requests) => {
                apply_requests(requests, &mut games[peer], &mut histories[peer])?;
                "ok"
            },
            Err(FortressError::NotSynchronized) => "not_synchronized",
            Err(error) => return Err(format!("timeout advance: {error:?}")),
        };
        let result = &mut survivors[peer];
        result["rows_after"] = json!(exposed_rows(session, 3 - peer as i32, session.confirmed_frame().as_i32())?);
        result["frame_after"] = json!(session.current_frame().as_i32());
        result["game_after"] = json!(hex(&games[peer].bytes()));
        result["advance"] = json!(advance);
        result["state"] = json!(session.current_state().to_string());
        result["dropped"] = json!(peer_dropped(session));
        result["connected"] = json!((4..6).map(|slot| session.diagnostic_player_connected(PlayerHandle::new(slot))).collect::<Vec<_>>());
        result["target_receipts"] = json!((4..6).map(|slot| session.diagnostic_player_receipt_frame(PlayerHandle::new(slot)).map(Frame::as_i32))
            .collect::<Vec<_>>());
    }
    let received = buffers.iter().take(2).flat_map(|queue| queue.lock().unwrap().received.clone()).collect::<Vec<_>>();
    let mut timed: Vec<_> = buffers.iter().take(2).flat_map(|queue| queue.lock().unwrap().timed_publications.clone()).collect();
    timed.sort_unstable();
    let timed_publications: Vec<_> = timed.into_iter().map(|(order, at_us)| json!({"order":order,"at_us":at_us})).collect();
    Ok(json!({"upstream_revision":REVISION, "before":before, "controls":control, "received_controls":received,
        "started_us":started_us, "timed_publications":timed_publications, "lost_history":fault.dropped, "survivors":survivors}))
}

fn peer_dropped(session: &mut P2PSession<Profile>) -> Vec<Value> {
    session.events().filter_map(|event| match event {
        FortressEvent::PeerDropped { handle, addr } => Some(json!({"handle":handle.as_usize(), "address":addr})),
        _ => None,
    }).collect()
}
fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if let [mode, offset] = arguments.as_slice() {
        if mode == "--coordinator-failover" {
            #[cfg(feature = "coordinator-failover")]
            {
                failover::run(offset);
                return;
            }
            #[cfg(not(feature = "coordinator-failover"))]
            {
                eprintln!("drop history: coordinator failover requires the v6 observer build");
                std::process::exit(2);
            }
        }
        if mode == "--donor-departure" {
            if fortress_rollback::PROTOCOL_VERSION != 6 || !matches!(offset.as_str(), "deliver" | "hold-live" | "silence") {
                eprintln!("drop history: donor departure requires v6 and a supported schedule");
                std::process::exit(2);
            }
            println!("{}", donor_departure::run(offset));
            return;
        }
        if mode == "--commit-deadline" {
            let offset = match offset.as_str() {
                "-1" => -1, "0" => 0, "1" => 1,
                _ => { eprintln!("drop history: unexpected deadline offset"); std::process::exit(2); }
            };
            match run(false, 1, 1, false, false, false, false, false, 0, Some(offset), false) {
                Ok(result) => println!("{result}"),
                Err(error) => { eprintln!("drop history: {error}"); std::process::exit(2); }
            }
            return;
        }
    }
    if arguments == ["--donor-retention-boundary"] {
        if !OBSERVE_CHECKSUMS {
            eprintln!("drop history: donor retention boundary requires the v6 observer build");
            std::process::exit(2);
        }
        println!("{}", donor_departure::retention_boundary());
        return;
    }
    if arguments == ["--drop-all-history"] {
        match run(false, 4, 2, true, false, false, false, false, 0, None, true) {
            Ok(result) => println!("{result}"),
            Err(error) => { eprintln!("drop history: {error}"); std::process::exit(2); }
        }
        return;
    }
    let loss = arguments.contains(&"--drop-first-history".into());
    let multi = arguments.contains(&"--multi-row-history".into());
    let grouped = arguments.contains(&"--multiple-target-slots".into());
    let commit_loss = arguments.contains(&"--drop-first-commit".into());
    let inventory_loss = arguments.contains(&"--drop-first-inventory".into());
    let prepare_loss = arguments.contains(&"--drop-first-prepare".into());
    let ack_loss = arguments.contains(&"--drop-first-ack".into());
    let wrapped = arguments.contains(&"--wrapped-history".into());
    let unequal = arguments.contains(&"--unequal-exposure".into());
    if arguments.len() != usize::from(inventory_loss) + usize::from(prepare_loss) + usize::from(ack_loss) + usize::from(commit_loss) + usize::from(unequal)
        + usize::from(loss) + usize::from(multi) + usize::from(grouped) + usize::from(wrapped) {
        eprintln!("drop history: unexpected argument"); std::process::exit(2);
    }
    match run(loss, if multi { 4 } else { 1 }, if grouped { 2 } else { 1 }, unequal, commit_loss, ack_loss, inventory_loss,
        prepare_loss, if wrapped { 251 } else { 0 }, None, false) {
        Ok(result) => println!("{result}"),
        Err(error) => { eprintln!("drop history: {error}"); std::process::exit(2); }
    }
}
