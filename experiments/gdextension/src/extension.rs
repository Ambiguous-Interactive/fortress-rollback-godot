use crate::Game;
use fortress_rollback::{
    network::codec, FortressError, FortressRequest, InputStatus, Message, NonBlockingSocket,
    P2PSession, PlayerHandle, PlayerType, SessionBuilder, SessionState,
};
use godot::prelude::*;
use std::{cell::RefCell, rc::Rc};

struct Library;
#[gdextension]
unsafe impl ExtensionLibrary for Library {}

// The experiment has exactly one remote endpoint. Queue overflow models packet loss.
#[derive(Default)]
struct Packets {
    incoming: Vec<(u16, Message)>,
    outgoing: Vec<Vec<u8>>,
    encode_failed: bool,
}

#[derive(Clone, Default)]
struct Socket(Rc<RefCell<Packets>>);

impl NonBlockingSocket<u16> for Socket {
    fn send_to(&mut self, msg: &Message, _: &u16) {
        let mut packets = self.0.borrow_mut();
        if packets.outgoing.len() < 256 {
            match codec::encode(msg) {
                Ok(bytes) => packets.outgoing.push(bytes),
                Err(_) => packets.encode_failed = true,
            }
        }
    }

    fn receive_all_messages(&mut self) -> Vec<(u16, Message)> {
        std::mem::take(&mut self.0.borrow_mut().incoming)
    }
}

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
struct FortressNativeSession {
    session: Option<P2PSession<Game>>,
    socket: Socket,
    local: usize,
    sync: Option<fortress_rollback::SyncTestSession<Game>>,
    players: usize,
}

#[godot_api]
impl FortressNativeSession {
    #[func]
    fn start(&mut self, local: i32) -> bool {
        if !(0..=1).contains(&local) || self.session.is_some() || self.sync.is_some() {
            return false;
        }
        self.socket = Socket::default();
        self.local = local as usize;
        let build = || {
            let mut builder = SessionBuilder::<Game>::new()
                .with_num_players(2)?
                .with_input_delay(0)?;
            for slot in 0..2 {
                let kind = if slot == self.local {
                    PlayerType::Local
                } else {
                    PlayerType::Remote(1)
                };
                builder = builder.add_player(kind, PlayerHandle::new(slot))?;
            }
            builder.start_p2p_session(self.socket.clone())
        };
        self.session = build().ok();
        self.session.is_some()
    }

    #[func]
    fn receive(&mut self, packet: PackedByteArray) -> bool {
        let mut queues = self.socket.0.borrow_mut();
        if self.session.is_none() || queues.incoming.len() >= 256 || packet.len() > 65507 {
            return false;
        }
        match codec::decode_message(packet.as_slice()) {
            Ok((message, used)) if used == packet.len() => {
                queues.incoming.push((1, message));
                true
            }
            _ => false,
        }
    }

    #[func]
    fn drain_packets(&mut self) -> Array<PackedByteArray> {
        self.socket
            .0
            .borrow_mut()
            .outgoing
            .drain(..)
            .map(|b| PackedByteArray::from(b.as_slice()))
            .collect()
    }

    #[func]
    fn confirmed_frame(&self) -> i32 {
        self.session
            .as_ref()
            .map_or(-1, |s| s.confirmed_frame().as_i32())
    }

    // 0 = advanced, 1 = waiting for peers, -1 = terminal failure.
    #[func]
    fn step(&mut self, input: PackedByteArray, game: Gd<Object>) -> i32 {
        let Some(session) = &mut self.session else {
            return -1;
        };
        let Ok(sample) = <[u8; 4]>::try_from(input.as_slice()) else {
            return -1;
        };
        session.poll_remote_clients();
        if self.socket.0.borrow().encode_failed {
            return -1;
        }
        if session.current_state() != SessionState::Running {
            return 1;
        }
        if session
            .add_local_input(PlayerHandle::new(self.local), sample)
            .is_err()
        {
            return -1;
        }
        let requests = match session.advance_frame() {
            Ok(requests) => requests,
            Err(FortressError::PredictionThreshold) => return 1,
            Err(_) => return -1,
        };
        if dispatch(requests, game) {
            0
        } else {
            self.session = None;
            -1
        }
    }

    #[func]
    fn start_sync(&mut self, players: i32) -> bool {
        if self.session.is_some() || self.sync.is_some() || !(2..=8).contains(&players) {
            return false;
        }
        self.players = players as usize;
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
            .is_ok_and(|requests| dispatch(requests, game));
        if !success {
            self.sync = None
        }
        success
    }
}

fn dispatch(requests: fortress_rollback::RequestVec<Game>, mut game: Gd<Object>) -> bool {
    for request in requests {
        let success = match request {
            FortressRequest::SaveGameState { frame, cell } => {
                let result = game.call("save_state", &[frame.as_i32().to_variant()]);
                if let Ok(bytes) = result.try_to::<PackedByteArray>() {
                    cell.save(frame, Some(bytes.as_slice().to_vec()), None)
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
