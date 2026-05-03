# Holo Table Design Decisions

Notes on the non-obvious choices baked into `lua/entities/holo_table_3d/`,
including alternatives that were considered and rejected. Useful when
revisiting performance, visual quality, or architecture.

## File layout

**Decision:** Standard GMod entity-folder split, with the client side
further divided into per-subsystem files driven by entity-style
lifecycle hooks (`InitializeMap`, `ThinkRadar`, etc.) on `ENT`. This
keeps `cl_init.lua` as a thin coordinator and makes each subsystem
independently movable / replaceable.

- `shared.lua` — `ENT.Type`/`Base`/metadata + `SetupDataTables`.
- `init.lua` — server-side `Initialize` (sets `SIMPLE_USE`),
  `ENT:Use`/`ReleaseController`/`OnRemove` ownership handling,
  `PlayerDisconnected` cleanup, the four control-layer net
  receivers (`holo_table_autocenter`, `holo_table_setparams`,
  `holo_table_setlayers`, `holo_table_release`), and `AddCSLuaFile`
  for every client component including a loop over `radar/*.lua`.
  Net receivers are ownership-gated and clamped to the NetworkVar
  limits in `shared.lua`.
- `cl_init.lua` — slim coordinator (~375 lines).
  `Initialize` / `Think` / `OnRemove` delegate to per-subsystem
  hooks. `Draw` only calls `DrawModel` so `halo.Render`'s opaque
  silhouette pass works correctly; the holographic content is drawn
  from a `PostDrawTranslucentRenderables` hook into `ENT:DrawHologram`,
  which owns the stencil cylinder mask, the 5-plane GPU clip prism +
  floor plane, and the scene matrix push. It then calls into the
  subsystem draw entry points (`DrawMap`, `DrawClippedMap`,
  `DrawBrushEntities`, baked/fallback prop draw paths, `DrawRadar`).
- `cl_map.lua` — map subsystem. The clipper, brush-mesh cache,
  prop bounds / csent caches, static-prop and `prop_dynamic`
  map-dressing bakes/fallbacks, async build pipeline (`Start*` /
  `Tick*` / `Commit*` / `Destroy*` + the all-in invariance cache),
  per-frame draw entry points, the auto-center solver
  (`ENT:ComputeAutoCenter`), and the `holo_table_profile`
  concommand. Lifecycle hooks `ENT:InitializeMap` / `ENT:CleanupMap`.
- `cl_radar.lua` — radar subsystem. Module loader, `RadarBase`
  (accessors that every per-entity instance inherits), and the four
  ENT lifecycle hooks (`InitializeRadar` / `ThinkRadar` /
  `DrawRadar` / `CleanupRadar`). See "Radar system".
- `radar/*.lua` — one file per tracked entity kind. Defines a
  `RADAR` table populated with any subset of `Initialize` / `Think` /
  `Draw` / `OnRemove`. Currently: `lvs.lua`, `other_vehicle.lua`,
  `player.lua`; `prop_dynamic.lua` is a stub because map dressing is
  owned by `cl_map.lua`. See "Radar system".
- `sh_controls.lua` — shared control layer: server ownership/net
  receivers plus client `+use`-toggled grab,
  per-frame input polling in `CreateMove`, `PlayerBindPress`
  suppression of conflicting binds, HUD overlay, throttled
  `setparams` send + immediate `setlayers` / `autocenter` send, and
  the `holo_table_release` / `holo_table_autocenter` concommands.
  See "Interactive controls".

**Decision:** Subsystem boundaries follow entity-style hook naming
(`InitializeMap` / `CleanupMap` / `DrawMap` etc.) rather than an
external module API (e.g. `holo_table.map.init(self)`). Reads as
idiomatic GMod and lets `cl_init.lua` stay declarative — every hook
call is a plain method on `self`. Sub-files attach their methods
straight onto `ENT` and add file-local helpers / caches for state
that doesn't need to live on the instance.

## Clipping volume

**Decision:** 32-sided software cylinder (Sutherland–Hodgman) for the
worldspawn mesh; 5-sided GPU clip prism + floor plane for live / fallback
content (brush entities, legacy prop fallbacks, ghosts, players). Baked
static props and baked `prop_dynamic` dressing draw as BSP-space IMeshes
inside the existing holo scene matrix.

**Rejected: GPU clip planes only for worldspawn.** The hardware budget is
6 planes, which forces a pentagonal footprint and visible flat sides at
zoom. The cylinder also needs full vertical extent — using two planes for
top/bottom of the cylinder would crop tall geometry.

**Rejected: Software cylinder for brush entities.** Brush models can
rotate (`func_door_rotating`, etc.), so each unique entity orientation
would need its own clipped mesh. That defeats the per-bmodel mesh cache.
Instead brush entities ride inside the existing GPU prism block, so
oversized geometry like hangar doors gets cropped at the rim. Cost is
visible flat sides on doors that span the rim.

**Decision:** Static BSP props default to a global baked renderer. A
shared, scale-specific IMesh cache is drawn inside the holo scene matrix
and clipped by the existing 5-plane GPU prism + floor plane. The original
V1 only used this bake for all-in views and fell back to per-prop
`ClientsideModel` draws for tight/partial views, but zoomed Venator
profiling showed that fallback was the remaining major cost. The current
default (`holo_table_staticprop_bake_mode 3`) keeps the global bake active
for zoomed views too.

**Trade-off:** The zoomed static-prop bake is clipped by the pentagonal
GPU prism rather than the 32-sided software cylinder. It measured far
faster than both legacy per-prop drawing and per-prop baked culling, but
visual edge cases should be checked on dense maps. If the prism edge is
not acceptable, the next design is material-grouped spatial chunks, not a
return to per-prop draws.

## Build pipeline

**Decision:** Coroutine-based async builder with a ~4 ms per-frame budget
(`CLIP_FRAME_BUDGET`). Stale `ClippedMeshes` keep rendering until the new
build commits.

**Rejected: Synchronous rebuild on parameter change.** A full clip pass
on `rp_venator_extensive_v1_4` takes ~400–600 ms. Dragging the scale
slider would lock the client.

**Decision:** "All-in" invariance cache. When the cylinder fully contains
the worldspawn AABB (after pan), the clipped output is identical to any
other all-in scale/height. The first all-in build is cached on
`AllInMeshes` and swapped back in (~0.02 ms) on partial → all-in
transitions; same-config all-in edits short-circuit even earlier.

**Decision:** ~150 ms debounce on parameter changes before kicking off a
new build, except for the very first build (the entity has nothing to
display until the initial pass commits, so making the user wait would
look broken). Combined with a "don't preempt" policy — an in-flight
coroutine always finishes, even if its target params are already stale —
this keeps slider drags smooth without the cost of constantly
abandoning partial builds.

**Decision:** Worldspawn-only iteration (`bsp.models[1].faces`) in the
clipper. Brush-entity faces are stored in their entity's local frame and
would render at the BSP origin if included here.

**Decision:** Per-face triangulation cache on `face._holoTris`. Faces
that pass the trivial-accept test (fully inside the cylinder) only ever
need triangulating + UV-projecting once; the resulting per-vertex
`{pos, normal, u, v}` table list is invariant across scale/pan/height
and lives directly on the bsp2 face for the rest of the map load. The
fast path is then "look up cache → `table.move` the tris into the
material group's vert list", with a one-shot `lastGroups`/`lastGroup`
ref to skip the per-face hash lookup. On
`rp_venator_extensive_v1_4` (~21 k faces, ~99.95 % fully-interior at
the auto-centered framing) this drops the clip phase from ~470 ms to
~100 ms steady-state.

**Decision:** `holo_table_profile` concommand runs `BuildClippedMap`
synchronously against the targeted (crosshair / nearest) holo table and
prints stage-by-stage timings (`clip` vs `imesh`), face counts
(`total / rejected / fast / clipped`), wall-plane stats
(`checked / skipped / cut`), and output (`tris / meshes`). The output
list is freed without touching the live build pipeline so profiling is
side-effect-free.

## Prop and brush-entity rendering

**Decision:** Static BSP props use a shared baked IMesh path. `cl_map.lua`
asynchronously builds a scale-specific mesh list from `bsp.props` using
`util.GetModelMeshes(model, 0, 0, skin)`. Vertices and normals are
transformed once into BSP space, grouped/chunked by material, and drawn
inside the existing holo matrix. The bake is scale-specific because the
legacy path already applies a sub-pixel cull based on current scale.
Toggle: `holo_table_staticprop_bake`.

**Decision:** Static prop bake mode is explicit. The cvar
`holo_table_staticprop_bake_mode` supports:
- `0` — legacy per-prop csent path.
- `1` — global bake only when the table is horizontally all-in.
- `2` — per-prop baked-cull experiment.
- `3` — default global bake clipped by the GPU prism for all static-prop
  views.

Mode `3` is the measured fast path for zoomed views. In one Venator zoom,
legacy `DrawStaticProps` was ~2.86 ms/frame, per-prop baked culling was
~2.0 ms/frame because it still drew ~1,800 props / ~3,400 meshes, and
global GPU-clipped bake was ~0.085 ms/frame.

**Decision:** Legacy static prop fallback stays. Disabled bake, mode `0`,
and rebuild windows still use per-prop `Entity:DrawModel` in world space,
with a file-level `ClientsideModel` cache keyed by model path.

**Rejected: `cam.PushModelMatrix` around `DrawModel`.** `Entity:DrawModel`
ignores the model matrix stack, so props would render at their raw BSP
positions (often far from the table). World-space `SetPos`/`SetAngles`
per prop is cheap and works.

**Decision:** `render.SuppressEngineLighting(true)` during the prop draw
loop / baked mesh draw. Static props use `VertexLitGeneric`, while the
bsp2 worldspawn materials are `UnlitGeneric` — without suppression the
props look noticeably darker than the surrounding mesh.

**Decision:** `prop_dynamic` map dressing belongs to the map subsystem,
not radar. Most map `prop_dynamic`s are static visual dressing, so
`cl_map.lua` owns an async baked IMesh path for horizontally all-in views
plus a per-table csent fallback for partial views, disabled bake, rebuild
windows, or individual moving props. A 1-second watcher compares
`EntIndex`, model, skin, position, and angles; added/removed/reskinned
stable props trigger an async rebuild while the previous bake keeps
drawing. Props observed moving/rotating are marked unbaked and drawn by
fallback instead of forcing a rebuild every watcher tick. Toggle:
`holo_table_dynamicprop_bake`.

**Rejected: leaving `prop_dynamic` in radar.** Profiling showed
`radar/prop_dynamic.lua:Draw` dominated the post-static-bake radar cost.
Conceptually these props are map dressing rather than tactical targets,
and baked IMeshes can draw inside the existing `m2` matrix while csent
`DrawModel` ghosts cannot.

**Decision:** Live `ent:GetPos()` / `ent:GetAngles()` per frame for
brush entities. `bmodel.origin` is the compile-time origin (often
`(0,0,0)`); using it would freeze doors at their closed position. Vertices
in `bmodel.faces` are stored in the entity's local frame, so the
per-entity matrix is just `T(GetPos()) * R(GetAngles())` composed on top
of the holo scene matrix via `cam.PushModelMatrix(m, true)`.

**Decision:** Per-bmodel mesh cache shared across all `holo_table_3d`
instances, cleared on the `CurrentBSPReady` hook. Brush models are
map-stable; multiple holo tables can reuse the same `IMesh`.

## Radar system

**Decision:** Tracked entities (LVS vehicles, other vehicle
frameworks, live players) are rendered
through a "radar" subsystem split across `cl_radar.lua` (registry +
base + ENT hooks) and one file per kind in
`lua/entities/holo_table_3d/radar/`. Each per-entity instance is
posed each frame to the source's live `(pos, ang)` mapped through the
hologram transform. Adding a new kind is just dropping a single file
in `radar/` — no edits to `cl_init.lua`, `cl_radar.lua`, or
`init.lua` are needed.

**Decision:** Module API. The loader walks
`entities/holo_table_3d/radar/*.lua`, sets `_G.RADAR` to a fresh
table whose metatable's `__index` chains to `RadarBase`, includes
the file, then registers the populated table. Each module defines
any subset of `RADAR:Initialize` / `RADAR:Think` / `RADAR:Draw` /
`RADAR:OnRemove`. Per-entity instances inherit
`mod -> RadarBase`, so a module's method body sees a `self` that has
the module's own state plus the base accessors:

- `self:GetEntity()` — the holo table entity
- `self:GetScale()` — the **inverse** scale (factor modules want when
  multiplying BSP-space positions). The forward direction is unused
  so far; if a module needs it, fetch via `self:GetEntity():GetScale()`.
- `self:GetOrigin()` / `self:GetAngles()` — the hologram's
  world-space frame, staged once per frame by `ENT:DrawRadar`.
- `self:Project(pos, ang)` — maps a BSP-space pose into the
  hologram's world-space slot. Only valid inside `RADAR:Draw`.

**Decision:** ENT lifecycle wiring. `ENT:InitializeRadar` builds one
instance per registered module on `self.Radars` (keyed by
`mod.Name`, defaulting to the file basename). `ENT:ThinkRadar` and
`ENT:CleanupRadar` iterate that table; `ENT:DrawRadar` first stages
the BSP→world transform on `self._radarOrigin` /
`self._radarAngles` / `self._radarInvScale` so each module's `Draw`
can read it via the base accessors without recomputing.
`ThinkRadar` lazy-inits if `self.Radars` is missing so live-reloading
the file against an already-spawned entity doesn't crash.

**Decision:** Module-owned tracking state. Each module decides how it
discovers source entities — `ents.FindByClass`, `ents.GetAll` filter,
`player.GetAll`, etc. — and stashes them on `self.Tracked` (or
whatever it wants). The base doesn't enforce a discovery model. csent
ghosts are created in `Initialize` / `Think` and torn down in
`OnRemove` (`SafeRemoveEntity`). The csents themselves get
`SetNoDraw(true)`, `SetSolid(SOLID_NONE)`, `MOVETYPE_NONE`, and
`PhysicsDestroy()` so they don't bump into geometry or play collision
sounds as we shove them around with `SetPos`.

**Current modules:**
- `lvs.lua` — LVS vehicles, csent mirrors with `SetPos` / `SetAngles`
  / `SetModelScale` synced per frame. Team-tinted `DrawModel` via a
  file-local `tintFor(tableTeam, entTeam)` → friendly/hostile/neutral
  `render.SetColorModulation`; neutral when either side is team 0.
- `other_vehicle.lua` — LFS / SW vehicles whose model coverage is
  patchy; just draws a red marker sphere at the mapped position via
  `self:Project(...)`.
- `player.lua` — red marker sphere per live player.
- `prop_dynamic.lua` — stub only. `prop_dynamic` map dressing moved to
  `cl_map.lua` so it can use baked BSP-space meshes and share map
  fallback/bake lifecycle.

**Rejected: drawing csent ghosts inside the `m2` /
`cam.PushModelMatrix` block.** `Entity:DrawModel` ignores the model
matrix stack, so ghosts would render at their raw world positions on
top of the live scene instead of inside the table. Same constraint
as static props. `ENT:DrawRadar` runs outside the `m2` block; modules
that draw csents apply the per-ghost world-space transform via
`SetPos` + `SetAngles` (computed through `self:Project`).
Marker-sphere drawers could run inside `m2` (since `render.DrawSphere`
respects the matrix) but currently also use `Project` for symmetry.

**Rejected: shared csent pool reused across source ents.** Calling
`SetPos` / `SetAngles` / `SetModelScale` / `SetupBones` between draws
of the same csent within a frame to ghost multiple source ents was
considered. `SetupBones` is the expensive bit and per-frame re-setup
would dominate. A dedicated csent per source ent costs a client-side
entity slot per ghost (cheap) and lets each csent's skin / bones
state be set once on creation.

**Rejected: returning a `radar` library table from `cl_radar.lua`.**
An earlier iteration exposed a `radar.Register` / `radar.Instance`
API and called it from a single ENT shim. The module file shape is
identical either way; the registry-as-table version was strictly more
ceremony for no extra capability. The hook-based version (modules
populate the registry as a side effect of being included) is the one
in tree.

## Scale pivot and pan

**Decision:** "Pinned-pivot" scaling — the table's BSP altitude (`pivotZ
= self:GetPos():Dot(self:GetUp())`) is the scale fixed point, so content
at that altitude appears at `table.z + height` regardless of scale.

**Rejected: Scaling around the BSP origin (0,0,0).** Increasing scale
visually slid the entire mesh upward (or downward, depending on the map's
relative origin), forcing the user to re-tune `height` after every scale
change.

**Decision:** Pan is a 2-component BSP-space offset (`PanX`, `PanY`) that
shifts the cylinder horizontally so the BSP point at `(panX, panY)`
appears at the table center. Cylinder wall planes get `d = radius +
panOffset:Dot(n)`, the floor plane is unchanged, and the scene matrix
subtracts the rotated pan term `(rotPan / scale)` from its translation.
The all-in containment check, prop cull, and brush-entity cull all
subtract the axis-perpendicular component of the pan from each test
position before measuring distance.

**Decision:** `holo_table_autocenter` concommand fits the worldspawn
AABB inside the cylinder: scale is `ceil(half-diagonal * 1.05 / 90)`,
pan is the AABB XY centroid, and height is solved so the BSP floor
lands ~1 unit above the table top. The result is networked to the
server which writes it back to the four NetworkVars.

## Interactive controls

**Decision:** `sh_controls.lua` is a shared control module rather than
mixed into `init.lua` / `cl_init.lua`. Server-side ownership and net
receivers live in the `SERVER` branch; client input/HUD/concommands live
after the early server return. The control layer's only handles into the
rest of the entity are NetworkVar accessors, the
`ent.ComputeAutoCenter` method, and four net strings.
`sh_controls.lua` is `include`d at the top of `cl_init.lua` before
`cl_map.lua` (where `ENT:ComputeAutoCenter` lives), but references the
method only from callbacks that fire after all files load.

**Decision:** Toggle-on-`+use` grab. Pressing E on a holo table
makes the activator the controller; pressing again releases.
Pressing E on a *different* table while controlling the first
releases the first and grabs the second. Other players are locked
out for the duration.

**Rejected: Hold-to-grab.** Considered making control active only
while `+use` is held (like a SWEP secondary). Loses the WASD pan
because the player's `+use` hand can't simultaneously hold E and
move; also forces a timer to debounce the first release frame. The
toggle model is unambiguous and lets the user release by walking
away (`OnRemove` / `PlayerDisconnected`) without any keypress.

**Decision:** `ENT:SetUseType(SIMPLE_USE)` in `Initialize`. The
`base_anim` default is continuous-while-held, which fires `Use` every
tick the player holds E and produced a flicker between grab and
release as the toggle bounced. `SIMPLE_USE` fires exactly once per
press edge.

**Decision:** Server is the source of truth for ownership and the
final NetworkVar values. Client writes to NetworkVars optimistically
on every input event so the table reacts the same frame; the
server's snapshot replays the (clamped, ownership-checked)
authoritative value within ~RTT. `holo_table_setparams` is throttled
to ~30 Hz (`SEND_INTERVAL = 0.033`) when `dirty`; `holo_table_setlayers`
and `holo_table_autocenter` ship immediately on the edge.

**Rejected: Server-authoritative input (write only on snapshot
arrival).** Adds RTT/2 of input lag to every pan/scroll, which is
visible at 30+ ms even on a listen server.

**Decision:** Movement is read off the cmd's button bits via
`cmd:KeyDown(IN_FORWARD/IN_BACK/IN_MOVELEFT/IN_MOVERIGHT)` and
`IN_SPEED` for the zoom modifier. This respects the player's
`+forward`/`+moveleft`/`+speed` binds (ESDF, arrow keys, etc.)
without us having to chase rebinds. The HUD displays the bound keys
via `input.LookupBinding`.

**Decision:** `+reload` is polled raw via
`input.IsKeyDown(input.GetKeyCode(input.LookupBinding('+reload')))`
rather than `cmd:KeyDown(IN_RELOAD)`. The control layer has to
suppress the `+reload` bind in `PlayerBindPress` to silence the
held-weapon reload animation/sound, and that suppression *also*
prevents the engine from setting the `IN_RELOAD` cmd bit (because
the `+reload` concommand never executes). Polling the raw key
sidesteps the loop.

**Decision:** `+duck` (default Ctrl) is the precision modifier
(`PRECISION_MUL = 0.25` for pan speed and height step;
`1 + (SCALE_FACTOR - 1) * mul` for the multiplicative scale step).
Captured into a local *before* `cmd:RemoveKey(IN_DUCK)` scrubs the
bit. Without that order, the modifier would always read false.

**Decision:** Layer toggles (T = entities, G = map) are raw-keyed
(`input.IsKeyDown(KEY_T/KEY_G)`) with edge detection. There is no
`+entities` or `+map` concommand to bind-poll, and inventing one
would require maintaining custom binds the user is unlikely to
discover. T/G also conflict with the default `messagemode`
(team chat) and `+menu_context` (sandbox tool menu) binds, which we
swallow in `PlayerBindPress` while the controller is active. Trade-
off: a player who has rebound T/G to other binds gets nothing useful
from the toggles. Acceptable — these are tertiary actions and the
HUD labels them explicitly.

**Decision:** `cmd:SetMouseWheel(0)` *and* swallow `invnext` /
`invprev` / `lastinv` in `PlayerBindPress`. The bind layer fires
before `CreateMove` sees the cmd, so zeroing the wheel alone still
let the weapon-selection HUD pop up and play its click sound on
every scroll tick.

**Decision:** `findControlTarget` (in `sh_controls.lua`) prefers
the actively-controlled table, then the entity under the crosshair,
then the nearest holo table. Used by both the
`holo_table_autocenter` concommand and the `+reload` hotkey. A
separate `findAutoCenterTarget` lives next to `holo_table_profile`
in `cl_map.lua` (crosshair → nearest, no controlled-table
preference); the duplication is ~12 lines and keeps the dev tool
decoupled from the control module. The author has flagged
`holo_table_profile` as eventually-removable debug code, so
consolidation is deliberately deferred.

**Decision:** Cleanup paths are explicit: `ENT:ReleaseController`
clears `self.Controller` and notifies the client; `ENT:OnRemove`
calls it; `PlayerDisconnected` walks every holo table and releases
any owned by the leaver. Stale controllers would otherwise wedge
a table forever.

## Material handling

**Decision:** Hybrid — bsp2's regenerated `UnlitGeneric` materials for
faces whose original shader was `LightmappedGeneric` (which would render
black without a lightmap), original VMTs otherwise. Resolved once per
texinfo and cached.

**Decision:** Group draws by `$basetexture` name, falling back to
material name. bsp2 emits one unique material per texinfo (so the same
texture tiled across many faces becomes many materials); grouping by
texture collapses these back into one render batch.

**Decision:** Cache the `mi.materials → matByTexinfo` lookup table at
file scope, keyed by the `mi.materials` table identity. The lookup
itself is just a `mat:GetName()` loop, but on big maps that list is
huge (rp_venator: 5934 entries) and the loop costs ~230 ms — paid on
every `BuildClippedMap` call before this was hoisted. Reusing the
cache across builds drops worldspawn clip time on Venator from
~245 ms to ~10 ms (24x). Auto-invalidates whenever bsp2 swaps the
materials list (i.e. on map load), no explicit hook required.

**Decision:** `loadTexdataMaterial(name)` strips a stray leading `/`
from BSP texdata paths and re-`Material()`s. Some maps (rp_finalizer)
ship with paths like `/FIRSTORDERBANNER`; `Material()` returns the
error material on those, the resulting `error` basetexture lands in
the filter set, and the affected faces silently disappear from the
holo. The strip-and-retry is in the per-texinfo resolve so the cost
is paid at most once per material per map load.

**Decision:** `unlitWrap(src)` builds a runtime `UnlitGeneric` mat
keyed on `src`'s `$basetexture` name (`holo_table_unlit_<crc>`), used
when the bsp2 anonymous fallback for a `LightmappedGeneric` texinfo
carries an `error` / `color/white` basetexture (typically because the
same malformed texdata path defeated bsp2's regeneration). Without
this, faces using a corrected `Material()` mat that's still
`LightmappedGeneric` render black in the holo (no lightmap available).
Cached per basetexture name across all `holo_table_3d` instances.

**Decision:** `resolveMat` for `LightmappedGeneric` faces prefers
bsp2's per-texinfo `UnlitGeneric` fallback, but inspects its
`$basetexture` first — if it's in the filter set, fall back to
`unlitWrap` of the corrected `Material()` result. This combination
recovers banner / flag / dressing faces that previously rendered as
the error texture (and were filtered out entirely). Same logic
applied in `GetBrushModelMeshes`.

**Rejected: double-sided dressing via duplicate reversed-winding
geometry.** Map-dressing faces (banners, flags) recovered by
`unlitWrap` are sometimes embedded in walls so the BSP-defined side
points *away* from the holo camera, leaving them invisible. Tried
emitting a reversed-winding duplicate of every face that resolved to
an `unlitWrap` mat (tracked via a `holoDoubleSidedMat` set) so both
sides would render without `$nocull`'s mirrored-overlay artifact on
single-quad dressing. Two failure modes:
1. Many "thin brush" flags already have a coplanar back face in the
   BSP. The duplicate sat on top of it and z-fought into a flickering
   split appearance regardless of camera angle.
2. Pushing the duplicate by `+normal * 0.1` to dodge the back face
   z-fight (`HOLO_DUP_OFFSET`) instead caused subtle translucency
   artifacts across unrelated parts of the map mesh — likely the
   offset duplicate combined with the cylinder stencil and the
   `$vertexalpha` enabled on the wrap mat producing partial-alpha
   pixels. Removing the offset brought back the original z-fight.

The flags that motivated the experiment turned out to be inside
enclosed ship interiors and would not have been visible from outside
in the live world either — their absence in the holo is correct.
**Outcome:** all double-sided code reverted (`holoDoubleSidedMat`,
`HOLO_DUP_OFFSET`, the duplicate-emission blocks in `BuildClippedMap`
fast and slow paths, and in `GetBrushModelMeshes`). `unlitWrap`
itself is kept — it's still needed for these mats to render at all
from their primary side. Don't reintroduce the doubling without a
real per-face "is the back face already in the BSP?" check.

## Culling

**Decision:** Per-face bounding-sphere pre-cull, cached on the bsp2 face
table itself (`face._holoCull = {cx, cy, cz, fr}`). Survives rebuilds
within the same map load; recomputed only when bsp2 reloads. Stored as
scalars rather than a `Vector` so the per-face hot loop can run pure
number math.

**Decision:** Skip the wall-clip pass when a face's bounding sphere is
fully inside the cylinder (`horizDist + fr <= radius`); same for the
floor plane. Saves ~32 plane clips per fully-interior face. The
trivial-accept feeds directly into the per-face triangulation cache
(see "Build pipeline").

**Decision:** Per-wall-plane sphere skip inside the slow path. After
the per-face sphere is projected into the (right, fwd) basis once
(`cR = c·right, cF = c·fwd`), each wall normal's signed distance is
just `cR*cos + cF*sin` and any plane whose half-space already contains
the sphere is skipped before invoking the Sutherland–Hodgman pass.
Typically only 2–4 of the 32 walls actually cut a given boundary face.

**Decision:** Sutherland–Hodgman trivial-accept (Common Halfspace) and
trivial-reject — when every input vertex is inside, return the input
list unchanged; when every vertex is outside, return a shared empty
table. Distance scan is hoisted out of the clip pass into a single
shared scratch table (`clipDistScratch`) so the clip loop can read the
pre-computed distances directly. This makes interior faces in the
slow path effectively free and cuts the allocation rate on faces that
genuinely cross.

**Decision:** Scalarised per-face cull math. The basis vectors
(`axis`, `right`, `fwd`) and pan offset are unpacked into `x/y/z`
locals once per build, so the per-face along/horiz tests run as bare
multiplies and adds — no temporary `Vector`s, no `:Dot` calls, no
per-face `:Length()` (squared distance is compared against
squared radii). On a 21 k-face map this eliminates ~100 k temporary
Vector allocations per build.

**Decision:** For brush entities, sphere cull on `(maxs - mins).Length()
* 0.5` around `entPos`. Cheap and conservative; the GPU prism handles the
exact crop.

**Decision:** For static props, per-prop bounding sphere derived from
`Entity:GetModelBounds()` of a one-shot `ClientsideModel`, cached in a
file-level table. Sphere center is rotated into world space for
non-axis-aligned props before the cylinder/floor test.

**Decision:** For baked static props and baked `prop_dynamic`, sub-pixel
filtering is applied before building IMeshes so bakes preserve the legacy
renderer's "don't draw tiny dressing" behaviour. Static-prop bakes are
scale-specific; `prop_dynamic` bakes are signature-specific and rebuilt
when the watcher sees added/removed/reskinned stable entities. Moving
`prop_dynamic`s stay on the fallback path.

## Known limitations / deferred work

- **Translucent / alpha-tested materials.** The build emits a single
  opaque pass, so faces whose resolved mat is `$translucent` or
  `$alphatest` (glass windows, fences, grates) currently render as
  opaque black or get filtered out entirely. Needs a second
  `ClippedMeshes`-style list collected at `resolveMat` time for
  translucent shaders, drawn in a follow-up pass after the opaque
  one. Probably wants per-camera depth sorting on the translucent
  groups, or at minimum back-to-front draw order based on the
  hologram's center-out distance.
- **3D skybox.** `sky_camera` lookup is plumbed but no skybox rendering
  is implemented. Maps without a 3D skybox (like the Venator) are
  unaffected.
- **Map-dressing visible from non-BSP side.** `unlitWrap`-ed banner
  and flag faces are single-sided and invisible from the side the
  BSP face normal points away from. The duplicate-reversed-winding
  experiment (see "Rejected: double-sided dressing") didn't pan out;
  a real fix needs per-face detection of whether the BSP already
  contains a coplanar opposing face before deciding to emit a
  duplicate. Low priority — most affected dressing is occluded by
  surrounding interior geometry anyway.
- **Brush-entity cost.** Static props and `prop_dynamic` map dressing
  now have baked all-in paths, so brush entities are often the next
  meaningful steady-frame cost. A future pass could identify stable
  brush entities (`func_brush`, stable `C_BaseToggle`, etc.) and bake
  those while leaving doors/trains/rotating entities live.
- **Semi all-in cache.** When the cylinder is *almost* all-in (a
  handful of faces cross the boundary), every parameter change still
  triggers a full rebuild. A split where static interior geometry is
  kept as a permanent IMesh and only boundary faces are re-clipped
  per parameter change would let "near all-in" zoomed-in views run at
  cache-hit speed. Not implemented yet; only worth doing if the
  per-face cache + scalar math doesn't get rebuild times low enough
  for tight-fit framings to feel instant.
- **Brush-entity flash on first frame.** The unclipped `bsp2` fallback
  in `DrawMap` draws every face — including brush-entity faces stacked
  at the BSP origin — for the few frames before the first clipped build
  commits. Could be hidden by skipping non-worldspawn meshes in the
  fallback loop.
- **Chunked baked-prop visibility.** Static prop mode `3` intentionally
  draws whole material chunks and relies on the GPU clip prism, even in
  zoomed views. This is currently much faster than legacy or per-prop
  baked culling, but if the prism edge causes visible static props to
  poke beyond the intended cylinder, material-grouped spatial chunks or
  leaf grouping are the next design. Per-prop baked culling was measured
  and rejected for dense maps because draw-call count stayed too high.
- **Transformed AABB cull for brush entities.** Sphere cull is generous
  on long thin doors. A rotated AABB cull would reject a few more
  off-screen draws, but draw cost isn't currently measurable.
- **Stale `face._holoCull` / `face._holoTris` shape.** The cache shape
  has changed (e.g. cull went from `{vec, fr}` to `{cx, cy, cz, fr}`)
  and a defensive `not cull.cx` check rebuilds entries from a previous
  session's format. Once the format is stable across a release, the
  shape check can drop in favour of a simple version stamp.
