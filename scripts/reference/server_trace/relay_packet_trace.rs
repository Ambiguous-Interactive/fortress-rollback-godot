// Compiled only into the instrumented local qualification server.
use crate::protocol::{PlayerId, RoomId};
use serde::{ser::SerializeStruct, Deserialize, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::convert::identity;
use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const CAPACITY: usize = 128;
const EXPANDED_CAPACITY: usize = 1024;
const ENVELOPE_HEADER_BYTES: usize = 57;
const NATIVE_HEADER_BYTES: usize = 81;
const MAX_SCOPE_BYTES: u64 = 1024;
const MAX_REQUEST_DIGITS: u64 = 20;
const MAX_REQUEST_LINKS: usize = 8;
const MAX_REQUEST_BYTES: u64 = MAX_REQUEST_DIGITS + MAX_REQUEST_LINKS as u64 * (1 + 32 + 1 + 32);
const RECEIPT_WRITE_BUFFER_BYTES: usize = 128 * 1024;
const PUBLISH_INTERVAL: Duration = Duration::from_millis(20);

static TRACE: OnceLock<Option<Arc<Trace>>> = OnceLock::new();

type Link = (usize, usize);

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

    fn link(&self, sender: &str, recipient: &str) -> Option<Link> {
        let slot = |id| self.roster.binary_search_by(|member| member.as_str().cmp(id)).ok();
        let link = (slot(sender)?, slot(recipient)?);
        (link.0 != link.1).then_some(link)
    }
}

fn valid_hex(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Serialize)]
struct Event {
    ordinal: u64,
    at_ns: u64,
    sender: String,
    recipient: String,
    actual_recipient: Option<String>,
    kind: u32,
    epoch: u32,
    seq: String,
    envelope_bytes: usize,
    envelope_sha256: String,
    payload_sha256: String,
    socket_ordinal: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    lane: Option<&'static str>,
}

#[derive(Default)]
struct Stream {
    count: u64,
    links: BTreeMap<Link, VecDeque<Arc<Event>>>,
}

impl Stream {
    fn record(&mut self, link: Link, mut event: Event, capacity: usize) {
        self.count += 1;
        event.ordinal = self.count;
        let events = self.links.entry(link).or_default();
        if events.len() == capacity {
            events.pop_front();
        }
        events.push_back(Arc::new(event));
    }

    fn snapshot(&self, selected: &[Link], capacity: usize) -> Self {
        let cap = if selected.is_empty() { CAPACITY } else { capacity };
        let links = self.links.iter().filter(|(link, _)| selected.is_empty() || selected.contains(link)).map(|(&link, events)| {
            let start = events.len().saturating_sub(cap);
            (link, events.range(start..).cloned().collect())
        }).collect();
        Self { count: self.count, links }
    }
}

impl Serialize for Stream {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut events: Vec<&Event> = self.links.values().flatten().map(Arc::as_ref).collect();
        events.sort_unstable_by_key(|event| event.ordinal);
        let mut stream = serializer.serialize_struct("Stream", 3)?;
        stream.serialize_field("count", &self.count)?;
        stream.serialize_field("omitted", &(self.count - events.len() as u64))?;
        stream.serialize_field("events", &events)?;
        stream.end()
    }
}

#[derive(Default, Serialize)]
struct Families {
    sync: Stream,
    input: Stream,
    quality: Stream,
}

impl Families {
    fn record(&mut self, link: Link, event: Event) {
        let (stream, capacity) = match event.kind {
            0 | 1 => (&mut self.sync, CAPACITY),
            2 | 3 => (&mut self.input, EXPANDED_CAPACITY),
            _ => (&mut self.quality, EXPANDED_CAPACITY),
        };
        stream.record(link, event, capacity);
    }

    fn snapshot(&self, selected: &[Link]) -> Self {
        Self {
            sync: self.sync.snapshot(selected, CAPACITY),
            input: self.input.snapshot(selected, EXPANDED_CAPACITY),
            quality: self.quality.snapshot(selected, EXPANDED_CAPACITY),
        }
    }
}

#[derive(Default, Serialize)]
struct Streams {
    ingress: Families,
    write: Families,
    unaddressed_writes: u64,
}

impl Streams {
    fn snapshot(&self, selected: &[Link]) -> Self {
        Self {
            ingress: self.ingress.snapshot(selected),
            write: self.write.snapshot(selected),
            unaddressed_writes: self.unaddressed_writes,
        }
    }
}

struct Trace {
    origin: Instant,
    scope: OnceLock<Scope>,
    state: Mutex<Streams>,
}

impl Trace {
    fn publish(&self, scope_path: &Path, paths: &ReceiptPaths) -> anyhow::Result<()> {
        loop {
            match Scope::read(scope_path) {
                Ok(scope) => {
                    let _ = self.scope.set(scope);
                    break;
                }
                Err(error) if error.downcast_ref::<io::Error>().is_some_and(|err| err.kind() == io::ErrorKind::NotFound) => {
                    std::thread::sleep(PUBLISH_INTERVAL);
                }
                Err(error) => return Err(error),
            }
        }

        let mut published = 0;
        loop {
            if let Some(request) = self.publish_request(paths, published, identity)? {
                published = request;
            }
            std::thread::sleep(PUBLISH_INTERVAL);
        }
    }

    fn publish_request<W: Write>(&self, paths: &ReceiptPaths, published: u64, wrap_output: impl FnOnce(File) -> W) -> anyhow::Result<Option<u64>> {
        let scope = self.scope.get().ok_or_else(|| anyhow::anyhow!("missing relay trace scope"))?;
        let Some(request) = paths.read_request(scope) else { return Ok(None) };
        if request.generation <= published || (published == 0 && request.generation != 1) {
            return Ok(None);
        }

        let at_ns = || self.origin.elapsed().as_nanos() as u64;
        let observed_ns = at_ns();

        #[derive(Serialize)]
        struct Snapshot<'a> {
            version: u8,
            request: u64,
            links: &'a [String],
            clock: &'static str,
            #[serde(flatten)]
            scope: &'a Scope,
            streams: Streams,
        }

        let state = self.state.lock().map_err(|_| anyhow::anyhow!("relay trace lock poisoned"))?;
        let cutoff_ns = at_ns();
        let streams = state.snapshot(&request.links);
        drop(state);
        let snapshot_finished_ns = at_ns();
        let links: Vec<_> = request.links.iter().map(|&(sender, recipient)| format!("{}/{}", scope.roster[sender], scope.roster[recipient])).collect();
        let mut writer = BufWriter::with_capacity(RECEIPT_WRITE_BUFFER_BYTES, wrap_output(File::create(&paths.scratch)?));
        serde_json::to_writer(
            &mut writer,
            &Snapshot {
                version: 2,
                request: request.generation,
                links: &links,
                clock: "server.monotonic",
                scope,
                streams,
            },
        )?;
        writer.flush()?;
        drop(writer);
        let serialized_ns = at_ns();
        let published = paths.commit(scope, &request)?;
        let commit_finished_ns = at_ns();
        // The receipt is immutable after rename. Log the observed rename outcome separately.
        eprintln!("relay receipt timing {}", serde_json::json!({
            "clock": "server.monotonic",
            "room": scope.room,
            "request": request.generation,
            "links": links,
            "request_observed_ns": observed_ns,
            "cutoff_ns": cutoff_ns,
            "snapshot_finished_ns": snapshot_finished_ns,
            "serialized_ns": serialized_ns,
            "commit_finished_ns": commit_finished_ns,
            "published": published,
        }));
        Ok(published.then_some(request.generation))
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Request {
    generation: u64,
    links: Vec<Link>,
}

struct ReceiptPaths {
    output: PathBuf,
    scratch: PathBuf,
    request: PathBuf,
}

impl ReceiptPaths {
    fn new(output: PathBuf) -> Self {
        let mut request = output.as_os_str().to_os_string();
        request.push(".request");
        let scratch = output.with_extension(format!("{}.next", std::process::id()));
        Self { output, scratch, request: request.into() }
    }

    fn read_request(&self, scope: &Scope) -> Option<Request> {
        let mut bytes = Vec::new();
        File::open(&self.request).ok()?.take(MAX_REQUEST_BYTES + 1).read_to_end(&mut bytes).ok()?;
        if bytes.len() as u64 > MAX_REQUEST_BYTES {
            return None;
        }
        let mut lines = std::str::from_utf8(&bytes).ok()?.split('\n');
        let generation = lines.next()?;
        if generation.len() as u64 > MAX_REQUEST_DIGITS || !generation.bytes().all(|byte| byte.is_ascii_digit()) || generation.starts_with('0') {
            return None;
        }
        let generation = generation.parse().ok()?;
        let mut links = Vec::new();
        for line in lines {
            let (sender, recipient) = line.split_once('/')?;
            let link = scope.link(sender, recipient)?;
            if links.len() == MAX_REQUEST_LINKS || links.contains(&link) {
                return None;
            }
            links.push(link);
        }
        Some(Request { generation, links })
    }

    fn commit(&self, scope: &Scope, request: &Request) -> io::Result<bool> {
        if self.read_request(scope).as_ref() != Some(request) {
            fs::remove_file(&self.scratch)?;
            return Ok(false);
        }
        fs::rename(&self.scratch, &self.output)?;
        Ok(true)
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
            let paths = ReceiptPaths::new(output);
            if !paths.output.is_absolute()
                || !scope.is_absolute()
                || scope == paths.output
                || scope == paths.request
                || scope == paths.scratch
                || paths.scratch == paths.output
                || paths.scratch == paths.request
            {
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
                if let Err(error) = publisher.publish(&scope, &paths) {
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
    Ingress { socket_ordinal: u64, received_at: Instant, addressed_to: Option<PlayerId> },
    Write { recipient: PlayerId, written_at: Instant, addressed: bool },
}

pub(crate) fn record(boundary: Boundary, room_id: RoomId, sender: PlayerId, seq: u64, epoch: u32, envelope: &[u8]) {
    let Some(trace) = trace() else { return };
    record_packet(trace, boundary, room_id, sender, seq, epoch, envelope);
}

fn record_packet(trace: &Trace, boundary: Boundary, room_id: RoomId, sender: PlayerId, seq: u64, epoch: u32, envelope: &[u8]) {
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
    let Some(link) = scope.link(&sender, &recipient) else { return };

    let (at, socket_ordinal, actual_recipient, addressed) = match boundary {
        Boundary::Ingress { socket_ordinal, received_at, addressed_to } => {
            if addressed_to.is_some_and(|actual| envelope[37..53] != *actual.as_bytes()) {
                return;
            }
            (received_at, Some(socket_ordinal), None, addressed_to.is_some())
        },
        Boundary::Write {
            recipient: actual,
            written_at,
            addressed,
        } => {
            if envelope[37..53] != *actual.as_bytes() {
                // Count copies made by room fan-out outside the addressed packet ring.
                if !addressed {
                    if let Ok(mut state) = trace.state.lock() {
                        state.unaddressed_writes += 1;
                    }
                }
                return;
            }
            (written_at, None, Some(actual.simple().to_string()), addressed)
        }
    };
    let event = Event {
        ordinal: 0,
        at_ns: at.saturating_duration_since(trace.origin).as_nanos() as u64,
        sender,
        recipient,
        actual_recipient,
        kind: tag,
        epoch,
        seq: seq.to_string(),
        envelope_bytes: envelope.len(),
        envelope_sha256: hex(&Sha256::digest(envelope)),
        payload_sha256: hex(&Sha256::digest(&envelope[ENVELOPE_HEADER_BYTES..])),
        socket_ordinal,
        lane: addressed.then_some("addressed"),
    };
    if let Ok(mut state) = trace.state.lock() {
        let families = if socket_ordinal.is_some() {
            &mut state.ingress
        } else {
            &mut state.write
        };
        families.record(link, event);
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

#[cfg(test)]
mod tests {
    use super::*;

    fn trace_for(room_id: RoomId, roster: &[PlayerId]) -> Trace {
        Trace {
            origin: Instant::now(),
            scope: OnceLock::from(Scope {
                room_id,
                room: room_id.simple().to_string(),
                roster: roster.iter().map(|id| id.simple().to_string()).collect(),
            }),
            state: Mutex::default(),
        }
    }

    fn record_pair(trace: &Trace, room_id: RoomId, sender: PlayerId, recipient: PlayerId, tag: u32, seq: u64) -> Vec<u8> {
        let mut envelope = vec![0; NATIVE_HEADER_BYTES + 4];
        envelope[..5].copy_from_slice(b"FSR1\x01");
        envelope[5..21].copy_from_slice(room_id.as_bytes());
        envelope[21..37].copy_from_slice(sender.as_bytes());
        envelope[37..53].copy_from_slice(recipient.as_bytes());
        envelope[53..57].copy_from_slice(&28_u32.to_le_bytes());
        envelope[57..73].copy_from_slice(room_id.as_bytes());
        envelope[73..77].copy_from_slice(&[0xf5, 0x52, 2, 0]);
        envelope[77..81].copy_from_slice(&(seq as u32).to_le_bytes());
        envelope[81..85].copy_from_slice(&tag.to_le_bytes());
        record_packet(trace, Boundary::Ingress { socket_ordinal: seq, received_at: trace.origin, addressed_to: None }, room_id, sender, seq, 7, &envelope);
        record_packet(trace, Boundary::Write { recipient, written_at: trace.origin, addressed: false }, room_id, sender, seq, 7, &envelope);
        record_packet(trace, Boundary::Write { recipient: sender, written_at: trace.origin, addressed: false }, room_id, sender, seq, 7, &envelope);
        envelope
    }

    #[test]
    fn addressed_receipts_keep_their_lane_and_match_the_actual_target() {
        let room = RoomId::from_u128(1);
        let roster = [2, 3, 4].map(PlayerId::from_u128);
        let [sender, recipient, bystander] = roster;
        let trace = trace_for(room, &roster);
        let envelope = record_pair(&trace, room, sender, recipient, 4, 1);
        for target in [recipient, bystander] {
            record_packet(&trace, Boundary::Ingress { socket_ordinal: 2, received_at: trace.origin, addressed_to: Some(target) },
                room, sender, 1, 7, &envelope);
            record_packet(&trace, Boundary::Write { recipient: target, written_at: trace.origin, addressed: true }, room, sender, 1, 7, &envelope);
        }
        let streams = serde_json::to_value(&*trace.state.lock().unwrap()).unwrap();
        for stage in ["ingress", "write"] {
            let events = streams[stage]["quality"]["events"].as_array().unwrap();
            assert_eq!(events.len(), 2, "{stage} must ignore the mismatched target");
            assert!(events[0].get("lane").is_none(), "legacy receipt shape changed");
            assert_eq!(events[1]["lane"], "addressed");
            for field in ["sender", "recipient", "epoch", "seq", "envelope_sha256", "payload_sha256"] {
                assert_eq!(events[0][field], events[1][field], "{field}");
            }
        }
        assert_eq!(streams["unaddressed_writes"], 1, "only ordinary room fan-out is counted");
    }

    // Value: protects=quiet directed packet joins; fails_when=busy links evict quiet links; why_new=single-link captures cannot expose cross-link eviction; seam=none
    #[test]
    fn quiet_link_survives_healthy_link_churn() {
        let room_id = RoomId::from_u128(1);
        let roster = [2, 3, 4, 5].map(PlayerId::from_u128);
        let trace = trace_for(room_id, &roster);
        let [sender, quiet, healthy_recipient, healthy_sender] = roster;
        let mut exact = Vec::new();
        for (family, tag) in [("input", 2), ("quality", 4)] {
            let first = record_pair(&trace, room_id, sender, quiet, tag, 31);
            for burst in 0..CAPACITY as u64 + 3 {
                record_pair(&trace, room_id, sender, healthy_recipient, tag, 32 + burst);
                record_pair(&trace, room_id, healthy_sender, quiet, tag, 32 + burst);
            }
            // Reverse traffic uses a separate ring.
            let reverse = record_pair(&trace, room_id, quiet, sender, tag, 8);
            exact.push((family, tag, first, reverse));
        }

        let directory = tempfile::tempdir().unwrap();
        let paths = ReceiptPaths::new(directory.path().join("receipt.json"));
        fs::write(&paths.request, "1").unwrap();
        assert_eq!(trace.publish_request(&paths, 0, identity).unwrap(), Some(1));
        let snapshot: serde_json::Value = serde_json::from_slice(&fs::read(&paths.output).unwrap()).unwrap();
        let streams = &snapshot["streams"];
        assert_eq!(streams["unaddressed_writes"], 2 * (2 * CAPACITY + 8));
        for (family, tag, first, reverse) in exact {
            for (stage, ingress) in [("ingress", true), ("write", false)] {
                let stream = &streams[stage][family];
                let events = stream["events"].as_array().unwrap();
                assert_eq!(events[0]["seq"], "31", "{stage}/{family} lost the quiet link");
                assert_eq!(stream["count"], 2 * CAPACITY + 8);
                assert_eq!(stream["omitted"], 6);
                assert_eq!(events.len(), 2 * CAPACITY + 2);
                assert!(events.iter().map(|event| event["ordinal"].as_u64().unwrap()).eq([1].into_iter().chain(8..=(2 * CAPACITY as u64 + 8))));
                for (event, envelope, from, to, seq) in [(&events[0], &first, sender, quiet, 31), (events.last().unwrap(), &reverse, quiet, sender, 8)] {
                    assert_eq!(event["sender"], from.simple().to_string());
                    assert_eq!(event["recipient"], to.simple().to_string());
                    assert_eq!(event["kind"], tag);
                    assert_eq!(event["epoch"], 7);
                    assert_eq!(event["seq"], seq.to_string());
                    assert_eq!(event["envelope_bytes"], envelope.len());
                    assert_eq!(event["envelope_sha256"], hex(&Sha256::digest(envelope)));
                    assert_eq!(event["payload_sha256"], hex(&Sha256::digest(&envelope[ENVELOPE_HEADER_BYTES..])));
                    assert_eq!(event["socket_ordinal"], if ingress { serde_json::json!(seq) } else { serde_json::Value::Null });
                    assert_eq!(event["actual_recipient"], if ingress { serde_json::Value::Null } else { serde_json::json!(to.simple().to_string()) });
                }
            }
        }
    }

    // Value: protects=exact selected history; fails_when=the normal tail is also the retained tail; why_new=quiet-link traffic cannot test a busy link's own rollover; seam=none
    #[test]
    fn selected_history_survives_its_own_link_churn() {
        let directory = tempfile::tempdir().unwrap();
        let paths = ReceiptPaths::new(directory.path().join("receipt.json"));
        let room_id = RoomId::from_u128(1);
        let [sender, recipient] = [2, 3].map(PlayerId::from_u128);
        let trace = trace_for(room_id, &[sender, recipient]);
        let mut originals = Vec::new();
        for (family, tag) in [("sync", 0), ("input", 2), ("quality", 4)] {
            originals.push((family, record_pair(&trace, room_id, sender, recipient, tag, 1)));
            record_pair(&trace, room_id, recipient, sender, tag, 1);
        }
        let mut last = 1;
        let mut published = 0;
        for (through, selected) in [(128, false), (129, false), (129, true), (512, true), (521, true), (1024, true), (1025, true), (1025, false)] {
            for seq in (last + 1)..=through {
                for tag in [0, 2, 4] {
                    record_pair(&trace, room_id, sender, recipient, tag, seq);
                    record_pair(&trace, room_id, recipient, sender, tag, seq);
                }
            }
            last = through;
            let generation = published + 1;
            let request = if selected { format!("{generation}\n{}/{}", sender.simple(), recipient.simple()) } else { generation.to_string() };
            fs::write(&paths.request, &request).unwrap();
            assert_eq!(trace.publish_request(&paths, published, identity).unwrap(), Some(generation), "{request:?}");
            published = generation;
            let snapshot: serde_json::Value = serde_json::from_slice(&fs::read(&paths.output).unwrap()).unwrap();
            assert_eq!(snapshot["request"], published);
            for (family, original) in &originals {
                let extended = selected && *family != "sync";
                let retained = through.min(if extended { 1024 } else { 128 });
                let first_forward = through - retained + 1;
                let first_reverse = through - 128 + 1;
                for stage in ["ingress", "write"] {
                    let stream = &snapshot["streams"][stage][family];
                    let events = stream["events"].as_array().unwrap();
                    assert_eq!(stream["count"], 2 * through, "{stage}/{family}");
                    assert_eq!(stream["omitted"], 2 * through - retained - if selected { 0 } else { 128 }, "{stage}/{family}");
                    let ordinals = (1..=(2 * through)).filter(|ordinal| {
                        if ordinal % 2 == 1 { *ordinal >= 2 * first_forward - 1 } else { !selected && *ordinal >= 2 * first_reverse }
                    });
                    assert!(events.iter().map(|event| event["ordinal"].as_u64().unwrap()).eq(ordinals), "{stage}/{family}");
                    if first_forward == 1 {
                        assert_eq!(events[0]["seq"], "1");
                        assert_eq!(events[0]["envelope_sha256"], hex(&Sha256::digest(original)));
                        assert_eq!(events[0]["payload_sha256"], hex(&Sha256::digest(&original[ENVELOPE_HEADER_BYTES..])));
                    }
                }
            }
        }
    }

    // Value: protects=the final eight-player receipt's I/O budget; fails_when=JSON is emitted in small writes; why_new=receipt equality does not bound writes; seam=Write
    #[test]
    fn full_room_receipt_batches_file_writes() {
        use std::cell::Cell;

        struct CountedFile<'a> {
            file: File,
            writes: &'a Cell<usize>,
        }

        impl Write for CountedFile<'_> {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                self.writes.set(self.writes.get() + 1);
                self.file.write(bytes)
            }

            fn flush(&mut self) -> io::Result<()> {
                self.file.flush()
            }
        }

        let room_id = RoomId::from_u128(1);
        let roster = [2, 3, 4, 5, 6, 7, 8, 9].map(PlayerId::from_u128);
        let trace = trace_for(room_id, &roster);
        for &sender in &roster {
            for &recipient in roster.iter().filter(|&&recipient| recipient != sender) {
                for seq in 1..=CAPACITY as u64 {
                    for tag in [2, 4] {
                        record_pair(&trace, room_id, sender, recipient, tag, seq);
                    }
                }
            }
        }
        let directory = tempfile::tempdir().unwrap();
        let paths = ReceiptPaths::new(directory.path().join("receipt.json"));
        fs::write(&paths.request, "3").unwrap();
        let writes = Cell::new(0);
        let generation = trace.publish_request(&paths, 2, |file| CountedFile { file, writes: &writes }).unwrap();
        assert_eq!(generation, Some(3));
        assert!(!paths.scratch.exists());
        let bytes = paths.output.metadata().unwrap().len();
        assert!((10 * 1024 * 1024..=14 * 1024 * 1024).contains(&bytes), "wrong receipt size: {bytes}");
        assert!((1..=128).contains(&writes.get()), "{} writes for {bytes} bytes", writes.get());
    }

    // Value: protects=one atomic receipt per generation; fails_when=idle or superseded requests publish; why_new=packet joins do not exercise the publisher; seam=none
    #[test]
    fn receipts_require_fresh_requests() {
        let directory = tempfile::tempdir().unwrap();
        let paths = ReceiptPaths::new(directory.path().join("receipt.json"));
        assert_eq!(paths.request, directory.path().join("receipt.json.request"));
        let room_id = RoomId::from_u128(1);
        let roster = [10, 11, 12, 13].map(PlayerId::from_u128);
        let [sender, recipient, _, _] = roster;
        let trace = trace_for(room_id, &roster);
        let scope = trace.scope.get().unwrap();
        let publish = |published| trace.publish_request(&paths, published, identity).unwrap();
        assert_eq!(publish(0), None);
        for invalid in ["", "0", "01", "+1", "1\n", "２", "2", "18446744073709551616", "999999999999999999999"] {
            fs::write(&paths.request, invalid).unwrap();
            assert_eq!(publish(0), None, "{invalid:?}");
            assert!(!paths.output.exists());
            assert!(!paths.scratch.exists());
        }
        let directed_pair = format!("{}/{}", sender.simple(), recipient.simple());
        let reversed_pair = format!("{}/{}", recipient.simple(), sender.simple());
        let pairs: Vec<String> = roster.iter().flat_map(|sender| {
            roster.iter().filter(move |recipient| *recipient != sender).map(move |recipient| format!("{}/{}", sender.simple(), recipient.simple()))
        }).collect();
        for invalid in [
            format!("1\n{directed_pair}\n{directed_pair}"),
            format!("1\n{directed_pair}\n"),
            format!("1\r\n{directed_pair}"),
            format!("1\n{}", directed_pair.to_ascii_uppercase()),
            format!("1\n {directed_pair}"),
            format!("1\n{}/{}", sender.simple(), sender.simple()),
            format!("1\n{}/{}", sender.simple(), room_id.simple()),
            format!("1\n{}", pairs[..9].join("\n")),
            format!("2\n{directed_pair}"),
        ] {
            fs::write(&paths.request, &invalid).unwrap();
            assert_eq!(publish(0), None, "{invalid:?}");
            assert!(!paths.output.exists());
            assert!(!paths.scratch.exists());
        }
        fs::write(&paths.request, "1").unwrap();
        assert_eq!(publish(0), Some(1));
        let first = fs::read(&paths.output).unwrap();
        let snapshot: serde_json::Value = serde_json::from_slice(&first).unwrap();
        assert_eq!(snapshot["version"], 2);
        assert_eq!(snapshot["request"], 1);
        assert_eq!(snapshot["links"], serde_json::json!([]));
        assert_eq!(snapshot["room"], scope.room);
        assert_eq!(snapshot["roster"], serde_json::json!(scope.roster));
        assert_eq!(snapshot["streams"]["ingress"]["input"]["count"], 0);
        record_pair(&trace, room_id, sender, recipient, 2, 1);
        assert_eq!(publish(1), None);
        assert_eq!(fs::read(&paths.output).unwrap(), first);
        let same_generation = format!("2\n{reversed_pair}");
        for new_request in [Some("3"), Some("invalid"), Some(same_generation.as_str()), None] {
            fs::write(&paths.request, format!("2\n{directed_pair}")).unwrap();
            let request = paths.read_request(scope).unwrap();
            assert_eq!(request, Request { generation: 2, links: vec![(0, 1)] });
            fs::write(&paths.scratch, "staged generation 2").unwrap();
            match new_request {
                Some(request) => fs::write(&paths.request, request).unwrap(),
                None => fs::remove_file(&paths.request).unwrap(),
            }
            assert!(!paths.commit(scope, &request).unwrap());
            assert_eq!(fs::read(&paths.output).unwrap(), first);
            assert!(!paths.scratch.exists());
        }
        let third_generation = u64::MAX;
        fs::write(&paths.request, format!("{third_generation}\n{}", pairs[..8].join("\n"))).unwrap();
        assert_eq!(publish(1), Some(third_generation));
        let third = fs::read(&paths.output).unwrap();
        let snapshot: serde_json::Value = serde_json::from_slice(&third).unwrap();
        assert_eq!(snapshot["request"], third_generation);
        assert_eq!(snapshot["links"], serde_json::json!(pairs[..8]));
        assert_eq!(snapshot["streams"]["ingress"]["input"]["count"], 1);
        assert!(!paths.scratch.exists());
        for generation in [2, third_generation] {
            fs::write(&paths.request, format!("{generation}\n{reversed_pair}")).unwrap();
            assert_eq!(publish(third_generation), None);
        }
        assert_eq!(fs::read(&paths.output).unwrap(), third);
    }
}
