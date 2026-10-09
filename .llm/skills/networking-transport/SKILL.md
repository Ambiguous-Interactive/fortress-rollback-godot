---
name: networking-transport
description: "Transport and serialization conventions: ENet/WebRTC peer setup, channel usage, StreamPeerBuffer fixed-width packets, replay file format, checksum exchange. Use when touching networking, packets, replays, or desync reporting."
metadata:
  category: feature
---

# Networking Transport

The session logic (see
[rollback-fundamentals](../rollback-fundamentals/SKILL.md)) must not know
whether it is talking to ENet, WebRTC, or a replay file. Everything on the
wire is bytes with an exact, versioned layout.

## Godot Peer Setup

| Target | Peer | Notes |
| --- | --- | --- |
| Desktop/native | `ENetMultiplayerPeer` | UDP; compress disabled (we control framing) |
| Web export | `WebRTCMultiplayerPeer` | No ENet in browsers; mesh topology |
| Local tests / replays | `StreamPeerBuffer` queues | Deterministic, no sockets in CI |

ENet channels: `0` = reliable ordered (handshake, events, checksums),
`1` = unreliable unordered (live input frames — a late packet is worthless,
so never resend it reliably).

## Serialization Rules

1. All packets are built with `StreamPeerBuffer` in **explicit little-endian,
   fixed-width** form (`put_u32`, `put_u16`, `put_u8`). Never `put_var` —
   its encoding is engine-version-dependent and kills replay stability.
2. Every packet begins with: `magic: u16`, `version: u8`, `type: u8`.
3. Floats on the wire only if IEEE-exact ops were used end to end (see
   [determinism](../determinism/SKILL.md)); prefer integers.
4. Inputs are delta-compressed only *after* correctness: predictability of
   the byte format beats bandwidth micro-optimizations. See
   [input_serialization.gd](../../code-samples/input_serialization.gd).

## Replay Format

```
magic "FRG1" | version u32 | seed u64 | input_delay u8
| frame_count u32 | then per frame: frame u32 + input bytes for each peer
```

Replays are the deterministic test fixtures (see
[testing](../testing/SKILL.md)). Bump `version` and provide a converter
whenever the layout changes; never mutate a released format in place.

## Desync Detection

1. Each peer checksums state every `CHECKSUM_INTERVAL` frames (see
   [state_checksum.gd](../../code-samples/state_checksum.gd)).
2. Checksum packets carry `frame`, `checksum`, and the input-hash history
   window so the exact diverging input can be identified.
3. On mismatch: emit `desync_detected` with both checksums + frames, dump
   both state blobs to a diagnostic file, and keep the session alive in
   "degraded" mode unless gameplay integrity is compromised.

## What Belongs Here vs Elsewhere

- Wire formats, channels, replay layout, checksum exchange: this skill.
- When to roll back and why: rollback-fundamentals.
- Bit-exactness of what you serialize: determinism.
