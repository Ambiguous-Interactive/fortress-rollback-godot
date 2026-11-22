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
    for endpoint in [i32::MIN, 0, 1, 9, i32::MAX] {
        assert!(!local.receive_from(endpoint, &hello));
    }
    assert!(!local.receive_from(8, &hello[..hello.len() - 1]));
    let mut trailing = hello.clone();
    trailing.push(0);
    assert!(!local.receive_from(8, &trailing));
    assert!(!local.receive_from(8, &[0; MAX_PACKET_BYTES + 1]));
    for _ in 0..MAX_PACKETS {
        assert!(local.receive_from(8, &hello));
    }
    assert!(!local.receive_from(8, &hello));
    assert_eq!(local.step(&[9; 4], |_| panic!("still synchronizing")), 1);
    assert!(local.receive_from(8, &hello));
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
            assert!(peers[recipient].receive_from(sender as i32 + 1, &packet));
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
            assert!(!peer.receive_from(2 - index as i32, &[]));
            assert_eq!(peer.step(&[], |_| panic!("terminal callback")), -1);
            assert_eq!(peer.terminal_reason(), "desync");
            return;
        }
    }
    panic!("no native desync was reported");
}

#[test]
fn reports_interruption_resume_and_disconnect_using_protocol_clock() {
    let time_ms = Arc::new(AtomicU64::new(0));
    let now = Instant::now();
    let builder = || {
        let time_ms = time_ms.clone();
        SessionBuilder::new().with_protocol_config(ProtocolConfig {
            clock: Some(Arc::new(move || {
                now + Duration::from_millis(time_ms.load(Ordering::Relaxed))
            })),
            ..ProtocolConfig::deterministic(42)
        })
    };
    let mut peers = [
        Peer::build(&[0, 2], builder()).unwrap(),
        Peer::build(&[1, 0], builder()).unwrap(),
    ];
    let mut games = [Simulation::default(), Simulation::default()];
    for _ in 0..15 {
        transfer(&mut peers);
        for (index, (peer, game)) in peers.iter_mut().zip(&mut games).enumerate() {
            run_frame(peer, game, &[index as u8]);
        }
    }
    assert!(peers.iter().all(Peer::is_running));

    let in_flight = peers[1].drain();
    assert!(!in_flight.is_empty());
    time_ms.store(600, Ordering::Relaxed);
    run_frame(&mut peers[0], &mut games[0], &[0]);
    assert_eq!(peers[0].interrupted_endpoints().collect::<Vec<_>>(), [2]);
    assert!(peers[0].is_running());

    for (_, packet) in in_flight {
        assert!(peers[0].receive_from(2, &packet));
    }
    run_frame(&mut peers[0], &mut games[0], &[0]);
    assert_eq!(peers[0].interrupted_endpoints().count(), 0);

    time_ms.store(2700, Ordering::Relaxed);
    let frame = peers[0].current_frame();
    assert_eq!(peers[0].step(&[0; 4], |_| panic!("terminal callback")), -1);
    assert_eq!(peers[0].terminal_reason(), "disconnected");
    assert_eq!(peers[0].current_frame(), frame);
    assert!(!peers[0].is_running());
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
}
