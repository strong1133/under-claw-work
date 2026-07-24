// Headless Core surface.
//
// Keep Flutter/plugin-backed services out of this barrel so `dart build cli`
// remains valid on machines without a Flutter engine.
export 'agent_registry_service.dart';
export 'auto_meta_worker.dart';
export 'auth.dart';
export 'canonical_repository.dart';
export 'canonical_secret_verifier.dart';
export 'canonical_sync_service.dart';
export 'claim_service.dart';
export 'control_service.dart';
export 'context_builder.dart';
export 'entity_service.dart';
export 'environment_service.dart';
export 'execution_worker.dart';
export 'git_remote_claim_service.dart';
export 'git_sync_service.dart';
export 'host_discovery.dart';
export 'hermes_meta_prompt_adapter.dart';
export 'id.dart';
export 'installed_runtime_registry.dart';
export 'legacy_migration.dart';
export 'match_service.dart';
export 'memory_recall_service.dart';
export 'meta_prompt_service.dart';
export 'models.dart';
export 'notification_service.dart';
export 'process_runner_adapter.dart';
export 'projection.dart';
export 'projection_lifecycle.dart';
export 'release_update_service.dart';
export 'relation_registry.dart';
export 'schema_validator.dart';
export 'setup_service.dart';
export 'skill_pipeline.dart';
export 'task_candidate_service.dart';
export 'task_codec.dart';
export 'task_repository.dart';
export 'workspace.dart';
