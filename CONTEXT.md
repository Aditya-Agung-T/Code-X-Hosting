# Code X Hosting Architectural Context & Audit Reference

> **Purpose for AI Agents**: This document is the definitive architectural map, domain index, and bug atlas for Code X Hosting. Consult this guide first to eliminate exploratory search loops ("scrape loops"), instantly pinpoint where features and bug hotspots live, and understand runtime invariants before reading or modifying code.

---

## Table of Contents
1. [Core Mental Model & Technology Invariants](#1-core-mental-model--technology-invariants)
2. [The Sentinel Record Matrix (`id = 0`)](#2-the-sentinel-record-matrix-id--0)
3. [End-to-End Execution Pipeline](#3-end-to-end-execution-pipeline)
4. [Feature Map: Where Every Domain Lives](#4-feature-map-where-every-domain-lives)
   - [Applications & Buildpacks](#41-applications--buildpacks)
   - [Standalone & Service Databases](#42-standalone--service-databases)
   - [Services & Docker Compose Stacks](#43-services--docker-compose-stacks)
   - [Servers & Remote SSH Execution Engine](#44-servers--remote-ssh-execution-engine)
   - [Proxy Layer (Traefik, Caddy, Nginx)](#45-proxy-layer-traefik-caddy-nginx)
   - [Scheduled Tasks & Backup Pipelines](#46-scheduled-tasks--backup-pipelines)
   - [Multi-Tenancy, Teams & Authorization](#47-multi-tenancy-teams--authorization)
   - [Real-Time WebSockets & Notifications](#48-real-time-websockets--notifications)
   - [REST API & MCP AI Server](#49-rest-api--mcp-ai-server)
5. [The "Where Bugs Live" Atlas: Known Failure Modes & Traps](#5-the-where-bugs-live-atlas-known-failure-modes--traps)
   - [Trap 1: Sentinel `id = 0` Query and Keyset Pagination Traps](#trap-1-sentinel-id--0-query-and-keyset-pagination-traps)
   - [Trap 2: Livewire 3 Dynamic Lists & Snapshot Missing Errors](#trap-2-livewire-3-dynamic-lists--snapshot-missing-errors)
   - [Trap 3: Sudo Wrapping for Non-Root SSH Execution](#trap-3-sudo-wrapping-for-non-root-ssh-execution)
   - [Trap 4: SSH Multiplexing & Socket Corruption](#trap-4-ssh-multiplexing--socket-corruption)
   - [Trap 5: Resource Stop State Persistence Race](#trap-5-resource-stop-state-persistence-race)
   - [Trap 6: Container Status Priority Machine & Crash Loop Detection](#trap-6-container-status-priority-machine--crash-loop-detection)
   - [Trap 7: Environment Variable Parsing, Encryption & JSON Escaping](#trap-7-environment-variable-parsing-encryption--json-escaping)
   - [Trap 8: Cron Overlapping Redis Lock Deadlock (`TTL = -1`)](#trap-8-cron-overlapping-redis-lock-deadlock-ttl---1)
   - [Trap 9: Test Runner Environments (Docker vs amphp in-process)](#trap-9-test-runner-environments-docker-vs-amphp-in-process)
6. [Agent Diagnostic & Audit Playbooks](#6-agent-diagnostic--audit-playbooks)
7. [Fast Symbol & Path Lookup Directory](#7-fast-symbol--path-lookup-directory)

---

## 1. Core Mental Model & Technology Invariants

Code X Hosting is an open-source, self-hostable PaaS managing servers, applications, databases, and services via SSH and Docker.

### 1.1 Structural Invariants
- **Framework**: Laravel 12 (`laravel/framework: ^12.65.0`).
- **File Structure**: **Laravel 10 legacy structure** (NOT Laravel 11/12 slim skeleton).
  - Middleware: `app/Http/Middleware/` and configured in `app/Http/Kernel.php`.
  - Providers: `app/Providers/` (`AuthServiceProvider.php`, `RouteServiceProvider.php`).
  - Scheduling: `app/Console/Kernel.php`.
  - Exceptions: `app/Exceptions/Handler.php`.
  - Helpers: `bootstrap/includeHelpers.php` auto-loads all files in `bootstrap/helpers/`.
- **Frontend**: Livewire 3 (`livewire/livewire: ^3.8.3`), Alpine.js, Tailwind CSS v4.
- **Model Primary Keys**: Eloquent models extend `App\Models\BaseModel`, which auto-generates CUID2 strings for `$model->uuid` on creation. Standard IDs are integers.
- **Actions Pattern**: Extensive use of `lorisleiva/laravel-actions` (`AsAction` trait) in `app/Actions/`. Classes can execute as synchronous service calls (`Action::run(...)`), queued background jobs (`Action::dispatch(...)`), or HTTP controllers.

---

## 2. The Sentinel Record Matrix (`id = 0`)

Code X Hosting seeds specific **instance-owned rows at primary key `id = 0`**. These are sentinel records representing the Code X Hosting installation itself.

| Record / Resource | Model / Query Pattern | Significance & Constraints |
| :--- | :--- | :--- |
| **Root Team** | `Team::find(0)`, `team_id === 0` | The instance owner team. Billing checks, cloud limits, and access gates exempt this team. |
| **Localhost Server** | `Server::find(0)`, `Server::findOrFail(0)` | The host running Code X Hosting. Upgrades, local backups, and engine health checks target this server. **Cannot be transferred.** |
| **Instance Settings** | `InstanceSettings::find(0)` | Singleton global configuration (registration toggles, update channels, SMTP defaults). |
| **Code X Hosting DB** | `StandalonePostgresql::find(0)` | The PostgreSQL instance (`coolify-db`) storing Code X Hosting’s own database. UI forbids deleting this database. |
| **Local Docker Dest** | `StandaloneDocker::find(0)` | Default Docker destination (`coolify`) on localhost (`destination_id = 0`). |

### Critical Invariants for Sentinel Rows
- **NEVER resequence, migrate, or renumber `id = 0` rows.**
- **PHP Pitfall**: `empty(0)` evaluates to `true`. Checking `if (empty($server->id))` is fatal for localhost.
- **Cursor Pagination Pitfall**: Keyset pagination doing `where('id', '>', $cursor)` where `$cursor = 0` drops the sentinel row. Keyset queries must initialize with cursor `< 0` or omit lower bound on the first chunk. Prefer `chunkById()`.

---

## 3. End-to-End Execution Pipeline

How actions flow through Code X Hosting from user interaction to remote host execution:

```
[Browser / UI] (Livewire Component in app/Livewire/)
     │
     ▼ (wire:click / Form Submit)
[Livewire Action] / [API Controller] (app/Http/Controllers/Api/)
     │
     ▼ (Validates & Authorizes via Gate/Policy)
[Domain Action / Service] (app/Actions/ or app/Services/)
     │
     ├── Direct Command (Sync)
     │        │
     │        ▼
     │   instant_remote_process() [bootstrap/helpers/remoteProcess.php]
     │        │  (Wraps parseCommandsByLineForSudo if non-root)
     │        ▼
     │   SshMultiplexingHelper::generateSshCommand()
     │        │  (Reuses ControlMaster socket / SSH connection)
     │        ▼
     │   Remote Server (executes via SSH / bash)
     │
     └── Background Pipeline (Async Job)
              │
              ▼
         ApplicationDeploymentJob / CoolifyTask [app/Jobs/]
              │
              ▼
         Redis Queue (monitored by Laravel Horizon)
              │
              ▼
         remote_process() creates Spatie Activity model (status: queued -> in_progress -> finished)
              │
              ▼
         WebSocket Event Dispatched (e.g. ApplicationStatusChanged)
              │
              ▼
         Soketi (port 6001/6002) pushes real-time terminal output to UI
```

---

## 4. Feature Map: Where Every Domain Lives

Use this map to directly locate classes and files for any task without recursive grepping.

### 4.1 Applications & Buildpacks
- **Core Model**: `app/Models/Application.php` (contains git configuration, ports, health checks, domains).
- **Deployment Engine**: `app/Jobs/ApplicationDeploymentJob.php` (~250KB monolithic orchestrator).
  - Handles buildpacks:
    - Nixpacks: `deploy_nixpacks_buildpack()`, `generate_nixpacks_confs()`
    - Railpack: `deploy_railpack_buildpack()`, `generate_railpack_config_file()`
    - Dockerfile: `deploy_dockerfile_buildpack()`, `deploy_simple_dockerfile()`
    - Docker Compose: `deploy_docker_compose_buildpack()`, `generate_compose_file()`
    - Docker Image: `deploy_dockerimage_buildpack()`
    - Static: `deploy_static_buildpack()`, `build_static_image()`
- **Deployment Queue**: `app/Models/ApplicationDeploymentQueue.php`.
- **Previews / PR Deployments**: `app/Models/ApplicationPreview.php`, `app/Actions/Application/CleanupPreviewDeployment.php`.
- **UI Components**:
  - Main Config: `app/Livewire/Project/Application/Configuration.php`
  - Deployments List & Terminal: `app/Livewire/Project/Application/Deployment/Index.php`, `Show.php`
  - Environment Variables: `app/Livewire/Project/Application/EnvironmentVariables.php`
  - Persistent Volumes / Storage: `app/Livewire/Project/Shared/Storages/`
- **Helpers**: `bootstrap/helpers/applications.php`, `bootstrap/helpers/parsers.php` (`applicationParser()`).

### 4.2 Standalone & Service Databases
- **Models**:
  - `app/Models/StandalonePostgresql.php`
  - `app/Models/StandaloneMysql.php`
  - `app/Models/StandaloneMariadb.php`
  - `app/Models/StandaloneMongodb.php`
  - `app/Models/StandaloneRedis.php`
  - `app/Models/StandaloneKeydb.php`
  - `app/Models/StandaloneDragonfly.php`
  - `app/Models/StandaloneClickhouse.php`
  - `app/Models/ServiceDatabase.php` (compose-managed sub-databases)
- **Actions**: `app/Actions/Database/`
  - `StartPostgresql.php`, `StartMysql.php`, `StartRedis.php`, etc.
  - `StopDatabase.php`, `RestartDatabase.php`
  - `StartDatabaseProxy.php`, `StopDatabaseProxy.php` (TCP proxy for external database access)
- **Backup Pipeline**:
  - Orchestrator: `app/Jobs/DatabaseBackupJob.php`
  - S3 / Local Retention: `bootstrap/helpers/databases.php` (`deleteOldBackupsLocally()`, `deleteOldBackupsFromS3()`)
  - Execution Tracking: `app/Models/ScheduledDatabaseBackupExecution.php`
- **UI Components**: `app/Livewire/Project/Database/Configuration.php`, `Backup/Index.php`, `Backup/Execution.php`.

### 4.3 Services & Docker Compose Stacks
- **Models**:
  - Parent: `app/Models/Service.php` (contains `docker_compose_raw`, `docker_compose`)
  - Children: `app/Models/ServiceApplication.php`, `app/Models/ServiceDatabase.php`
- **Templates**: `templates/service-templates-latest.json` (defines 1-click installable services: Plausible, Nextcloud, MinIO, etc.).
- **Actions**: `app/Actions/Service/`
  - `StartService.php` (parses compose, ensures network attachability, mounts `.env`, runs `docker compose up -d`)
  - `StopService.php`, `RestartService.php`
  - `DeployServiceApplication.php`
- **Helpers**:
  - `bootstrap/helpers/services.php` (substitutes templates, evaluates service variables)
  - `bootstrap/helpers/parsers.php` (`serviceParser()`, `validateDockerComposeForInjection()`)
- **UI Components**: `app/Livewire/Project/Service/Index.php`, `Configuration.php`, `Storage.php`.

### 4.4 Servers & Remote SSH Execution Engine
- **Models**: `app/Models/Server.php`, `app/Models/ServerSetting.php`, `app/Models/PrivateKey.php`.
- **Execution Primitives**: `bootstrap/helpers/remoteProcess.php`
  - `instant_remote_process()`: Synchronous SSH run via Symfony/Laravel Process wrapper.
  - `instant_remote_process_with_timeout()`: Enforces hard timeouts.
  - `remote_process()`: Dispatches async `CoolifyTask` job, tracked in Activity log.
  - `instant_scp()`, `instant_scp_from_server()`: File copy over SSH.
- **SSH Multiplexing**: `app/Helpers/SshMultiplexingHelper.php`, `app/Helpers/SshRetryHandler.php`.
  - Reuses OpenSSH ControlMaster sockets in `/root/.ssh/` or `/var/www/html/storage/app/ssh/` to prevent SSH connection exhaustion.
- **Sudo Parsing**: `bootstrap/helpers/sudo.php` (`parseCommandsByLineForSudo()`).
- **Sentinel Daemon**: Code X Hosting host metrics & health collector daemon running on remote servers.
  - `app/Jobs/CheckAndStartSentinelJob.php`, `app/Actions/Server/StartSentinel.php`.
- **Server Migration**: `app/Services/ServerTransfer/` (`ServerTransferMigrator.php`, `ServerTransferExporter.php`, `ServerTransferImporter.php`).
- **UI Components**: `app/Livewire/Server/Show.php`, `ValidateAndInstall.php`, `Proxy.php`, `Advanced.php`.

### 4.5 Proxy Layer (Traefik, Caddy, Nginx)
- **Supported Enums**: `App\Enums\ProxyTypes` (`TRAEFIK`, `CADDY`, `NGINX`, `NONE`).
- **Helpers**: `bootstrap/helpers/proxy.php`
  - `connectProxyToNetworks(Server $server)`: Connects `coolify-proxy` container to each application/service network.
  - Dynamic Configs: Traefik dynamic YAML generation and Caddyfile label mapping.
  - FQDN Labels: `fqdnLabelsForTraefik()`, `fqdnLabelsForCaddy()` in `bootstrap/helpers/docker.php`.
- **Domain Verification & Collision Detection**: `bootstrap/helpers/domains.php` (`checkDomainUsage()`, `isValidDomainUrl()`).
- **Actions**: `app/Actions/Proxy/StartProxy.php`, `StopProxy.php`, `CheckProxy.php`, `SaveProxyConfiguration.php`.
- **UI Components**: `app/Livewire/Server/Proxy/Show.php`, `DynamicConfigurations.php`, `Logs.php`.

### 4.6 Scheduled Tasks & Backup Pipelines
- **Scheduled Job Manager**: `app/Jobs/ScheduledJobManager.php`
  - Runs on the `crons` Redis queue every minute.
  - Evaluates cron expressions for `ScheduledTask`, `ScheduledDatabaseBackup`, and `ScheduledVolumeBackup`.
- **Jobs**:
  - `app/Jobs/ScheduledTaskJob.php`
  - `app/Jobs/DatabaseBackupJob.php`
  - `app/Jobs/VolumeBackupJob.php`
  - `app/Jobs/DockerCleanupJob.php`
- **Lock Management**: Uses `WithoutOverlapping` middleware with explicit TTL clearing to prevent permanent deadlocks.

### 4.7 Multi-Tenancy, Teams & Authorization
- **Models**: `app/Models/Team.php`, `app/Models/User.php`, `app/Models/TeamInvitation.php`.
- **Role Hierarchy**: `App\Enums\Role` (`MEMBER` = 1, `ADMIN` = 2, `OWNER` = 3).
  - Methods: `$role->gt('member')`, `$role->lt('owner')`, `$role->rank()`.
- **Policies**: 27 model policies registered in `app/Providers/AuthServiceProvider.php` (e.g. `ServerPolicy.php`, `ApplicationPolicy.php`, `ProjectPolicy.php`).
- **Form Authorization Trait / Components**:
  - Blade forms enforce `canGate` and `:canResource` attributes.
  - Server-side validation MUST call `$this->authorize(...)` or `Gate::authorize(...)`.
- **Onboarding Flow**: Handled by `app/Http/Middleware/DecideWhatToDoWithUser.php` and `app/Livewire/Boarding/Index.php`.

### 4.8 Real-Time WebSockets & Notifications
- **Broadcasting Engine**: Soketi / Pusher compatible (`routes/channels.php`).
- **Core Status Events**:
  - `ApplicationStatusChanged`: Fired on deploy, crash, or manual stop.
  - `ServiceStatusChanged`: Dispatched when compose service states flip.
  - `DatabaseStatusChanged`: Dispatched when standalone DB status changes.
  - `ProxyStatusChanged`: Dispatched during proxy reloads.
- **Notification Channels**: `app/Notifications/Channels/` (Discord, Telegram, Slack, Email, Pushover, Webhook).

### 4.9 REST API & MCP AI Server
- **REST Endpoints**: `routes/api.php` under `/api/v1/`.
  - Controllers: `app/Http/Controllers/Api/`
  - Middleware Stack: `['auth:sanctum', 'api.token.team', ApiAllowed::class, 'api.sensitive']`.
  - Token Abilities: `api.ability:read`, `api.ability:write`, `api.ability:write:sensitive`.
  - Sensitive Data Masking: Handled by `app/Http/Middleware/ApiSensitiveData.php`.
- **MCP AI Server**: `routes/ai.php` mounts `/mcp` via `App\Mcp\Servers\CoolifyServer`.
  - Tools: `app/Mcp/Tools/` (40+ tools including `ListApplications`, `Deploy`, `GetLogs`, `GetServer`).
  - Resources & Prompts: `app/Mcp/Resources/`, `app/Mcp/Prompts/`.

---

## 5. The "Where Bugs Live" Atlas: Known Failure Modes & Traps

This section documents the exact conditions that cause recurring bugs across the codebase, with specific diagnostic rules and fixes.

### Trap 1: Sentinel `id = 0` Query and Keyset Pagination Traps
- **Root Cause**: Database seeds instance records at `id = 0`. PHP’s `empty(0)` is `true`. Keyset queries filtering `where('id', '>', $cursor)` will skip record `0` if cursor starts at `0`.
- **Where It Breaks**:
  - Scheduled backup lookups (`ScheduledDatabaseBackup::find(0)` is invalid; only instance DB is `0`).
  - Mass queries or migrations iterating IDs.
  - Transferring server: `Server(0)` cannot be transferred between Code X Hosting instances (`ServerTransferMigrator.php`).
- **Rule for AI Agents**:
  - When querying paginated models, use `chunkById()` or initialize pagination cursor at `< 0`.
  - Never check `if (!$model->id)` — always check `if (is_null($model->id))` or `if (!isset($model->id))`.

### Trap 2: Livewire 3 Dynamic Lists & Snapshot Missing Errors
- **Root Cause**: Livewire 3 throws `Snapshot missing on Livewire component` during dynamic adds/deletes if components in loops lack stable keys or if an event re-renders a parent while targeting a child that DOM morphed out.
- **Where It Breaks**:
  - Storages, Environment Variables, File Mounts, and Service Application lists.
  - Teleported Alpine modals referencing stale `$index`.
- **Rule for AI Agents**:
  1. Every component in a loop must have `:key="$item->uuid"` or `:key="$item->id"`. **NEVER** use `$loop->index` or count.
  2. Actions must accept immutable identifiers (`deleteStorage(string $uuid)`), **never** array indexes (`deleteStorage(int $index)`).
  3. Do not broadcast one generic refresh event to both parent and child components simultaneously. Dispatch targeted events: `$this->dispatch('refresh')->to(ChildComponent::class)`.

### Trap 3: Sudo Wrapping for Non-Root SSH Execution
- **Root Cause**: Remote commands executed on servers with non-root SSH users run through `parseCommandsByLineForSudo()` in `bootstrap/helpers/sudo.php`. The parser injects `sudo` into commands.
- **Where It Breaks**:
  - Complex piped commands (`cmd1 | cmd2 && cmd3`). If not recognized as complex, `sudo` is injected mid-pipe or into subshells incorrectly.
  - Redirection operators (`> /etc/file`). In Linux, `sudo echo "x" > /file` fails because the shell redirection executes as the non-root user.
- **Rule for AI Agents**:
  - Pipes requiring full root context must be wrapped in `sudo bash -c '...'`.
  - File writes to system directories must use `tee`: `echo "data" | sudo tee /path/to/file >/dev/null`.
  - Review `parseCommandsByLineForSudo()` when introducing new remote shell commands.

### Trap 4: SSH Multiplexing & Socket Corruption
- **Root Cause**: `SshMultiplexingHelper` establishes persistent control sockets (`ControlMaster=auto`, `ControlPath=...`). If a server reboots, network drops mid-stream, or permissions drift, stale socket files block all future commands with SSH errors.
- **Where It Breaks**: `instant_remote_process()` hangs or throws exit code 255.
- **Fix Mechanism**:
  - `SshRetryHandler::retry()` attempts auto-recovery.
  - `app/Jobs/CleanupStaleMultiplexedConnections.php` periodically purges orphaned sockets.
  - To bypass multiplexing for sensitive tests: pass `disableMultiplexing: true` to `instant_remote_process()`.

### Trap 5: Resource Stop State Persistence Race
- **Root Cause**: Calling Docker CLI to stop a container (`docker stop ...`) without immediately persisting the database record causes background status checkers (`GetContainersStatus.php`) or UI pollers to read old status or flip state between `exited` and `running`.
- **Where It Breaks**: `StopApplication`, `StopDatabase`, `StopService`, and Preview stops.
- **Rule for AI Agents**:
  - Every stop action MUST explicitly call `$model->update(['status' => 'exited'])` and reset restart counters.
  - Regression verified by `tests/Unit/StopActionsPersistStatusTest.php`.

### Trap 6: Container Status Priority Machine & Crash Loop Detection
- **Root Cause**: Containers in Docker can have multiple states (e.g. running but unhealthy, restarting, mixed replica statuses).
- **Service**: `app/Services/ContainerStatusAggregator.php`
- **Priority Order**:
  1. `degraded:unhealthy` (highest priority; includes crashed sub-resources, dead containers)
  2. `restarting` (returns `degraded:unhealthy` by default, or `restarting:unknown` if `preserveRestarting = true`)
  3. `mixed` (some running + some exited -> `degraded:unhealthy`; running + starting -> `starting:unknown`)
  4. `running` (`running:healthy`, `running:unhealthy`, `running:unknown`)
  5. `paused:unknown`
  6. `starting:unknown` / `created`
  7. `exited`
- **Crash Loop Tracking**: Evaluated via `app/Services/RestartCountTracker.php`. If `restart_count >= max_restart_count`, notifications fire and status locks to degraded.

### Trap 7: Environment Variable Parsing, Encryption & JSON Escaping
- **Root Cause**: Environment variables are stored encrypted in the database (`casts => ['value' => 'encrypted']`). During deployment, `real_value` evaluates inheritance and escaping.
- **Where It Breaks**:
  - JSON objects or arrays in environment variables. Past bug #6160: standard escaping corrupted valid JSON strings.
  - Double escaping of dollar signs (`$$`) in Docker Compose files.
- **Rule for AI Agents**:
  - Check `EnvironmentVariable::realValue()` in `app/Models/EnvironmentVariable.php`.
  - JSON values matching `json_validate($real_value)` must bypass standard shell escaping.
  - Understand the inheritance cascade:
    `Resource Env` > `Environment Shared` > `Project Shared` > `Server Shared` > `Team Shared`.

### Trap 8: Cron Overlapping Redis Lock Deadlock (`TTL = -1`)
- **Root Cause**: Laravel's `WithoutOverlapping` middleware stores locks in Redis. During unexpected container restarts, Redis crashes, or upgrades, locks can lose their TTL (`TTL = -1`), permanently freezing scheduled jobs with no visible error.
- **Where It Breaks**: `app/Jobs/ScheduledJobManager.php` (Issue #8327).
- **Self-Healing Code**: `ScheduledJobManager::clearStaleLockIfPresent()` actively inspects the Redis key and purges locks with `ttl === -1`. Keep this guard intact in all queue/cron refactors.

### Trap 9: Test Runner Environments (Docker vs amphp in-process)
- **Feature Tests**: Depend on Postgres and Redis.
  - **MUST run inside Docker**: `docker exec coolify php artisan test`.
  - Running feature tests on the host will fail with database connection errors.
- **Unit Tests**: Mocked, no database required.
  - Run outside Docker: `./vendor/bin/pest tests/Unit`.
- **Browser Tests (Pest Plugin Browser)**:
  - Runs headless Chromium via Playwright and boots an **in-process amphp HTTP server** on an ephemeral port.
  - **In-process sharing**: The amphp server shares in-memory SQLite and PHP process memory with the test runner.
  - **Redis class missing on host**: Host PHP lacks phpredis; maintenance store hard-wires to redis in config. Fix in test `beforeEach`: `config()->set('app.maintenance.store', 'array');`.
  - **Onboarding redirect trap**: Fresh users redirect to `/boarding`. Clear before navigating:
    `Team::query()->update(['show_boarding' => false]); Cache::flush();`.

---

## 6. Agent Diagnostic & Audit Playbooks

When assigned an issue, follow these exact diagnostic paths instead of open-ended code exploration.

### Playbook A: Deployment Fails or Hangs
1. **Locate Logs**: Inspect `ApplicationDeploymentQueue` entry via `id` or `deployment_uuid`.
2. **Determine Failure Phase**:
   - `clone_repository()` -> Check SSH keys, deploy keys, git URL parsing (`bootstrap/helpers/github.php`, `gitlab.php`).
   - `generate_env_variables()` -> Check `EnvironmentVariable.php` real value resolution and JSON escaping.
   - `build_image()` -> Check Docker buildx flags, Docker daemon disk space, build secrets formatting.
   - Container startup -> Check `connectProxyToNetworks()` in `proxy.php`, network conflicts, Traefik label parsing.
3. **Core File**: `app/Jobs/ApplicationDeploymentJob.php`.

### Playbook B: Server Connection or Remote Command Times Out
1. Check if the target server uses a non-root user (`$server->isNonRoot()`).
2. Verify command pipeline through `parseCommandsByLineForSudo()` in `bootstrap/helpers/sudo.php`.
3. Check for stale SSH multiplexing sockets in `SshMultiplexingHelper::generateSshCommand()`.
4. Run synchronous test command with `instant_remote_process(['echo 1'], $server, disableMultiplexing: true)`.

### Playbook C: UI Unresponsive or Component State Lost
1. Check Livewire component in `app/Livewire/`.
2. Check corresponding Blade view in `resources/views/livewire/`.
3. Verify that the view has **exactly one root HTML element** (Livewire 3 invariant).
4. Verify all loops have immutable `:key` attributes (`uuid` or `id`).
5. Check if `wire:loading` or `x-cloak` is permanently stuck due to missing `@livewireStyles`.
6. Inspect browser console for `Snapshot missing on Livewire component`.

### Playbook D: Proxy or Domain Routing Fails (404 / 502 / SSL Error)
1. Inspect proxy type on server: `$server->proxyType()`.
2. Inspect Traefik/Caddy labels generated for the resource via `generateLabelsApplication()` in `bootstrap/helpers/docker.php`.
3. Check Traefik Docker network attachment: `addTraefikDockerNetworkLabel()` in `parsers.php`.
4. Ensure `coolify-proxy` is connected to the application's network: `connectProxyToNetworks()` in `proxy.php`.
5. Check for FQDN collisions across teams: `checkDomainUsage()` in `domains.php`.

---

## 7. Fast Symbol & Path Lookup Directory

| Concept / Task | Primary File / Class | Relevant Methods / Helpers |
| :--- | :--- | :--- |
| **Application Deployment** | `app/Jobs/ApplicationDeploymentJob.php` | `handle()`, `build_image()`, `deploy_nixpacks_buildpack()` |
| **Compose File Parser** | `bootstrap/helpers/parsers.php` | `applicationParser()`, `serviceParser()`, `validateDockerComposeForInjection()` |
| **Docker Remote Execution** | `bootstrap/helpers/remoteProcess.php` | `instant_remote_process()`, `remote_process()` |
| **Non-Root Sudo Wrapper** | `bootstrap/helpers/sudo.php` | `parseCommandsByLineForSudo()`, `shouldChangeOwnership()` |
| **SSH Multiplexing** | `app/Helpers/SshMultiplexingHelper.php` | `generateSshCommand()`, `ensureMultiplexedConnection()` |
| **Container Status Machine**| `app/Services/ContainerStatusAggregator.php` | `aggregateFromStrings()` |
| **Crash Loop Tracker** | `app/Services/RestartCountTracker.php` | `evaluate()` |
| **Traefik/Caddy Labels** | `bootstrap/helpers/docker.php` | `fqdnLabelsForTraefik()`, `fqdnLabelsForCaddy()`, `generateLabelsApplication()` |
| **Proxy Network Hook** | `bootstrap/helpers/proxy.php` | `connectProxyToNetworks()`, `collectDockerNetworksByServer()` |
| **Database Backups** | `app/Jobs/DatabaseBackupJob.php` | `handle()`, `upload_to_s3()`, `failed()` |
| **Cron / Schedule Locks** | `app/Jobs/ScheduledJobManager.php` | `middleware()`, `clearStaleLockIfPresent()` |
| **Environment Variables** | `app/Models/EnvironmentVariable.php` | `realValue()`, `get_real_environment_variables()` |
| **Server Transfer Engine** | `app/Services/ServerTransfer/ServerTransferMigrator.php` | `migrate()` |
| **REST API Routes** | `routes/api.php` | Group `/api/v1/` with Sanctum middleware |
| **MCP AI Server Tools** | `app/Mcp/Servers/CoolifyServer.php` | Tools in `app/Mcp/Tools/` |
| **Global Search Engine** | `app/Livewire/GlobalSearch.php` | Search indexing across all Code X Hosting models |
| **Code Formatter** | `vendor/bin/pint` | Run `vendor/bin/pint --dirty --format agent` |
| **Unit Test Suite** | `./vendor/bin/pest tests/Unit` | Runs outside Docker |
| **Feature Test Suite** | `docker exec coolify php artisan test` | Requires running Docker app container |
