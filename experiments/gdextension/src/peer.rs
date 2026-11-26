use crate::Game;
use fortress_rollback::{
    network::codec, FortressError, FortressEvent, Message, NonBlockingSocket, P2PSession,
    PlayerHandle, PlayerType, RequestVec, SessionBuilder, SessionState,
};
use std::{cell::RefCell, rc::Rc};

const MAX_PLAYERS: i32 = 8;
const MAX_PACKETS: usize = 256;
// At most 7 local slots * 4 bytes * 128 pending frames, plus RLE and wire overhead.
const MAX_PACKET_BYTES: usize = 8192;
const INPUT_BYTES: usize = 4;
type Datagram = (u16, Vec<u8>);

// These values are mirrored by FortressNativeDriver.ReceiveCode.
#[derive(Debug, PartialEq, Eq)]
#[repr(i32)]
pub(crate) enum ReceiveCode {
    Accepted = 0,
    Rejected = 1,
    Full = 2,
}

#[derive(Default)]
struct Packets {
    incoming: Vec<(u16, Message)>,
    outgoing: Vec<Datagram>,
    encode_failed: bool,
}

#[derive(Clone, Default)]
struct Socket(Rc<RefCell<Packets>>);

impl NonBlockingSocket<u16> for Socket {
    fn send_to(&mut self, msg: &Message, endpoint: &u16) {
        let mut packets = self.0.borrow_mut();
        // The upstream unreliable datagram protocol can recover dropped sends.
        if packets.outgoing.len() < MAX_PACKETS {
            match codec::encode(msg) {
                Ok(bytes) if bytes.len() <= MAX_PACKET_BYTES => {
                    packets.outgoing.push((*endpoint, bytes));
                }
                _ => packets.encode_failed = true,
            }
        }
    }

    fn receive_all_messages(&mut self) -> Vec<(u16, Message)> {
        std::mem::take(&mut self.0.borrow_mut().incoming)
    }
}

pub(crate) struct ConfirmationSlot {
    pub(crate) slot: usize,
    pub(crate) receipt_frame: i32,
    pub(crate) connected: bool,
    pub(crate) pending_output: Option<u64>,
    pub(crate) gossip_bound: Option<i32>,
}

pub(crate) struct Peer {
    session: P2PSession<Game>,
    socket: Socket,
    local_slots: Vec<PlayerHandle>,
    remote_endpoints: u16,
    interrupted: u16,
    terminal: &'static str,
    terminal_endpoint: u16,
    current_frame: i32,
    confirmed_frame: i32,
    abort_on_event: bool,
}

impl Peer {
    pub(crate) fn start(endpoints: &[i32]) -> Option<Self> {
        Self::build(endpoints, SessionBuilder::new())
    }

    pub(crate) fn start_legacy(endpoints: &[i32]) -> Option<Self> {
        let mut peer = Self::start(endpoints)?;
        peer.abort_on_event = false;
        Some(peer)
    }

    fn build(endpoints: &[i32], builder: SessionBuilder<Game>) -> Option<Self> {
        if !(2..=MAX_PLAYERS as usize).contains(&endpoints.len()) {
            return None;
        }

        let mut builder = builder
            .with_num_players(endpoints.len())
            .and_then(|builder| builder.with_input_delay(0))
            .ok()?;
        let mut local_slots = Vec::new();
        let mut remote_endpoints = 0;
        for (slot, &endpoint) in endpoints.iter().enumerate() {
            let handle = PlayerHandle::new(slot);
            let player = match endpoint {
                0 => {
                    local_slots.push(handle);
                    PlayerType::Local
                }
                1..=MAX_PLAYERS => {
                    remote_endpoints |= 1 << endpoint;
                    PlayerType::Remote(endpoint as u16)
                }
                _ => return None,
            };
            builder = builder.add_player(player, handle).ok()?;
        }
        if local_slots.is_empty() || remote_endpoints == 0 {
            return None;
        }

        let socket = Socket::default();
        let session = builder.start_p2p_session(socket.clone()).ok()?;
        Some(Self {
            current_frame: session.current_frame().as_i32(),
            confirmed_frame: session.confirmed_frame().as_i32(),
            session,
            socket,
            local_slots,
            remote_endpoints,
            interrupted: 0,
            terminal: "",
            terminal_endpoint: 0,
            abort_on_event: true,
        })
    }

    pub(crate) fn receive_from(&mut self, endpoint: i32, bytes: &[u8]) -> ReceiveCode {
        if !self.terminal.is_empty()
            || !(1..=MAX_PLAYERS).contains(&endpoint)
            || self.remote_endpoints & (1 << endpoint) == 0
            || bytes.len() > MAX_PACKET_BYTES
        {
            return ReceiveCode::Rejected;
        }
        let Ok((message, used)) = codec::decode_message(bytes) else {
            return ReceiveCode::Rejected;
        };
        if used != bytes.len() {
            return ReceiveCode::Rejected;
        }
        let mut packets = self.socket.0.borrow_mut();
        if packets.incoming.len() >= MAX_PACKETS {
            return ReceiveCode::Full;
        }
        packets.incoming.push((endpoint as u16, message));
        ReceiveCode::Accepted
    }

    pub(crate) fn drain(&mut self) -> Vec<Datagram> {
        std::mem::take(&mut self.socket.0.borrow_mut().outgoing)
    }

    pub(crate) fn current_frame(&self) -> i32 {
        self.current_frame
    }

    pub(crate) fn confirmed_frame(&self) -> i32 {
        self.confirmed_frame
    }

    pub(crate) fn confirmation_diagnostics(&self) -> Vec<ConfirmationSlot> {
        if !self.is_running() {
            return Vec::new();
        }
        let slots = (0..self.session.num_players()).map(PlayerHandle::new);
        let Some(remote) = slots.clone().find(|handle| !self.local_slots.contains(handle)) else {
            return Vec::new();
        };
        slots
            .filter_map(|handle| {
                let receipt_frame = self.session.diagnostic_player_receipt_frame(handle)?.as_i32();
                let connected = self.session.diagnostic_player_connected(handle)?;
                let pending_output = self.session.peer_metrics(handle).ok().map(|stats| stats.pending_output_len);
                // The target bound folds every remote view, regardless of the queried endpoint.
                let gossip_bound = self
                    .session
                    .diagnostic_hostile_gossip(remote, handle)
                    .and_then(|diagnostic| diagnostic.target_confirmed_bound)
                    .map(|bound| bound.as_i32());
                Some(ConfirmationSlot {
                    slot: handle.as_usize(),
                    receipt_frame,
                    connected,
                    pending_output,
                    gossip_bound,
                })
            })
            .collect()
    }

    pub(crate) fn terminal_reason(&self) -> &'static str {
        self.terminal
    }

    pub(crate) fn terminal_endpoint(&self) -> i32 {
        i32::from(self.terminal_endpoint)
    }

    pub(crate) fn interrupted_endpoints(&self) -> impl Iterator<Item = i32> + '_ {
        (1..=MAX_PLAYERS).filter(|&endpoint| self.interrupted & (1 << endpoint) != 0)
    }

    pub(crate) fn is_running(&self) -> bool {
        self.terminal.is_empty() && self.session.current_state() == SessionState::Running
    }

    // 0 = advanced, 1 = waiting for peers, -1 = terminal failure.
    pub(crate) fn step(
        &mut self,
        inputs: &[u8],
        dispatch: impl FnOnce(RequestVec<Game>) -> bool,
    ) -> i32 {
        if !self.terminal.is_empty() {
            return -1;
        }
        if inputs.len() != INPUT_BYTES * self.local_slots.len() {
            return self.fail("invalid_input");
        }

        self.session.poll_remote_clients();
        if !self.read_events() {
            return -1;
        }
        if !self.is_running() {
            return 1;
        }

        for (&slot, sample) in self
            .local_slots
            .iter()
            .zip(inputs.chunks_exact(INPUT_BYTES))
        {
            let sample = [sample[0], sample[1], sample[2], sample[3]];
            if self.session.add_local_input(slot, sample).is_err() {
                return self.fail("advance_failed");
            }
        }

        let result = self.session.advance_frame();
        if !self.read_events() {
            return -1;
        }
        match result {
            Ok(requests) => {
                if !dispatch(requests) {
                    return self.fail("callback_failed");
                }
            }
            Err(FortressError::PredictionThreshold) => {}
            Err(_) => return self.fail("advance_failed"),
        }

        let next_frame = self.session.current_frame().as_i32();
        let advanced = next_frame > self.current_frame;
        self.current_frame = next_frame;
        self.confirmed_frame = self.session.confirmed_frame().as_i32();
        if advanced {
            0
        } else {
            1
        }
    }

    fn read_events(&mut self) -> bool {
        // The original raw binding leaves upstream disconnect policy in charge.
        if !self.abort_on_event {
            let failed = self.socket.0.borrow().encode_failed;
            if failed {
                self.fail("packet_encode");
            }
            return !failed;
        }
        let mut terminal = "";
        for event in self.session.events() {
            match event {
                FortressEvent::Disconnected { addr } => {
                    terminal = "disconnected";
                    self.terminal_endpoint = addr;
                }
                FortressEvent::DesyncDetected { .. } => terminal = "desync",
                FortressEvent::SyncTimeout { .. } => terminal = "sync_timeout",
                FortressEvent::NetworkInterrupted { addr, .. } => self.interrupted |= 1 << addr,
                FortressEvent::NetworkResumed { addr } => self.interrupted &= !(1 << addr),
                _ => {}
            }
            if !terminal.is_empty() {
                break;
            }
        }
        if terminal.is_empty() && self.socket.0.borrow().encode_failed {
            terminal = "packet_encode";
        }
        if !terminal.is_empty() {
            self.fail(terminal);
        }
        terminal.is_empty()
    }

    fn fail(&mut self, reason: &'static str) -> i32 {
        self.terminal = reason;
        self.interrupted = 0;
        let mut packets = self.socket.0.borrow_mut();
        packets.incoming.clear();
        packets.outgoing.clear();
        -1
    }
}

#[cfg(test)]
mod tests;
