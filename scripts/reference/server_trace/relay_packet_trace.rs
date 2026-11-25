// Compiled only into the instrumented local qualification server.
use crate::protocol::{PlayerId, RoomId};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::VecDeque;
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const CAPACITY: usize = 128;
const ENVELOPE_HEADER_BYTES: usize = 57;
const NATIVE_HEADER_BYTES: usize = 81;
const MAX_SCOPE_BYTES: u64 = 1024;

static TRACE: OnceLock<Option<Arc<Trace>>> = OnceLock::new();

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Scope {
    room_id: RoomId,
    room: String,
    roster: Vec<String>,
}

impl Scope {
    fn read(path: &Path) -> anyhow::Result<Self> {
        let file = File::open(path)?;
        let mut bytes = Vec::new();
        BufReader::new(file).take(MAX_SCOPE_BYTES + 1).read_to_end(&mut bytes)?;
        anyhow::ensure!(bytes.len() as u64 <= MAX_SCOPE_BYTES, "room scope is too large");
        let scope: Self = serde_json::from_slice(&bytes)?;
        anyhow::ensure!(
            !scope.room_id.is_nil()
                && valid_hex(&scope.room)
                && (2..=8).contains(&scope.roster.len())
                && scope.roster.iter().all(|uuid| valid_hex(uuid))
                && scope.roster.windows(2).all(|pair| pair[0] < pair[1]),
            "invalid relay trace room scope"
        );
        Ok(scope)
    }
}

fn valid_hex(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Clone, Serialize)]
struct Event {
    ordinal: u64,
    at_ns: u64,
    sender: String,
    recipient: String,
    kind: u32,
    epoch: u32,
    seq: String,
    envelope_bytes: usize,
    envelope_sha256: String,
    payload_sha256: String,
    socket_ordinal: Option<u64>,
}

#[derive(Clone, Default, Serialize)]
struct Stream {
    count: u64,
    omitted: u64,
    events: VecDeque<Event>,
}

impl Stream {
    fn record(&mut self, mut event: Event) {
        self.count += 1;
        event.ordinal = self.count;
        if self.events.len() == CAPACITY {
            self.events.pop_front();
            self.omitted += 1;
        }
        self.events.push_back(event);
    }
}

#[derive(Clone, Default, Serialize)]
struct Families {
    sync: Stream,
    input: Stream,
    quality: Stream,
}

impl Families {
    fn stream(&mut self, kind: u32) -> &mut Stream {
        match kind {
            0 | 1 => &mut self.sync,
            2 | 3 => &mut self.input,
            _ => &mut self.quality,
        }
    }
}

#[derive(Clone, Default, Serialize)]
struct Streams {
    ingress: Families,
    write: Families,
}

struct Trace {
    origin: Instant,
    scope: OnceLock<Scope>,
    state: Mutex<(u64, Streams)>,
}

impl Trace {
    fn publish(&self, scope_path: &Path, output: &Path, scratch: &Path) -> anyhow::Result<()> {
        loop {
            match Scope::read(scope_path) {
                Ok(scope) => {
                    let _ = self.scope.set(scope);
                    break;
                }
                Err(error) if error.downcast_ref::<io::Error>().is_some_and(|err| err.kind() == io::ErrorKind::NotFound) => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(error) => return Err(error),
            }
        }

        #[derive(Serialize)]
        struct Snapshot<'a> {
            version: u8,
            clock: &'static str,
            #[serde(flatten)]
            scope: &'a Scope,
            streams: Streams,
        }

        let scope = self.scope.get().ok_or_else(|| anyhow::anyhow!("missing relay trace scope"))?;
        let mut published = None;
        loop {
            let pending = {
                let state = self.state.lock().map_err(|_| anyhow::anyhow!("relay trace lock poisoned"))?;
                (Some(state.0) != published).then(|| state.clone())
            };
            if let Some((revision, streams)) = pending {
                let file = File::create(scratch)?;
                let mut writer = BufWriter::new(file);
                serde_json::to_writer(
                    &mut writer,
                    &Snapshot {
                        version: 1,
                        clock: "server.monotonic",
                        scope,
                        streams,
                    },
                )?;
                writer.flush()?;
                fs::rename(scratch, output)?;
                published = Some(revision);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

fn trace() -> Option<&'static Trace> {
    TRACE
        .get_or_init(|| {
            let output = std::env::var_os("FORTRESS_RELAY_TRACE_OUTPUT").map(PathBuf::from);
            let scope = std::env::var_os("FORTRESS_RELAY_TRACE_SCOPE").map(PathBuf::from);
            let Some((output, scope)) = output.zip(scope) else {
                return None;
            };
            let scratch = output.with_extension(format!("{}.next", std::process::id()));
            if !output.is_absolute() || !scope.is_absolute() || output == scope || scratch == scope || scratch == output {
                tracing::error!("invalid relay trace paths");
                return None;
            }
            let trace = Arc::new(Trace {
                origin: Instant::now(),
                scope: OnceLock::new(),
                state: Mutex::default(),
            });
            let publisher = trace.clone();
            if let Err(error) = std::thread::Builder::new().name("relay-packet-trace".into()).spawn(move || {
                if let Err(error) = publisher.publish(&scope, &output, &scratch) {
                    tracing::error!(%error, "relay packet trace publisher failed");
                }
            }) {
                tracing::error!(%error, "could not start relay packet trace publisher");
                return None;
            }
            Some(trace)
        })
        .as_deref()
}

pub(crate) fn enabled() -> bool {
    trace().is_some()
}

pub(crate) enum Boundary {
    Ingress { socket_ordinal: u64, received_at: Instant },
    Write { recipient: PlayerId, written_at: Instant },
}

pub(crate) fn record(boundary: Boundary, room_id: RoomId, sender: PlayerId, seq: u64, epoch: u32, envelope: &[u8]) {
    let Some(trace) = trace() else { return };
    let Some(scope) = trace.scope.get() else { return };
    if scope.room_id != room_id
        || !(NATIVE_HEADER_BYTES + 4..=65536).contains(&envelope.len())
        || envelope[0..5] != *b"FSR1\x01"
        || envelope[5..21] != envelope[57..73]
        || envelope[21..37] != *sender.as_bytes()
        || envelope[73..77] != [0xf5, 0x52, 2, 0]
    {
        return;
    }
    let [declared, tag] = [53, 81].map(|offset| {
        let mut bytes = [0; 4];
        bytes.copy_from_slice(&envelope[offset..offset + 4]);
        u32::from_le_bytes(bytes)
    });
    if declared as usize != envelope.len() - ENVELOPE_HEADER_BYTES || tag > 5 || hex(&envelope[5..21]) != scope.room {
        return;
    }
    let sender = sender.simple().to_string();
    let recipient = hex(&envelope[37..53]);
    if sender == recipient || scope.roster.binary_search(&sender).is_err() || scope.roster.binary_search(&recipient).is_err() {
        return;
    }

    let (at, socket_ordinal) = match boundary {
        Boundary::Ingress { socket_ordinal, received_at } => (received_at, Some(socket_ordinal)),
        Boundary::Write {
            recipient: actual,
            written_at,
        } => {
            if envelope[37..53] != *actual.as_bytes() {
                return;
            }
            (written_at, None)
        }
    };
    let event = Event {
        ordinal: 0,
        at_ns: at.saturating_duration_since(trace.origin).as_nanos() as u64,
        sender,
        recipient,
        kind: tag,
        epoch,
        seq: seq.to_string(),
        envelope_bytes: envelope.len(),
        envelope_sha256: hex(&Sha256::digest(envelope)),
        payload_sha256: hex(&Sha256::digest(&envelope[ENVELOPE_HEADER_BYTES..])),
        socket_ordinal,
    };
    if let Ok(mut state) = trace.state.lock() {
        let families = if socket_ordinal.is_some() {
            &mut state.1.ingress
        } else {
            &mut state.1.write
        };
        families.stream(tag).record(event);
        state.0 += 1;
    }
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        text.push(char::from(DIGITS[usize::from(byte >> 4)]));
        text.push(char::from(DIGITS[usize::from(byte & 15)]));
    }
    text
}
