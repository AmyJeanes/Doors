# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Garry's Mod (Lua) addon that provides a **framework** for "TARDIS-style" doors: a small exterior entity that, when entered, teleports players through a `linked_portal_door` to a much larger interior spawned far away on the map. The repository lives in-place inside `garrysmod/addons/Doors`; there is no compile/build step locally.

This repo only contains the base entities and shared infrastructure. Concrete doors (with models, portal geometry, fallback positions, etc.) are shipped as **separate dependent addons** that base their entities on `gmod_door_exterior` / `gmod_door_interior` and contribute behaviour by registering hooks on those bases.

**Hard runtime dependency:** `AmyJeanes/world-portals` (the `wp.*` API + `linked_portal_door` entity). Without it the addon errors at runtime — it is checked out alongside this repo in CI and combined into a single Workshop upload.

## Build / publish

There is no local build, lint or test command. GMod loads the `lua/` tree at server start.

Publishing is CI-only, via the shared `gmod-addon-tools` `publish-workshop.yml` (SteamCMD + fastgmad), which combines this repo and `world-portals` into one `.gma` — world-portals first, then this repo on top, so **same-path files here win**. Two channels:

- **Beta** (push to `main`) — `ci.yml` bundles `Doors@main` + `world-portals@main` and publishes the beta item silently. A world-portals `main` push auto-triggers it too.
- **Stable** (a full GitHub *release* on either repo) — `release.yml` resolves the **latest release** of both Doors and world-portals, bundles each at its tag, and publishes the stable item (phone-gated). Trigger-agnostic: either repo's release reruns the same resolve (world-portals dispatches this workflow). Write a `## Summary` in the release body — its first paragraph becomes the Steam change note (plain prose; Steam is BBCode, not Markdown); version links are automatic. The `LAST_STABLE_PAIR` repo variable guards against re-shipping the same tag pair.

When verifying CI changes, remember the combine step means **paths here collide with `world-portals`** — files with the same path in this repo win.

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

Every world-portals callback (`wp-shouldtp`, `wp-shouldrender`, `wp-predraw`, `wp-postdraw`, `wp-prerender`, `wp-postrender`, `wp-trace`, `wp-tracefilter`, `wp-teleport`, `wp-allowthickportal`, `wp-shouldghostdraw`, `wp-nocollide`) is forwarded into a per-entity hook (`ShouldTeleportPortal`, `ShouldRenderPortal`, `NoCollidePortal`, …). Modules customise rendering / teleport behaviour by registering on those.

The interior's `ShouldRenderPortal` gates its own child portals (custom / false-world) by render direction, reading the scan-phase `wp.renderparent` (the draw-phase `wp.drawingent` is nil when the decision is made and cached): **hidden** while filling its interior door (`rp == self.portals.interior` - the looking-out view is the outside world, so the interior's portals don't belong in it); **shown** while filling its exterior door (`rp == self.portals.exterior` - a false world is a portal nested in the regular portal, so it must render for anyone looking *in*, occupant or not); otherwise **inside-only** (`not self:LocalPlayerInside() → hide` - recursive: the occupant or anyone standing in a TARDIS nested inside this one at any depth), so the interior's portals never appear standalone in the open world. This mirrors `ShouldDraw` (interior world) and the cordon (props), completing the set.

`wp-shouldghostdraw(sourceEnt, ghostEnt, portal, exit)` is routed (in `sh_portals.lua`) by the **emerged half's host** — `exit:GetParent()` — to a `ShouldDrawGhost` ENT hook. World-portals draws a prop straddling a portal as two clipped halves (real entry-half + a clientside ghost of the emerged half at `exit`), and fires this per render pass so consumers can suppress the ghost in passes where its location is hidden. A prop entering through the exterior portal has its emerged half at the interior portal (inside the skybox-parked interior); `gmod_door_interior`'s `ShouldDrawGhost` (in `sh_handleplayers.lua`, next to the interior's own `ShouldDraw`) returns `false` to skip drawing it unless the interior itself is currently visible — it just mirrors `self:CallHook("ShouldDraw")`, so it tracks "through the door or while inside" for Doors and TARDIS alike. This is a draw-time skip on a model world-portals owns; it is **not** the cordon's `RenderOverride` gate (which hides the engine-native interior props themselves).

The `wp-shouldtp` and `wp-teleport` registrations are **shared-realm** (outside any `if SERVER` block). World-portals' predicted-player teleport in `SetupMove` fires both hooks on the client (LocalPlayer) and on the server, so the registration has to exist in both realms. On the client `wp-teleport` fires on **every prediction pass — first-time AND resim** (see the resim-safety note under "Stuck handling" below), so every `PostTeleportPortal` handler must be idempotent and resim-safe. Inner `ShouldTeleportPortal` veto chains stay server-only (the client's `CallHook` returns nil → no veto); the `PostTeleportPortal` chains that intentionally predict client-side use the `"predict"` handlers, which are written position-only / idempotent for exactly this reason. The server stays authoritative.

### Cordon (`sh_cordon.lua`)

The interior is spawned far enough from anything to be empty, but other props can drift in. The cordon system:

- On client, every second `UpdateCordon` finds entities inside the interior's OBB (defaults to `OBBMins/Maxs * 0.95`, can be overridden by `self.mins`/`self.maxs`). Each captured prop gets a per-entity `RenderOverride` (`cordonShouldDraw`) deriving visibility fresh per render pass: hidden in the open world from outside, shown inside, shown looking through the exterior door, hidden looking out the interior door. The `Cordon` hook lets a module veto a specific class/entity from being captured.
- On server, when the interior is removed, captured props are deleted unless `ShouldRemoveProp` returns false (in which case they are frozen via `DoorsPhysicsFrozen`).
- The gate shares the one `RenderOverride` slot with a prop's pre-existing override (chained as `base`, so another system's look survives) and world-portals' ghost clip. While `wp.IsGhosting(prop)` the cordon yields the slot to the ghost (which chains the gate via its own saved override); on leave it hands `base` back, or drops it into a ghost-owned slot for the ghost to re-capture next frame. A consumer rendering its own RT that must not contain interior props (the TARDIS scanner) sets `self.cordonhidden = true` for the duration; Doors stays unaware of what the RT is. Props are never `NoDraw`'d, so world-portals' ghost system treats them like any other prop - no opt-in hook needed.

Players track which interior they're "inside" client-side via `ply.doori`, set by the `Doors-EnterExit` net message in `sh_players.lua`. The interior's `ENT:LocalPlayerInside()` (`sh_handleplayers.lua`) is the single source of truth for "is the local player inside this interior" across every render/think/visibility gate (`ShouldDraw`, `ShouldThink`, `ShouldRenderPortal`, the cordon, plus TARDIS's `ShouldDraw` and interior-door auto-close). It's **recursive**: true for the occupant (`doori`) or anyone standing in a box nested inside this one at any depth, walking out each box's `insideof` chain (capped against a stale cycle) — so a TARDIS parked inside another (inside another…) renders and ticks correctly. TARDIS gates route through this Doors helper rather than `GetTardisData("interior")`; the two can briefly diverge in the predicted enter/exit window, the one place to watch for flicker.

### Player enter/exit (`sh_players.lua`, server side)

Entry path: `CanPlayerEnter` → record in `occupants` → broadcast `Doors-EnterExit` → if portals exist and this is **not** a portal-triggered entry (`notp` flag), teleport the player to the interior `Fallback` position with rotated eye angles (`wp.TransformPortalAngle`). If no interior, the player goes into `OBS_MODE_ROAMING` spectate.

Exit path mirrors it. The exit-without-interior branch does an ugly but necessary `Spectate(NONE) + Spawn() + restore weapons/ammo/health` because `Spectate` can't be left cleanly otherwise. Players exiting without an interior get a 1-second cooldown (`doors_cooldowncur`) to prevent immediate re-entry.

The interior `Fallback` position math is shared via `gmod_door_exterior` `ENT:ResolveFallbackPos(ply, exiting)` (`sh_players.lua`) — a **pure** position-only resolver (`LocalToWorld(Fallback.pos)` + roll-lift, no eye/velocity writes, no hooks). `PlayerEnter`/`PlayerExit` source their fallback position from it but keep their own `SetEyeAngles`/`SetLocalVelocity` for the legacy-door Use callers.

### Stuck handling / predicted unstick (`sh_handleplayers.lua`)

After a portal teleport a player can land embedded in geometry. `CheckPlayer` (server, driven by the `wp-teleport` hook) detects this with `IsStuck` and repositions via `ENT:ResolveSafePos(ply, exiting)` — a **pure** resolver: floor-snap within 10u, else `exterior:ResolveFallbackPos`. It is position-only (no eye writes) so it runs identically on the server and the **predicting client**: the client mirrors it in the `PostTeleportPortal "predict"` hooks (exit on the interior, entry on the exterior), and world-portals re-syncs `mv` from `ply:GetPos()` after `wp-teleport` so the relocation survives gamemovement and matches the prediction (no rubberband). It deliberately avoids the `PlayerEnter`/`PlayerExit` path, whose server-side `SetEyeAngles` reverts under prediction and whose entry/exit hooks would double-fire.

**Resim-safety (high-ping).** World-portals fires `wp-teleport` on the client on **every** prediction pass (first-time AND resim), and re-applies `ply:SetPos(newPos)` + the `mv` re-sync each pass too. This is required: at ~100ms `net_fakelag` the crossing command stays unacked — and so resimulated — for ~RTT, and the raw portal transform re-runs each resim. If the unstick only fired first-time-predicted, every resim left the player at the raw (embedded) pos until the server snapshot corrected them ~RTT later — the "stuck after teleport, fixed once the lag catches up" bug. Because `ResolveSafePos` is pure/deterministic/idempotent, re-running it each pass lands identically. The corollary: **anything registered on `PostTeleportPortal` (or `wp-teleport`) must be idempotent and resim-safe** — the existing handlers (unstick, cordon `UpdateCordon`, TARDIS data set/clear) all are; don't add sounds/effects/one-shot counters there.

The stuck-trace filter is built in `GetStuckTrace` from `{ply}` plus a shared `StuckFilter` hook (returns a table of networked entities to exclude — TARDIS contributes its interior door part). The hook is evaluated at trace time so the server and predicting client build identical filter membership; it must return only networked entities or the realms diverge. `StuckFilter` returns a value (not a veto), so the single owning consumer returns the whole list — don't register a second one that returns non-nil or it short-circuits the first.

### Other small but load-bearing pieces

- `lua/doors/sh_hooks.lua` monkey-patches `Entity.SetSkin` and `Entity.SetBodygroup` to fire gamemode hooks `SkinChanged` / `BodygroupChanged`, which are then forwarded to door entities' per-entity hook chains.
- `lua/doors/sh_owner.lua` (`Doors:SetupOwner`) sets `Creator` (with a client-side polyfill) and `CPPISetOwner` if Falco's CPPI is loaded; fires the `SetupOwner` hook (so a consumer can recurse owner setup into its own sub-entities) and recurses into `ent.interior`. Always use this rather than setting owner directly so prop-protection and the client-visible creator stay consistent.
- `lua/doors/libraries/libraries/sh_von.lua` is a vendored copy of vON 1.3.4 (table serialization) — leave it alone unless syncing with upstream Vercas/vON.
- Both base entities pick `base_wire_entity` if `WireLib` is loaded, otherwise `base_gmodentity`. The client `Draw` calls `Wire_Render(self)` only when WireLib exists.

## Conventions when adding code

- New behaviour goes in a new module file under the appropriate `modules/` directory with a `sh_/sv_/cl_` prefix — don't edit the base `shared.lua`/`init.lua`/`cl_init.lua` unless you're changing the framework itself.
- When adding a new hook name, document on the call site what `nil` vs a non-nil return means, since the first non-nil short-circuits. If you don't intend to veto, return nothing.
- If a new module needs per-player networked state, hook into `PlayerInitialize` (write side, server) and `PlayerInitialize` (read side, client) so you don't have to manage a separate net message lifecycle. Read order must match write order.
- When iterating `Doors:GetInteriors()` / `GetExteriors()` in a hook, always `IsValid` the key — entries are only removed via the `Doors:RemoveInterior/Exterior` calls in the `OnRemove` hook, which runs at end-of-frame.
- `addon.json` "ignore" already excludes `*.md`, so committing docs (including this file) is safe.

## API reference wiki (`scripts/generate-wiki-api.ps1`)

The type-reference pages in the sibling `Doors.wiki` repo are generated from the `---@class` / `---@field` annotations on the door base entities and portal contract tables. The door base entities keep their runtime `gmod_door_exterior` / `gmod_door_interior` names as their documented type names; only the non-entity contract structs use the public `doors_` prefix (`doors_portal_side`, `doors_custom_portal`). The shared `gmod-addon-tools` module owns the renderer; `scripts/generate-wiki-api.ps1` is a thin driver and `scripts/wiki-api.config.ps1` is the reusable category/owned-prefix config that lets other generated-wiki addons link these `gmod_door_` / `doors_` types automatically when this repo appears in their `.luarc.json` workspace libraries.

## Tooling

- `.luarc.json` configures sumneko-LuaLS with `./.tools/glua-api` (GLua type stubs) and `./.luatypes` (local override aliases) plus sibling addons (`../world-portals` is a hard dep; `../wire` is referenced behind `if WireLib then` guards). The recommended VS Code extension is `Pollux.gmod-glua-ls`.

### Type annotations

The analyzer (`glua_ls` / `glua_check`) understands `---@class`, `---@field`, `---@return`, and inline `--[[@as X]]` casts. Patterns that matter for this codebase:

- **Hook-set fields don't propagate.** Inside a hook callback (`ENT:AddHook("Initialize", "id", function(self) self.X = ... end)`), the analyzer doesn't follow `self` back to other functions on the entity, so `self.X` looks undefined elsewhere. Declare the field with a `---@class gmod_door_X` block (re-opening the entity class — e.g. `---@class gmod_door_interior` in `sh_cordon.lua`) at the top of the **module that owns it** — that's the cleanest place since multi-file `---@class` blocks merge automatically. Direct `function ENT:X()` body assignments propagate without annotation.
- **Don't use the `(partial)` modifier.** GLuaLS treats every class as implicitly partial; the modifier is redundant and trips other VS Code Lua parsers with a syntax-error squiggle.
- **Framework-contract fields** (`Model`, `Portal`, `Fallback`, `CustomPortals`) — set only by concrete subclass addons, no module owner. Declare them on a `---@class` block at the top of the base's `shared.lua`. The two base entity classes are declared `---@class gmod_door_exterior : Entity` / `---@class gmod_door_interior : Entity` — the folder-derived runtime names, which is what the analyzer infers `self` to be inside the entity code, so engine methods resolve. Their pairing cross-refs are declared with deliberate nullability: `interior` on the exterior is `gmod_door_interior?` (an exterior exists before — and can outlive — its interior), but `exterior` on the interior is non-nullable `gmod_door_exterior` (a live interior is *always* paired, set at spawn server-side and in the validated net handler client-side, and the pair mutually `DeleteOnRemove`s — so interior code dereferences `self.exterior` without a nil guard). `door` / `doori` on `Player` (in `sh_players.lua`) are `?`. Without these declarations the inferred field types don't carry `IsValid` narrowing (see the diagnostics note below).
- **Trace tables.** `util.TraceHull` wants a `HullTrace` but the analyzer can't infer that from a plain `td = {}` built incrementally. Annotate functions returning a trace with `---@return HullTrace` and put a `--[[@as HullTrace]]` cast on the return statement (see `sh_handleplayers.lua` `GetStuckTrace`). For inline-built traces, cast at the call site: `util.TraceHull(td --[[@as HullTrace]])`.
- **`assert(FindMetaTable("Entity"))`.** The stub returns `Entity?` but the built-in metatable always exists. `assert` narrows the type and is runtime-correct since failure would be catastrophic anyway.
- **`.luatypes/`** — local LuaLS workspace stubs, picked up by `.luarc.json` `workspace.library`.
  - `glua_overrides.lua` works around glua-api-snippets typing enum-parameter functions (`SetUseType`, `SetCollisionGroup`, …) with strict string-literal-union aliases (`_USE`, `COLLISION_GROUP`, `FCVAR`) while typing the matching constants as plain `integer`. Two fixes: it re-types each enum constant we actually pass (`SIMPLE_USE`, `COLLISION_GROUP_WORLD`, `FCVAR_*`) as its alias so `param-type-mismatch` sees a match (add a line when a new strictly-typed enum constant gets used — the LSP flags it the moment it does), and it widens `MASK` to `integer` for trace `.mask` field assignments like `td.mask = MASK_PLAYERSOLID`. Re-typing the constant beats re-aliasing the whole enum to `integer` because glua_ls 1.0.20+ no longer honours a duplicate `---@alias` override of a stub enum. Also declares a `CreateConVar` overload accepting `string|number` for the default value (the stub is overly strict).
  - `cppi.lua` declares Falco's optional CPPI library (`CPPI` table + `Entity:CPPISetOwner`).
- **vON** (`lua/doors/libraries/libraries/sh_von.lua`) carries a file-level `---@diagnostic disable` because it's third-party and we don't touch it. Same pattern for any future vendored library.

The `.luarc.json` `diagnostics.disable` block is **empty** — all three flow-analysis rules (`param-type-mismatch`, `unchecked-nil-access`, `need-check-nil`) are enforced. `param-type-mismatch` is satisfied by the enum-constant re-typing in `glua_overrides.lua` (above). The two nil rules are satisfied by giving the framework's dynamic data real types: the `: Entity` base on both door classes, the cross-ref fields (`interior` / `exterior`, plus `door` / `doori` on `Player`), the config-table shape classes, and the hook-set fields. `IsValid()` *does* narrow for glua_ls (a plain `if IsValid(x) then x:m() end` is clean); the old false positives came from those values being *inferred* from scattered `x = nil` / `x = ents.Create(...)` assignments rather than declared, and inferred cross-file types don't carry the narrowing.

`need-check-nil` is the strictest of the three — it flags any deref/index/call of a possibly-nil value, so keeping it green relies on a few techniques (grep the tree for live examples):

- **Type the hook-callback `self`.** `AddHook`'s `func` param is annotated `fun(self: gmod_door_X, ...): any?` so engine methods (`self:LocalToWorld`) resolve inside callbacks instead of reading as possibly-nil.
- **Hook-callback *payload* params are typed by a generated overload catalogue.** The `---@overload` block above each base's `ENT:AddHook` (in `shared.lua`) is **generated** — `scripts/generate-hook-types.ps1` scrapes every `CallHook("Name", ...)` site, resolves the payload types, and injects one literal-string overload per hook, so `ENT:AddHook("PlayerEnter", "id", function(self, ply) ... end)` types `ply` as `Player` with no manual `---@param`. Do **not** hand-edit the block (CI `generate-hook-types.yml` rewrites it on push, and a local run is `scripts/generate-hook-types.ps1`); to add or fix a payload type, retype it at the `CallHook` call site. Where the scraper can't resolve an arg (a method-call or loop-var payload, e.g. `Cordon`) it falls to `any` — keep a manual `---@param` on that specific callback if a concrete type matters.
- **Declare the config-table shapes.** `doors_portal_side` / `doors_custom_portal` (top of `sh_portals.lua`) type the `Portal` / `CustomPortals` / `FalseWorldWindows` framework-contract tables; the always-present fields (`pos` / `ang` / `width` / `height`) are non-optional so direct access is clean (declared non-optional fields *are* honoured — they are not implicitly nilable).
- **`---@cast` the `pairs` value.** glua_ls has a narrowing bug where a field of a `pairs`-iterated `table<K,V>` loop variable reads as nilable inside *inline* conditional bodies, despite the field being declared non-optional and the table being fully typed (the value is already the right class — the cast just resets the buggy narrowing, it adds no type info). `---@cast v doors_custom_portal` at the top of the loop clears it. The only cast-free alternative is extracting the loop body into a helper with a `---@param v doors_custom_portal` (a typed *parameter* narrows correctly where an inline loop variable doesn't) — not worth it for the large `CustomPortals` body, so the cast stays. Note `local entry = v.entry` is *not* a fix — the bind itself is typed nilable, making it worse.
- **Avoid `if not (a and b)`.** A negated *parenthesized* compound doesn't narrow `a` / `b`; write `if not a or not b then return end` (De Morgan) — that form narrows.
- **`---@cast self.field` for invariants.** Where a nilable field is guaranteed live by an invariant the analyzer can't see (e.g. `self.interior` immediately after it is spawned in `sh_interior.lua`), a one-line `---@cast self.interior gmod_door_interior` clears the whole cluster without a runtime branch; where a guard is cheap and defensive instead (a live interior always has an exterior), prefer `if not IsValid(x) then return end`.

<!-- >>> GENERATED shared conventions (gmod-addon-tools) - do not edit; regen: scripts/generate-claude-md.ps1 >>> -->

_Shared conventions for my GMod addons - generated from [`gmod-addon-tools/docs/gmod-addon-conventions.md`](https://github.com/AmyJeanes/gmod-addon-tools/blob/main/docs/gmod-addon-conventions.md). Edit it there, not in this file; the block below is overwritten by CI. Addon-specific guidance lives outside the markers._

## Code style

- **Pure Lua syntax only - no GMod-Lua extensions.** No `//` comments, no `continue`, no `!=`, no `&&`/`||`. Use `--`, `goto continue`, `~=`, `and`/`or`.
- **Comments: concise, the _why_ not the _what_.** A couple of lines at most; reserve length for genuinely non-obvious rationale and bias toward cutting - match the surrounding density, don't pad to essay length. Don't restate the code, don't explain it by what it replaced, and keep the _why_ self-contained (no pointers to external docs or fragile cross-file references). Keep comments ASCII: `->` not an arrow, a single spaced hyphen for a dash (never a double `--`, which reads as a second comment marker, nor an em-dash).
- **Drop the loop variable you don't use** rather than naming it: `for _, v in pairs(t)`, `for k in pairs(t)`, `for _ = 1, n do`. The `unused` lint is on - keep the noise floor at zero.
- **Every `---@diagnostic disable` needs a paired reason** on the same or preceding line naming _why_ the rule is suppressed. The default is to fix the issue, not suppress it.

## First-time setup (before touching `.lua` files)

The tooling (`glua_check`, `glua_ls`, the GLua API stubs, and the wiki/typing type-model) is provisioned by the shared [`gmod-addon-tools`](https://github.com/AmyJeanes/gmod-addon-tools) module, cloned **beside this addon**. `scripts/install-tools.ps1` is a thin wrapper - `scripts/bootstrap.ps1` resolves the sibling module and it calls `Initialize-GmodTools`, so the version pins live once in the module and every addon runs the exact same engine.

```bash
git clone https://github.com/AmyJeanes/gmod-addon-tools ../gmod-addon-tools
pwsh -File scripts/install-tools.ps1
```

It is idempotent - re-running is a no-op when the pinned versions are already present, so it is also the recovery path when diagnostics look wrong. After a fresh install, run `/reload-plugins` so Claude Code re-launches the LSP against the new binary.

## Claude Code LSP integration (`glua-lsp` plugin)

Diagnostics, hover, and jump-to-definition come from the [`glua-lsp` plugin](https://github.com/AmyJeanes/gmod-claude-plugins) (marketplace `AmyJeanes/gmod-claude-plugins`), which wraps the [`glua_ls`](https://github.com/Pollux12/gmod-glua-ls) server - the same EmmyLua-Analyzer-Rust engine as `glua_check`, running long-lived. Diagnostics arrive automatically after every edit; no hook involvement. `.claude/settings.json` declares the marketplace so contributors get prompted to install on first open, and the plugin auto-resolves `glua_ls` from this project's `.tools/bin/` at launch (no global install, no PATH plumbing). The `glua-lsp:install-glua-ls` skill covers the same recovery flow if symptoms appear later. Treat reported diagnostics as actionable only if your edit caused them - pre-existing noise on unrelated lines is not in scope for the current change.

## Whole-repo scans (`scripts/glua-check.ps1`)

`glua_ls` only analyzes files as they are opened or edited. To audit the whole repo at once, run `pwsh -File scripts/glua-check.ps1` - it provisions tooling on demand (no-op when present) and runs `glua_check --warnings-as-errors` against the workspace root. It takes no path filter, so it always scans everything; CI runs the same script. Useful after a fix ripples across the tree, or when picking the project up to surface latent issues the LSP hasn't opened yet.

## Typing enforcement (`scripts/typing-check.ps1`)

`glua_check` catches _wrong_ types but not _missing_ ones - an untyped param is a silent `any` it never flags. `Test-GmodTyping` (CI: `typing-check.yml`) closes that gap, failing the build on any of: an untyped param, annotation rot (a `---@param` for a param that no longer exists), a modeled function whose resolved return type contains `unknown`, a hook fire-site argument that resolves to `unknown`, or a `:CallHook`-style hook whose receiver resolves to `unknown` (so its "Fired on" column would render _Unknown_ - usually fixed with a `---@param self <class>` on the enclosing function). Satisfy it at the **source** - prefer a `---@param` / `---@return` / `---@class` annotation over a per-callsite `---@cast`, since annotations propagate to every caller. The only accepted escapes are explicit and greppable: `---@param x any` (a reviewed, genuine `any`), an `_` discard for a deliberately-unused arg, and a file-level `---@vendored` marker on third-party code.

Where an addon fires its own hooks, callback payload params are typed by a generated `---@overload` catalogue (`scripts/generate-hook-types.ps1`, CI: `generate-hook-types.yml`) - do not hand-edit it; retype a payload at its `CallHook` / `hook.Run` site instead. Custom global-hook overloads are spliced into the provisioned `hook.lua` by `Initialize-GmodTools`, so after pulling a change to a generated fragment mid-session, re-run `scripts/install-tools.ps1` (it re-syncs) then `/reload-plugins` to refresh live types.

## Bumping the shared tooling

Tool versions and this conventions block are pinned to a `gmod-addon-tools` tag. Bump the version constants in `gmod-addon-tools/src/install.ps1` (or edit the shared docs); merging to the module's `main` auto-cuts a new tag, and Renovate then raises a pin-bump PR here that regenerates the affected artifacts and runs GLua Check before it merges. CI pins the module by tag (the `ref:` in each workflow); a local sibling checkout uses whatever branch it is on, so keep it on the pinned tag to mirror CI exactly.

<!-- <<< END GENERATED shared conventions <<< -->
