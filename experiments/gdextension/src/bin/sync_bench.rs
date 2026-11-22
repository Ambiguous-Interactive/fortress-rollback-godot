use fortress_gdextension_experiment::Game;
use fortress_rollback::{FortressRequest, PlayerHandle, SessionBuilder};
use serde_json::json;
use std::time::Instant;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let players: usize = std::env::args().nth(1).ok_or("missing count")?.parse()?;
    let mut session = SessionBuilder::<Game>::new()
        .with_num_players(players)?
        .with_input_delay(0)?
        .with_check_distance(2)
        .start_synctest_session()?;
    let mut state = vec![0u8; 4096];
    let mut frame = 0u32;
    let mut trace = Vec::new();
    let mut ticks = Vec::new();
    let mut copies = Vec::new();
    for step in 0..256 {
        let samples: Vec<_> = (0..players)
            .map(|i| ((1 + i as u32) * (1 + step)).to_le_bytes())
            .collect();
        let start = Instant::now();
        for (i, sample) in samples.into_iter().enumerate() {
            session.add_local_input(PlayerHandle::new(i), sample)?;
        }
        for request in session.advance_frame()? {
            match request {
                FortressRequest::SaveGameState { cell, frame: which } => {
                    trace.push(format!("S{}", which.as_i32()));
                    let now = Instant::now();
                    let snapshot = state.clone();
                    copies.push(now.elapsed().as_secs_f64() * 1e6);
                    if !cell.save(which, Some(snapshot), None) {
                        return Err("save".into());
                    }
                }
                FortressRequest::LoadGameState { cell, frame: which } => {
                    trace.push(format!("L{}", which.as_i32()));
                    let now = Instant::now();
                    state = cell.load().ok_or("load")?;
                    copies.push(now.elapsed().as_secs_f64() * 1e6);
                    frame = u32::from_le_bytes(state[..4].try_into()?);
                    if which.as_i32() != frame as i32 {
                        return Err("restore frame".into());
                    }
                }
                FortressRequest::AdvanceFrame { inputs } => {
                    trace.push(format!("A{frame}"));
                    for (i, (sample, status)) in inputs.iter().enumerate() {
                        if *status != fortress_rollback::InputStatus::Confirmed {
                            return Err("input status".into());
                        }
                        let offset = 4 + i * 4;
                        let sum = u32::from_le_bytes(state[offset..offset + 4].try_into()?)
                            + u32::from_le_bytes(*sample);
                        state[offset..offset + 4].copy_from_slice(&sum.to_le_bytes());
                    }
                    frame += 1;
                    state[..4].copy_from_slice(&frame.to_le_bytes());
                }
            }
        }
        ticks.push(start.elapsed().as_secs_f64() * 1e6);
    }
    let hex: String = state.iter().map(|b| format!("{b:02x}")).collect();
    println!(
        "BENCH {}",
        json!({"trace":trace,"state":hex,"ticks":ticks,"copies":copies})
    );
    Ok(())
}
