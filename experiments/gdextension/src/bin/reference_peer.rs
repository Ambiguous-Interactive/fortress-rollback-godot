// A separate process using the crate's stock UDP transport and no Godot dependency.
use fortress_rollback::{
    Config, FortressError, FortressRequest, PlayerHandle, PlayerType, SessionBuilder, SessionState,
    UdpNonBlockingSocket,
};
use serde_json::json;
use std::{
    io::{self, BufRead},
    net::SocketAddr,
};

struct Peer;
impl Config for Peer {
    type Input = [u8; 4];
    type Address = SocketAddr;
    type State = [u32; 3];
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    let local: usize = args[1].parse()?;
    let remote: SocketAddr = args[2].parse()?;
    let socket = UdpNonBlockingSocket::bind_to_port(0)?;
    println!("{}", socket.local_addr()?.port());
    let mut builder = SessionBuilder::<Peer>::new()
        .with_num_players(2)?
        .with_input_delay(0)?;
    for slot in 0..2 {
        let kind = if slot == local {
            PlayerType::Local
        } else {
            PlayerType::Remote(remote)
        };
        builder = builder.add_player(kind, PlayerHandle::new(slot))?;
    }
    let mut session = builder.start_p2p_session(socket)?;
    let mut state = [0u32; 3];
    let mut history = Vec::new();
    let mut loads = 0;
    let mut checkpoint = [0u32; 3];
    for tick in io::stdin().lock().lines() {
        tick?;
        session.poll_remote_clients();
        if session.current_state() == SessionState::Running && state[0] < 64 {
            let input = (state[0] + 1) * (local as u32 + 17);
            session.add_local_input(PlayerHandle::new(local), input.to_le_bytes())?;
            match session.advance_frame() {
                Ok(requests) => {
                    for request in requests {
                        match request {
                            FortressRequest::SaveGameState { cell, frame } => {
                                if !cell.save(frame, Some(state), None) {
                                    return Err("invalid save".into());
                                }
                            }
                            FortressRequest::LoadGameState { cell, .. } => {
                                state = cell.load().ok_or("missing snapshot")?;
                                history.truncate(state[0] as usize);
                                loads += 1;
                            }
                            FortressRequest::AdvanceFrame { inputs } => {
                                let mut row = [0; 2];
                                for (i, (input, _)) in inputs.iter().enumerate() {
                                    row[i] = u32::from_le_bytes(*input);
                                    state[i + 1] = state[i + 1].wrapping_add(row[i]);
                                }
                                history.push(row);
                                state[0] += 1;
                                if state[0] == 40 {
                                    checkpoint = state;
                                }
                            }
                        }
                    }
                }
                Err(FortressError::PredictionThreshold) => (),
                Err(err) => return Err(err.into()),
            }
        }
        println!(
            "{}",
            json!({"state":state,"history":history,"checkpoint":checkpoint,"confirmed":session.confirmed_frame().as_i32(),"loads":loads})
        );
    }
    Ok(())
}
