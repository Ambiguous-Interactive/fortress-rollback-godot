//! Observe actual pinned host/spectator sessions through fake, bounded delivery.
#![forbid(unsafe_code)]
use fortress_rollback::{Config, FortressRequest, InputStatus, Message, NonBlockingSocket,
    PlayerType, ProtocolConfig, SessionBuilder, SpectatorConfig, SyncConfig};
use serde_json::{json, Value};
use std::{sync::{Arc, Mutex}, time::Duration};
#[derive(Debug)]
struct Profile;
impl Config for Profile { type Input = u8; type State = (); type Address = String; }
#[derive(Default)]
struct Queue { incoming: Vec<(String, Message)>, outgoing: Vec<(String, Message)> }
struct Socket(Arc<Mutex<Queue>>);
impl NonBlockingSocket<String> for Socket {
    fn send_to(&mut self, message: &Message, address: &String) {
        self.0.lock().unwrap().outgoing.push((address.clone(), message.clone()));
    }
    fn receive_all_messages(&mut self) -> Vec<(String, Message)> {
        std::mem::take(&mut self.0.lock().unwrap().incoming)
    }
}
fn transfer(queues: &[Arc<Mutex<Queue>>]) {
    for (source, queue) in queues.iter().enumerate() {
        for (destination, message) in std::mem::take(&mut queue.lock().unwrap().outgoing) {
            queues[destination.parse::<usize>().unwrap()].lock().unwrap().incoming.push((source.to_string(), message));
        }
    }
}
fn builder(seed: u64, players: usize) -> SessionBuilder<Profile> {
    let origin = web_time::Instant::now();
    SessionBuilder::new().with_num_players(players).unwrap().with_max_prediction_window(0)
        .with_protocol_config(ProtocolConfig { clock: Some(Arc::new(move || origin)), protocol_rng_seed: Some(seed),
            quality_report_interval: Duration::from_secs(100), ..Default::default() })
        .with_sync_config(SyncConfig { num_sync_packets: 1, keepalive_interval: Duration::from_secs(100), ..Default::default() })
}
fn observe(viewer: &fortress_rollback::SpectatorSession<Profile>, speed: usize, delay: usize) -> Value {
    let backlog = viewer.frames_behind_host();
    json!({"current": viewer.current_frame().as_i32(), "backlog": backlog,
        "advice": std::cmp::min(backlog.saturating_sub(delay), if backlog.saturating_sub(delay) > 1 { speed } else { 1 }), "catchup": backlog.saturating_sub(delay) > 1})
}
fn run(capacity: usize, preplay: bool, speed: usize, delay: usize, delayed: bool, players: usize, roster: bool, statuses: bool, reserved_slot: usize) -> Result<Value, String> {
    let queues = (0..(if statuses { 3 } else { 2 })).map(|_| Arc::new(Mutex::new(Queue::default()))).collect::<Vec<_>>();
    let mut host_builder = builder(1701, players);
    if statuses { host_builder = host_builder.with_max_prediction_window(1); }
    for player in 0..players {
        if statuses && player == reserved_slot {
            #[cfg(feature = "spectator-status")]
            { host_builder = host_builder.add_reserved_player("2".into(), player.into()).unwrap(); }
            #[cfg(not(feature = "spectator-status"))]
            { return Err("status observer requires spectator-status feature".into()); }
        } else { host_builder = host_builder.add_player(PlayerType::Local, player.into()).unwrap(); }
    }
    let mut host = host_builder.add_player(PlayerType::Spectator("1".into()), players.into()).unwrap()
        .start_p2p_session(Socket(queues[0].clone())).unwrap();
    let mut viewer_builder = builder(1702, players);
    if statuses { viewer_builder = viewer_builder.with_max_prediction_window(1); }
    let mut viewer = viewer_builder.with_spectator_config(SpectatorConfig {
        buffer_size: capacity, catchup_speed: speed, max_frames_behind: 1, stream_delay: delay, ..Default::default() })
        .try_start_spectator_session("0".into(), Socket(queues[1].clone())).unwrap();
    for _ in 0..8 { host.poll_remote_clients(); viewer.poll_remote_clients(); transfer(&queues); }
    if format!("{:?}", viewer.current_state()) != "Running" {
        return Err(format!("spectator bootstrap incomplete: host={:?} viewer={:?} host-events={:?} viewer-events={:?}",
            host.current_state(), viewer.current_state(), host.events().collect::<Vec<_>>(), viewer.events().collect::<Vec<_>>()));
    }
    let mut transcript = Vec::<Vec<i32>>::new();
    let mut state = 0_i64;
    let mut observations = vec![observe(&viewer, speed, delay)];
    let mut cycles = Vec::new();
    for frame in 0..12 {
        for attempt in 0..3 {
            if host.current_frame().as_i32() == frame as i32 + 1 { break; }
            if attempt == 2 { return Err("host failed to advance within bounded local-input retries".into()); }
            for player in 0..players {
                if statuses && player == reserved_slot { continue; }
                let input = if roster { ((frame * 17 + player * 31 + frame * player) % 256) as u8 }
                    else if player == 0 { (frame % 2) as u8 } else { 0 };
                host.add_local_input(player.into(), input).map_err(|e| format!("{e:?}"))?;
            }
            for request in host.advance_frame().map_err(|e| format!("{e:?}"))? {
                match request {
                    FortressRequest::AdvanceFrame { .. } => {},
                    FortressRequest::SaveGameState { cell, frame } if statuses => {
                        if !cell.save(frame, Some(()), Some(0)) { return Err("reserved host save refused".into()); }
                    },
                    _ => return Err("unexpected host snapshot".into()),
                }
            }
        }
        host.poll_remote_clients(); transfer(&queues); viewer.poll_remote_clients(); transfer(&queues);
        observations.push(observe(&viewer, speed, delay));
        let service = if delayed { viewer.frames_behind_host() == capacity }
            else { (preplay && frame % capacity == capacity - 1) || (!preplay && frame % capacity == 0) };
        if service || frame == 11 {
            while viewer.frames_behind_host() > delay {
                let before = observe(&viewer, speed, delay);
                let requests = viewer.advance_frame().map_err(|e| format!("{e:?}"))?;
                let mut count = 0;
                for request in requests {
                    if let FortressRequest::AdvanceFrame { inputs } = request {
                        let mut row = vec![transcript.len() as i32];
                        for (player, (input, status)) in inputs.into_iter().enumerate() {
                            let expected = if statuses && player == reserved_slot { InputStatus::Disconnected } else { InputStatus::Confirmed };
                            if status != expected { return Err(format!("unexpected spectator status at slot {player}: {status:?}")); }
                            row.push(i32::from(input));
                            if statuses {
                                let code = if status == InputStatus::Disconnected { 3 } else { 1 };
                                row.push(code);
                                state = (state * 17 + i64::from(input) + i64::from(code) * 31 + transcript.len() as i64) % 1_000_000_007;
                            }
                        }
                        if statuses { row.push(state as i32); }
                        transcript.push(row); count += 1;
                    } else { return Err("unexpected spectator snapshot".into()); }
                }
                if count == 0 { return Err("spectator made no progress".into()); }
                cycles.push(json!({"before": before, "steps": count, "after": observe(&viewer, speed, delay)}));
            }
            observations.push(observe(&viewer, speed, delay));
            if viewer.advance_frame().is_ok() { return Err("spectator did not stall on empty input".into()); }
        }
    }
    let mut result = json!({"capacity": capacity, "preplay": preplay, "speed": speed,
        "observations": observations, "cycles": cycles, "transcript": transcript});
    if delayed { result["delay"] = json!(delay); }
    if roster { result["players"] = json!(players); }
    if statuses { result["reserved_slot"] = json!(reserved_slot); }
    Ok(result)
}
fn main() {
    let result = (|| -> Result<Vec<Value>, String> {
        let mut traces = Vec::new();
        let statuses = std::env::args().any(|argument| argument == "--statuses");
        let roster = statuses || std::env::args().any(|argument| argument == "--roster");
        let delayed = roster || std::env::args().any(|argument| argument == "--delayed");
        for players in if roster { (2..=8).collect::<Vec<_>>() } else { vec![2] } {
        for reserved_slot in if statuses { std::iter::once(players - 1).chain(0..players - 1).collect::<Vec<_>>() } else { vec![players - 1] } {
        for preplay in [true, false] { for capacity in if delayed { [4, 5] } else { [2, 3] } { for speed in [1, 2] {
            let delay = if delayed { if preplay { 1 } else { capacity - 1 } } else { 0 };
            traces.push(run(capacity, preplay, speed, delay, delayed, players, roster, statuses, reserved_slot)?);
        } } } } }
        Ok(traces)
    })();
    match result { Ok(value) => println!("{}", json!({"format": 1, "traces": value})),
        Err(error) => { eprintln!("{error}"); std::process::exit(1); } }
}
