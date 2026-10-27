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
fn builder(seed: u64) -> SessionBuilder<Profile> {
    let origin = web_time::Instant::now();
    SessionBuilder::new().with_num_players(2).unwrap().with_max_prediction_window(0)
        .with_protocol_config(ProtocolConfig { clock: Some(Arc::new(move || origin)), protocol_rng_seed: Some(seed),
            quality_report_interval: Duration::from_secs(100), ..Default::default() })
        .with_sync_config(SyncConfig { num_sync_packets: 1, keepalive_interval: Duration::from_secs(100), ..Default::default() })
}
fn observe(viewer: &fortress_rollback::SpectatorSession<Profile>, speed: usize, delay: usize) -> Value {
    let backlog = viewer.frames_behind_host();
    json!({"current": viewer.current_frame().as_i32(), "backlog": backlog,
        "advice": std::cmp::min(backlog.saturating_sub(delay), if backlog.saturating_sub(delay) > 1 { speed } else { 1 }), "catchup": backlog.saturating_sub(delay) > 1})
}
fn run(capacity: usize, preplay: bool, speed: usize, delay: usize, delayed: bool) -> Result<Value, String> {
    let queues = vec![Arc::new(Mutex::new(Queue::default())), Arc::new(Mutex::new(Queue::default()))];
    let mut host = builder(1701).add_player(PlayerType::Local, 0.into()).unwrap()
        .add_player(PlayerType::Local, 1.into()).unwrap()
        .add_player(PlayerType::Spectator("1".into()), 2.into()).unwrap()
        .start_p2p_session(Socket(queues[0].clone())).unwrap();
    let mut viewer = builder(1702).with_spectator_config(SpectatorConfig {
        buffer_size: capacity, catchup_speed: speed, max_frames_behind: 1, stream_delay: delay, ..Default::default() })
        .try_start_spectator_session("0".into(), Socket(queues[1].clone())).unwrap();
    for _ in 0..8 { host.poll_remote_clients(); viewer.poll_remote_clients(); transfer(&queues); }
    if format!("{:?}", viewer.current_state()) != "Running" { return Err("spectator bootstrap incomplete".into()); }
    let mut transcript = Vec::<Vec<i32>>::new();
    let mut observations = vec![observe(&viewer, speed, delay)];
    let mut cycles = Vec::new();
    for frame in 0..12 {
        for attempt in 0..3 {
            if host.current_frame().as_i32() == frame as i32 + 1 { break; }
            if attempt == 2 { return Err("host failed to advance within bounded local-input retries".into()); }
            host.add_local_input(0.into(), (frame % 2) as u8).map_err(|e| format!("{e:?}"))?;
            host.add_local_input(1.into(), 0).map_err(|e| format!("{e:?}"))?;
            for request in host.advance_frame().map_err(|e| format!("{e:?}"))? {
                if !matches!(request, FortressRequest::AdvanceFrame { .. }) { return Err("unexpected host snapshot".into()); }
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
                        for (input, status) in inputs {
                            if status != InputStatus::Confirmed { return Err("unconfirmed spectator input".into()); }
                            row.push(i32::from(input));
                        }
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
    Ok(result)
}
fn main() {
    let result = (|| -> Result<Vec<Value>, String> {
        let mut traces = Vec::new();
        let delayed = std::env::args().any(|argument| argument == "--delayed");
        for preplay in [true, false] { for capacity in if delayed { [4, 5] } else { [2, 3] } { for speed in [1, 2] {
            let delay = if delayed { if preplay { 1 } else { capacity - 1 } } else { 0 };
            traces.push(run(capacity, preplay, speed, delay, delayed)?);
        } } }
        Ok(traces)
    })();
    match result { Ok(value) => println!("{}", json!({"format": 1, "traces": value})),
        Err(error) => { eprintln!("{error}"); std::process::exit(1); } }
}
