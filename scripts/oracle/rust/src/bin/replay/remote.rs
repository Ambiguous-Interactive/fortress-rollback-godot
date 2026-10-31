//! Actual remote confirmation/correction recording through unchanged source sockets.
use super::*;
use fortress_rollback::{ProtocolConfig, SyncConfig};
use std::{sync::{Arc, Mutex}, time::Duration};

#[derive(Default)]
struct Buffers { incoming: Vec<(String, Message)>, outgoing: Vec<(String, Message)> }
struct Socket(Arc<Mutex<Buffers>>);
impl NonBlockingSocket<String> for Socket {
    fn send_to(&mut self, message: &Message, destination: &String) {
        self.0.lock().unwrap().outgoing.push((destination.clone(), message.clone()));
    }
    fn receive_all_messages(&mut self) -> Vec<(String, Message)> { std::mem::take(&mut self.0.lock().unwrap().incoming) }
}

fn exchange(buffers: &[Arc<Mutex<Buffers>>]) -> usize { exchange_selected(buffers, &[true, true]) }

fn exchange_selected(buffers: &[Arc<Mutex<Buffers>>], eligible: &[bool; 2]) -> usize {
    let mut count = 0;
    for (sender, buffer) in buffers.iter().enumerate() {
        let outgoing = std::mem::take(&mut buffer.lock().unwrap().outgoing);
        for (destination, message) in outgoing {
            let target = destination.parse::<usize>().unwrap();
            if eligible[target] {
                buffers[target].lock().unwrap().incoming.push((sender.to_string(), message));
                count += 1;
            } else { buffer.lock().unwrap().outgoing.push((destination, message)); }
        }
    }
    count
}

pub fn run(mode: &str) -> Result<Value, String> {
    let seed = u32::MAX;
    let withhold = mode == "--remote-recording-withhold";
    let neutral = mode.contains("neutral");
    let asymmetric = mode.contains("asymmetric") || mode.contains("pressure");
    let pressure = mode.contains("pressure");
    let rounds = if mode.ends_with("-long") || asymmetric { 257 } else { 9 };
    let clock = Arc::new(Mutex::new(0u64));
    let origin = web_time::Instant::now();
    let mut sessions = Vec::new();
    let mut buffers = Vec::new();
    for peer in 0..2 {
        let time = clock.clone();
        let protocol = ProtocolConfig { clock: Some(Arc::new(move || origin + Duration::from_micros(*time.lock().unwrap()))),
            protocol_rng_seed: Some(1701 + peer as u64), quality_report_interval: Duration::from_secs(100), ..Default::default() };
        let mut builder = SessionBuilder::<Cfg>::new().with_num_players(2).map_err(|e| e.to_string())?
            .with_max_prediction_window(4).with_recording(true).with_protocol_config(protocol)
            .with_sync_config(SyncConfig { num_sync_packets: 1, keepalive_interval: Duration::from_secs(100), ..Default::default() });
        for slot in 0..2 {
            builder = builder.add_player(if slot == peer { PlayerType::Local } else { PlayerType::Remote(slot.to_string()) }, slot.into())
                .map_err(|e| e.to_string())?;
        }
        let buffer = Arc::new(Mutex::new(Buffers::default()));
        sessions.push(builder.start_p2p_session(Socket(buffer.clone())).map_err(|e| e.to_string())?);
        buffers.push(buffer);
    }
    for _ in 0..8 { for session in &mut sessions { session.poll_remote_clients(); } exchange(&buffers); }
    for session in &mut sessions {
        if format!("{:?}", session.current_state()) != "Running" { return Err("remote bootstrap incomplete".into()); }
        session.events().for_each(drop);
    }
    let mut states = [[0, seed, seed, 0]; 2];
    let mut records = [Vec::new(), Vec::new()];
    let mut services = [Vec::new(), Vec::new()];
    let mut deliveries = Vec::new();
    for turn in 0..if pressure { 400 } else { rounds } {
        if pressure && states.iter().all(|state| state[0] == rounds as u32) { break; }
        *clock.lock().unwrap() = (turn + 1) * 1000;
        for peer in 0..2 {
            if pressure && states[peer][0] == rounds as u32 { continue; }
            let round = if pressure { states[peer][0] as u64 } else { turn };
            let before = states[peer][0];
            let first = records[peer].len();
            let value = if neutral { 0 } else { seed.wrapping_add((round as u32).wrapping_mul(1234567)).wrapping_add((peer as u32).wrapping_mul(0x1020304)) };
            sessions[peer].add_local_input(peer.into(), value).map_err(|e| e.to_string())?;
            for request in sessions[peer].advance_frame().map_err(|e| e.to_string())? {
                match request {
                    FortressRequest::SaveGameState { cell, frame } => {
                        records[peer].push(json!({"kind":"save", "frame":frame.as_i32(), "bytes":hex(&bytes(&states[peer])), "inputs":[]}));
                        if !cell.save(frame, Some(states[peer]), Some(u128::from_le_bytes(bytes(&states[peer]).try_into().unwrap()))) {
                            return Err("remote save refused".into());
                        }
                    }
                    FortressRequest::LoadGameState { cell, frame } => {
                        states[peer] = cell.load().ok_or("missing remote rollback snapshot")?;
                        records[peer].push(json!({"kind":"load", "frame":frame.as_i32(), "bytes":hex(&bytes(&states[peer])), "inputs":[]}));
                    }
                    FortressRequest::AdvanceFrame { inputs } => {
                        let observed: Vec<_> = inputs.iter().map(|(value, status)| json!({"value":value,"status":status.to_string().to_lowercase()})).collect();
                        let frame = states[peer][0];
                        for (slot, (value, _)) in inputs.iter().enumerate() {
                            states[peer][1] = states[peer][1].wrapping_mul(33).wrapping_add(*value).wrapping_add(slot as u32);
                            states[peer][2] = states[peer][2].wrapping_mul(1664525).wrapping_add(1013904223);
                            states[peer][3] = states[peer][3].wrapping_add(states[peer][1]) ^ states[peer][2];
                        }
                        states[peer][0] += 1;
                        records[peer].push(json!({"kind":"advance", "frame":frame, "bytes":hex(&bytes(&states[peer])), "inputs":observed}));
                    }
                }
            }
            if pressure && mode.ends_with("-withhold") && states[peer][0] == before {
                return Err(format!("pressure prediction-window stall: peer={peer} turn={turn} frames=[{},{}]", states[0][0], states[1][0]));
            }
            if states[peer][0] != round as u32 + 1 && !pressure {
                if round == 4 && before == 4 && states[peer][0] == 4 && sessions[peer].metrics().stall_count == 1
                    && records[peer][first..].iter().all(|row| row["kind"] == "save") {
                    if asymmetric {
                        return Err(format!("asymmetric prediction-window stall: peer={peer} round=4 frames=[{},{}]", states[0][0], states[1][0]));
                    }
                    return Err("remote prediction-window stall: round=4 before=4 after=4 stall_count=1".into());
                }
                return Err("unexpected remote nonadvancing batch".into());
            }
            services[peer].push(json!({"round":if pressure { turn } else { round }, "before":before, "after":states[peer][0],
                "requests":records[peer][first..].iter().map(|row| row["kind"].clone()).collect::<Vec<_>>()}));
        }
        let eligible = if pressure { [turn % 2 == 1, turn % 5 == 4 && !mode.ends_with("-withhold")] }
            else if asymmetric { [turn % 2 == 1, turn % 3 == 2 && !mode.ends_with("-withhold")] } else { [turn % 2 == 1; 2] };
        if eligible.iter().any(|value| *value) && !withhold {
            let mut delivered = 0;
            for _ in 0..4 { delivered += exchange_selected(&buffers, &eligible); for session in &mut sessions { session.poll_remote_clients(); } }
            let mut observation = json!({"round":turn,"messages":delivered});
            if asymmetric { observation["eligible"] = json!(eligible); }
            deliveries.push(observation);
        }
    }
    if pressure && states.iter().any(|state| state[0] != rounds as u32) { return Err("pressure service bound exhausted".into()); }
    let mut recovery = Vec::new();
    if asymmetric {
        let mut delivered = 0;
        for _ in 0..4 {
            if !mode.ends_with("-final-missing") { delivered += exchange(&buffers); }
            for session in &mut sessions { session.poll_remote_clients(); }
        }
        let mut errors = Vec::new();
        let mut frontiers = Vec::new();
        for (peer, session) in sessions.iter_mut().enumerate() {
            let before = session.current_frame().as_i32();
            let error = session.advance_frame().err().ok_or("source unexpectedly allowed recovery without a local sample")?;
            errors.push(error.to_string());
            let last_inputs = session.confirmed_inputs_for_frame(fortress_rollback::Frame::new(rounds as i32 - 1))
                .map_err(|_| format!("source final original input unavailable: peer={peer} frame={}", rounds - 1))?;
            frontiers.push(json!({"peer":peer,"current_before":before,"current_frame":session.current_frame().as_i32(),
                "confirmed_frame":session.confirmed_frame().as_i32(),
                "receipt_frame":session.diagnostic_player_receipt_frame((1 - peer).into()).ok_or("missing source receipt frontier")?.as_i32(),
                "last_inputs":last_inputs,"callback_count":records[peer].len()}));
        }
        recovery.push(json!({"messages":delivered,"frames":states.iter().map(|state|state[0]).collect::<Vec<_>>(),
            "errors":errors,"frontiers":frontiers}));
    }
    let mut peers = Vec::new();
    for (peer, session) in sessions.into_iter().enumerate() {
        let replay = session.into_replay().map_err(|e| e.to_string())?;
        let encoded = replay.to_bytes().map_err(|e| e.to_string())?;
        let decoded = Replay::<u32>::from_bytes(&encoded).map_err(|e| e.to_string())?;
        if decoded != replay { return Err("remote recording roundtrip changed".into()); }
        let played = play_replay(format!("remote-{peer}"), seed, true, decoded.clone())?;
        peers.push(json!({"peer":peer,"current_frame":states[peer][0],"bytes":hex(&bytes(&states[peer])),
            "records":records[peer],"services":services[peer],"frames":decoded.frames,
            "checksums":decoded.checksums.iter().map(|n|n.map(|v|hex(&v.to_le_bytes()))).collect::<Vec<_>>(),
            "skipped":decoded.metadata.skipped_frames,"playback":played}));
    }
    let mut result = json!({"format":1,"peers":peers,"deliveries":deliveries});
    if asymmetric { result["recovery"] = json!(recovery); }
    Ok(result)
}
