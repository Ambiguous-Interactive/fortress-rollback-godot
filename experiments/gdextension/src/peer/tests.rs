use super::*;
use fortress_rollback::{FortressRequest, ProtocolConfig};
use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

#[test]
fn rejects_invalid_rosters_and_bounds_ingress() {
    for endpoints in [
        &[][..],
        &[0],
        &[0, 1, 2, 3, 4, 5, 6, 7, 8],
        &[0, 0],
        &[1, 2],
        &[0, -1],
        &[0, 9],
    ] {
        assert!(Peer::start(endpoints).is_none(), "{endpoints:?}");
    }

    let mut local = Peer::start(&[0, 8]).unwrap();
    let mut remote = Peer::start(&[8, 0]).unwrap();
    assert_eq!(remote.step(&[0; 4], |_| panic!("still synchronizing")), 1);
    let (_, hello) = remote
        .drain()
        .pop()
        .expect("upstream starts synchronization");
    for _ in 0..MAX_PACKETS {
        assert_eq!(local.receive_from(8, &hello), ReceiveCode::Accepted);
    }
    let mut trailing = hello.clone();
    trailing.push(0);
    for (endpoint, packet) in [
        (i32::MIN, hello.as_slice()),
        (0, hello.as_slice()),
        (1, hello.as_slice()),
        (9, hello.as_slice()),
        (i32::MAX, hello.as_slice()),
        (8, &hello[..hello.len() - 1]),
        (8, trailing.as_slice()),
        (8, &[0; MAX_PACKET_BYTES + 1]),
    ] {
        assert_eq!(local.receive_from(endpoint, packet), ReceiveCode::Rejected);
    }
    assert_eq!(local.receive_from(8, &hello), ReceiveCode::Full);
    assert_eq!(local.socket.0.borrow().incoming.len(), MAX_PACKETS);
    assert_eq!(local.step(&[9; 4], |_| panic!("still synchronizing")), 1);
    assert_eq!(local.receive_from(8, &hello), ReceiveCode::Accepted);
}

#[derive(Default)]
struct Simulation {
    rows: Vec<Vec<[u8; 4]>>,
    diverges: bool,
}

impl Simulation {
    fn dispatch(&mut self, requests: RequestVec<Game>) -> bool {
        for request in requests {
            match request {
                FortressRequest::SaveGameState { frame, cell } => {
                    assert_eq!(self.rows.len(), frame.as_i32() as usize);
                    let mut bytes = vec![u8::from(self.diverges)];
                    bytes.extend(self.rows.iter().flatten().flatten().copied());
                    let checksum = fortress_rollback::hash_bytes_fnv1a(&bytes);
                    assert!(cell.save(frame, Some(bytes), Some(checksum)));
                }
                FortressRequest::LoadGameState { frame, cell } => {
                    self.rows.truncate(frame.as_i32() as usize);
                    let bytes = cell.load().unwrap();
                    assert_eq!(bytes[0], u8::from(self.diverges));
                    assert!(bytes[1..].iter().copied().eq(self
                        .rows
                        .iter()
                        .flatten()
                        .flatten()
                        .copied()));
                }
                FortressRequest::AdvanceFrame { inputs } => {
                    self.rows
                        .push(inputs.into_iter().map(|(sample, _)| sample).collect());
                }
            }
        }
        true
    }
}

fn transfer(peers: &mut [Peer]) {
    for sender in 0..peers.len() {
        for (endpoint, packet) in peers[sender].drain() {
            let recipient = usize::from(endpoint) - 1;
            assert_ne!(recipient, sender);
            assert_eq!(
                peers[recipient].receive_from(sender as i32 + 1, &packet),
                ReceiveCode::Accepted
            );
        }
    }
}

fn run_frame(peer: &mut Peer, game: &mut Simulation, slots: &[u8]) {
    let inputs: Vec<u8> = slots
        .iter()
        .flat_map(|slot| [*slot, peer.current_frame() as u8, 0x01, 0xf2])
        .collect();
    let result = peer.step(&inputs, |requests| game.dispatch(requests));
    assert_ne!(result, -1, "{}", peer.terminal_reason());
    assert_eq!(peer.current_frame() as usize, game.rows.len());
}

#[test]
fn routes_a_mesh_with_multiple_local_slots_in_ascending_slot_order() {
    let mut peers = [
        Peer::start(&[0, 2, 0, 3]).unwrap(),
        Peer::start(&[1, 0, 1, 3]).unwrap(),
        Peer::start(&[1, 2, 1, 0]).unwrap(),
    ];
    let mut games = std::array::from_fn::<_, 3, _>(|_| Simulation::default());
    for _ in 0..100 {
        transfer(&mut peers);
        for ((peer, game), slots) in peers
            .iter_mut()
            .zip(&mut games)
            .zip([&[0, 2][..], &[1], &[3]])
        {
            run_frame(peer, game, slots);
        }
    }
    for (peer, game) in peers.iter().zip(&games) {
        assert!(peer.is_running());
        let confirmed = peer.confirmed_frame();
        assert!(confirmed > 70, "{confirmed}");
        for frame in 0..confirmed as usize {
            let expected: Vec<[u8; 4]> =
                (0..4).map(|slot| [slot, frame as u8, 0x01, 0xf2]).collect();
            assert_eq!(game.rows[frame], expected);
        }
    }
}

#[test]
fn native_desync_halts_before_dispatch_and_preserves_the_first_cause() {
    let mut peers = [Peer::start(&[0, 2]).unwrap(), Peer::start(&[1, 0]).unwrap()];
    let mut games = [
        Simulation::default(),
        Simulation {
            diverges: true,
            ..Simulation::default()
        },
    ];
    for _ in 0..180 {
        transfer(&mut peers);
        for (index, (peer, game)) in peers.iter_mut().zip(&mut games).enumerate() {
            let before = peer.current_frame();
            let confirmed = peer.confirmed_frame();
            let mut dispatched = false;
            let result = peer.step(&[index as u8; 4], |requests| {
                dispatched = true;
                game.dispatch(requests)
            });
            if result != -1 {
                continue;
            }
            assert!(!dispatched);
            assert_eq!(peer.terminal_reason(), "desync");
            assert_eq!(peer.current_frame(), before);
            assert_eq!(peer.confirmed_frame(), confirmed);
            assert!(!peer.is_running());
            assert!(peer.drain().is_empty());
            assert_eq!(
                peer.receive_from(2 - index as i32, &[]),
                ReceiveCode::Rejected
            );
            assert_eq!(peer.step(&[], |_| panic!("terminal callback")), -1);
            assert_eq!(peer.terminal_reason(), "desync");
            return;
        }
    }
    panic!("no native desync was reported");
}

#[test]
fn reports_interruption_resume_and_disconnect_using_protocol_clock() {
    check_timeout_policy(true);
    check_timeout_policy(false);
}

fn clocked_builder(time_ms: &Arc<AtomicU64>, now: Instant) -> SessionBuilder<Game> {
    let time_ms = time_ms.clone();
    SessionBuilder::new().with_protocol_config(ProtocolConfig {
        clock: Some(Arc::new(move || {
            now + Duration::from_millis(time_ms.load(Ordering::Relaxed))
        })),
        ..ProtocolConfig::deterministic(42)
    })
}

fn check_timeout_policy(abort_on_event: bool) {
    let time_ms = Arc::new(AtomicU64::new(0));
    let now = Instant::now();
    let mut peers = [
        Peer::build(&[0, 2], clocked_builder(&time_ms, now)).unwrap(),
        Peer::build(&[1, 0], clocked_builder(&time_ms, now)).unwrap(),
    ];
    let mut games = [Simulation::default(), Simulation::default()];
    for _ in 0..15 {
        transfer(&mut peers);
        for (index, (peer, game)) in peers.iter_mut().zip(&mut games).enumerate() {
            run_frame(peer, game, &[index as u8]);
        }
    }
    assert!(peers.iter().all(Peer::is_running));
    peers[0].abort_on_event = abort_on_event;

    let in_flight = peers[1].drain();
    assert!(!in_flight.is_empty());
    time_ms.store(600, Ordering::Relaxed);
    run_frame(&mut peers[0], &mut games[0], &[0]);
    let interrupted = peers[0].interrupted_endpoints().collect::<Vec<_>>();
    assert_eq!(interrupted, if abort_on_event { vec![2] } else { vec![] });
    assert!(peers[0].is_running());
    assert_eq!(peers[0].terminal_endpoint(), 0);

    for (_, packet) in in_flight {
        assert_eq!(peers[0].receive_from(2, &packet), ReceiveCode::Accepted);
    }
    run_frame(&mut peers[0], &mut games[0], &[0]);
    assert_eq!(peers[0].interrupted_endpoints().count(), 0);
    assert_eq!(peers[0].terminal_endpoint(), 0);

    time_ms.store(2700, Ordering::Relaxed);
    let frame = peers[0].current_frame();
    if !abort_on_event {
        assert_eq!(peers[0].step(&[0; 4], |_| panic!("paused upstream session")), 1);
        assert_eq!(peers[0].terminal_reason(), "");
        assert_eq!(peers[0].terminal_endpoint(), 0);
        assert_eq!(peers[0].current_frame(), frame);
        assert_eq!(peers[0].session.current_state(), SessionState::Synchronizing);
        return;
    }
    assert_eq!(peers[0].step(&[0; 4], |_| panic!("terminal callback")), -1);
    assert_eq!(peers[0].terminal_reason(), "disconnected");
    assert_eq!(peers[0].current_frame(), frame);
    assert!(!peers[0].is_running());
    assert_eq!(peers[0].terminal_endpoint(), 2);
    assert_eq!(peers[0].step(&[], |_| panic!("terminal callback")), -1);
    assert_eq!(peers[0].terminal_reason(), "disconnected");
    assert_eq!(peers[0].terminal_endpoint(), 2);
}

#[test]
fn identifies_the_expired_endpoint_among_multiple_remotes() {
    let time_ms = Arc::new(AtomicU64::new(0));
    let now = Instant::now();
    let mut peers = [
        Peer::build(&[0, 2, 3], clocked_builder(&time_ms, now)).unwrap(),
        Peer::build(&[1, 0, 3], clocked_builder(&time_ms, now)).unwrap(),
        Peer::build(&[1, 2, 0], clocked_builder(&time_ms, now)).unwrap(),
    ];
    let mut games = std::array::from_fn::<_, 3, _>(|_| Simulation::default());
    for _ in 0..15 {
        transfer(&mut peers);
        for (index, (peer, game)) in peers.iter_mut().zip(&mut games).enumerate() {
            run_frame(peer, game, &[index as u8]);
        }
    }
    assert!(peers.iter().all(Peer::is_running));
    let deliver_live = |peers: &mut [Peer; 3]| {
        let mut delivered = false;
        for (recipient, packet) in peers[1].drain() {
            if recipient == 1 {
                assert_eq!(peers[0].receive_from(2, &packet), ReceiveCode::Accepted);
                delivered = true;
            }
        }
        assert!(delivered);
    };

    time_ms.store(600, Ordering::Relaxed);
    deliver_live(&mut peers);
    run_frame(&mut peers[0], &mut games[0], &[0]);
    assert_eq!(peers[0].interrupted_endpoints().collect::<Vec<_>>(), [3]);
    assert_eq!(peers[0].terminal_endpoint(), 0);
    run_frame(&mut peers[1], &mut games[1], &[1]);

    time_ms.store(2100, Ordering::Relaxed);
    deliver_live(&mut peers);
    assert_eq!(peers[0].step(&[0; 4], |_| panic!("terminal callback")), -1);
    assert_eq!(peers[0].terminal_reason(), "disconnected");
    assert_eq!(peers[0].terminal_endpoint(), 3);
}

#[test]
fn rejects_an_incomplete_local_batch_before_polling_or_simulating() {
    let mut peer = Peer::start(&[0, 1, 0]).unwrap();
    assert_eq!(peer.step(&[0; 8], |_| panic!("still synchronizing")), 1);
    assert!(!peer.socket.0.borrow().outgoing.is_empty());
    assert_eq!(peer.step(&[0; 4], |_| panic!("invalid input callback")), -1);
    assert_eq!(peer.terminal_reason(), "invalid_input");
    assert_eq!(peer.current_frame(), 0);
    assert!(peer.drain().is_empty());
    assert_eq!(peer.step(&[0; 8], |_| panic!("terminal callback")), -1);
    assert_eq!(peer.terminal_reason(), "invalid_input");
    assert_eq!(peer.terminal_endpoint(), 0);
}
