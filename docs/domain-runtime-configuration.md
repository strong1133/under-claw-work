# Domain-scoped runtime configuration

Under Claw Work owns Domain/Milestone routing. `under-claw-jarvis-plan` remains an unchanged collection of explicitly invoked skills.

## Boundary

- Git-canonical: Domain, Milestone, Project, logical Repository, Persona, Agent Group, Channel Binding, MCP Binding, Skill Policy.
- Host-local (`.worklog/host-bindings.json`): absolute repository paths, Hermes profile names, MCP commands, and secure-store account keys.
- Never store tokens, passwords, API keys, authorization headers, `.env` content, or local paths in canonical entities.

## Canonical configuration

Create a JSON descriptor and pass it to:

```text
worklog scope-config-create <workspace> repository <descriptor.json>
worklog scope-config-create <workspace> project <descriptor.json>
worklog scope-config-create <workspace> persona <descriptor.json>
worklog scope-config-create <workspace> agent_group <descriptor.json>
worklog scope-config-create <workspace> channel_binding <descriptor.json>
worklog scope-config-create <workspace> mcp_binding <descriptor.json>
worklog scope-config-create <workspace> skill_policy <descriptor.json>
```

A Skill Policy refers to installed skill IDs. It does not make the skill repository a Project or Milestone.

```json
{
  "title": "Governed planning",
  "domain_id": "DOM-example",
  "ordered_skill_ids": [
    "under-claw-meta-prompt",
    "under-claw-jarvis-plan-loop"
  ],
  "per_round_skill_id": "under-claw-jarvis-plan"
}
```

Resolve the effective portable context:

```text
worklog context-resolve <workspace> <domain-id> [milestone-id] [discord-channel-id]
```

Domain bindings are inherited by a Milestone. Milestone-specific bindings are included only for that Milestone. A supplied Discord channel must be explicitly bound to the requested scope.

## Host-local binding

```json
{
  "environment_id": "ENV-example",
  "domain_id": "DOM-example",
  "hermes_profile": "example-profile",
  "discord_account_key": "example-discord-account",
  "repository_paths": {
    "REP-example": "/absolute/path/on-this-host"
  },
  "mcp_commands": {
    "underclaw-knowledge": [
      "/usr/local/bin/worklog",
      "mcp-serve"
    ]
  }
}
```

```text
worklog host-binding-set <workspace> <descriptor.json>
```

The registry is written under `.worklog/`, which setup places in `.gitignore`. Account keys are opaque labels; credentials remain in Hermes/OS secure storage.

## Read-only scoped MCP

```text
worklog mcp-serve <workspace> <domain-id> [milestone-id]
```

The server uses MCP stdio JSON-RPC and exposes only:

- `underclaw_recall`
- `underclaw_resolve_context`
- `underclaw_list_milestones`
- `underclaw_build_task_context`

The Domain/Milestone is fixed at process startup. Tool arguments cannot widen it, and restricted/secret Knowledge is excluded because this server accepts no restricted-recall authorization.

### Hermes

Use a separate Hermes Profile only for a real identity, credential, memory, tool, approval, or gateway boundary. Register the stdio server through the Hermes CLI rather than editing `config.yaml` directly:

```text
hermes --profile <profile> mcp add <server-name> \
  --command /usr/local/bin/worklog \
  --args mcp-serve <workspace> <domain-id> [milestone-id]
```

Verify with:

```text
hermes --profile <profile> mcp test <server-name>
```

Profile exports can carry non-secret setup to another Hermes Desktop installation, but each host must set local paths and credentials independently.

### Claude and Codex desktop clients

Configure the same executable and argument vector as a local stdio MCP server in each client's native MCP settings. Keep the canonical Domain ID identical across hosts while changing only the workspace path. Do not copy Hermes profile directories or `.env` files as a synchronization mechanism.

## Discord routing

A `channel_binding` stores the Discord channel ID, Domain/Milestone scope, and Agent Group. It never stores the bot token. A channel identifier is accepted by `context-resolve` only when it matches that scope. Hard isolation still requires separate profiles/gateways/bot credentials or a trusted gateway router; a model-supplied channel ID is routing metadata, not an authorization boundary.
