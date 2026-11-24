use crate::{
    peer::{Peer, ReceiveCode},
    Game,
};
use fortress_rollback::{FortressRequest, InputStatus, PlayerHandle, SessionBuilder};
use godot::prelude::*;

struct Library;
#[gdextension]
unsafe impl ExtensionLibrary for Library {}

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
struct FortressNativeSession {
    peer: Option<Peer>,
    legacy_peer: bool,
    sync: Option<fortress_rollback::SyncTestSession<Game>>,
    players: usize,
    sync_checksums: bool,
}

#[godot_api]
impl FortressNativeSession {
    #[func]
    fn start(&mut self, local: i32) -> bool {
        let endpoints = match local {
            0 => [0, 1],
            1 => [1, 0],
            _ => return false,
        };
        self.configure_peer(&endpoints, true)
    }

    #[func]
    fn wire_profile(&self) -> GString {
        "fortress-native-d124c890-v1-u32".into()
    }

    #[func]
    fn start_roster(&mut self, endpoints: PackedInt32Array) -> bool {
        self.configure_peer(endpoints.as_slice(), false)
    }

    fn configure_peer(&mut self, endpoints: &[i32], legacy: bool) -> bool {
        if self.peer.is_some() || self.sync.is_some() {
            return false;
        }
        self.peer = if legacy {
            Peer::start_legacy(endpoints)
        } else {
            Peer::start(endpoints)
        };
        self.legacy_peer = self.peer.is_some() && legacy;
        self.peer.is_some()
    }

    #[func]
    fn receive(&mut self, packet: PackedByteArray) -> bool {
        self.legacy_peer && self.receive_from(1, packet)
    }

    #[func]
    fn receive_from(&mut self, endpoint: i64, packet: PackedByteArray) -> bool {
        self.receive_from_result(endpoint, packet) == ReceiveCode::Accepted as i32
    }

    #[func]
    fn receive_from_result(&mut self, endpoint: i64, packet: PackedByteArray) -> i32 {
        let Ok(endpoint) = i32::try_from(endpoint) else {
            return ReceiveCode::Rejected as i32;
        };
        self.peer.as_mut().map_or(ReceiveCode::Rejected, |peer| {
            peer.receive_from(endpoint, packet.as_slice())
        }) as i32
    }

    #[func]
    fn drain_packets(&mut self) -> Array<PackedByteArray> {
        if !self.legacy_peer {
            return Array::new();
        }
        self.peer
            .iter_mut()
            .flat_map(Peer::drain)
            .map(|(_, bytes)| PackedByteArray::from(bytes.as_slice()))
            .collect()
    }

    #[func]
    fn drain_routed_packets(&mut self) -> Array<VarDictionary> {
        self.peer
            .iter_mut()
            .flat_map(Peer::drain)
            .map(|(endpoint, bytes)| {
                let mut packet = VarDictionary::new();
                packet.set("endpoint", i32::from(endpoint));
                packet.set("bytes", &PackedByteArray::from(bytes.as_slice()));
                packet
            })
            .collect()
    }

    #[func]
    fn current_frame(&self) -> i32 {
        self.peer.as_ref().map_or(-1, Peer::current_frame)
    }

    #[func]
    fn confirmed_frame(&self) -> i32 {
        self.peer.as_ref().map_or(-1, Peer::confirmed_frame)
    }

    #[func]
    fn is_running(&self) -> bool {
        self.peer.as_ref().is_some_and(Peer::is_running)
    }

    #[func]
    fn terminal_reason(&self) -> GString {
        self.peer.as_ref().map_or("", Peer::terminal_reason).into()
    }

    #[func]
    fn terminal_endpoint(&self) -> i32 {
        self.peer.as_ref().map_or(0, Peer::terminal_endpoint)
    }

    #[func]
    fn interrupted_endpoints(&self) -> PackedInt32Array {
        self.peer
            .iter()
            .flat_map(Peer::interrupted_endpoints)
            .collect()
    }

    #[func]
    fn step(&mut self, input: PackedByteArray, game: Gd<Object>) -> i32 {
        if !self.legacy_peer || input.len() != 4 {
            return -1;
        }
        let code = self.step_peer(input, game, false);
        if code < 0 && self.peer.as_ref().is_some_and(|peer| peer.terminal_reason() == "callback_failed") {
            self.peer = None;
            self.legacy_peer = false;
        }
        code
    }

    #[func]
    fn step_roster(&mut self, inputs: PackedByteArray, game: Gd<Object>) -> i32 {
        if self.legacy_peer {
            return -1;
        }
        self.step_peer(inputs, game, true)
    }

    fn step_peer(&mut self, inputs: PackedByteArray, game: Gd<Object>, checksums: bool) -> i32 {
        self.peer.as_mut().map_or(-1, |peer| {
            peer.step(inputs.as_slice(), |requests| {
                dispatch(requests, game, checksums)
            })
        })
    }

    #[func]
    fn start_sync(&mut self, players: i32) -> bool {
        self.configure_sync(players, true)
    }

    #[func]
    fn start_sync_without_checksums(&mut self, players: i32) -> bool {
        self.configure_sync(players, false)
    }

    fn configure_sync(&mut self, players: i32, checksums: bool) -> bool {
        if self.peer.is_some() || self.sync.is_some() || !(2..=8).contains(&players) {
            return false;
        }
        self.players = players as usize;
        self.sync_checksums = checksums;
        self.sync = SessionBuilder::<Game>::new()
            .with_num_players(self.players)
            .and_then(|b| b.with_input_delay(0))
            .and_then(|b| b.with_check_distance(2).start_synctest_session())
            .ok();
        self.sync.is_some()
    }

    #[func]
    fn step_sync(&mut self, inputs: PackedByteArray, game: Gd<Object>) -> bool {
        let Some(session) = &mut self.sync else {
            return false;
        };
        if inputs.len() != 4 * self.players {
            return false;
        }
        for (slot, sample) in inputs.as_slice().chunks_exact(4).enumerate() {
            let bytes = [sample[0], sample[1], sample[2], sample[3]];
            if session
                .add_local_input(PlayerHandle::new(slot), bytes)
                .is_err()
            {
                self.sync = None;
                return false;
            }
        }
        let success = session
            .advance_frame()
            .is_ok_and(|requests| dispatch(requests, game, self.sync_checksums));
        if !success {
            self.sync = None
        }
        success
    }
}

fn dispatch(
    requests: fortress_rollback::RequestVec<Game>,
    mut game: Gd<Object>,
    checksums: bool,
) -> bool {
    for request in requests {
        let success = match request {
            FortressRequest::SaveGameState { frame, cell } => {
                let result = game.call("save_state", &[frame.as_i32().to_variant()]);
                if let Ok(bytes) = result.try_to::<PackedByteArray>() {
                    let bytes = bytes.as_slice();
                    let checksum = checksums.then(|| fortress_rollback::hash_bytes_fnv1a(bytes));
                    cell.save(frame, Some(bytes.to_vec()), checksum)
                } else {
                    false
                }
            }
            FortressRequest::LoadGameState { frame, cell } => cell.load().is_some_and(|bytes| {
                let args = [
                    frame.as_i32().to_variant(),
                    PackedByteArray::from(bytes.as_slice()).to_variant(),
                ];
                game.call("load_state", &args)
                    .try_to::<bool>()
                    .unwrap_or(false)
            }),
            FortressRequest::AdvanceFrame { inputs } => {
                let mut bytes = PackedByteArray::new();
                let mut statuses = PackedByteArray::new();
                for (sample, status) in inputs {
                    for byte in sample {
                        bytes.push(byte);
                    }
                    statuses.push(match status {
                        InputStatus::Confirmed => 0,
                        InputStatus::Predicted => 1,
                        InputStatus::Disconnected => 2,
                    });
                }
                game.call("advance_game", &[bytes.to_variant(), statuses.to_variant()])
                    .try_to::<bool>()
                    .unwrap_or(false)
            }
        };
        if !success {
            return false;
        }
    }
    true
}
