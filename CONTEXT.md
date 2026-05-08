# Holo Table — Conversation Handoff

Drop this in front of a fresh agent so it can pick up where the previous
session left off. `DESIGN.md` is the canonical reference for *why* the
code looks the way it does; this file is just the working state.

## Project

Garry's Mod addon (`addons/holo_table`) — a "war room" holographic table
entity that renders a miniature 3D view of the current map at the table
top. Map geometry is pulled from NikNaks through a small compatibility
adapter in `lua/autorun/bsp2.lua` (the old vendored parser is gone, but
the local `bsp2.*` API name is intentionally preserved for the holo table
code). Worldspawn is software-clipped against a 32-sided cylinder; brush
entities, static props, radar markers, and players are GPU-clipped via a
5-sided prism + floor plane (the engine's 6-plane clip budget).

## File layout

- `lua/autorun/bsp2.lua` — NikNaks-backed BSP adapter. `require`s
  `niknaks`, builds the small legacy surface this addon consumes
  (`bsp2.GetCurrent`, `bsp2.GetModelInfo`, `bsp2_rebuild`, and
  `CurrentBSPReady`), adapts NikNaks bmodels/faces/texinfo/static props
  into the old table shape, and creates one `UnlitGeneric` fallback
  material per texinfo for lightmap-free holo rendering.
- `lua/entities/holo_table_3d/shared.lua` — `ENT.Type/Base`, metadata,
  `SetupDataTables` (NetworkVars: `Entities` Bool0, `Map` Bool1,
  `Height` Float0, `Scale` Float1, `PanX` Float2, `PanY` Float3).
- `lua/entities/holo_table_3d/init.lua` — server `Initialize` (sets
  `SIMPLE_USE`), `ENT:Use`/`ReleaseController`/`OnRemove` ownership
  handling, `PlayerDisconnected` cleanup, net receivers for
  `holo_table_autocenter` / `holo_table_focus_table` /
  `holo_table_setparams` / `holo_table_setlayers` /
  `holo_table_release`, and `AddCSLuaFile` for
  every client component including loops over `map/*.lua` and
  `radar/*.lua`.
  `setparams` / `setlayers` / `release` are ownership-gated;
  `setparams`, `autocenter`, and `focus_table` are clamped to the
  NetworkVar limits. `autocenter` / `focus_table` are blocked when the
  table is controlled by someone else, while remaining usable on
  unowned tables.
- `lua/entities/holo_table_3d/cl_init.lua` — slim coordinator (~410
  lines). `ENT:Initialize`/`Think`/`OnRemove` delegate to the
  per-subsystem hooks (`InitializeMap` / `InitializeRadar` / etc.).
  Owns `ENT:Draw` (just `DrawModel` so halo.Render works) and
  `ENT:DrawHologram` (stencil + GPU clip prism setup, scene matrix
  push, async-build kick), plus the self-installing
  `PostDrawTranslucentRenderables` dispatch hook. That hook exists only
  while at least one `holo_table_3d` exists and loops with
  `ipairs(ents.FindByClass('holo_table_3d'))`. `include`s
  `sh_controls.lua`, `cl_map.lua`, `cl_radar.lua` at the top.
- `lua/entities/holo_table_3d/cl_map.lua` — ordered include shim for the
  map subsystem. The implementation lives in `map/cl_map_*.lua`; shared
  cross-fragment internals live on `ENT.MapCache`, while entity-facing hooks
  stay as `ENT:` methods.
- `lua/entities/holo_table_3d/map/*.lua` — map subsystem fragments:
  `cl_map_shared.lua` (hot-reload cleanup and shared helpers such as
  `ENT:_SafeDestroyMesh`), `cl_map_materials.lua`, `cl_map_prewarm.lua`,
  `cl_map_static_props.lua`, `cl_map_dynamic_props.lua`,
  `cl_map_clip.lua`, `cl_map_brushes.lua`, `cl_map_core.lua`, and
  `cl_map_tools.lua`. Together they own the software clipper
  (`BuildClippedMap`), brush-mesh cache, prop bounds/csent cache, async
  build pipeline, static-prop and `prop_dynamic` map-dressing
  bake/fallback paths, draw entry points, `ComputeAutoCenter`, and the
  `holo_table_profile` concommand.
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
  Currently: `lvs.lua` (LVS vehicles, team-tinted csent ghosts, and
  clientside LVS bullet tracer projection),
  `other_vehicle.lua` (LFS / SW vehicles, red marker spheres),
  `player.lua` (live player/weapon models; remote players are drawn by
  temporarily projecting the real entity, while the local player uses a
  clientside mirror with copied bones). `prop_dynamic.lua` is now
  a stub only; map-owned `prop_dynamic` dressing lives in
  `map/cl_map_dynamic_props.lua`.
- `lua/entities/holo_table_3d/sh_controls.lua` — interactive control
  layer: `+use`-toggled grab, `CreateMove`-driven WASD pan / wheel
  height / `+speed`+wheel zoom / `+reload` recenter /
  `+speed`+`+reload` table-focus / `+duck` precision modifier /
  T entities / G map, throttled `setparams` send, immediate
  `setlayers` / `autocenter` / `focus_table` send, HUD overlay with
  dynamic key labels via `input.LookupBinding`, `holo_table_release`
  / `holo_table_autocenter` / `holo_table_focus_table` concommands.
  Table-focus snaps to scale `8` and height `28`, centered on the
  physical table's map position.
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
    Auto-invalidates when the adapter swaps the materials list.
12. Tracked-entity rendering ("radar system"). Originally a single
    monolithic ghost system in `cl_init.lua`; now split into
    `cl_radar.lua` (registry + `RadarBase` + ENT lifecycle hooks)
    and one file per kind in `radar/`. The base provides
    `GetEntity` / `GetScale` (inverse) / `GetOrigin` / `GetAngles` /
    `Project(pos, ang)`; modules define any subset of
    `Initialize` / `Think` / `Draw` / `OnRemove`. Current modules:
    `lvs.lua` (csent ghosts, team-tinted via file-local `tintFor`),
    `other_vehicle.lua` (LFS / SW vehicles, red marker spheres),
    `player.lua` (live player/weapon models; remote players draw their
    real entity at a temporary projected pose, local player uses a
    `ClientsideModel` mirror). `prop_dynamic.lua`
    later became a stub; map dressing moved to
    `map/cl_map_dynamic_props.lua`.
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
      `src`'s `$basetexture` for use when the adapter-generated fallback
      for a texinfo carries the error texture (typically because the
      same malformed path defeated the raw material lookup). Cached per
      basetexture name.
    - `resolveMat(tinfo)` for `LightmappedGeneric` faces prefers
      the adapter's per-texinfo `UnlitGeneric` fallback unless its
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
      send for pan / scale / height. `holo_table_setlayers`,
      `holo_table_autocenter`, and `holo_table_focus_table` ship
      immediately on the edge.
    - HUD displays bound keys via `input.LookupBinding` so it
      auto-updates when the player rebinds (`WASD`/`SHIFT`/`R`/`E`
      become whatever they actually have). T / G are static labels
      since they're not bound to a `+command`.
    - `holo_table_autocenter` / `holo_table_focus_table` concommands
      live in `sh_controls.lua` so they can share `findControlTarget`
      (prefers the actively-
      controlled table) with the `+reload` hotkey.
      `focus_table` uses scale `8`, pan = the table entity's world
      `x/y`, and height `28` so the surrounding floor remains visible
      in the close tactical view.
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
    `CleanupMap`). `cl_init.lua` is now ~410 lines and only owns
    lifecycle dispatch, `Draw` (just `DrawModel`), and `DrawHologram`
    (stencil + GPU clip prism setup, scene matrix push, async-build
    kick) plus the lifecycle-gated `PostDrawTranslucentRenderables`
    hook that drives it.
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
    Static prop bounds/prewarm use `util.GetModelInfo` now, so prewarm
    no longer creates throwaway clientside entities.
18. Targeted hot-global localization in `cl_map.lua` (`SysTime`,
    `Vector`, `Material`, `Mesh`, `bit.band`, `table.move`, selected
    `math.*`, `coroutine.*`, `hook.Add/Remove`, `render.SetMaterial`).
    This is a micro-optimization, not a new architecture; measured
    live draw samples improved by roughly 0.1 ms/frame but build
    profiles remain IMesh-bound.
19. `prop_dynamic` map dressing moved out of radar. The radar module is
    now a stub so loader/AddCSLuaFile behaviour stays stable, while
    `map/cl_map_dynamic_props.lua` owns `prop_dynamic` as map dressing:
    an async baked IMesh path drawn inside the holo matrix and cropped by
    the existing GPU clip prism in both all-in and partial views, a
    1-second watcher that detects added/removed/moved/reskinned props and
    rebuilds, and a legacy per-table csent fallback for disabled bake or
    individual moving/rotating props. Bake rebuild windows suppress the
    stable-prop fallback instead of creating temporary mirror props.
    Venator's moving `hypertunnel.mdl` exposed why movers must be
    excluded from the bake instead of forcing a rebuild every watcher
    tick. Toggle with `holo_table_dynamicprop_bake`.
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
22. Vendored BSP parser removed. `lua/autorun/bsp2.lua` is now a thin
    NikNaks adapter that preserves the holo table's existing `bsp2`
    contract instead of forcing `cl_map.lua` to learn the NikNaks API
    directly. It adapts NikNaks bmodel 0 into `models[1]` (worldspawn),
    bmodels `1..N` into `models[2..]`, face edges/planes/texinfo into
    the legacy shape, static props into `{model, origin, angles, skin}`,
    and keeps `bsp.faces` as the worldspawn fallback. `bsp2_rebuild`
    clears/rebuilds the adapter state and re-runs `CurrentBSPReady`.
23. Material flag preservation for translucent / alpha-tested
    `LightmappedGeneric` sources. `resolveMat` now checks the source
    material flags (`MATFLAG_TRANSLUCENT`, `MATFLAG_ALPHATEST`) and asks
    `unlitWrap` to create matching `UnlitGeneric` variants, so glass,
    grates, foliage, and similar alpha-bearing textures no longer lose
    their transparency just because the holo pass has no lightmaps.
    There is still no dedicated sorted translucent pass.
24. Console `KeyValues Error ... mdlkeyvalue` spam on map load /
    auto-refresh was traced to malformed embedded model KeyValues in
    third-party models such as `models/cires992/props2/shelf02_l.mdl`.
    `ClientsideModel` / `ents.CreateClientProp` makes the engine parse
    those bad blocks; `util.GetModelMeshes` and `util.GetModelInfo` do
    not spam by themselves. The current mitigation avoids clientside
    entity creation during static-prop prewarm and uses the baked
    `prop_dynamic` path for stable map dressing instead of steady
    clientside mirror props.
25. Hot-reload cleanup. `cl_map.lua` registers
    `_G.HOLO_TABLE_3D_CL_MAP_CLEANUP` and runs the previous generation's
    cleanup at file load. This tears down shared static/dynamic prop
    bakes, brush mesh caches, prewarm hooks, and cached clientside draw
    entities so Lua auto-refresh does not strand IMesh/csent resources.
26. `cl_map.lua` was extracted into ordered map fragments under
    `lua/entities/holo_table_3d/map/`. The shim now only includes the
    fragments in dependency order. Shared internal state deliberately
    lives on `ENT.MapCache` (for example material helpers, bake state,
    prewarm hooks, scratch `Vector`/`Angle` objects), while public entity
    methods stay on `ENT` (`InitializeMap`, `DrawClippedMap`,
    `ComputeAutoCenter`, `ENT:_SafeDestroyMesh`, etc.). Avoid dynamic
    `file.Read`/`CompileString` loaders here; normal `include` keeps
    auto-refresh and stack traces understandable.
27. LVS tracer projection. `radar/lvs.lua` wraps clientside
    `util.Effect` and records effects that correspond to live LVS bullet
    entries. It does **not** whitelist effect names; instead it resolves
    `data:GetMaterialIndex()` through `LVS:GetBullet(id)` and accepts the
    tracer only when the bullet's source entity is an LVS ship and the
    bullet's `TracerName` matches the effect being emitted. The holo
    table draws short glowing beams in the radar layer until they expire.
28. Spawn-time split leaks fixed. The extraction initially left several
    monolith-local assumptions in Think hooks: `anyClipCoroutineActive`,
    `STATIC_PROP_BAKE_*`, `addStaticPropBakeVert`, and one runtime
    `ENT:_SafeDestroyMesh` call. These now live on `ENT.MapCache`, have
    dynamic-prop-local constants where appropriate, or call through
    `self:`. When testing spawn regressions, capture console output
    after `ent_create holo_table_3d`; map/model `KeyValues Error ...
    mdlkeyvalue` spam from malformed third-party models is separate from
    holo-table Lua stack traces.
29. Steady-state Lua allocation estimate. With one visible spawned table
    on the current test map, GC-paused wrapper probes measured total
    client Lua allocation at ~33.8 KB/frame, with the holo table draw hook
    contributing ~21.0 KB/frame. Inner breakdown over 240 frames:
    `DrawBrushEntities` ~15.5 KB/frame, `DrawBakedDynamicProps`
    ~2.9 KB/frame, `UpdateHologramTransform` ~1.2 KB/frame,
    `DrawClippedMap`/`DrawMap`/`DrawRadar` each under ~0.4 KB/frame, and
    controls/HUD effectively zero. Build phases allocate much more
    transiently; these numbers are steady-state after bakes are ready.
30. Player radar upgraded from markers to live miniatures. Remote
    players use the wOS-style trick of moving the real player entity to
    the projected holo pose for one `DrawModel` call, drawing its active
    weapon, then restoring position/angles/model scale. The local player
    uses a `ClientsideModel` mirror because first-person local-player
    drawing is special-cased by the engine. The local weapon mirror is
    bone-merged/attached to that player mirror. Local attack/reload
    animation support does **not** poll `IN_ATTACK` or copy animation
    layers: `ClientsideModel` is not `BaseAnimatingOverlay`, so layer
    APIs are ignored. Instead `holo_table_player_anim_events` toggles a
    solved bone-matrix copy from `LocalPlayer()` to the projected mirror,
    which preserves movement, hold types, firing gestures, and reloads.
    Player/weapon radar models suppress engine map lighting and use
    neutral model lighting; tune with `holo_table_player_light` (default
    `1`).
31. `PostDrawTranslucentRenderables` hook optimized. The old hook always
    ran and scanned `ents.Iterator()` every frame even on maps with no
    holo table. `cl_init.lua` now installs the hook from `ENT:Initialize`,
    removes it after the last table is gone, and defensively self-removes
    if a draw tick sees no tables. The draw loop uses
    `ipairs(ents.FindByClass('holo_table_3d'))`, matching the wiki's
    guidance for single-class lookup. Live client benchmark on the current
    map with zero tables / 842 entities, 2000 calls: `ents.Iterator` +
    `GetClass()` was ~117.5 ms total (~58.8 us/call);
    `ents.FindByClass('holo_table_3d')` was ~55.8 ms total
    (~27.9 us/call). A busy class (`beam`, 275 ents) still favored
    `FindByClass` (~71.1 ms vs ~119.5 ms).
32. Static IMesh construction switched from `IMesh:BuildFromTriangles`
    to `mesh.Begin(msh, MATERIAL_TRIANGLES, triCount)` via
    `MapCache.buildMeshFromTriangles`. Wiki docs confirm
    `mesh.Begin(IMesh, primitiveType, primitiveCount)` and note the
    static mesh vertex limit; current chunks stay below it. On
    `holo_table_profile` with the same table/map, warm map build timings
    dropped from roughly 83-92 ms total (75-84 ms imesh phase) to
    roughly 30-32 ms total (21-22 ms imesh phase).
33. Player radar local mirror bone-copy path optimized. The local player
    mirror now caches valid bone IDs and uses reusable matrices plus
    `Entity:CopyBoneMatrix` when available, instead of allocating fresh
    matrices / `WorldToLocal` / `LocalToWorld` objects per bone. Wiki
    docs confirm `CopyBoneMatrix` is the faster copy-into-matrix variant.
    A matrix comparison against the previous math matched within
    ~1e-8 in the sampled case. Allocation around `RADAR:player:Draw`
    dropped from roughly 91.6 KB/frame before the rewrite to about
    4.0 KB/frame after it; live `RADAR:player:Draw` was then around
    0.19 ms average / 0.8 ms max in the sampled scene.
34. Dynamic `prop_dynamic` partial-view fallback hitch fixed. A close
    table-focus view with 144 `prop_dynamic` mirrors showed fallback
    allocation around 56 KB/frame and occasional draw stalls up to
    ~36 ms. Scalarizing the fallback transform reduced fallback
    allocation to ~22.6 KB/frame, but the real fix was using the baked
    dynamic-prop mesh in partial views too: the same 3000-frame test
    ended with `mirrors=0`, `DrawDynamicProps` ~0.003 ms average /
    0.112 ms max, `DrawBakedDynamicProps` ~0.027 ms average /
    0.242 ms max, and no real frames over 8 ms.
35. LVS-heavy profiling with 12 LVS ships showed the big drops were
    mostly outside this addon. Baseline with the holo table active:
    `RADAR:lvs:Draw` ~0.082 ms average / 0.553 ms max, and the
    `util.Effect` tracer wrapper averaged ~0.0385 ms per call. Worst
    real frames were 35-52 ms while measured holo-table addon work on
    those frames was only about 1.5-2.9 ms. With `DrawHologram` no-op'd,
    similar 49-68 ms drops still occurred; with only the holo LVS radar
    disabled, similar 49-56 ms drops still occurred. Conclusion: the
    large frame drops are likely LVS / game-side ship activity, not the
    holo-table radar. The radar can still gain optional headroom later
    with marker-only / tracer-only modes, but that will not fix the
    measured 50 ms spikes.

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

Take-away: the imesh phase used to dominate all-in framings when built
with `IMesh:BuildFromTriangles`; the current `mesh.Begin` static-IMesh
path is much faster but still scales with emitted triangles. Further
wins require either avoiding the rebuild entirely (semi all-in cache) or
skipping faces (more aggressive culling).

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
- `PostDrawTranslucentRenderables` dispatch was later changed to
  self-install only while holo tables exist and to use
  `ents.FindByClass('holo_table_3d')` instead of scanning
  `ents.Iterator()`.
- Close table-focus view with 144 `prop_dynamic` mirrors, before
  partial-view dynamic bake: `DrawDynamicProps` ~0.48 ms average with
  rare stalls up to ~36 ms. After drawing the global baked dynamic-prop
  mesh in partial views too: `mirrors=0`, `DrawDynamicProps`
  ~0.003 ms average / 0.112 ms max, `DrawBakedDynamicProps`
  ~0.027 ms average / 0.242 ms max, 3000-frame real-time max
  ~5.85 ms and no frames over 8 ms in that sample.
- LVS-heavy scene with 12 LVS ships: `RADAR:lvs:Draw` ~0.082 ms average
  / 0.553 ms max; disabling the holo render or disabling only the holo
  LVS radar did not remove 50 ms-class real-frame spikes. Treat those
  spikes as mostly outside this addon unless a future profiler shows
  different alignment.

**Steady-state Lua allocation notes** (GC paused, one visible spawned
table on the current test map):

- Whole client Lua: ~33.8 KB/frame.
- Holo table draw hook inclusive: ~21.0 KB/frame.
- Inner draw allocation: `DrawBrushEntities` ~15.5 KB/frame,
  `DrawBakedDynamicProps` ~2.9 KB/frame,
  `UpdateHologramTransform` ~1.2 KB/frame, `DrawClippedMap` ~0.3
  KB/frame, `DrawMap` ~0.3 KB/frame, `DrawRadar` ~0.2 KB/frame,
  `DrawBakedStaticProps` ~0.05 KB/frame.
- Current map had 118 brush-model entities; most steady-state allocation
  is from live brush-entity `GetPos`/`GetAngles`/matrix work, not static
  props or radar.

## Open questions / next steps

Current likely next work:

1. **Translucent draw ordering.** Alpha-tested / translucent material
   flags are now preserved on the generated `UnlitGeneric` wrappers, so
   the old "opaque black glass" failure mode is mostly gone. The build
   still emits a single material-batched mesh list, though; a future
   pass may need a separate translucent group list drawn after opaque
   geometry, probably with camera-relative sorting, if blended surfaces
   show order artifacts.
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

- NikNaks is the required BSP parser dependency. The addon keeps a local
  `bsp2` compatibility adapter so the map subsystem can keep using the
  old `bsp2.GetCurrent()` / `bsp2.GetModelInfo()` surface; without
  NikNaks (or if `require('niknaks')` fails) the entity draws no map.
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
- The main hologram render hook should not be permanent. `cl_init.lua`
  installs `holo_table_3d.DrawHologram` only when at least one
  `holo_table_3d` exists, removes it after the last table is gone, and
  uses `ents.FindByClass('holo_table_3d')` for the active-table loop.
  Do not replace this with a global `ents.Iterator()` scan unless a new
  benchmark shows a real win.
- The NikNaks adapter emits one unique `UnlitGeneric` material per
  texinfo. Group draws by `$basetexture` name (fallback: material name)
  to collapse those back into one batch per texture.
- `_holoCull` / `_holoTris` live on the adapted face tables themselves
  and survive across rebuilds within a map load; a `CurrentBSPReady`
  hook clears the brush mesh cache.
- `matByTexinfo` is cached at file scope (`getMatByTexinfo`) keyed by
  `mi.materials` table identity. **Do not rebuild this per call** —
  on big maps the rebuild is ~230 ms and dominates the clip phase
  if reintroduced. Used by both `BuildClippedMap` and
  `GetBrushModelMeshes`. The material list comes from the NikNaks
  adapter's `bsp2.GetModelInfo()`.
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
  map-owned dynamic dressing bake/fallback lives in
  `map/cl_map_dynamic_props.lua`.
- Player radar has two paths. Remote players temporarily draw the real
  entity/weapon at the projected pose and restore it immediately. The
  local player uses a persistent `ClientsideModel` mirror plus a weapon
  mirror because `LocalPlayer():DrawModel()` may be hidden in first
  person. Do not reintroduce local animation-layer copying for the
  mirror: `Entity:SetLayerSequence` only works on `BaseAnimatingOverlay`,
  so the current solved bone-matrix copy is the working animation path.
- Map-dressing faces (banners, flags, decals on thin brushes) are
  single-sided in the BSP and stay that way in the holo. Don't
  reintroduce double-sided emission — it z-fights with the existing
  coplanar back faces and turns the whole mesh translucent. Flags
  inside enclosed rooms are correctly occluded by the room walls,
  same as in the live world from outside.
- Server is the source of truth for control ownership. Client
  optimistically writes to NetworkVars on input so the table reacts
  the same frame; the server's snapshot replays the clamped /
  ownership-checked authoritative value within ~RTT. `autocenter`
  accepts client-computed fit params, but clamps them and rejects
  attempts to change a table controlled by another player. Don't add a
  client-side action that needs to *persist* without a corresponding
  net send — the server snapshot will overwrite it.
- Client sub-files (`sh_controls.lua`, `cl_map.lua`, `cl_radar.lua`) are
  `include`d at the *top* of `cl_init.lua`, in that order. `cl_map.lua`
  then includes the `map/cl_map_*.lua` fragments in dependency order:
  shared → materials → prewarm → static props → dynamic props → clip →
  brushes → core → tools. Methods that one sub-file defines on `ENT`
  (e.g. `ENT:ComputeAutoCenter` in `cl_map_tools.lua`) are referenced by
  earlier ones (`sh_controls.lua`'s `holo_table_autocenter`) only from
  concommand callbacks / hooks that fire after every file has finished
  loading — fine. If you add file-execute-time code that needs an ENT
  method or `ENT.MapCache` helper from a later sibling, reorder the includes
  or move/export the helper earlier.
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
  **client-side** via a temp file. Good for inspecting NikNaks adapter
  shapes, per-face cache state, NetworkVar values, or anything that
  needs more than a one-liner. Use `lua_run` via the command tool when
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
