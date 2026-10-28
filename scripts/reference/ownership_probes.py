#!/usr/bin/env python3
"""Verify integer, ownership and production byte sessions on pinned native/Web engines."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import zipfile

from fetch import CACHE, ROOT, digest, fetch, load_manifest, prepare_zip
from local_ownership import claim

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import host_capacity  # noqa: E402

from receipt_arguments import ReceiptParser
from godot_smoke import run
from run import begin_results, capture, captured_text
from browser.webrtc_matrix import prepare_firefox
from browser.webrtc_import import freeze_after_import
from signalfish_probe import inventory

PREFIX = 'FORTRESS_TEST_RESULT '
PROGRESS_PREFIX = 'FORTRESS_TEST_PROGRESS '
# The observation of a round is bounded: a fixed number of fields, a fixed
# number of retained errors and a fixed error length. A rejected run keeps its
# diagnosis without buffering the output that produced it.
MAX_RETAINED_ERRORS = 8
MAX_ERROR_LENGTH = 200
EXPECTED = {
    'res://tests/unit/test_protocol_codec.gd': {'golden', 'truncation', 'malformed', 'limits', 'types', 'ownership', 'semantics', 'hostile_bytes'},
    'res://tests/unit/test_protocol_handshake_fields.gd': {'compatibility', 'geometry', 'bounds'},
    'res://tests/unit/test_handshake.gd': {'roundtrips', 'echoes', 'mismatch', 'time', 'identity', 'backpressure', 'timeout_pressure', 'ownership'},
    'res://tests/determinism/test_buffer_ownership.gd': {'engine_boundaries', 'owned_input', 'snapshot_wraps', 'snapshot_bounds'},
    'res://tests/determinism/test_integer_encoding.gd': {'arithmetic', 'binary', 'bounds', 'checksum'},
}
EXPECTED.update({
    'res://tests/unit/test_endpoint_lifecycle.gd': {'control_receive', 'strict_timers', 'liveness', 'quality',
        'checksum_goodbye', 'capacity', 'pacing', 'long_running', 'retention_failure', 'status_nudge_capacity'},
    'res://tests/unit/test_peer_lifecycle.gd': {'checksum_export', 'healthy_exchange', 'real_desync', 'terminal_timeout', 'close',
        'checksum_conflict', 'checksum_future', 'stale_checksum', 'interrupted_resume', 'checksum_capacity', 'event_capacity', 'statistics',
        'lockstep_checksums', 'later_peer_expiry'},
    'res://tests/unit/test_input_endpoint.gd': {'loss_ack', 'retry', 'validation', 'retention', 'capacity', 'ownership',
        'status_nudge', 'status_nudge_transitions'},
    'res://tests/unit/test_stalled_gossip.gd': {'drained', 'dropped_reordered', 'missing_receipt', 'step_recovery', 'grouped_locals'},
    'res://tests/unit/test_session_network_seams.gd': {'delay_startup', 'scheduled_sample', 'confirmation_limit', 'mesh_stall_save'},
    'res://tests/unit/test_peer_session.gd': {'mesh', 'loss', 'multiple_locals', 'backpressure', 'ingress',
        'partial_publication', 'reentry', 'begin_preflight', 'long_runtime', 'request_mismatch', 'low_windows', 'packet_service'},
    'res://tests/unit/test_peer_checksum_repair.gd': {'pending_repair_is_not_a_loss', 'lost_snapshot_still_fails',
        'lost_snapshot_under_a_repair_still_fails'},
})
EXPECTED.update({
    'res://tests/unit/test_diagnostic_trace.gd': {'owned_window', 'disabled_equality', 'bounds', 'failed_callback', 'local_divergence',
        'rollback_window', 'driver_export'},
    'res://tests/unit/test_peer_diagnostic_trace.gd': {'real_divergence', 'healthy_equality'},
    'res://tests/unit/test_replay_callbacks.gd': {'snapshot_failures', 'uninitialized_replay', 'callback_arguments'},
    'res://tests/unit/test_diagnostic_player.gd': {'captured_window', 'canonical_mismatch', 'malformed', 'callbacks', 'bounds'},
    'res://tests/unit/test_diagnostic_viewer.gd': {'imports', 'controls', 'divergence', 'scene_controls'},
    'res://tests/unit/test_replay_viewer.gd': {'controls', 'rejects_incompatible', 'stops_at_divergence', 'scene_controls', 'navigation', 'navigation_boundaries'},
    'res://tests/unit/test_replay.gd': {'records_corrected_match', 'records_metadata', 'detects_changed_rules', 'golden',
        'rejects_malformed_files', 'bounds_recording', 'lockstep_confirmation_limit', 'refuses_foreign_recording',
        'protects_input_rows', 'status_integrity'},
})
EXPECTED.update({
    'res://tests/unit/test_spectator_session.gd': {'configuration', 'confirmed_playback', 'buffering', 'delay_and_loss',
        'expert_parity', 'host_export', 'storage_budget', 'host_export_repair', 'exhaustion', 'shapes',
        'retained_row', 'delay_bounds', 'mesh_mutators'},
    'res://tests/unit/test_driver_callback_results.gd': {'valid', 'malformed', 'termination', 'peer_failure'},
})
EXPECTED.update({
    'res://tests/unit/test_driver.gd': {'parity', 'reentry', 'failure', 'validation', 'stall',
        'terminate_reconfigure', 'notifications', 'input_validation', 'missing_samples', 'client_status'},
    'res://tests/unit/test_replay_checkpoints.gd': {'cached_navigation', 'bounded_cache', 'restore_failures', 'checkpoint_callbacks'},
    'res://tests/unit/test_spectator_stream.gd': {'wire_golden', 'byte_delivery', 'malformed', 'authentication', 'negotiation',
        'lifetime_and_timeout', 'clean_tail', 'bounds', 'busy', 'keepalive', 'viewer_lifetime', 'viewer_lifetime_control',
        'policy_preserved', 'replaced_viewer', 'wide_shapes', 'offer_lifecycle', 'closed_input_duplicates', 'initial_state_agreement', 'obsolete_rows'},
    'res://tests/unit/test_driver_callback_signatures.gd': {'arity', 'optional', 'diagnostic', 'argument_types'},
    'res://tests/unit/test_driver_script_view_types.gd': {'driver', 'diagnostic', 'replay'},
    'res://tests/unit/test_replay_diagnostics.gd': {'playback_evidence', 'restore_evidence', 'viewer_evidence', 'boundary_validation'},
    'res://tests/unit/test_spectator_demo.gd': {'corrected_viewing', 'pause_and_catchup', 'lost_history', 'idle_host_liveness'},
    'res://tests/unit/test_spectator_policy.gd': {
        'confirmation_policy', 'playback_events', 'failure_events', 'empty_end_and_reentry', 'completion_status', 'gapped_end'},
    'res://tests/unit/test_spectator_publisher.gd': {'retained_publication', 'clean_end', 'lifetime_and_busy'},
    'res://tests/unit/test_replay_speed.gd': {'cadence', 'controls', 'failure', 'scene_speed', 'backward_step', 'scene_backward_step', 'keyboard_controls'},
})
EXPECTED['res://tests/unit/test_driver_recovery.gd'] = {
    'final_history', 'staged_sample', 'failures', 'guards', 'expert_parity', 'matching_tail', 'boundary_checksum', 'client_history'}
EXPECTED['res://tests/unit/test_spectator_demo.gd'].update({'clean_host_end', 'paused_final_tail'})
EXPECTED['res://tests/unit/test_spectator_demo.gd'].update({'single_frame', 'single_frame_end', 'single_frame_control', 'host_loss', 'host_loss_control'})
EXPECTED['res://tests/unit/test_peer_recovery.gd'] = {'final_mesh', 'guards', 'callbacks', 'timeout', 'idle_confirmation'}
EXPECTED['res://tests/unit/test_peer_replay_capture.gd'] = {'capture_final', 'capture_guards', 'capture_callbacks', 'capture_cap'}
EXPECTED['res://tests/unit/test_replay_coverage.gd'] = {'coverage', 'counting', 'unchecked_seek', 'paused_input_integrity', 'selected_state_status'}
EXPECTED['res://tests/unit/test_driver.gd'].add('input_exhaustion')
EXPECTED['res://tests/unit/test_replay_diagnostics.gd'].update({'stepped_boundaries', 'paused_boundaries'})
EXPECTED['res://tests/unit/test_spectator_model.gd'] = {
    'bounded_delivery_model', 'loss_and_conflict_model', 'transcript_mutation_control', 'caller_bounded_catchup_model'}
EXPECTED['res://tests/unit/test_frame_inputs.gd'] = {'copy', 'validation', 'driver_parity'}
EXPECTED['res://tests/unit/test_input_queue.gd'] = {'delay', 'prediction', 'ring', 'validation', 'ownership', 'reclaim', 'reclaim_delay'}
EXPECTED['res://tests/unit/test_spectator_status.gd'] = {'rows', 'wire_status', 'host_drop'}
EXPECTED['res://tests/unit/test_replay_drop.gd'] = {
    'retained_freeze', 'certified_freeze', 'predicted_retained_freeze', 'predicted_certified_freeze', 'failed_recovery_fence'}
EXPECTED['res://tests/unit/test_replay_expert.gd'] = {
    'canonical_parity', 'request_lifetime', 'save_failures', 'callback_guards', 'paused_termination', 'paused_termination_bad_result'}
EXPECTED['res://tests/unit/test_replay_terminal.gd'] = {
    'capture_final_boundary', 'terminal_validation', 'expert_terminal', 'capture_refusals', 'terminal_golden', 'capture_lifetime', 'recording_cap'}
EXPECTED['res://tests/unit/test_replay_terminal_recovery.gd'] = {'corrected_terminal', 'retained_drop_terminal', 'certified_drop_terminal'}
EXPECTED['res://tests/unit/test_replay_validation.gd'] = {'paused_parity', 'paused_integrity', 'paused_lifetime'}
EXPECTED['res://tests/unit/test_replay_expert_navigation.gd'] = {'navigation_parity', 'restore_integrity', 'restore_lifetime', 'checkpoint_revalidation'}
EXPECTED['res://tests/unit/test_peer_drop_inventory.gd'] = {
    'independent_inventory_golden', 'startup_feature', 'legacy_startup_refused', 'retained_only_startup_refused', 'control_packet_budget',
    'unknown_version', 'empty_inventory', 'wrong_cardinality', 'wrong_target', 'unbounded_interval', 'changed_certificate', 'candidate_below_receipts',
    'unchanged_short_certificate', 'extended_short_certificate'}
EXPECTED['res://tests/unit/test_peer_drop_history.gd'] = {
    'retained_below_confirmation', 'certified_below_confirmation', 'unequal_exposed_frontiers', 'missing_actual_rows', 'pending_repair_raised_cut',
    'matching_frozen_backfill', 'conflicting_frozen_backfill'}
EXPECTED['res://tests/unit/test_history_backfill.gd'] = {
    'overlap_suffix', 'atomic_refusal', 'wrap_floor', 'prediction', 'session_fences', 'session_repair'}
EXPECTED['res://tests/unit/test_driver_external_parity.gd'] = {'immediate', 'delayed_bursts'}
EXPECTED['res://tests/unit/test_driver_peer_parity.gd'] = {'two_peers', 'multiple_local_slots', 'eight_peers', 'observer_controls', 'partial_publication', 'retained_retry'}
EXPECTED['res://tests/unit/test_driver_drop_parity.gd'] = {
    'confirmed_departure', 'predicted_departure', 'repair_control', 'certification_control', 'withheld_certificate'}
EXPECTED['res://tests/unit/test_peer_drop_backfill.gd'] = {
    'remote_donor', 'loss_reorder', 'conflicting_duplicate', 'malformed_chunk', 'wrong_donor', 'lost_history_timeout',
    'resource_limit', 'multiple_target_slots', 'no_donor', 'conflicting_overlap'}
EXPECTED['res://tests/unit/test_peer_drop_capacity.gd'] = {
    'fast_capacity_control', 'slow_complete_control', 'slow_minimum_capacity', 'slow_remote_donor', 'slow_lost_plan',
    'refused_prepare_retries_after_drain', 'refused_inventory_retries_after_drain',
    'refused_commit_retries_after_drain', 'partial_prepare_retries_only_refused_link', 'staggered_prepare_retry'}
EXPECTED['res://tests/unit/test_peer_drop_eviction.gd'] = {'unequal_retained_history', 'retained_history_control', 'journal_after_ring_wrap'}
EXPECTED['res://tests/unit/test_peer_drop_history_pressure.gd'] = {'partial_history_plan_retry', 'staggered_history_plan_retry', 'complete_history_plan_control'}
EXPECTED['res://tests/unit/test_peer_drop_donor_fairness.gd'] = {'healthy_donor_destination', 'unpressured_donor_control'}
EXPECTED['res://tests/unit/test_peer_drop_plan_fairness.gd'] = {
    'refused_plan_preserves_healthy_data', 'complete_plan_data_control', 'half_retry_lost_chunk',
    'half_retry_lost_chunk_control', 'equal_retry_lost_chunk', 'equal_retry_lost_chunk_control'}
EXPECTED['res://tests/unit/test_peer_drop_ready_pressure.gd'] = {'partial_ready_retry', 'staggered_ready_retry', 'complete_ready_control'}
EXPECTED['res://tests/unit/test_driver_input_policy.gd'] = {'stalled_retry', 'delay_policy', 'unconfigured'}
EXPECTED['res://tests/unit/test_driver_termination.gd'] = {'client_stop', 'callbacks', 'completion_handler'}
EXPECTED['res://tests/unit/test_replay_viewer.gd'].update({'full_length_recording', 'empty_terminal'})
EXPECTED['res://tests/unit/test_signalfish_spectator_relay.gd'] = {
    'startup', 'playback', 'refusal', 'queue_pressure', 'expiry', 'lifetimes', 'configuration', 'busy',
    'blocked_liveness', 'retained_callbacks', 'busy_deadline', 'control_retry', 'control_invalid',
    'control_lifetime', 'control_expiry', 'control_busy', 'control_row_pressure', 'reordered_recovery',
    'heartbeat_fairness', 'clean_tail_retries', 'post_completion', 'terminal_failures', 'getter_lifetime', 'configure_lifetime', 'obsolete_rows'}
EXPECTED['res://tests/unit/test_signalfish_spectator_host.gd'] = {
    'startup', 'canonical_playback', 'pressure', 'lifetimes', 'configuration', 'reentry', 'history_loss', 'player_coexistence', 'active_requests',
    'fair_liveness', 'finish_retry', 'callback_lifetimes', 'setup_callbacks'}
EXPECTED['res://tests/unit/test_peer_session.gd'].add('scheduled_inputs')
EXPECTED['res://tests/unit/test_replay_callbacks.gd'].add('failure_kinds')
EXPECTED['res://tests/unit/test_replay_diagnostics.gd'].update({'failure_download', 'comparison_domains'})
EXPECTED['res://tests/unit/test_replay_final_coverage.gd'] = {'final_state_coverage', 'viewer_final_coverage', 'selected_state_coverage', 'terminal_checkpoints'}
EXPECTED['res://tests/unit/test_peer_drop_history.gd'].add('last_survivor_receipts')
EXPECTED['res://tests/unit/test_peer_drop_multi_slot.gd'] = {
    'interleaved_slots', 'reversed_slot_ownership', 'last_survivor_multi_slot', 'last_survivor_missing_slot'}
EXPECTED['res://tests/unit/test_peer_notifications.gd'] = {
    'completion', 'stall_and_repair', 'failure', 'callback_failure', 'shared_engine', 'handler_stop', 'external_facade'}
EXPECTED['res://tests/unit/test_signalfish_spectator_relay.gd'].update({'source_departures', 'source_callback_lifetime'})
EXPECTED['res://tests/unit/test_signalfish_spectator_host.gd'].add('viewer_departures')
EXPECTED['res://tests/unit/test_replay_configuration.gd'] = {
    'malformed_storage', 'malformed_metadata', 'valid_recording_ownership', 'invalid_config_type', 'recording_accessors'}
EXPECTED['res://tests/unit/test_peer_expert.gd'] = {'public_api', 'batch_ownership', 'callback_failures', 'recovery', 'pressure', 'capture'}
EXPECTED['res://tests/unit/test_snapshot_history.gd'] = {'round_trip', 'failures', 'ownership', 'validation', 'misuse', 'wide_writes', 'reusable_reads'}
EXPECTED['res://tests/unit/test_spectator_demo.gd'].update({'restart_lifetimes', 'restart_busy', 'service_busy'})
EXPECTED['res://tests/unit/test_spectator_demo.gd'].update({'playback_feedback', 'terminal_feedback'})
EXPECTED['res://tests/unit/test_integration_demo.gd'] = {'delayed_matches', 'reset_and_validation', 'replays_corrected_match', 'restart_lifetimes'}
EXPECTED['res://tests/unit/test_replay_prefix.gd'] = {'captured_prefix_evidence', 'prefix_evidence_boundaries', 'incomplete_prefix_digests', 'incomplete_prefix_storage'}
EXPECTED['res://tests/unit/test_spectator_demo_recording.gd'] = {'prefix_capture', 'clean_end_capture', 'capture_guards'}
EXPECTED_COUNT = sum(len(cases) for cases in EXPECTED.values())
FILES = [
    'tests/runner/scenario_runner.gd', 'tests/runner/test_context.gd', 'tests/runner/run_tests.gd',
    'tests/runner/abort_supervisor.gd',
    'tests/determinism/test_buffer_ownership.gd', 'tests/determinism/ownership_slots.gd',
    'tests/determinism/test_integer_encoding.gd', 'tests/determinism/integer_codec.gd', 'tests/determinism/integer_vectors.json',
    '.llm/code-samples/state_checksum.gd',
    'tests/unit/test_protocol_codec.gd', 'tests/unit/test_protocol_handshake_fields.gd', 'tests/fixtures/protocol/golden.json',
    'addons/fortress_rollback/protocol/protocol_codec.gd', 'addons/fortress_rollback/protocol/protocol_types.gd',
    'addons/fortress_rollback/protocol/protocol_reader.gd', 'addons/fortress_rollback/protocol/protocol_validation.gd',
    'addons/fortress_rollback/protocol/protocol_projection.gd',
    'tests/unit/test_handshake.gd', 'addons/fortress_rollback/protocol/handshake.gd',
    'addons/fortress_rollback/protocol/handshake_types.gd', 'addons/fortress_rollback/protocol/handshake_agreement.gd',
]
FILES += [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'addons/fortress_rollback/core').glob('*.gd'))]
FILES += ['addons/fortress_rollback/protocol/input_endpoint.gd',
          'addons/fortress_rollback/protocol/lifecycle_types.gd', 'addons/fortress_rollback/protocol/endpoint_lifecycle.gd',
          'tests/unit/test_endpoint_lifecycle.gd', 'tests/unit/test_peer_lifecycle.gd',
          'addons/fortress_rollback/protocol/input_endpoint_types.gd',
          'tests/unit/test_input_endpoint.gd', 'tests/unit/test_session_network_seams.gd',
          'tests/unit/test_peer_session.gd', 'tests/unit/test_stalled_gossip.gd', 'tests/oracle/p2p_game.gd', 'tests/oracle/reference_game.gd']
FILES += ['tests/unit/test_diagnostic_trace.gd', 'tests/unit/test_peer_diagnostic_trace.gd', 'tests/unit/test_driver.gd']
FILES += ['tests/unit/test_replay_callbacks.gd', 'tests/unit/test_replay.gd', 'tests/fixtures/replay/golden.json', 'examples/integration/game.gd']
FILES += ['tests/unit/test_diagnostic_player.gd', 'tests/unit/test_replay_viewer.gd',
          'examples/online/replay_viewer.gd', 'examples/online/replay_scene.gd', 'examples/online/replay.tscn', 'examples/offline/simulation.gd']
FILES += ['tests/unit/test_diagnostic_viewer.gd', 'examples/online/diagnostic_viewer.gd',
          'examples/online/diagnostic_scene.gd', 'examples/online/diagnostic.tscn']
FILES += ['tests/unit/test_spectator_session.gd', 'tests/unit/test_driver_callback_results.gd']
FILES += ['tests/unit/test_replay_checkpoints.gd', 'tests/unit/test_spectator_stream.gd']
FILES += ['tests/unit/test_driver_callback_signatures.gd', 'tests/unit/test_driver_script_view_types.gd', 'tests/unit/test_replay_diagnostics.gd']
FILES += ['tests/unit/test_spectator_demo_recording.gd', 'tests/unit/test_spectator_demo.gd', 'examples/spectator/demo.gd',
          'examples/spectator/spectator.gd', 'examples/integration/demo.gd', 'examples/integration/loop.gd', 'examples/integration/effects.gd']
FILES += ['tests/unit/test_spectator_policy.gd', 'tests/unit/test_replay_speed.gd', 'tests/unit/test_spectator_publisher.gd']
FILES += ['tests/unit/test_driver_recovery.gd', 'tests/unit/test_peer_recovery.gd', 'tests/unit/test_peer_replay_capture.gd']
FILES += ['tests/unit/test_replay_coverage.gd']
FILES += ['tests/unit/test_peer_checksum_repair.gd']
FILES += ['tests/unit/test_spectator_model.gd']
FILES += ['tests/unit/test_frame_inputs.gd']
FILES += ['tests/unit/test_input_queue.gd']
FILES += ['tests/unit/test_replay_expert.gd', 'tests/unit/test_spectator_status.gd', 'tests/unit/test_replay_drop.gd']
FILES += ['tests/unit/test_replay_validation.gd', 'tests/unit/test_replay_terminal.gd', 'tests/unit/test_replay_terminal_recovery.gd']
FILES += ['tests/unit/test_replay_expert_navigation.gd', 'tests/unit/test_replay_final_coverage.gd']
FILES += ['tests/unit/test_replay_prefix.gd']
FILES += ['tests/unit/test_peer_drop_inventory.gd', 'tests/unit/test_peer_drop_history.gd',
          'tests/unit/test_peer_drop_barrier.gd', 'tests/unit/test_peer_drop.gd', 'tests/unit/test_peer_drop_multi_slot.gd']
FILES += ['tests/unit/test_history_backfill.gd', 'tests/unit/test_driver_external_parity.gd', 'tests/unit/test_peer_drop_backfill.gd']
FILES += ['tests/unit/test_peer_drop_capacity.gd', 'tests/unit/test_peer_drop_eviction.gd']
FILES += ['tests/unit/test_peer_drop_history_pressure.gd', 'tests/unit/test_peer_drop_donor_fairness.gd']
FILES += ['tests/unit/test_peer_drop_plan_fairness.gd']
FILES += ['tests/unit/test_peer_drop_ready_pressure.gd']
FILES += ['tests/unit/test_driver_input_policy.gd']
FILES += ['tests/unit/test_driver_termination.gd']
FILES += ['tests/unit/test_driver_peer_parity.gd']
FILES += ['tests/unit/test_driver_drop_parity.gd']
FILES += ['tests/unit/test_peer_notifications.gd']
FILES += ['tests/unit/test_replay_configuration.gd']
FILES += ['tests/unit/test_peer_expert.gd', 'tests/unit/test_snapshot_history.gd', 'tests/unit/test_integration_demo.gd']
FILES += ['addons/fortress_rollback/transport/signalfish_adapter.gd', 'addons/fortress_rollback/transport/signalfish_membership.gd',
          'addons/fortress_rollback/transport/signalfish_relay.gd', 'addons/fortress_rollback/transport/signalfish_relay_envelope.gd',
          'addons/fortress_rollback/transport/signalfish_relay_types.gd', 'addons/fortress_rollback/transport/signalfish_spectator_relay.gd',
          'tests/unit/test_signalfish_membership.gd', 'tests/unit/test_signalfish_relay.gd', 'tests/unit/test_signalfish_spectator_relay.gd']
FILES += ['addons/fortress_rollback/transport/signalfish_spectator_host.gd', 'tests/unit/test_signalfish_spectator_host.gd']
FILES = list(dict.fromkeys(FILES))
HOST = '''extends Node
const Scenarios = preload("res://tests/runner/scenario_runner.gd")
const Suite = preload("res://tests/determinism/test_buffer_ownership.gd")
const Integers = preload("res://tests/determinism/test_integer_encoding.gd")
const Protocol = preload("res://tests/unit/test_protocol_codec.gd")
const HandshakeFields = preload("res://tests/unit/test_protocol_handshake_fields.gd")
const Handshake = preload("res://tests/unit/test_handshake.gd")
const Endpoint = preload("res://tests/unit/test_input_endpoint.gd")
const Seams = preload("res://tests/unit/test_session_network_seams.gd")
const Peers = preload("res://tests/unit/test_peer_session.gd")
const Lifecycle = preload("res://tests/unit/test_endpoint_lifecycle.gd")
const PeerLifecycle = preload("res://tests/unit/test_peer_lifecycle.gd")
const DiagnosticTrace = preload("res://tests/unit/test_diagnostic_trace.gd")
const PeerTrace = preload("res://tests/unit/test_peer_diagnostic_trace.gd")
const StalledGossip = preload("res://tests/unit/test_stalled_gossip.gd")
const Replay = preload("res://tests/unit/test_replay.gd")
const ReplayCallbacks = preload("res://tests/unit/test_replay_callbacks.gd")
const DiagnosticPlayer = preload("res://tests/unit/test_diagnostic_player.gd")
const DiagnosticViewer = preload("res://tests/unit/test_diagnostic_viewer.gd")
const ReplayViewer = preload("res://tests/unit/test_replay_viewer.gd")
const Spectator = preload("res://tests/unit/test_spectator_session.gd")
const DriverInputs = preload("res://tests/unit/test_driver.gd")
const ReplayCheckpoints = preload("res://tests/unit/test_replay_checkpoints.gd")
const SpectatorStream = preload("res://tests/unit/test_spectator_stream.gd")
const CallbackResults = preload("res://tests/unit/test_driver_callback_results.gd")
const CallbackSignatures = preload("res://tests/unit/test_driver_callback_signatures.gd")
const ScriptViewTypes = preload("res://tests/unit/test_driver_script_view_types.gd")
const ReplayDiagnostics = preload("res://tests/unit/test_replay_diagnostics.gd")
const SpectatorDemoRecording = preload("res://tests/unit/test_spectator_demo_recording.gd")
const SpectatorDemo = preload("res://tests/unit/test_spectator_demo.gd")
const SpectatorPolicy = preload("res://tests/unit/test_spectator_policy.gd")
const SpectatorPublisher = preload("res://tests/unit/test_spectator_publisher.gd")
const PeerRecovery = preload("res://tests/unit/test_peer_recovery.gd")
const PeerReplayCapture = preload("res://tests/unit/test_peer_replay_capture.gd")
const PeerNotifications = preload("res://tests/unit/test_peer_notifications.gd")
const PeerExpert = preload("res://tests/unit/test_peer_expert.gd")
const DriverRecovery = preload("res://tests/unit/test_driver_recovery.gd")
const ReplaySpeed = preload("res://tests/unit/test_replay_speed.gd")
const ReplayFinalCoverage = preload("res://tests/unit/test_replay_final_coverage.gd")
const IntegrationDemo = preload("res://tests/unit/test_integration_demo.gd")
const SnapshotHistory = preload("res://tests/unit/test_snapshot_history.gd")
const ReplayConfiguration = preload("res://tests/unit/test_replay_configuration.gd")
const ReplayCoverage = preload("res://tests/unit/test_replay_coverage.gd")
const SpectatorModel = preload("res://tests/unit/test_spectator_model.gd")
const FrameInputs = preload("res://tests/unit/test_frame_inputs.gd")
const InputQueue = preload("res://tests/unit/test_input_queue.gd")
const ReplayExpert = preload("res://tests/unit/test_replay_expert.gd")
const ReplayTerminalRecovery = preload("res://tests/unit/test_replay_terminal_recovery.gd")
const ReplayTerminal = preload("res://tests/unit/test_replay_terminal.gd")
const ReplayPrefix = preload("res://tests/unit/test_replay_prefix.gd")
const ReplayValidation = preload("res://tests/unit/test_replay_validation.gd")
const ReplayNavigation = preload("res://tests/unit/test_replay_expert_navigation.gd")
const ReplayDrop = preload("res://tests/unit/test_replay_drop.gd")
const SpectatorStatus = preload("res://tests/unit/test_spectator_status.gd")
const PeerChecksumRepair = preload("res://tests/unit/test_peer_checksum_repair.gd")
const DropInventory = preload("res://tests/unit/test_peer_drop_inventory.gd")
const DropMultiSlot = preload("res://tests/unit/test_peer_drop_multi_slot.gd")
const DropHistory = preload("res://tests/unit/test_peer_drop_history.gd")
const HistoryBackfill = preload("res://tests/unit/test_history_backfill.gd")
const DropCapacity = preload("res://tests/unit/test_peer_drop_capacity.gd")
const DropBackfill = preload("res://tests/unit/test_peer_drop_backfill.gd")
const DropEviction = preload("res://tests/unit/test_peer_drop_eviction.gd")
const DropHistoryPressure = preload("res://tests/unit/test_peer_drop_history_pressure.gd")
const DropDonorFairness = preload("res://tests/unit/test_peer_drop_donor_fairness.gd")
const DropPlanFairness = preload("res://tests/unit/test_peer_drop_plan_fairness.gd")
const DropReadyPressure = preload("res://tests/unit/test_peer_drop_ready_pressure.gd")
const DriverInputPolicy = preload("res://tests/unit/test_driver_input_policy.gd")
const DriverTermination = preload("res://tests/unit/test_driver_termination.gd")
const DriverParity = preload("res://tests/unit/test_driver_external_parity.gd")
const DriverPeerParity = preload("res://tests/unit/test_driver_peer_parity.gd")
const DriverDropParity = preload("res://tests/unit/test_driver_drop_parity.gd")
const SpectatorRelay = preload("res://tests/unit/test_signalfish_spectator_relay.gd")
const SpectatorHost = preload("res://tests/unit/test_signalfish_spectator_host.gd")
func _ready() -> void:
\tvar scripts: Array[Script] = [Suite, Integers, Protocol, HandshakeFields, Handshake, Endpoint, Seams, Peers, Lifecycle, PeerLifecycle, StalledGossip, DiagnosticTrace,
\t\tPeerTrace, Replay, ReplayCallbacks, DiagnosticPlayer, DiagnosticViewer, ReplayViewer, Spectator, CallbackResults, DriverInputs,
\t\tReplayTerminalRecovery, ReplayTerminal, ReplayCheckpoints, SpectatorStream, CallbackSignatures, ScriptViewTypes,
\t\tReplayDiagnostics, SpectatorDemo, SpectatorDemoRecording, SpectatorPolicy, SpectatorPublisher, ReplaySpeed,
		DriverRecovery, PeerRecovery, PeerReplayCapture, PeerNotifications, ReplayFinalCoverage, ReplayCoverage, SpectatorModel, FrameInputs, InputQueue,
		ReplayExpert, ReplayDrop, ReplayConfiguration, PeerExpert, SnapshotHistory, IntegrationDemo, ReplayPrefix,
		PeerChecksumRepair, SpectatorStatus, DropInventory, DropHistory, DropMultiSlot,
		HistoryBackfill, DriverParity, DriverPeerParity, DriverDropParity, DropBackfill, DropCapacity, DropEviction, DropHistoryPressure, DropDonorFairness,
		DropPlanFairness, DropReadyPressure,
		DriverInputPolicy, DriverTermination, SpectatorRelay, SpectatorHost, ReplayValidation, ReplayNavigation]
\tscripts.sort_custom(func(first: Script, second: Script) -> bool: return first.resource_path < second.resource_path)
\t# The launcher sends a bounded set of suites in URL parameters.
\t# JSON decoding is a dynamic boundary; reject unknown or repeated paths.
\tvar requested: Variant = JSON.parse_string(str(JavaScriptBridge.eval("JSON.stringify(new URLSearchParams(location.search).getAll('suite'))")))
\tvar selected: Array[Script] = []
\tvar seen: Dictionary = {}
\tvar valid: bool = requested is Array and not requested.is_empty()
\tif requested is Array:
\t\tfor resource: Variant in requested:
\t\t\tif not resource is String or seen.has(resource):
\t\t\t\tvalid = false
\t\t\t\tcontinue
\t\t\tseen[resource] = true
\t\t\tvar found: bool = false
\t\t\tfor candidate: Script in scripts:
\t\t\t\tif candidate.resource_path == resource:
\t\t\t\t\tfound = true
\t\t\tvalid = valid and found
\tfor candidate: Script in scripts:
\t\tif seen.has(candidate.resource_path):
\t\t\tselected.append(candidate)
\tvar requested_cases: Variant = JSON.parse_string(str(JavaScriptBridge.eval("JSON.stringify(new URLSearchParams(location.search).getAll('case'))")))
\tvar case_names: PackedStringArray = []
\tvalid = valid and requested_cases is Array
\tif requested_cases is Array and not requested_cases.is_empty():
\t\tvalid = valid and requested_cases.size() == 1 and selected.size() == 1
\t\tif valid:
\t\t\tvar inventory: Variant = selected[0].new().cases()
\t\t\tvalid = inventory is PackedStringArray and requested_cases[0] is String and requested_cases[0] in inventory
\t\t\tif valid:
\t\t\t\tcase_names.append(requested_cases[0])
\tif not valid:
\t\tJavaScriptBridge.eval("document.body.dataset.fortressOwnership = " + JSON.stringify(JSON.stringify({"complete": false})))
\t\treturn
\tvar result: Dictionary = Scenarios.new().execute(selected, "determinism", "", 1701, case_names, _publish_progress, _clock)
\tvar text: String = JSON.stringify(result)
\tJavaScriptBridge.eval("document.body.dataset.fortressOwnership = " + JSON.stringify(text))
\n\n## A rejected run must name the case that was executing and the time the last
## completed case took, so a slow run can be told apart from an engine or
## script failure.
func _publish_progress(value: Dictionary) -> void:
\tvar progress: Dictionary = value.duplicate()
\tprogress["unit"] = "us"
\tvar text: String = JSON.stringify(progress)
\tJavaScriptBridge.eval("document.body.dataset.fortressOwnershipProgress = " + JSON.stringify(text))

\n\n## The browser host injects the real host clock, so the reported elapsed times
## are the time each case actually took.
func _clock() -> int:
\treturn Time.get_ticks_usec()
'''


def same_json(first, second):
    """Compare every JSON value without Python's bool/int/float aliases."""
    if type(first) is not type(second):
        return False
    if isinstance(first, dict):
        return first.keys() == second.keys() and all(same_json(first[key], second[key]) for key in first)
    if isinstance(first, list):
        return len(first) == len(second) and all(same_json(left, right) for left, right in zip(first, second))
    return first == second


def validate_browser(browser, identity, selected='chromium', pins=None):
    """Do not discard an earlier batch's errors or browser identity."""
    fields = {'browser', 'version', 'result', 'errors'}
    if selected == 'firefox':
        fields |= {'firefox_preferences', 'display'}
    if not isinstance(browser, dict) or set(browser) != fields:
        raise ValueError('incorrect browser result fields')
    if selected not in ('chromium', 'firefox') or browser['browser'] != selected.title() or type(browser['version']) is not str or not browser['version']:
        raise ValueError('incorrect browser identity')
    if pins is not None and browser['version'] != pins['browser'][selected + '_version']:
        raise ValueError('browser version differs from selected pin')
    if selected == 'firefox':
        if not same_json(browser['firefox_preferences'], {'webgl.force-enabled': True, 'webgl.disabled': False,
                                                        'toolkit.shutdown.fastShutdownStage': 0}):
            raise ValueError('Firefox preferences differ from qualification')
        display = browser['display']
        if (not isinstance(display, dict) or set(display) != {'x', 'y', 'width', 'height', 'screen_width', 'screen_height'}
                or any(type(value) is not int for value in display.values()) or display['x'] != 0 or display['y'] != 0
                or any(not 1 <= display[key] <= 32768 for key in ('width', 'height', 'screen_width', 'screen_height'))
                or display['width'] < 81):
            raise ValueError('Firefox owned window visibility is invalid')
    if type(browser['errors']) is not list or browser['errors']:
        raise ValueError('browser reported errors')
    observed = (browser['browser'], browser['version'])
    if identity is not None and observed != identity:
        raise ValueError('browser identity changed between batches')
    return observed


def validate(result, negative, expected=None):
    expected = EXPECTED if expected is None else expected
    expected_count = sum(len(cases) for cases in expected.values())
    required = {'format', 'complete', 'count', 'errors', 'passed', 'records'}
    if not isinstance(result, dict) or set(result) != required:
        raise ValueError('incorrect result fields')
    if type(result['format']) is not int or type(result['count']) is not int or type(result['passed']) is not bool:
        raise ValueError('incorrect result scalar types')
    if not isinstance(result['errors'], list) or not isinstance(result['records'], list):
        raise ValueError('incorrect result collection types')
    for record in result['records']:
        fields = {'suite', 'case', 'category', 'seed', 'runs'}
        if not isinstance(record, dict) or set(record) != fields:
            raise ValueError('missing record fields')
        if any(not isinstance(record[key], str) for key in ('suite', 'case', 'category', 'seed')):
            raise ValueError('incorrect record scalar types')
        if not isinstance(record['runs'], list):
            raise ValueError('incorrect repetition collection type')
        for repetition in record['runs']:
            fields = {'assertions', 'states', 'failures'}
            if not isinstance(repetition, dict) or set(repetition) != fields:
                raise ValueError('missing repetition fields')
            if type(repetition['assertions']) is not int or repetition['assertions'] < 1:
                raise ValueError('incorrect assertion count')
            if any(not isinstance(repetition[key], list) for key in ('states', 'failures')):
                raise ValueError('incorrect repetition collection types')
            if any(not isinstance(item, dict) for key in ('states', 'failures') for item in repetition[key]):
                raise ValueError('incorrect diagnostic/state record types')
            for state in repetition['states']:
                if set(state) != {'frame', 'bytes'} or type(state['frame']) is not int or type(state['bytes']) is not str:
                    raise ValueError('incorrect state record schema')
    if result.get('format') != 1 or result.get('complete') is not True or result.get('count') != expected_count:
        raise ValueError('missing/incomplete ownership result')
    observed = {(record['suite'], record['case']) for record in result['records']}
    expected = {(suite, case) for suite, cases in expected.items() for case in cases}
    if result.get('errors') or observed != expected:
        raise ValueError('wrong inventory or repeat divergence')
    if len(result['records']) != expected_count or result['passed'] != (not negative):
        raise ValueError('unexpected ownership verdict')
    failures = []
    for record in result['records']:
        if record['seed'] != '1701' or record['category'] != 'determinism' or len(record['runs']) != 2:
            raise ValueError('incorrect seed, category or repetition accounting')
        if not same_json(record['runs'][0], record['runs'][1]):
            raise ValueError('repeat divergence')
        for repetition in record['runs']:
            if repetition['assertions'] < 1:
                raise ValueError('unasserted case')
            if repetition['failures'] and (record['suite'], record['case']) != ('res://tests/determinism/test_buffer_ownership.gd', 'owned_input'):
                raise ValueError('failure outside the intended alias control')
            failures.extend(repetition['failures'])
    expected_labels = ['copied submission survives caller mutation', 'callback copy cannot edit history']
    if negative:
        expected_failures = [
            {'kind': 'bytes', 'label': label, 'frame': 0, 'byte': 0, 'expected': '0100', 'actual': '0909'}
            for label in expected_labels for _ in range(2)
        ]
        if not same_json(sorted(failures, key=lambda f: f.get('label', '')), sorted(expected_failures, key=lambda f: f['label'])):
            raise ValueError('negative control failed for unexpected reason')
    elif failures:
        raise ValueError('ownership assertions failed')
    return result


def negative_suite(suite, negative):
    """Only the mutated ownership suite is expected to fail in a negative round."""
    return negative and suite == 'res://tests/determinism/test_buffer_ownership.gd'


def select_suites(part):
    """Split suite work while retaining the alias control in every part."""
    if type(part) is not str or part not in ('all', '1', '2'):
        raise ValueError('invalid ownership suite part')
    ordered = sorted(EXPECTED)
    selected = ordered if part == 'all' else ordered[int(part) - 1::2]
    control = 'res://tests/determinism/test_buffer_ownership.gd'
    return {suite: EXPECTED[suite] for suite in ordered if suite in selected or suite == control}


def aggregate_native(batches, negative, expected=None):
    """Require every complete batch, retaining the browser's suite/case order."""
    expected = EXPECTED if expected is None else expected
    batches = [([suites] if isinstance(suites, str) else suites, result) for suites, result in batches]
    if [suite for suites, result in batches for suite in suites] != sorted(expected):
        raise ValueError('missing, duplicate or unordered suite batches')
    records = []
    for suites, result in batches:
        subset = {suite: expected[suite] for suite in suites}
        validate(result, any(negative_suite(suite, negative) for suite in suites), subset)
        records.extend(result['records'])
    return validate({'format': 1, 'complete': True, 'count': len(records), 'passed': not negative,
                     'errors': [], 'records': records}, negative, expected)


def aggregate_case_pages(suite, pages, native):
    """Retain native case order and every record when a slow suite needs separate pages."""
    expected = {suite: EXPECTED[suite]}
    validate(native, False, expected)
    names = [record['case'] for record in native['records']]
    if len(pages) != len(names):
        raise ValueError('missing or duplicate ownership case pages')
    records = []
    for name, page in zip(names, pages):
        validate(page, False, {suite: {name}})
        records.extend(page['records'])
    result = validate({'format': 1, 'complete': True, 'count': len(records), 'passed': True, 'errors': [], 'records': records}, False, expected)
    if not same_json(result, native):
        raise ValueError('native/web ownership case divergence')
    return result


def validate_coverage(records, part, suites):
    """A partial receipt must describe exactly the canonical requested suite part."""
    expected = select_suites(part)
    if type(suites) is not dict or list(suites) != sorted(expected) or not same_json(suites, {suite: sorted(cases) for suite, cases in expected.items()}):
        raise ValueError('incorrect declared ownership suite inventory')
    if type(records) is not list or not records:
        raise ValueError('missing ownership coverage records')
    for record in records:
        negative = record.get('negative_control')
        if type(negative) is not bool:
            raise ValueError('incorrect ownership control type')
        validate(record['native'], negative, expected)
        if 'browser' in record:
            validate(record['browser']['result'], negative, expected)
            if not same_json(record['native'], record['browser']['result']):
                raise ValueError('native/web ownership divergence')


def last_progress(output):
    """Return the last progress record, so an interrupted run names its case."""
    record = None
    for line in output.splitlines():
        if not line.startswith(PROGRESS_PREFIX):
            continue
        try:
            value = json.loads(line[len(PROGRESS_PREFIX):])
        except ValueError:
            continue
        if isinstance(value, dict):
            record = value
    return record


def bounded_progress(record, stage):
    """Reduce a progress record to the few fields a reader needs."""
    if not isinstance(record, dict):
        return None
    executing = record.get('executing')
    last = record.get('last_completed')
    executing = executing if isinstance(executing, dict) else {}
    last = last if isinstance(last, dict) else {}
    return {'stage': stage, 'completed': record.get('completed'), 'suite': executing.get('suite'),
            'case': executing.get('case'), 'last_case': last.get('case'), 'elapsed': last.get('elapsed'),
            'unit': record.get('unit')}


def bounded_errors(errors):
    """Keep a fixed number of error strings, each one truncated."""
    if not isinstance(errors, list):
        return []
    return [str(error)[:MAX_ERROR_LENGTH] for error in errors[:MAX_RETAINED_ERRORS]]


def failure_lines(output):
    """Return the engine, script or tool failure lines of a run."""
    markers = ('SCRIPT ERROR:', 'TOOL_FAILURE:', 'TIMEOUT:')
    lines = [line for line in output.splitlines()
             if any(marker in line for marker in markers) or line.startswith('ERROR:')]
    return bounded_errors(lines)


def watchdog_detail(text):
    """Return the last watchdog detail the browser runner printed."""
    detail = None
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and value.get('stage') == 'ownership-result':
            detail = value
    return detail


def detail_errors(detail):
    """Return the browser and engine errors the rejected page reported."""
    if not isinstance(detail, dict):
        return []
    errors = list(detail.get('errors') or [])
    for key in ('page_error', 'progress_error'):
        if detail.get(key):
            errors.append(str(detail[key]))
    return bounded_errors(errors)


def detail_alive(detail):
    """Report whether the page was still readable when the watchdog fired."""
    if not isinstance(detail, dict):
        return False
    if detail.get('page_error') or detail.get('progress_error'):
        return False
    return detail.get('reported') is not None or isinstance(detail.get('progress'), dict)


def rejected_state(progress):
    """Name the state of a run that a deadline rejected."""
    return 'progressing' if progress and progress.get('case') else 'watchdog'


def source_inventory():
    helpers = ['scripts/reference/ownership_probes.py', 'scripts/reference/browser/ownership.cjs',
               'scripts/reference/fetch.py', 'scripts/reference/run.py', 'scripts/reference/godot_smoke.py', 'scripts/reference/receipt_arguments.py',
               'scripts/reference/local_ownership.py', 'scripts/reference/browser/webrtc_matrix.py',
               'scripts/reference/browser/webrtc_import.py', 'scripts/reference/signalfish_probe.py',
               'scripts/reference/browser/webrtc_display.cjs', 'scripts/reference/browser/package.json',
               'scripts/reference/browser/package-lock.json', 'docs/reference/pins.json', 'project.godot']
    return {filename: digest(ROOT / filename) for filename in FILES + helpers}


def verify_sources(expected):
    for filename, checksum in expected.items():
        path = ROOT / filename
        if not path.is_file() or digest(path) != checksum:
            raise ValueError(f'ownership source changed during execution: {filename}')


def staged_paths(project):
    """Include every staged input while leaving the engine's mutable cache outside evidence."""
    return {path.name: path for path in project.iterdir() if path.name != '.godot'}


def verify_staged(project, expected):
    if inventory(staged_paths(project)) != expected:
        raise ValueError('ownership staged project changed during execution')


def verify_tools(paths, expected):
    if tool_inventory(paths) != expected:
        raise ValueError('ownership runtime inputs changed during execution')


def verify_browser_inputs(paths, frozen, export, exported_sources):
    verify_tools(paths, frozen)
    verify_tools({'export': export}, exported_sources)


def tool_inventory(paths):
    """Hash every selected runtime file, rejecting missing inputs and symlinks."""
    result = {}
    for name, path in paths.items():
        if not path.exists() or path.is_symlink():
            raise ValueError(f'ownership runtime input missing or symlinked: {name}')
        for source in sorted(path.rglob('*')) if path.is_dir() else [path]:
            key = name + '/' + str(source.relative_to(path)) if path.is_dir() else name
            if source.is_symlink():
                raise ValueError(f'ownership runtime input is symlinked: {key}')
            if source.is_file():
                result[key] = digest(source)
    return result


def prepare_browser(data, arch, offline, environment, selected):
    """Own an installation independently of the transport witness's Firefox."""
    paths = {}
    if selected == 'firefox':
        prepare_firefox(data, arch, offline, paths, environment, installation=CACHE / 'ownership-firefox' / arch)
        artifact = f"firefox-{data['browser']['firefox_revision']}-ubuntu24.04-{arch}.zip"
        executable = paths['firefox_executable']
    else:
        artifact = f"chromium-{data['browser']['chromium_revision']}-{arch}.zip"
        archive = fetch(data['artifacts'][artifact], artifact, offline)
        installation = CACHE / 'ownership-chromium' / arch
        if installation.exists():
            shutil.rmtree(installation)
        installation.mkdir(parents=True)
        prepare_zip(archive, installation, executable_members=('chrome-linux/chrome',))
        executable = installation / 'chrome-linux/chrome'
        paths.update(browser_archive=archive, browser_installation=installation, browser_executable=executable)
        environment['FORTRESS_CHROMIUM_EXECUTABLE'] = str(executable)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError('selected ownership browser executable is unavailable')
    package = CACHE / 'browser/node_modules'
    registry = package / 'playwright-core/browsers.json'
    if digest(registry) != data['browser']['browser_registry_sha256']:
        raise ValueError('browser registry differs from pin')
    node = shutil.which('node')
    if node is None:
        raise ValueError('ownership browser requires node')
    # Node imports these packages directly; npm's unused .bin command links are not executed.
    paths.update({name: package / relative for name, relative in (
        ('playwright_test', '@playwright/test'), ('playwright', 'playwright'), ('playwright_core', 'playwright-core'))})
    paths['node'] = Path(node).resolve()
    environment['FORTRESS_PLAYWRIGHT_PACKAGE'] = str(package / '@playwright/test')
    environment['FORTRESS_OWNERSHIP_BROWSER'] = selected
    return artifact, paths


def validate_phases(records, rounds, versions, phases=None):
    """Require every requested phase, without granting unrequested qualification."""
    phases = ['negative', 'positive'] if phases is None else phases
    if type(phases) is not list or any(type(phase) is not str for phase in phases) or phases not in (
            ['negative'], ['positive'], ['negative', 'positive']):
        raise ValueError('invalid requested ownership phases')
    expected = [[version, phase == 'negative'] for version in versions for phase in phases]
    observed = [[record.get('engine_version'), record.get('negative_control')] for record in records]
    labels = [version + ('-negative' if negative else '-positive') for version, negative in expected]
    if not same_json(observed, expected) or [entry.get('label') for entry in rounds] != labels:
        raise ValueError('missing or unexpected ownership phase')
    if any(entry.get('outcome') != 'passed' for entry in rounds):
        raise ValueError('incomplete ownership phase')


def main():
    parser = ReceiptParser(description=__doc__, receipt='ownership.json', output=CACHE / 'results')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--web', action='store_true')
    parser.add_argument('--browser', choices=['chromium', 'firefox'], default='chromium')
    parser.add_argument('--phase', choices=['both', 'negative', 'positive'], default='both')
    parser.add_argument('--suite-part', choices=['all', '1', '2'], default='all')
    pins = load_manifest()['godot']
    parser.add_argument('--version', choices=list(dict.fromkeys([pins['minimum'], pins['current_stable']])))
    args = parser.parse_args()
    if args.browser != 'chromium' and not args.web:
        parser.error('--browser firefox requires --web')
    results = CACHE / 'results'
    # One local run at a time owns these paths, and the browser part needs a
    # responsive host: a local test wave would otherwise starve it and turn a
    # slow run into a timeout.
    if not host_capacity.acquire_when_free('ownership-witness', 900.0):
        raise ValueError('the development host stayed busy; the ownership witness needs a responsive host')
    with claim('ownership', directory=CACHE / 'locks'):
        return run_probes(args, results)


def run_probes(args, results):
    begin_results(results, 'ownership.json', [p.name for p in results.glob('ownership-*.log')] + ['ownership-rounds.json'])
    # Bounded per-round observations. A watchdog rejects the run before it
    # can print its own inventory, so the round that was executing is
    # written down as it starts and stays on disk when the run fails. A
    # rejected round also keeps the progress of its last case, the errors
    # the engine or the browser reported and the state the rejection found.
    rounds = []
    rounds_path = results / 'ownership-rounds.json'

    def write_rounds():
        rounds_path.write_text(json.dumps(rounds, indent=2) + '\n')

    def observe(label):
        rounds.append({'label': label, 'outcome': 'running', 'started': time.time(), 'seconds': None,
                       'alive': None, 'native_progress': None, 'browser_progress': None, 'errors': []})
        write_rounds()
        return time.monotonic()

    def update(**fields):
        rounds[-1].update(fields)
        write_rounds()

    def finish(started):
        update(outcome='passed', seconds=round(time.monotonic() - started, 3))

    def reject(started, state, **fields):
        """Keep why the round ended before the failure is raised again."""
        update(outcome=state, seconds=round(time.monotonic() - started, 3), **fields)

    frozen_sources = source_inventory()
    data = load_manifest()
    arch = {'aarch64': 'arm64', 'x86_64': 'x86_64'}.get(platform.machine())
    if platform.system() != 'Linux' or arch is None:
        raise ValueError('ownership tool bootstrap supports Linux arm64/x86_64')
    environment = os.environ.copy()
    environment['XDG_DATA_HOME'] = str(CACHE / 'godot-data')
    browser_paths = {}
    browser_frozen = {}
    browser_artifact = None
    if args.web:
        browser_artifact, browser_paths = prepare_browser(data, arch, args.offline, environment, args.browser)
        browser_frozen = tool_inventory(browser_paths)
    records = []
    versions_requested = [args.version] if args.version is not None else [data['godot']['minimum'], data['godot']['current_stable']]
    phases_requested = ['negative', 'positive'] if args.phase == 'both' else [args.phase]
    selected = select_suites(args.suite_part)
    suites_requested = {suite: sorted(cases) for suite, cases in selected.items()}
    if any(version not in (data['godot']['minimum'], data['godot']['current_stable']) for version in versions_requested):
        raise ValueError('requested ownership engine is not pinned')
    for version in versions_requested:
        name = f'Godot_v{version}-stable_linux.{arch}.zip'
        archive = fetch(data['artifacts'][name], name, args.offline)
        editor_dir = CACHE / 'ownership-editors' / version
        editor_dir.mkdir(parents=True, exist_ok=True)
        prepare_zip(archive, editor_dir, executable_members=(name[:-4],))
        editor = editor_dir / name[:-4]
        editor.chmod(0o755)
        editor_paths = {'editor': editor}
        editor_frozen = tool_inventory(editor_paths)
        verify_tools(editor_paths, editor_frozen)
        actual = run([str(editor), '--version'], environment, results / f'ownership-{version}-version.log').strip()
        verify_tools(editor_paths, editor_frozen)
        if not actual.startswith(version + '.stable.'):
            raise ValueError('incorrect editor version')
        for phase in phases_requested:
            negative = phase == 'negative'
            label = f'{version}-' + ('negative' if negative else 'positive')
            started = observe(label)
            project = CACHE / 'ownership-projects' / label
            if project.exists():
                shutil.rmtree(project)
            project.mkdir(parents=True)
            for filename in FILES:
                target = project / filename
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / filename, target)
                if digest(target) != frozen_sources[filename]:
                    raise ValueError(f'ownership copied source changed before execution: {filename}')
            # Godot exports exclude hidden .llm directories: relocate identical
            # sample bytes and adapt only the preload resource path in both hosts.
            checksum_source = '.llm/code-samples/state_checksum.gd'
            checksum_target = 'tests/determinism/reference_checksum.gd'
            shutil.copyfile(project / checksum_source, project / checksum_target)
            if digest(project / checksum_target) != frozen_sources[checksum_source]:
                raise ValueError(f'ownership copied source changed before execution: {checksum_target}')
            integers_source = 'tests/determinism/test_integer_encoding.gd'
            integers = project / integers_source
            if digest(integers) != frozen_sources[integers_source]:
                raise ValueError(f'ownership copied source changed before adaptation: {integers_source}')
            preload = ('res://' + checksum_source).encode('utf-8')
            original_integers = integers.read_bytes()
            if original_integers.count(preload) != 1:
                raise ValueError('checksum preload adaptation no longer applicable')
            adapted_integers = original_integers.replace(preload, ('res://' + checksum_target).encode('utf-8'))
            integers.write_bytes(adapted_integers)
            if integers.read_bytes() != adapted_integers:
                raise ValueError(f'ownership copied source changed after adaptation: {integers_source}')
            if negative:
                suite = project / 'tests/determinism/test_buffer_ownership.gd'
                text = suite.read_text()
                before = 'var history: PackedByteArray = caller.duplicate()'
                if text.count(before) != 1:
                    raise ValueError('negative control mutation no longer applicable')
                suite.write_text(text.replace(before, 'var history: PackedByteArray = caller'))
            # Replays record the addon version, which tests compare with the project setting.
            versions = [line for line in (ROOT / 'project.godot').read_text().splitlines() if line.startswith('config/version=')]
            if len(versions) != 1:
                raise ValueError('project version line missing or duplicated')
            (project / 'project.godot').write_text(
                f'config_version=5\n[application]\nconfig/name="Ownership probes"\n{versions[0]}\nrun/main_scene="res://main.tscn"\n'
                '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
            (project / 'host.gd').write_text(HOST)
            (project / 'main.tscn').write_text(
                '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://host.gd" id="1"]\n'
                '[node name="Ownership" type="Node"]\nscript = ExtResource("1")\n')
            if args.web:
                (project / 'export_presets.cfg').write_text(
                    '[preset.0]\nname="Web"\nplatform="Web"\nrunnable=true\nexport_filter="all_resources"\ninclude_filter="*.json"\nexclude_filter=""\n'
                    '[preset.0.options]\nvariant/extensions_support=false\nvariant/thread_support=false\n')
            staged_before = inventory(staged_paths(project))
            base = [str(editor), '--headless', '--path', str(project)]
            verify_tools(editor_paths, editor_frozen)
            run(base + ['--editor', '--quit'], environment, results / f'ownership-{label}-import.log')
            verify_tools(editor_paths, editor_frozen)
            staged_frozen = freeze_after_import(staged_paths(project), staged_before)
            # Each suite retains both in-process repetitions and its own 180s
            # watchdog. A growing inventory must not merge bounded suites into
            # one process that exceeds their shared deadline.
            batches = []
            for suite in sorted(selected):
                native_log = results / f'ownership-{label}-native-{Path(suite).stem}.log'
                try:
                    verify_staged(project, staged_frozen)
                    verify_tools(editor_paths, editor_frozen)
                    code, output = capture(base + ['--script', 'tests/runner/run_tests.gd', '--', '--category', 'determinism']
                                           + ['--suite', suite],
                                           environment, native_log, timeout=180)
                except subprocess.TimeoutExpired as error:
                    # The native deadline rejected the run. Its progress record
                    # names the case that was executing when the deadline fired.
                    output = captured_text(error.output) + captured_text(error.stderr)
                    progress = bounded_progress(last_progress(output), 'native')
                    reject(started, rejected_state(progress), native_progress=progress, alive=False,
                           errors=failure_lines(output))
                    raise
                except Exception:
                    # The engine never ran: the tool failed before it produced output.
                    reject(started, 'failed', alive=False,
                           errors=failure_lines(native_log.read_text(encoding='utf-8', errors='replace')
                                                if native_log.exists() else ''))
                    raise
                progress = bounded_progress(last_progress(output), 'native')
                update(native_progress=progress)
                try:
                    verify_staged(project, staged_frozen)
                    verify_tools(editor_paths, editor_frozen)
                    if code != (1 if negative_suite(suite, negative) else 0) or 'SCRIPT ERROR:' in output or any(s.startswith('ERROR:') for s in output.splitlines()):
                        raise ValueError('native command failed outside the intended control')
                    markers = [line[len(PREFIX):] for line in output.splitlines() if line.startswith(PREFIX)]
                    if len(markers) != 1:
                        raise ValueError('missing/duplicate native report')
                    batch = validate(json.loads(markers[0]), negative_suite(suite, negative), {suite: EXPECTED[suite]})
                    batches.append((suite, batch))
                except Exception:
                    reject(started, 'failed', alive=False, errors=failure_lines(output))
                    raise
            native = aggregate_native(batches, negative, selected)
            record = {'engine_version': version, 'version': actual, 'editor_artifact': name, 'negative_control': negative, 'native': native,
                      'staged_inventory': staged_frozen, 'editor_inventory': editor_frozen}
            if args.web:
                template_name = f'Godot_v{version}-stable_export_templates.tpz'
                templates = fetch(data['artifacts'][template_name], template_name, args.offline)
                template_dir = Path(environment['XDG_DATA_HOME']) / 'godot/export_templates' / (version + '.stable')
                template_dir.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(templates) as package:
                    for member in package.namelist():
                        if Path(member).name.startswith('web_'):
                            (template_dir / Path(member).name).write_bytes(package.read(member))
                export_paths = {**editor_paths, 'web_templates': template_dir}
                export_frozen = {**editor_frozen, **tool_inventory({'web_templates': template_dir})}
                export = CACHE / 'ownership-exports' / label
                export.mkdir(parents=True, exist_ok=True)
                verify_staged(project, staged_frozen)
                verify_tools(export_paths, export_frozen)
                run(base + ['--export-release', 'Web', str(export / 'index.html')], environment, results / f'ownership-{label}-export.log')
                verify_tools(export_paths, export_frozen)
                verify_staged(project, staged_frozen)
                exported_sources = tool_inventory({'export': export})
                browser_batches = []
                browser_identity = None
                ordered_suites = sorted(selected)
                batch_size = 1 if args.browser == 'firefox' else 4
                for batch_index, offset in enumerate(range(0, len(ordered_suites), batch_size)):
                    suites = ordered_suites[offset:offset + batch_size]
                    case_names = [None]
                    native_suite = None
                    if args.browser == 'firefox' and suites == ['res://tests/unit/test_driver_peer_parity.gd']:
                        suite_records = [record for record in native['records'] if record['suite'] == suites[0]]
                        native_suite = {**native, 'passed': True, 'count': len(suite_records), 'records': suite_records}
                        case_names = [record['case'] for record in suite_records]
                    pages = []
                    for case_index, case_name in enumerate(case_names):
                        suffix = '' if case_name is None else f'-case-{case_index:02d}'
                        browser_log = results / f'ownership-{label}-browser-{batch_index:02d}{suffix}.log'
                        try:
                            verify_staged(project, staged_frozen)
                            verify_browser_inputs(browser_paths, browser_frozen, export, exported_sources)
                            verify_sources(frozen_sources)
                            output = run([str(browser_paths['node']), str(ROOT / 'scripts/reference/browser/ownership.cjs'),
                                          str(export), json.dumps(suites)] + ([] if case_name is None else [case_name]),
                                          environment, browser_log, timeout=240)
                            verify_sources(frozen_sources)
                            verify_staged(project, staged_frozen)
                            verify_browser_inputs(browser_paths, browser_frozen, export, exported_sources)
                            browser = json.loads(output)
                            browser_identity = validate_browser(browser, browser_identity, args.browser, data)
                            validate(browser['result'], any(negative_suite(suite, negative) for suite in suites),
                                     {suite: EXPECTED[suite] if case_name is None else {case_name} for suite in suites})
                            pages.append(browser['result'])
                        except Exception:
                            # The browser watchdog rejected the run. Its inventory of
                            # page and engine errors, and the progress the page
                            # published, are in the log and not in the raised error,
                            # so they are read back before the failure is raised again.
                            text = browser_log.read_text(encoding='utf-8', errors='replace') if browser_log.exists() else ''
                            detail = watchdog_detail(text)
                            if detail is None:
                                reject(started, 'failed', alive=False, errors=bounded_errors(text.splitlines()[-4:]))
                                raise
                            browser_progress = bounded_progress(detail.get('progress'), 'browser')
                            reject(started, rejected_state(browser_progress), browser_progress=browser_progress,
                                   alive=detail_alive(detail), errors=detail_errors(detail))
                            raise
                    if native_suite is not None:
                        try:
                            browser['result'] = aggregate_case_pages(suites[0], pages, native_suite)
                        except ValueError:
                            reject(started, 'failed', alive=False, errors=['incomplete or divergent ownership case pages'])
                            raise
                    browser_batches.append((suites, browser['result']))
                browser['result'] = aggregate_native(browser_batches, negative, selected)
                if not same_json(browser['result'], native):
                    reject(started, 'failed', alive=False, errors=['native/web ownership divergence'])
                    raise ValueError('native/web ownership divergence')
                record.update(browser=browser, browser_artifact=browser_artifact, template_artifact=template_name,
                              export_inventory=exported_sources, export_tool_inventory=export_frozen)
            verify_staged(project, staged_frozen)
            records.append(record)
            finish(started)
            print(f'Ownership {label}: native' + (' and Web' if args.web else '') + ' verified')
    validate_phases(records, rounds, versions_requested, phases_requested)
    validate_coverage(records, args.suite_part, suites_requested)
    verify_sources(frozen_sources)
    if tool_inventory(browser_paths) != browser_frozen:
        raise ValueError('ownership browser runtime changed during execution')
    report = {'status': 'passed', 'web_requested': args.web, 'architecture': arch, 'seed': '1701',
              'browser_requested': args.browser if args.web else None, 'browser_runtime_inventory': browser_frozen,
              'rounds': rounds, 'versions_requested': versions_requested, 'phases_requested': phases_requested,
              'suite_part_requested': args.suite_part, 'suites_requested': suites_requested,
              'manifest_sha256': frozen_sources['docs/reference/pins.json'],
              'sources': frozen_sources,
              'records': records, 'scope': 'For requested engine pins, phases and suite inventory only: '
              'Integer/ownership, byte handshakes, input recovery, 2–8-player gameplay and replay playback; '
              'no real transport, performance or unselected-browser/platform claim.'}
    (results / 'ownership.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
