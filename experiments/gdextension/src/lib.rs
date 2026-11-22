use fortress_rollback::Config;

pub struct Game;

impl Config for Game {
    type Input = [u8; 4];
    type State = Vec<u8>;
    type Address = u16;
}

#[cfg(feature = "extension")]
mod extension;
