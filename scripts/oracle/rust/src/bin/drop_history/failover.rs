use super::*;
use fortress_rollback::network::codec;
use serde::Deserialize;

#[derive(Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
struct Schedule {
    peers: usize,
    warmup: usize,
    target: usize,
    coordinator: usize,
    target_silence_us: u64,
    tick_us: usize,
    delay_us: u64,
    disconnect_us: u64,
    deadline_us: u64,
    coordinator_silence_us: u64,
    through_us: u64,
}

impl Schedule {
    fn active(&self, peer: usize, now: u64) -> bool {
        (peer != self.target || now < self.target_silence_us)
            && (peer != self.coordinator || now < self.coordinator_silence_us)
    }
}

type Queues = Vec<Arc<Mutex<Buffers>>>;

struct Packet {
    from: usize,
    to: usize,
    message: Message,
    control: Option<Value>,
}

fn build(schedule: &Schedule, clock: &Arc<Mutex<u64>>) -> (Vec<P2PSession<Profile>>, Queues) {
    let origin = web_time::Instant::now();
    let order = Arc::new(Mutex::new(0));
    let mut sessions = Vec::new();
    let mut buffers = Vec::new();
    for peer in 0..schedule.peers {
        let shared = clock.clone();
        let protocol = ProtocolConfig {
            clock: Some(Arc::new(move || origin + Duration::from_micros(*shared.lock().unwrap()))),
            protocol_rng_seed: Some(1701 + peer as u64),
            quality_report_interval: Duration::from_millis(1),
            ..Default::default()
        };
        let sync = SyncConfig {
            num_sync_packets: 1,
            keepalive_interval: Duration::from_millis(1),
            ..Default::default()
        };
        let mut builder = SessionBuilder::<Profile>::new().with_num_players(schedule.peers).unwrap()
            .with_max_prediction_window(8).with_disconnect_behavior(DisconnectBehavior::ContinueWithout)
            .with_protocol_config(protocol).with_sync_config(sync)
            .with_disconnect_timeout(Duration::from_micros(schedule.disconnect_us))
            .with_disconnect_notify_delay(Duration::from_millis(100));
        for slot in 0..schedule.peers {
            let kind = if slot == peer { PlayerType::Local } else { PlayerType::Remote(slot.to_string()) };
            builder = builder.add_player(kind, PlayerHandle::new(slot)).unwrap();
        }
        let queue = Arc::new(Mutex::new(Buffers { order: order.clone(), ..Default::default() }));
        let socket = Socket::new(queue.clone(), 32_768);
        sessions.push(builder.start_p2p_session(socket).unwrap());
        buffers.push(queue);
    }
    (sessions, buffers)
}

fn drain(buffers: &Queues, now: u64) -> Vec<Packet> {
    let mut packets = Vec::new();
    for (from, buffer) in buffers.iter().enumerate() {
        for (to, message, order) in std::mem::take(&mut buffer.lock().unwrap().outgoing) {
            let to = to.parse().unwrap();
            let control = order.map(|id| json!({"id":id, "from":from, "to":to, "sent_us":now, "raw":message,
                "bytes":hex(&codec::encode(&message).unwrap())}));
            packets.push(Packet { from, to, message, control });
        }
    }
    packets
}

fn deliver(packet: Packet, buffers: &Queues, now: u64) {
    let Packet { from, to, mut message, control } = packet;
    let control = control.map(|mut record| {
        let bytes = codec::encode(&message).unwrap();
        let (decoded, consumed) = codec::decode_message(&bytes).unwrap();
        assert_eq!(consumed, bytes.len());
        assert_eq!(record["bytes"], hex(&bytes));
        message = decoded;
        record["received_us"] = json!(now);
        record
    });
    buffers[to].lock().unwrap().incoming.push((from.to_string(), message, control));
}

fn settle(sessions: &mut [P2PSession<Profile>], buffers: &Queues) {
    for _ in 0..7 {
        for packet in drain(buffers, 0) {
            deliver(packet, buffers, 0);
        }
        for session in sessions.iter_mut() {
            session.poll_remote_clients();
        }
    }
}

fn snapshot(session: &P2PSession<Profile>, game: &Game, history: &BTreeMap<i32, Value>, peer: usize) -> Value {
    let rows = (0..5).map(|frame| {
        let inputs = session.confirmed_inputs_for_frame(Frame::new(frame)).unwrap();
        json!({"frame":frame, "inputs":inputs.iter().map(|bytes| hex(bytes)).collect::<Vec<_>>(), "bytes":history[&frame]["bytes"]})
    }).collect::<Vec<_>>();
    json!({"peer":peer, "confirmed":session.confirmed_frame().as_i32(), "rows":rows,
        "frame":game.frame, "game_bytes":hex(&game.bytes()), "state":format!("{:?}",session.current_state())})
}

pub(super) fn run(path: &str) {
    assert_eq!(fortress_rollback::PROTOCOL_VERSION, 6);
    let schedule: Schedule = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let clock = Arc::new(Mutex::new(0_u64));
    let (mut sessions, buffers) = build(&schedule, &clock);
    let mut games = vec![Game { frame: 0, values: vec![0; schedule.peers] }; schedule.peers];
    let mut histories = vec![BTreeMap::new(); schedule.peers];
    settle(&mut sessions, &buffers);
    for session in &mut sessions {
        assert_eq!(format!("{:?}", session.current_state()), "Running");
        session.events().for_each(drop);
    }
    for _ in 0..schedule.warmup {
        *clock.lock().unwrap() += 1000;
        for peer in 0..schedule.peers {
            let game = &mut games[peer];
            sessions[peer].add_local_input(PlayerHandle::new(peer), sample(peer, game.frame)).unwrap();
            apply_requests(sessions[peer].advance_frame().unwrap(), game, &mut histories[peer]).unwrap();
        }
        settle(&mut sessions, &buffers);
    }
    let mut before = Vec::new();
    for peer in 0..schedule.peers {
        apply_requests(sessions[peer].recover_confirmed_inputs().unwrap(), &mut games[peer], &mut histories[peer]).unwrap();
        before.push(snapshot(&sessions[peer], &games[peer], &histories[peer], peer));
    }
    let start = *clock.lock().unwrap();
    let mut queued: BTreeMap<u64, Vec<Packet>> = BTreeMap::new();
    let mut controls = Vec::new();
    let mut dropped = Vec::new();
    let mut withheld_ready = Vec::new();
    for now in (0..=schedule.through_us).step_by(schedule.tick_us) {
        *clock.lock().unwrap() = start + now;
        for packet in queued.remove(&now).unwrap_or_default() {
            if schedule.active(packet.from, now) && schedule.active(packet.to, now) {
                deliver(packet, &buffers, now);
            }
        }
        for (peer, session) in sessions.iter_mut().enumerate().filter(|(peer, _)| schedule.active(*peer, now)) {
            session.poll_remote_clients();
            let targets = session.events().filter_map(|event| match event {
                FortressEvent::PeerDropped { handle, .. } => Some(handle),
                _ => None,
            }).collect::<Vec<_>>();
            for handle in targets {
                let cut = session.diagnostic_player_receipt_frame(handle).unwrap().as_i32();
                dropped.push(json!({"peer":peer, "target":handle.as_usize(), "at_us":now, "cut":cut,
                    "connected":session.diagnostic_player_connected(handle).unwrap()}));
            }
        }
        for packet in drain(&buffers, now) {
            let active = schedule.active(packet.from, now) && schedule.active(packet.to, now);
            if let Some(record) = &packet.control {
                controls.push(record.clone());
                if active && packet.to == schedule.coordinator && record["raw"]["body"]["DropReport"]["stage"] == "Ready" {
                    withheld_ready.push(record["id"].clone());
                    continue;
                }
            }
            if active {
                queued.entry(now + schedule.delay_us).or_default().push(packet);
            }
        }
    }
    let mut received = Vec::new();
    for buffer in &buffers {
        received.extend(std::mem::take(&mut buffer.lock().unwrap().received));
    }
    let after = (0..schedule.peers).filter(|&peer| schedule.active(peer, schedule.through_us)).map(|peer| {
        snapshot(&sessions[peer], &games[peer], &histories[peer], peer)
    }).collect::<Vec<_>>();
    println!("{}", json!({"upstream_revision":REVISION, "schedule":schedule, "before":before,
        "after":after, "controls":controls, "received":received, "dropped":dropped, "withheld_ready":withheld_ready}));
}
