# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Garry's Mod (Lua) addon that provides a **framework** for "TARDIS-style" doors: a small exterior entity that, when entered, teleports players through a `linked_portal_door` to a much larger interior spawned far away on the map. The repository lives in-place inside `garrysmod/addons/Doors`; there is no compile/build step locally.

This repo only contains the base entities and shared infrastructure. Concrete doors (with models, portal geometry, fallback positions, etc.) are shipped as **separate dependent addons** that base their entities on `gmod_door_exterior` / `gmod_door_interior` and contribute behaviour by registering hooks on those bases.

**Hard runtime dependency:** `AmyJeanes/world-portals` (the `wp.*` API + `linked_portal_door` entity). Without it the addon errors at runtime — it is checked out alongside this repo in CI and combined into a single Workshop upload.

## Build / publish

There is no local build, lint or test command. GMod loads the `lua/` tree at server start.

The only "build" is CI (`.github/workflows/ci.yml`), which on push to `dev`:
1. Checks out this repo and `AmyJeanes/world-portals@dev` into sibling directories.
2. Copies both into a single `combined/` folder (world-portals first, then this repo on top).
3. Runs `AmyJeanes/gmod-upload` to publish to the beta Workshop ID.

When verifying changes touch CI, remember the combine step means **paths in this repo collide with paths in `world-portals`** — files with the same path in this repo win.

## Architecture

### Module loader convention

Both `lua/autorun/doors.lua` and each entity's `shared.lua` define a `LoadFolder` helper that scans a folder for `*.lua` and routes by filename prefix:

- `sh_*.lua` — loaded on both realms; AddCSLuaFile'd on the server.
- `sv_*.lua` — server only.
- `cl_*.lua` — client only; AddCSLuaFile'd.

A `modules/libraries/` subfolder exists so library code can load **before** modules that depend on it (`shared.lua` calls `LoadFolder("modules/libraries")` then `LoadFolder("modules")`). Adding new behaviour generally means dropping a new `sh_/sv_/cl_*.lua` into the appropriate `modules/` directory — no central registration needed.

### Per-entity hook system (the central abstraction)

Each base entity (`gmod_door_exterior/shared.lua`, `gmod_door_interior/shared.lua`) defines its own private `hooks` table with `ENT:AddHook(name,id,func)`, `ENT:RemoveHook`, and `ENT:CallHook`. Modules attach behaviour by calling `ENT:AddHook` at file load time. This is the entire extension model — there is almost no inheritance; everything is composition through hooks.

`CallHook` semantics worth knowing:

- **First non-nil return short-circuits** the rest of the chain and is returned to the caller. So callers test patterns like `if self:CallHook("CanPlayerEnter",ply)==false then return end` or `~=true`. If you add a hook that incidentally returns a value, you may silently suppress every later hook with the same name — return nothing unless you mean to veto.
- The `Use`, `Think`, `OnRemove`, `Draw`, `Initialize`, etc. core entity callbacks each just dispatch to the corresponding hook chain; the bases themselves contain almost no logic.

Common hook names (non-exhaustive — grep for `AddHook` and `CallHook`): `Initialize` / `PostInitialize` / `PreInitialize`, `PreOnRemove` / `OnRemove`, `Think` / `SlowThink` (1 Hz tick) / `ShouldThinkFast` (return true to opt into per-frame think), `Use`, `CanPlayerEnter` / `CanPlayerExit` / `PlayerEnter` / `PlayerExit` / `PostPlayerExit`, `PlayerInitialize` / `PostPlayerInitialize` (used as net-message extension points — see below), `ShouldSpawnInterior`, `FindingPosition` / `FoundPosition` / `FindingPositionFailed` / `AllowInteriorPos`, `InteriorReady`, `SetupPosition`, `ShouldDraw` / `PreDraw` / `Draw`, `ShouldRenderPortal` / `PreRenderPortal` / `PostRenderPortal` / `PreDrawPortal` / `PostDrawPortal` / `PreRenderPortal` / `ShouldTracePortal` / `TraceFilterPortal` / `ShouldTeleportPortal` / `PostTeleportPortal` / `ShouldAllowThickPortal`, `Cordon` / `ShouldRemoveProp`, `CustomData`, `SkinChanged` / `BodygroupChanged`, `ShouldDrawPlayer`.

There are also four **gamemode-level** hooks fired via `hook.Call(..., GAMEMODE, ...)` for outside listeners: `Doors-InteriorAdded` / `Doors-InteriorRemoved` / `Doors-ExteriorAdded` / `Doors-ExteriorRemoved` (in `lua/doors/libraries/sh_entities.lua`).

### Exterior ↔ interior pairing

When an exterior is created server-side, `sh_interior.lua`:

1. Spawns a `gmod_door_interior` and marks it `spacecheck=true` so its `Initialize` only sets up physics/state but does **not** run module `Initialize` hooks yet.
2. Kicks off a `FindPosition` coroutine that random-samples up to `doors_interior_tries` (convar, default 10000) points within ±16384 units, hull-traces each, and keeps the highest empty point. The coroutine yields whenever a frame budget (1/30 s) is exceeded — this is why `ShouldThinkFast` exists, so `Think` runs every frame while searching.
3. On success, calls the interior's `SetupPosition` hook (which can override the chosen position), `SetPos`, mutually `DeleteOnRemove`s the pair, and **then** runs the real `interior:Initialize()` which fires module hooks (which is when portals are created — see `sh_portals.lua` `PreInitialize` hook).
4. Fires `InteriorReady` on the exterior. On failure, removes the interior and fires `InteriorReady` with `false`.

The two entities cross-reference as `ext.interior` and `int.exterior`. Both share the same `occupants` table by reference (set up in interior `handleplayers` Initialize hook) so server and client stay symmetric.

### Two-phase client init handshake

Because the interior may not exist yet when a client first sees the exterior (or vice-versa), both `cl_init.lua` files do this:

1. Client `Initialize` sends `Doors-Initialize` / `DoorsI-Initialize` to the server with itself.
2. Server's `InitializePlayer` writes the paired entity, creator, then calls the `PlayerInitialize` hook chain — **modules write their own per-player payload into the same net message** (e.g. `sh_players.lua` writes `occupants`, `sh_portals.lua` writes the portal entity refs and custom-portal table). Order matters: hooks run in `pairs()` order, so the read side must mirror the write side. Adding a new module that needs per-player networking goes in this hook.
3. Both sides only set `ent._init = true` once **both** exterior and interior are ready (`_ready`). Most module code guards with `if self._init`.

If a client requests init before the interior coroutine finishes, the request is queued in `initqueue` and flushed from `InteriorReady` (exterior) / `PostInitialize` (interior).

### Portals (`sh_portals.lua`)

Created in the interior's `PreInitialize` hook (server side) using two `linked_portal_door` entities — one parented to the exterior at `ext.Portal.{pos,ang,width,height,...}` and one parented to the interior at `int.Portal.*`. Optional fields on the `Portal` table: `link`, `exit_point`/`exit_point_offset`, `thickness`, `inverted`, `model`, `model_offset`. An entity may also define `CustomPortals` — a name → `{entry, exit}` map for additional same-pair portal links inside the interior, with optional `black` (skip rendering) and `fallback` (un-stuck position).

Every world-portals callback (`wp-shouldtp`, `wp-shouldrender`, `wp-predraw`, `wp-postdraw`, `wp-prerender`, `wp-postrender`, `wp-trace`, `wp-tracefilter`, `wp-teleport`, `wp-allowthickportal`) is forwarded into a per-entity hook (`ShouldTeleportPortal`, `ShouldRenderPortal`, `PreDrawPortal`, …). Modules customise rendering / teleport behaviour by registering on those.

### Cordon (`sh_cordon.lua` + `cl_cordon.lua`)

The interior is spawned far enough from anything to be empty, but other props can drift in. The cordon system:

- On client, every second `UpdateCordon` finds entities inside the interior's OBB (defaults to `OBBMins/Maxs * 0.95`, can be overridden by `self.mins`/`self.maxs`) and toggles `NoDraw` based on whether `LocalPlayer()` is inside this interior. The `Cordon` hook lets a module veto a specific class/entity from being captured.
- On server, when the interior is removed, captured props are deleted unless `ShouldRemoveProp` returns false (in which case they are frozen via `DoorsPhysicsFrozen`).
- During `PreRenderPortal` / `PostRenderPortal`, cordoned props are forced visible (exterior view) or hidden (interior view) so they render correctly through the portal.

Players track which interior they're "inside" client-side via `ply.doori`, set by the `Doors-EnterExit` net message in `sh_players.lua`.

### Player enter/exit (`sh_players.lua`, server side)

Entry path: `CanPlayerEnter` → record in `occupants` → broadcast `Doors-EnterExit` → if portals exist and this is **not** a portal-triggered entry (`notp` flag), teleport the player to the interior `Fallback` position with rotated eye angles (`wp.TransformPortalAngle`). If no interior, the player goes into `OBS_MODE_ROAMING` spectate.

Exit path mirrors it. The exit-without-interior branch does an ugly but necessary `Spectate(NONE) + Spawn() + restore weapons/ammo/health` because `Spectate` can't be left cleanly otherwise. Players exiting without an interior get a 1-second cooldown (`doors_cooldowncur`) to prevent immediate re-entry.

### Other small but load-bearing pieces

- `lua/doors/sh_hooks.lua` monkey-patches `Entity.SetSkin` and `Entity.SetBodygroup` to fire gamemode hooks `SkinChanged` / `BodygroupChanged`, which are then forwarded to door entities' per-entity hook chains.
- `lua/doors/sh_owner.lua` (`Doors:SetupOwner`) sets `Creator` (with a client-side polyfill) and `CPPISetOwner` if Falco's CPPI is loaded; recurses into `ent.parts` and `ent.interior`. Always use this rather than setting owner directly so prop-protection and the client-visible creator stay consistent.
- `lua/doors/libraries/libraries/sh_von.lua` is a vendored copy of vON 1.3.4 (table serialization) — leave it alone unless syncing with upstream Vercas/vON.
- Both base entities pick `base_wire_entity` if `WireLib` is loaded, otherwise `base_gmodentity`. The client `Draw` calls `Wire_Render(self)` only when WireLib exists.

## Conventions when adding code

- **Pure Lua syntax only — no GMod-Lua extensions.** No `//` comments, no `continue`, no `!=`, no `&&`/`||`. Use `--`, `goto continue`, `~=`, `and`/`or`. The existing source already follows this; keep it that way.
- New behaviour goes in a new module file under the appropriate `modules/` directory with a `sh_/sv_/cl_` prefix — don't edit the base `shared.lua`/`init.lua`/`cl_init.lua` unless you're changing the framework itself.
- When adding a new hook name, document on the call site what `nil` vs a non-nil return means, since the first non-nil short-circuits. If you don't intend to veto, return nothing.
- If a new module needs per-player networked state, hook into `PlayerInitialize` (write side, server) and `PlayerInitialize` (read side, client) so you don't have to manage a separate net message lifecycle. Read order must match write order.
- When iterating `Doors:GetInteriors()` / `GetExteriors()` in a hook, always `IsValid` the key — entries are only removed via the `Doors:RemoveInterior/Exterior` calls in the `OnRemove` hook, which runs at end-of-frame.
- For `pairs`/`ipairs` loops, drop the variable you don't use rather than naming it: `for k in pairs(t)` discards the value, `for _, v in pairs(t)` discards the key, `for _ = 1, n do` for plain N-iteration. The `unused` lint is on so future dead `local x = expensive_call()` survivors get flagged — keep the noise floor at zero by using these forms.
- `addon.json` "ignore" already excludes `*.md`, so committing docs (including this file) is safe.

## Tooling

- `.luarc.json` configures sumneko-LuaLS with `./.tools/glua-api` (GLua type stubs) and `./.luatypes` (local override aliases) plus sibling addons (`../world-portals` is a hard dep; `../wire` is referenced behind `if WireLib then` guards). The recommended VS Code extension is `Pollux.gmod-glua-ls`.

### Type annotations

The analyzer (`glua_ls` / `glua_check`) understands `---@class`, `---@field`, `---@return`, and inline `--[[@as X]]` casts. Patterns that matter for this codebase:

- **Hook-set fields don't propagate.** Inside a hook callback (`ENT:AddHook("Initialize", "id", function(self) self.X = ... end)`), the analyzer doesn't follow `self` back to other functions on the entity, so `self.X` looks undefined elsewhere. Declare the field with a `---@class gmod_door_X` block at the top of the **module that owns it** — that's the cleanest place since multi-file `---@class` blocks merge automatically. Direct `function ENT:X()` body assignments propagate without annotation.
- **Don't use the `(partial)` modifier.** GLuaLS treats every class as implicitly partial; the modifier is redundant and trips other VS Code Lua parsers with a syntax-error squiggle.
- **Framework-contract fields** (`Model`, `Portal`, `Fallback`, `CustomPortals`) — set only by concrete subclass addons, no module owner. Declare them on a `---@class` block at the top of the base's `shared.lua`.
- **Trace tables.** `util.TraceHull` wants a `HullTrace` but the analyzer can't infer that from a plain `td = {}` built incrementally. Annotate functions returning a trace with `---@return HullTrace` and put a `--[[@as HullTrace]]` cast on the return statement (see `sh_handleplayers.lua` `GetStuckTrace`). For inline-built traces, cast at the call site: `util.TraceHull(td --[[@as HullTrace]])`.
- **`assert(FindMetaTable("Entity"))`.** The stub returns `Entity?` but the built-in metatable always exists. `assert` narrows the type and is runtime-correct since failure would be catastrophic anyway.
- **`.luatypes/`** — local LuaLS workspace stubs, picked up by `.luarc.json` `workspace.library`.
  - `glua_overrides.lua` aliases the integer enums (`MASK`, `COLLISION_GROUP`, `_USE`, `FCVAR`) — glua-api-snippets ships them as string-literal unions, which breaks assignments like `td.mask = MASK_PLAYERSOLID`. Also declares a `CreateConVar` overload accepting `string|number` for the default value (the stub is overly strict).
  - `cppi.lua` declares Falco's optional CPPI library (`CPPI` table + `Entity:CPPISetOwner`).
- **vON** (`lua/doors/libraries/libraries/sh_von.lua`) carries a file-level `---@diagnostic disable` because it's third-party and we don't touch it. Same pattern for any future vendored library.

There is intentionally **no `diagnostics.disable` block in `.luarc.json`** — every rule earns its keep. Prefer code-level fixes or targeted annotations over global suppression. If a rule starts producing pure noise the underscore convention can't fix, that's the time to revisit.

### Claude Code LSP integration (`glua-lsp` plugin)

Diagnostics, hover, and jump-to-definition are provided via the [`glua-lsp` plugin](https://github.com/AmyJeanes/gmod-claude-plugins) (marketplace: `AmyJeanes/gmod-claude-plugins`). The plugin wraps the [`glua_ls`](https://github.com/Pollux12/gmod-glua-ls) language server — same EmmyLua-Analyzer-Rust engine as `glua_check`, just running long-lived. Diagnostics arrive automatically after every edit; no hook involvement.

`.claude/settings.json` declares `extraKnownMarketplaces` so contributors get prompted to install the plugin on first open. The plugin auto-resolves `glua_ls` from each project's `.tools/bin/` at LSP launch, so the binary is provided per-repo by `scripts/install-tools.ps1` rather than installed globally.

#### First-time setup (do this before doing other work)

`scripts/install-tools.ps1` is the single source of truth for `glua_check`, `glua_ls`, and the GLua API stubs. Versions are pinned at the top of the script and shared with CI, so local and CI run the exact same engine.

In a fresh clone, run it once before touching `.lua` files:

```bash
pwsh -File scripts/install-tools.ps1
```

It is idempotent — re-running is a no-op when the pinned versions are already present, so it's also the recovery path when LSP diagnostics look wrong. After a fresh install just `/reload-plugins` so Claude Code re-launches the LSP against the new binary.

To bump a version: edit the `$GluaLsVersion` / `$GluaApiVersion` constants in `scripts/install-tools.ps1`, commit, and CI + every fresh clone picks it up. Renovate (`.github/renovate.json` customManagers) also raises bump PRs automatically, gated by the GLua Check CI job.

The `glua-lsp:install-glua-ls` skill covers the same recovery flow if symptoms appear later. Treat reported diagnostics as actionable only if the edit caused them — pre-existing noise on unrelated lines is not in scope for the current change.

#### Workspace-wide scans with `glua_check`

`glua_ls` only analyzes files as they are opened/edited. To audit the whole repo at once, use `scripts/glua-check.ps1` — it installs the pinned tooling on demand (no-op when present) and runs `glua_check --warnings-as-errors` against the repo. CI calls the same script.

```bash
pwsh -File scripts/glua-check.ps1                 # whole repo
pwsh -File scripts/glua-check.ps1 lua/doors        # scoped path
```

Useful when a fix has rippled across the codebase or when picking up the project to find latent issues the LSP hasn't surfaced yet.
