# Holo Table — Conversation Handoff

Drop this in front of a fresh agent so it can pick up where the previous
session left off. `DESIGN.md` is the canonical reference for *why* the
code looks the way it does; this file is just the working state.

## Project

Garry's Mod addon (`addons/holo_table`) — a "war room" holographic table
entity that renders a miniature 3D view of the current map at the table
top. Map geometry is pulled from `bsp2` (required dep). Worldspawn is
software-clipped against a 32-sided cylinder; brush entities, static
props, radar markers, and players are GPU-clipped via a 5-sided prism +
floor plane (the engine's 6-plane clip budget).

## File layout

- `lua/entities/holo_table_3d/shared.lua` — `ENT.Type/Base`, metadata,
  `SetupDataTables` (NetworkVars: `Entities` Bool0, `Map` Bool1,
  `Height` Float0, `Scale` Float1, `PanX` Float2, `PanY` Float3).
- `lua/entities/holo_table_3d/init.lua` — server `Initialize` (sets
  `SIMPLE_USE`), `ENT:Use`/`ReleaseController`/`OnRemove` ownership
  handling, `PlayerDisconnected` cleanup, net receivers for
  `holo_table_autocenter` / `holo_table_setparams` /
  `holo_table_setlayers` / `holo_table_release` (all ownership-gated
  and clamped to the NetworkVar limits), and `AddCSLuaFile` for every
  client component including a loop over `radar/*.lua`.
- `lua/entities/holo_table_3d/cl_init.lua` — slim coordinator (~375
  lines). `ENT:Initialize`/`Think`/`OnRemove` delegate to the
  per-subsystem hooks (`InitializeMap` / `InitializeRadar` / etc.).
  Owns `ENT:Draw` (just `DrawModel` so halo.Render works) and
  `ENT:DrawHologram` (stencil + GPU clip prism setup, scene matrix
  push, async-build kick), plus the
  `PostDrawTranslucentRenderables` dispatch hook. `include`s
  `sh_controls.lua`, `cl_map.lua`, `cl_radar.lua` at the top.
- `lua/entities/holo_table_3d/cl_map.lua` — map subsystem. Software
  clipper (`BuildClippedMap`), brush-mesh cache, prop bounds/csent
  cache, async build pipeline (`StartClippedBuild` /
  `TickClippedBuild` / `CommitClippedBuild` / `DestroyPendingBuild` /
  `DestroyClippedMap` + the all-in invariance cache), static-prop and
  `prop_dynamic` map-dressing bake/fallback paths, the per-frame draw
  entry points (`DrawMap`, `DrawClippedMap`, `DrawBrushEntities`,
  `DrawStaticProps`, `DrawBakedStaticProps`, `DrawDynamicProps`,
  `DrawBakedDynamicProps`), `ComputeAutoCenter`, and the
  `holo_table_profile` concommand with its own `findAutoCenterTarget`
  helper. Lifecycle hooks `ENT:InitializeMap` / `CleanupMap`.
- `lua/entities/holo_table_3d/cl_radar.lua` — radar subsystem.
  Module loader (`file.Find('entities/holo_table_3d/radar/*.lua')`),
  `RadarBase` with `GetEntity` / `GetScale` (returns the *inverse*
  scale) / `GetOrigin` / `GetAngles` / `Project`, and ENT hooks
  `InitializeRadar` / `ThinkRadar` / `DrawRadar` / `CleanupRadar`.
  `DrawRadar` stages the BSP→world transform on `self._radar*` fields
  once per frame so each module's `Draw` can `Project` cheaply.
- `lua/entities/holo_table_3d/radar/*.lua` — one file per tracked
  entity kind. Defines a `RADAR` table populated with any subset of
  `Initialize` / `Think` / `Draw` / `OnRemove`; the loader sets
  `RADAR` as a global with `__index = RadarBase` for the duration of
  the include, so the module sees the base accessors via `self:`.
  Currently: `lvs.lua` (LVS vehicles, team-tinted csent ghosts),
  `other_vehicle.lua` (LFS / SW vehicles, red marker spheres),
  `player.lua` (red sphere per live player). `prop_dynamic.lua` is now
  a stub only; map-owned `prop_dynamic` dressing lives in `cl_map.lua`.
- `lua/entities/holo_table_3d/sh_controls.lua` — interactive control
  layer: `+use`-toggled grab, `CreateMove`-driven WASD pan / wheel
  height / `+speed`+wheel zoom / `+reload` recenter / `+duck`
  precision modifier / T entities / G map, throttled `setparams`
  send, immediate `setlayers` / `autocenter` send, HUD overlay with
  dynamic key labels via `input.LookupBinding`, `holo_table_release`
  and `holo_table_autocenter` concommands.
- `DESIGN.md` — design decisions, alternatives considered/rejected,
  deferred-work list. **Read this before changing anything non-trivial.**
- The old monolithic `lua/entities/holo_table_3d.lua` was deleted;
  the folder split happened well before the radar/map extraction.

## Recent work history

1. Async coroutine build (4 ms / frame budget, `CLIP_FRAME_BUDGET`).
2. "All-in" cache (`AllInMeshes`) for cylinders that fully contain the
   map AABB; same-config and partial→all-in transitions short-circuit.
3. Pinned-pivot scaling — table BSP altitude is the scale fixed point.
4. Pan (`PanX`/`PanY`) shifts cylinder center in BSP space; auto-center
   command fits the AABB and networks the result back to the server.
5. Sutherland–Hodgman trivial-accept/reject + shared distance scratch
   (`clipDistScratch`).
6. Per-wall-plane sphere skip in the slow path (project face sphere onto
   `(right, fwd)` basis once, skip planes whose half-space contains it).
7. Per-face cull cache `face._holoCull = {cx, cy, cz, fr}` (scalars, not
   Vector — old `{vec, fr}` shape rebuilt by `not cull.cx` check).
8. Per-face triangulation cache `face._holoTris = {matKey, mat, tris,
   triCount, lastGroups, lastGroup}` for fully-interior faces. Fast path
   is now: lookup → `table.move(tris, 1, triCount, #verts+1, verts)`.
9. Scalarised per-face cull math (basis vectors unpacked into x/y/z
   locals, no `:Dot`/`:Length` in the hot loop, squared distance compares).
10. Monolithic file split into the standard GMod
    `shared.lua`/`init.lua`/`cl_init.lua` folder layout. Behaviour
    unchanged. `DESIGN.md` updated to match.
11. `matByTexinfo` lookup hoisted to a file-scope cache keyed by
    `mi.materials` table identity. The rebuild loop was running per
    `BuildClippedMap` call and on Venator (5934 materials) cost
    ~230 ms — invisible in the fast-path microbench but obvious in
    real timings. Same fix applied to `GetBrushModelMeshes`.
    Auto-invalidates when bsp2 swaps the materials list.
12. Tracked-entity rendering ("radar system"). Originally a single
    monolithic ghost system in `cl_init.lua`; now split into
    `cl_radar.lua` (registry + `RadarBase` + ENT lifecycle hooks)
    and one file per kind in `radar/`. The base provides
    `GetEntity` / `GetScale` (inverse) / `GetOrigin` / `GetAngles` /
    `Project(pos, ang)`; modules define any subset of
    `Initialize` / `Think` / `Draw` / `OnRemove`. Current modules:
    `lvs.lua` (csent ghosts, team-tinted via file-local `tintFor`),
    `other_vehicle.lua` (LFS / SW vehicles, red marker spheres),
    `player.lua` (red sphere per live player). `prop_dynamic.lua`
    later became a stub; map dressing moved to `cl_map.lua`.
    Model-based drawers still need to run outside the `m2` matrix
    block because `Entity:DrawModel` ignores `cam.PushModelMatrix`;
    `ENT:DrawRadar` stages the BSP→world transform on `self._radar*`
    so each module can `Project` cheaply without recomputing.
13. Material loading robustness:
    - `loadTexdataMaterial(name)` strips a stray leading `/` from
      BSP texdata paths (e.g. `/FIRSTORDERBANNER`) which would
      otherwise return the error material and get filtered out,
      silently hiding banner / flag faces.
    - `unlitWrap(src)` builds a `UnlitGeneric` material around
      `src`'s `$basetexture` for use when the bsp2 anonymous fallback
      for a texinfo carries the error texture (typically because the
      same malformed path defeated bsp2). Cached per basetexture name.
    - `resolveMat(tinfo)` for `LightmappedGeneric` faces prefers
      bsp2's per-texinfo `UnlitGeneric` fallback unless its
      `$basetexture` is in the filter set (`error` / `color/white`),
      in which case it wraps the corrected `Material()` result via
      `unlitWrap`. Same logic applied in `GetBrushModelMeshes`.
14. Experimented with duplicate-reversed-winding geometry on
    `unlitWrap`-ed faces to make single-quad map dressing visible from
    both sides without the `$nocull` mirrored-overlay artifact. Tried
    with and without a 0.1-unit `+normal` offset to dodge z-fighting
    against pre-existing BSP back faces on thin-brush flags. Net
    result was worse: thin brushes z-fought into translucent splotches
    across the rest of the mesh, and the originally-invisible flags
    were genuinely occluded by ship interior walls and would never
    have been visible from outside anyway. **All double-sided code
    reverted.** Flags now render only from their BSP-defined side,
    same as the actual map. See "Rejected: double-sided dressing"
    in `DESIGN.md`.
15. Interactive control layer (`sh_controls.lua`). Replaces slider-
    only adjustment with `+use`-toggled grab on the table:
    - Server flips `SIMPLE_USE` so a single E press toggles cleanly
      (default base_anim continuous-while-held caused flicker).
    - Server tracks `ent.Controller`; new controller request locks
      out other players until release / disconnect / `OnRemove`.
    - Client polls `cmd:KeyDown(IN_FORWARD/BACK/MOVELEFT/MOVERIGHT)`
      for pan and `IN_SPEED` for zoom modifier (so user binds work).
      `+reload` is polled raw via `input.LookupBinding`+`IsKeyDown`
      because we suppress it in `PlayerBindPress` to silence the
      weapon reload — that suppression also kills the `IN_RELOAD`
      cmd bit, so `cmd:KeyDown(IN_RELOAD)` doesn't fire. `+duck`
      precision modifier is captured *before* `RemoveKey(IN_DUCK)`
      scrubs it. T / G layer toggles are raw-keyed (no
      `+something` binding to look up); `messagemode` and
      `+menu_context` get swallowed in `PlayerBindPress` so they
      don't fight the toggles.
    - Optimistic local NetworkVar writes for zero-latency feedback;
      throttled (33 Hz / `SEND_INTERVAL`) `holo_table_setparams`
      send for pan / scale / height. `holo_table_setlayers` and
      `holo_table_autocenter` ship immediately on the edge.
    - HUD displays bound keys via `input.LookupBinding` so it
      auto-updates when the player rebinds (`WASD`/`SHIFT`/`R`/`E`
      become whatever they actually have). T / G are static labels
      since they're not bound to a `+command`.
    - `holo_table_autocenter` concommand lives in `sh_controls.lua`
      so it can share `findControlTarget` (prefers the actively-
      controlled table) with the `+reload` hotkey.
      `holo_table_profile` lives in `cl_map.lua` with its own
      `findAutoCenterTarget` (crosshair → nearest); the duplication
      is intentional — the dev tool stays decoupled from the control
      module.
16. `cl_init.lua` modularisation. Extracted the radar/ghost system into
    `cl_radar.lua` + `radar/*.lua` modules (entity-style hooks
    `InitializeRadar` / `ThinkRadar` / `DrawRadar` / `CleanupRadar`),
    and the entire map subsystem (clipper, brush mesh cache, prop
    cache, async build pipeline, draw entry points, `ComputeAutoCenter`,
    `holo_table_profile`) into `cl_map.lua` (hooks `InitializeMap` /
    `CleanupMap`). `cl_init.lua` is now ~375 lines and only owns
    lifecycle dispatch, `Draw` (just `DrawModel`), and `DrawHologram`
    (stencil + GPU clip prism setup, scene matrix push, async-build
    kick) plus the `PostDrawTranslucentRenderables` hook that drives
    it.
17. Static BSP prop mesh bake. The old per-frame `DrawStaticProps`
    path was drawing ~1,100 `ClientsideModel:DrawModel()` calls/frame
    on Venator all-in views (~1.7 ms/frame), and zoomed Venator views
    later measured ~2.9 ms/frame in the same fallback. `cl_map.lua`
    now builds a shared, scale-specific, async IMesh bake from
    `bsp.props` via `util.GetModelMeshes(model, 0, 0, skin)`,
    transforms vertices once into BSP space, groups/chunks by material,
    and draws the baked meshes inside the existing `m2` holo matrix.
    The default `holo_table_staticprop_bake_mode 3` keeps this global
    bake active for zoomed/partial views and lets the existing GPU clip
    prism trim it. Mode `1` restores the older all-in-only bake, mode
    `2` is the per-prop baked-cull experiment, mode `0` is legacy.
18. Targeted hot-global localization in `cl_map.lua` (`SysTime`,
    `Vector`, `Material`, `Mesh`, `bit.band`, `table.move`, selected
    `math.*`, `coroutine.*`, `hook.Add/Remove`, `render.SetMaterial`).
    This is a micro-optimization, not a new architecture; measured
    live draw samples improved by roughly 0.1 ms/frame but build
    profiles remain IMesh-bound.
19. `prop_dynamic` map dressing moved out of radar. The radar module is
    now a stub so loader/AddCSLuaFile behaviour stays stable, while
    `cl_map.lua` owns `prop_dynamic` as map dressing: an async baked
    IMesh path for horizontally all-in views, a 1-second watcher that
    detects added/removed/moved/reskinned props and rebuilds, and a
    legacy per-table csent fallback for disabled bake, rebuild windows,
    partial views, or individual moving/rotating props. Venator's
    moving `hypertunnel.mdl` exposed why movers must be excluded from
    the bake instead of forcing a rebuild every watcher tick. Toggle
    with `holo_table_dynamicprop_bake`.
20. Static prop zoom bake experiments. Per-prop baked culling worked but
    was still too expensive on a zoomed Venator view because it drew
    ~1,800 visible props / ~3,400 meshes; `DrawBakedStaticProps` was
    ~2.0 ms/frame. Forcing the global bake through the existing GPU clip
    prism dropped the same zoomed view to `DrawBakedStaticProps`
    ~0.085 ms/frame and `DrawHologram` ~0.35-0.45 ms/frame, with
    legacy `DrawStaticProps` at 0 calls.
21. Post-bake live timings on the current Venator-like test scene:
    static prop bake ready at 1057 / 2256 props, 286 meshes,
    3,208,512 verts; `prop_dynamic` bake ready at 81 props, 14 meshes,
    74,550 verts. Representative all-in frame samples:
    all-in `DrawHologram` ~0.8-1.1 ms/frame, `DrawBakedStaticProps`
    ~0.17-0.25 ms, `DrawBakedDynamicProps` ~0.02-0.05 ms,
    `DrawRadar` ~0.08 ms after `prop_dynamic` removal from radar.

## Profiling baselines

`holo_table_profile` (synchronous, no coroutine yields, no debounce).
Always run twice — cold (after wiping `_holoCull`/`_holoTris`) and
warm (steady-state).

**rp_venator_extensive_v1_4** (~24 k worldspawn faces, 495 brush
models, 2154 props), all-in framing (scale ≈ 263):

- Pre-optimisation: ~545 ms total.
- After per-face triangulation cache: ~263 ms total (clip 190).
- After scalarised cull math + `table.move` splice: ~322 ms steady
  (clip 245, imesh 77) — the gap vs the earlier 178 ms turned out
  to be variance from the matByTexinfo rebuild, not a regression.
- After matByTexinfo cache: **~95 ms warm** (clip 13, imesh 82),
  ~398 ms cold (face caches empty, materials warm). First-ever
  build on a fresh map adds ~230 ms one-time for the materials
  cache populate.
- Tight framing (scale 40): ~8.5 ms (clip 7.7, imesh 0.5),
  21097 / 21257 sphere-rejected, 84% wall-plane skip.

**rp_finalizer** (~26 k worldspawn faces, 121 brush models, 15
props), all-in framing (scale ≈ 255), measured *before* the
matByTexinfo fix but its material count is small enough that the
rebuild was already cheap there:

- ~196 ms cold, ~96 ms warm (clip 18, imesh 78). Steady state is
  imesh-bound. After the matByTexinfo fix this should be the same
  or marginally faster.
- Tight framing (scale 40): 13.5 ms (clip 12.6, imesh 0.9),
  23678 / 23951 sphere-rejected, 76% wall-plane skip.

**gm_flatgrass** (~1.7 k faces): 5–15 ms warm/cold across all
framings. Trivial.

Take-away: imesh phase (~1.2 µs/tri in `Mesh:BuildFromTriangles`) is
now the dominant cost on every all-in framing. Further wins require
either avoiding the rebuild entirely (semi all-in cache) or skipping
faces (more aggressive culling).

**Post-bake frame-time notes** (same Venator-like all-in scene, one
visible table, scale 270):

- Before static-prop bake: `DrawHologram` ~2.5 ms/frame,
  `DrawStaticProps` ~1.7 ms/frame, `DrawRadar` ~0.36 ms/frame.
- After static-prop bake mode `1`: `DrawHologram` ~1.0 ms/frame,
  `DrawBakedStaticProps` ~0.18 ms/frame, legacy `DrawStaticProps`
  0 calls in all-in views.
- After moving `prop_dynamic` to map-owned bake: `DrawRadar` ~0.08
  ms/frame, `DrawBakedDynamicProps` ~0.02-0.05 ms/frame.
- Zoomed Venator view before mode `3`: `DrawHologram` ~3.46 ms/frame,
  `DrawStaticProps` ~2.86 ms/frame.
- Same zoom with `holo_table_staticprop_bake_mode 3`:
  `DrawHologram` ~0.35-0.45 ms/frame, `DrawBakedStaticProps`
  ~0.085 ms/frame, legacy `DrawStaticProps` 0 calls.
- `PostDrawTranslucentRenderables` dispatch still shows in profilers,
  but recent fprofiler output was ~246 ms over 10 seconds (~0.17
  ms/frame at ~147 calls/sec), so it is not currently the main target.

## Open questions / next steps

Current likely next work:

1. **Translucent / alpha-tested materials.** Glass windows, fences,
   grates and similar `$translucent` / `$alphatest` faces currently
   render as opaque black (or are filtered out entirely) because the
   build emits everything in one opaque pass. Needs a second pass that
   collects translucent-shader mats into their own group list, draws
   them after the opaque pass, and probably depth-sorts per camera.
   Likely requires `$translucent` detection on the resolved mat at
   `resolveMat` time and a parallel `ClippedMeshesTrans` list.
2. **Brush entity cost.** With static props and `prop_dynamic` baked,
   `DrawBrushEntities` is often the next meaningful per-frame cost on
   Venator-like maps. Potential work: separate static `func_brush` /
   stable brush entities from moving doors/trains and bake the stable
   subset, leaving live brush entities on the current matrix path.
3. **Spatial baked-prop chunks if mode 3 clips badly.** The current
   default draws the full static-prop bake in zoomed views and relies on
   the 5-plane GPU clip prism. It is fast, but if visuals show props
   poking beyond the intended cylinder edge, the next candidate is
   material-grouped spatial chunks. The per-prop baked cull experiment
   was measured and is too draw-call-heavy for dense maps.
4. **Semi all-in cache.** Keep static interior geometry as a permanent
   IMesh and only re-clip the few boundary faces on parameter change.
   Bigger refactor; only worth it if rebuild hitches during edits are
   still visible after prewarm/bake work.

## Pinned facts (don't relitigate)

- `bsp2` is a required dependency (worldspawn faces, brush models,
  static props, materials all come from it). Without it the entity
  draws nothing.
- Clipping volume is a 32-sided cylinder, radius `scale * 90`. The 5
  GPU clip planes form an outward-circumscribing pentagonal prism; the
  cylinder pokes through the prism corners which is fine because the
  software clip already cropped worldspawn there.
- Worldspawn-only iteration in the clipper (`bsp.models[1].faces`).
  Brush-entity faces are in entity-local space and would render at the
  BSP origin if dropped into the world batch — `DrawBrushEntities`
  handles those separately with a per-entity matrix.
- Static prop bake modes: `holo_table_staticprop_bake_mode 0` = legacy
  csent path, `1` = global bake only when horizontally all-in, `2` =
  per-prop baked cull experiment, `3` = default global bake clipped by
  the GPU prism in all static-prop views. Mode `3` is the measured fast
  zoom path; mode `2` exists for comparison but is not the preferred
  optimisation.
- `Entity:DrawModel` ignores `cam.PushModelMatrix`. Legacy static and
  `prop_dynamic` fallback paths draw csents in world space using a
  precomputed `tableOrigin + R * (p / scale)` transform; baked static
  props and baked `prop_dynamic` dressing are IMeshes in BSP space and
  draw inside the `m2` holo matrix.
- bsp2 emits one unique `UnlitGeneric` material per texinfo. Group draws
  by `$basetexture` name (fallback: material name) to collapse those
  back into one batch per texture.
- `_holoCull` / `_holoTris` live on the bsp2 face tables themselves and
  survive across rebuilds within a map load; a `CurrentBSPReady` hook
  clears the brush mesh cache (face-level caches die naturally with the
  bsp2 face tables they sit on).
- `matByTexinfo` is cached at file scope (`getMatByTexinfo`) keyed by
  `mi.materials` table identity. **Do not rebuild this per call** —
  on big maps the rebuild is ~230 ms and dominates the clip phase
  if reintroduced. Used by both `BuildClippedMap` and
  `GetBrushModelMeshes`.
- Re-`include`-ing `cl_init.lua` (or any of `cl_map.lua` / `cl_radar.lua`
  / `sh_controls.lua`) from a runstring does **not** update already-
  spawned entity instances. `scripted_ents.GetStored(...).t` has the
  new methods; instance functions still point at the old closures. To
  live-test an edit without respawning, scaffold
  `ENT = { Type = 'anim', Base = 'base_anim' }`, `include` `shared.lua`
  + the touched sub-files (or just `cl_init.lua`, which pulls them all
  in), `scripted_ents.Register(ENT, 'holo_table_3d')`, then iterate
  `ents.FindByClass('holo_table_3d')` copying `type(v) == 'function'`
  fields from the stored table onto each instance.
- Adding a new tracked-entity kind: drop a single file in
  `lua/entities/holo_table_3d/radar/<kind>.lua` defining any subset of
  `RADAR:Initialize` / `RADAR:Think` / `RADAR:Draw` / `RADAR:OnRemove`
  (use `self:GetEntity()` for the table, `self:GetScale()` for the
  inverse scale, `self:Project(pos, ang)` to map BSP space into the
  holo). The loader picks it up; `init.lua`'s `radar/*.lua` AddCSLuaFile
  loop ships it to clients automatically. No edits to `cl_init.lua` /
  `cl_radar.lua` / `init.lua` needed.
- `prop_dynamic` is intentionally **not** a tracked radar kind anymore.
  `radar/prop_dynamic.lua` is a stub to keep loader behaviour stable;
  map-owned dynamic dressing bake/fallback lives in `cl_map.lua`.
- Map-dressing faces (banners, flags, decals on thin brushes) are
  single-sided in the BSP and stay that way in the holo. Don't
  reintroduce double-sided emission — it z-fights with the existing
  coplanar back faces and turns the whole mesh translucent. Flags
  inside enclosed rooms are correctly occluded by the room walls,
  same as in the live world from outside.
- Server is the source of truth for control ownership. Client
  optimistically writes to NetworkVars on input so the table reacts
  the same frame; the server's snapshot replays the (clamped /
  ownership-checked) authoritative value within ~RTT. Don't add a
  client-side action that needs to *persist* without a corresponding
  net send — the server snapshot will overwrite it.
- All four client sub-files (`sh_controls.lua`, `cl_map.lua`,
  `cl_radar.lua`) are `include`d at the *top* of `cl_init.lua`, in
  that order. Methods that one sub-file defines on `ENT` (e.g.
  `ENT:ComputeAutoCenter` in `cl_map.lua`) are referenced by earlier
  ones (`sh_controls.lua`'s `holo_table_autocenter`) only from
  concommand callbacks / hooks that fire after every file has
  finished loading — fine. If you add file-execute-time code that
  needs an ENT method from a later sibling, reorder the includes or
  move the method up.
- Runtime `util.AddNetworkString` does **not** backfill into
  already-connected clients (registry is replicated at server boot).
  Hot-reloading `sh_controls.lua` works for hooks/HUD/concommands but
  any new `holo_table_*` net string needs a `changelevel` before the
  client can resolve it. Live tests on already-registered strings
  (e.g. `holo_table_setparams`) work fine.
- `PlayerBindPress` returning `true` for a `+command` cancels the
  bind execution, which means the corresponding `IN_*` button bit
  never gets set on the cmd. If you need both to suppress the weapon
  side-effect *and* detect the press, suppress in `PlayerBindPress`
  and poll the raw key via `input.LookupBinding(cmd) ->`
  `input.GetKeyCode(name) -> input.IsKeyDown(code)` instead of
  `cmd:KeyDown(IN_*)`. This is exactly what `+reload` does.
- `cmd:RemoveKey(IN_*)` clears the bit from the cmd's button bitmask
  before the rest of the engine processes it. So if you need to read
  whether the player is holding e.g. `+duck` *and* prevent them from
  ducking, capture `cmd:KeyDown(IN_DUCK)` into a local *before*
  calling `cmd:RemoveKey(IN_DUCK)`. The precision modifier in
  `sh_controls.lua` does this.

## Tooling (MCP servers)

The agent has two relevant MCP-backed integrations beyond the standard
file/process tools. Use them aggressively — they replace guessing about
GMod APIs and make profiling self-service.

### Garry's Mod Wiki

For confirming signatures, return types, and what's actually available
before writing code that calls into the engine. Don't assume — check.

- `gmod_get_doc("table.GetKeys")` — page for a specific function /
  method / class. Use dot notation: `Library.Function`,
  `Class.Method`, `hook.Add`, `Entity.GetPos`, etc.
- `gmod_search("query")` — fuzzy search across the whole wiki.
  Optional `category` filter (Globals, Classes, Libraries, Hooks,
  GameEvents, Panels, Enumerations, Structures, Shaders, Methods).
- `gmod_library_functions("table")` — every function in a library
  (`hook`, `net`, `timer`, `util`, `table`, `string`, …). Use this
  when you want to know everything available rather than searching
  for one specific name.
- `gmod_class_methods("Entity")` — every method on a class
  (`Entity`, `Player`, `Vector`, `Angle`, `Panel`, …).
- `gmod_list_category("Hooks")` — enumerate a whole category.

Example workflow: before calling `table.SomeThing` in an edit, run
`gmod_get_doc("table.SomeThing")` to confirm the signature, or
`gmod_library_functions("table")` if you're not sure of the exact
name.

### In-game execution / profiling

The agent can drive a running GMod instance directly via three tools
(needs the user to have started the MCP server — confirm with a cheap
command like `echo` first if unsure):

- `run_gmod_command_Garry_s_Mod(command, timeout)` — fire any console
  command (`holo_table_profile`, `holo_table_autocenter`, `lua_run …`,
  etc.) and capture output for `timeout` seconds.
- `execute_lua_code_Garry_s_Mod(code, timeout)` — runs Lua
  **client-side** via a temp file. Good for inspecting `bsp2` shapes,
  per-face cache state, NetworkVar values, or anything that needs
  more than a one-liner. Use `lua_run` via the command tool when
  server-side execution is needed.
- `capture_console_output_Garry_s_Mod(duration)` — passive listener;
  useful for monitoring multi-frame async events (coroutine build
  progress, `CurrentBSPReady` hooks, errors triggered by sliders).

Workflow conventions:

- Take a baseline `holo_table_profile` before an edit and a follow-up
  after, then report the delta. Don't claim a perf win without numbers.
- Always run profile **twice** (cold cache + warm cache); `_holoCull` /
  `_holoTris` populate on the first pass, and steady-state is what
  matters. Report both if they differ meaningfully.
- Prefer `holo_table_profile` over the live build for measurements —
  it's synchronous, bypasses the coroutine and the 150 ms debounce,
  and frees its temp meshes without disturbing `ClippedMeshes`.
- Reproduce bugs end-to-end (spawn → autocenter → tweak → observe)
  rather than asking the user to repro by hand.


## Style / working agreement

- The user values terse, accurate explanations, no flattery, no
  hand-wavy "this should be much faster" — give numbers when claiming
  perf wins, and ask for the next `holo_table_profile` output to
  confirm.
- Use `<augment_code_snippet>` with `mode="EXCERPT"` and four backticks
  when showing code. Keep snippets <10 lines.
- Don't commit, push, or restructure files without asking. Don't create
  new docs unless explicitly requested (this file was requested).
- When making edits, gather context first (codebase-retrieval / view)
  and respect the existing comment style — terse intent comments,
  no rationale-as-comments.
