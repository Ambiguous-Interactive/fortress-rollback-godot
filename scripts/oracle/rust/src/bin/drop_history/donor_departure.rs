//! Four-endpoint retained-history witness with a real donor timeout.
use super::*;

const PEERS: usize = 4;
const DONOR: usize = 1;
const TARGET: usize = 3;
const RECIPIENTS: [usize; 2] = [0, 2];
const ORDER_LIMIT: usize = 50_000;

struct Mesh {
    sessions: Vec<P2PSession<Profile>>,
    buffers: Vec<Arc<Mutex<Buffers>>>,
    games: Vec<Game>,
    states: Vec<BTreeMap<i32, Value>>,
    clock: Arc<Mutex<u64>>,
    held: BTreeMap<usize, (Message, Value)>,
    aborts: Vec<Value>,
    commits: Vec<Value>,
    donor_present: bool,
    target_present: bool,
    asymmetric: bool,
    hold_history: bool,
}

impl Mesh {
    fn new() -> Self {
        let clock = Arc::new(Mutex::new(0_u64));
        let origin = web_time::Instant::now();
        let order = Arc::new(Mutex::new(0_usize));
        let mut mesh = Self {
            sessions: Vec::new(),
            buffers: Vec::new(),
            clock,
            games: vec![Game { frame: 0, values: vec![0; PEERS] }; PEERS],
            states: vec![BTreeMap::new(); PEERS],
            held: BTreeMap::new(),
            aborts: Vec::new(),
            commits: Vec::new(),
            donor_present: true,
            target_present: true,
            asymmetric: false,
            hold_history: true,
        };
        for peer in 0..PEERS {
            let shared = mesh.clock.clone();
            let protocol = ProtocolConfig {
                clock: Some(Arc::new(move || origin + Duration::from_micros(*shared.lock().unwrap()))),
                protocol_rng_seed: Some(1701 + peer as u64),
                quality_report_interval: Duration::from_millis(5),
                ..Default::default()
            };
            let sync = SyncConfig {
                num_sync_packets: 1,
                keepalive_interval: Duration::from_millis(5),
                ..Default::default()
            };
            let mut builder = SessionBuilder::<Profile>::new()
                .with_num_players(PEERS)
                .unwrap()
                .with_max_prediction_window(8)
                .with_disconnect_behavior(DisconnectBehavior::ContinueWithout)
                .with_protocol_config(protocol)
                .with_sync_config(sync)
                .with_disconnect_timeout(Duration::from_millis(200))
                .with_disconnect_notify_delay(Duration::from_millis(50));
            for slot in 0..PEERS {
                let kind = if slot == peer { PlayerType::Local } else { PlayerType::Remote(slot.to_string()) };
                builder = builder.add_player(kind, PlayerHandle::new(slot)).unwrap();
            }
            let buffer = Arc::new(Mutex::new(Buffers {
                order: order.clone(),
                ..Default::default()
            }));
            mesh.sessions.push(
                builder
                    .start_p2p_session(Socket {
                        buffers: buffer.clone(),
                        publication_clock: None,
                        receipt_clock: Some(mesh.clock.clone()),
                        order_limit: ORDER_LIMIT,
                    })
                    .unwrap(),
            );
            mesh.buffers.push(buffer);
        }
        mesh
    }

    fn active(&self, peer: usize) -> bool {
        (peer != TARGET || self.target_present) && (peer != DONOR || self.donor_present)
    }

    fn now(&self) -> u64 {
        *self.clock.lock().unwrap()
    }

    fn deliver_held(&mut self) {
        self.hold_history = false;
        for (to, (message, packet)) in std::mem::take(&mut self.held) {
            self.buffers[to].lock().unwrap().incoming.push((DONOR.to_string(), message, Some(packet)));
        }
    }

    fn poll(&mut self) {
        for peer in 0..PEERS {
            if self.active(peer) {
                self.sessions[peer].poll_remote_clients();
            }
        }
        for (from, buffer) in self.buffers.iter().enumerate() {
            for (address, message, order) in std::mem::take(&mut buffer.lock().unwrap().outgoing) {
                let to: usize = address.parse().unwrap();
                let wire = serde_json::to_value(&message).unwrap();
                let mut receipt = None;
                if let Some(body) = wire["body"].get("DropAbort") {
                    self.aborts.push(json!({"at":self.now(),"from":from,"to":to,"body":body}));
                }
                if let Some(body) = wire["body"].get("DropCommit") {
                    let record = json!({"at":self.now(),"from":from,"to":to,"body":body,"publication_order":order.unwrap()});
                    if (from, to) == (0, 2) {
                        receipt = Some(record.clone());
                    }
                    self.commits.push(record);
                }
                if !self.active(from) || !self.active(to) || (self.asymmetric && from == TARGET && RECIPIENTS.contains(&to) && wire["body"].get("Input").is_some()) {
                    continue;
                }
                if self.hold_history && from == DONOR && RECIPIENTS.contains(&to) {
                    if let Some(body) = wire["body"].get("DropBackfill") {
                        let packet = json!({"at":self.now(),"from":from,"to":to,"body":body});
                        self.held.entry(to).or_insert((message, packet));
                        continue;
                    }
                }
                self.buffers[to].lock().unwrap().incoming.push((from.to_string(), message, receipt));
            }
        }
    }

    fn tick(&mut self, us: u64) {
        *self.clock.lock().unwrap() += us;
        self.poll();
    }

    fn frame(&mut self, peer: usize) -> Result<(), FortressError> {
        let local_frame = self.games[peer].frame;
        self.sessions[peer].add_local_input(PlayerHandle::new(peer), sample(peer, local_frame))?;
        self.advance(peer)
    }

    fn advance(&mut self, peer: usize) -> Result<(), FortressError> {
        let requests = self.sessions[peer].advance_frame()?;
        apply_requests(requests, &mut self.games[peer], &mut self.states[peer]).expect("game callback batch");
        Ok(())
    }

    fn rows(&self, peer: usize) -> Value {
        let source = &self.sessions[peer];
        let last = source.confirmed_frame().as_i32().min(self.games[peer].frame - 1);
        json!(exposed_rows(source, 0, last).expect("rows from the short warmup remain in the original history"))
    }

    fn snapshot(&mut self, peer: usize) -> Value {
        let target = PlayerHandle::new(TARGET);
        let donor = PlayerHandle::new(DONOR);
        let current = self.sessions[peer].current_frame().as_i32();
        let confirmed = self.sessions[peer].confirmed_frame().as_i32();
        let connected = [
            self.sessions[peer].diagnostic_player_connected(target),
            self.sessions[peer].diagnostic_player_connected(donor),
        ];
        let target_receipt = self.sessions[peer].diagnostic_player_receipt_frame(target).map(Frame::as_i32);
        let dropped = peer_dropped(&mut self.sessions[peer]);
        json!({"state":self.sessions[peer].current_state().to_string(),"current":current,"confirmed":confirmed,
               "target_receipt":target_receipt,"connected":connected,"dropped":dropped,"game":hex(&self.games[peer].bytes())})
    }
}

pub(super) fn run(mode: &str) -> Value {
    let mut mesh = Mesh::new();
    for _ in 0..12 {
        mesh.tick(1000);
    }
    for sess in &mesh.sessions {
        assert_eq!(sess.current_state().to_string(), "Running");
    }
    for frame in 0..9 {
        if frame == 8 {
            mesh.asymmetric = true;
        }
        let active: &[usize] = if frame < 6 { &[0, 1, 2, 3] } else { &[3] };
        for &peer in active {
            mesh.frame(peer).unwrap();
        }
        for _ in 0..4 {
            mesh.tick(250);
        }
    }
    let opening = RECIPIENTS.map(|peer| mesh.snapshot(peer));
    let rows = RECIPIENTS.map(|peer| mesh.rows(peer));
    mesh.target_present = false;
    for peer in 0..TARGET {
        mesh.sessions[peer].remove_player(PlayerHandle::new(TARGET)).unwrap();
    }
    for _ in 0..32 {
        mesh.tick(1000);
        if mesh.held.len() == RECIPIENTS.len() {
            break;
        }
    }
    assert_eq!(
        mesh.held.keys().copied().collect::<Vec<_>>(),
        RECIPIENTS,
        "unique selected donor publishes both original chunks"
    );
    let held: Vec<Value> = mesh.held.values().map(|(_, row)| row.clone()).collect();
    let planned = RECIPIENTS.map(|peer| mesh.snapshot(peer));
    let started = mesh.now();
    let silence = mode == "silence";
    let mut release_at = None;
    if mode == "deliver" {
        release_at = Some(mesh.now());
        mesh.deliver_held();
    } else if silence {
        mesh.donor_present = false;
    }
    let mut terminal = BTreeMap::new();
    let mut installed = BTreeMap::new();
    let mut before_delay_release = None;
    for tick in 0..40 {
        if mode == "hold-live" && tick == 30 {
            before_delay_release = Some(RECIPIENTS.map(|peer| mesh.snapshot(peer)));
            release_at = Some(mesh.now());
            mesh.deliver_held();
        }
        mesh.tick(10_000);
        for peer in RECIPIENTS {
            if mesh.sessions[peer].current_state().to_string() != "Running" && !terminal.contains_key(&peer) {
                terminal.insert(peer, json!({"offset":mesh.now()-started,"state":mesh.snapshot(peer),"rows":mesh.rows(peer)}));
            }
            if mesh.sessions[peer].diagnostic_player_connected(PlayerHandle::new(TARGET)) == Some(false) && !installed.contains_key(&peer) {
                let order = next_order(&mesh.buffers[peer].lock().unwrap().order, ORDER_LIMIT);
                installed.insert(peer, json!({"at":mesh.now(),"order":order,"state":mesh.snapshot(peer)}));
            }
        }
    }
    let final_before = RECIPIENTS.map(|peer| mesh.snapshot(peer));
    if silence {
        release_at = Some(mesh.now());
        mesh.deliver_held();
        mesh.tick(1000);
    } else {
        for _ in 0..12 {
            for peer in 0..TARGET {
                mesh.frame(peer).unwrap();
            }
            for _ in 0..4 {
                mesh.tick(250);
            }
        }
    }
    let mut commit_receipts = Vec::new();
    let received = RECIPIENTS.map(|peer| {
        let packets = std::mem::take(&mut mesh.buffers[peer].lock().unwrap().received);
        packets.into_iter().filter_map(|packet| {
            if packet["body"].get("DropCommit").is_some() {
                commit_receipts.push(packet);
                None
            } else {
                Some(packet)
            }
        }).collect::<Vec<_>>()
    });
    let advance = if !silence {
        Vec::new()
    } else {
        RECIPIENTS.into_iter().map(|peer| mesh.advance(peer).map_err(|error| format!("{error:?}"))).collect()
    };
    let runtime_rows = if silence {
        Vec::new()
    } else {
        (0..TARGET)
            .map(|peer| {
                let confirmed = mesh.sessions[peer].confirmed_frame().as_i32();
                mesh.states[peer].range(..=confirmed).map(|(_, row)| row.clone()).collect::<Vec<_>>()
            })
            .collect()
    };
    json!({"revision":REVISION,"mode":mode,"opening":opening,"opening_rows":rows,"held":held,"planned":planned,
        "held_at":started,"release_at":release_at,"terminal":terminal,"before_delay_release":before_delay_release,"aborts":mesh.aborts,"commits":mesh.commits,
        "installed":installed,"commit_receipts":commit_receipts,
        "final_before":final_before,"received":received,"advance":advance,"runtime_rows":runtime_rows,
        "final_after":RECIPIENTS.map(|peer| mesh.snapshot(peer)), "final_rows":RECIPIENTS.map(|peer| mesh.rows(peer))})
}
