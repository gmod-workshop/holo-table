-- Map subsystem: BSP clipping, map dressing, brush entities, props,
-- auto-centering, and profiling. The subsystem is split into ordinary
-- includes; shared internals live on ENT.MapCache.

include('map/cl_map_shared.lua')
include('map/cl_map_materials.lua')
include('map/cl_map_prewarm.lua')
include('map/cl_map_static_props.lua')
include('map/cl_map_dynamic_props.lua')
include('map/cl_map_clip.lua')
include('map/cl_map_brushes.lua')
include('map/cl_map_core.lua')
include('map/cl_map_tools.lua')
