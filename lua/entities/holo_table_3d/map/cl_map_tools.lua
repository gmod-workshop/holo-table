local math_sqrt = math.sqrt
local math_max = math.max
local math_ceil = math.ceil

function ENT:ComputeAutoCenter()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.models or not bsp.models[1] then return end
    local m = bsp.models[1]

    local centerX = (m.mins.x + m.maxs.x) * 0.5
    local centerY = (m.mins.y + m.maxs.y) * 0.5
    local halfDX = (m.maxs.x - m.mins.x) * 0.5
    local halfDY = (m.maxs.y - m.mins.y) * 0.5

    -- Worst-case horizontal distance from the centroid is the AABB's
    -- half-diagonal; pad ~5% so map geometry never sits flush against the
    -- cylinder rim.
    local needRadius = math_sqrt(halfDX * halfDX + halfDY * halfDY) * 1.05
    local scale = math_max(1, math_ceil(needRadius / 90))

    -- A BSP point at altitude P.z appears at world altitude
    --   pivotZ + height + (P.z - pivotZ) / scale
    -- Setting that equal to (pivotZ + 25 + clearance) for P.z = mins.z
    -- (the lowest map face along the up axis) lands the floor on the
    -- table top. clearance = 1 keeps it from z-fighting the floor clip.
    local axis = self:GetUp()
    local pivotZ = self:GetPos():Dot(axis)
    local minsAlong = m.mins:Dot(axis)
    local clearance = 1
    local height = 25 + clearance - (minsAlong - pivotZ) / scale

    return scale, centerX, centerY, height
end



-- Picks a target holo table for the auto-center command: prefers the
-- entity under the player's crosshair, falls back to the nearest one
-- in the world. Returns nil if no holo table exists.
local function findAutoCenterTarget()
    local lp = LocalPlayer()
    if not IsValid(lp) then return end

    local trEnt = lp:GetEyeTrace().Entity
    if IsValid(trEnt) and trEnt:GetClass() == 'holo_table_3d' then
        return trEnt
    end

    local best, bestDist = nil, math.huge
    for _, e in ipairs(ents.FindByClass('holo_table_3d')) do
        local d = e:GetPos():DistToSqr(lp:GetPos())
        if d < bestDist then best, bestDist = e, d end
    end
    return best
end

-- The `holo_table_autocenter` concommand lives in sh_controls.lua so
-- it can share the find-target helper with the +reload hotkey.

-- Synchronously runs BuildClippedMap with the entity's current params,
-- prints stage-by-stage timings + counts, and frees the temporary
-- meshes without touching the live ClippedMeshes. Useful for
-- benchmarking changes to the clipper without touching the live build
-- pipeline (no debounce, no coroutine yields).
concommand.Add('holo_table_profile', function()
    local ent = findAutoCenterTarget()
    if not IsValid(ent) then
        MsgC(Color(255, 120, 120), '[holo_table] No holo_table_3d found.\n')
        return
    end
    if not (bsp2 and bsp2.GetCurrent()) then
        MsgC(Color(255, 120, 120), '[holo_table] bsp2 not loaded.\n')
        return
    end

    local scale = ent:GetScale()
    local height = ent:GetHeight()
    local panX = ent:GetPanX()
    local panY = ent:GetPanY()

    local stats = {}
    local list = ent:BuildClippedMap(scale, height, panX, panY, false, stats)
    for _, item in ipairs(list) do
        if item.mesh then item.mesh:Destroy() end
    end

    local total = (stats.tEnd - stats.tStart) * 1000
    local clip  = (stats.tClipEnd - stats.tStart) * 1000
    local mesh  = (stats.tEnd - stats.tClipEnd) * 1000
    MsgC(Color(120, 200, 255), string.format(
        '[holo_table] sync build %.1f ms (clip %.1f, imesh %.1f)\n' ..
        '  faces: total=%d rejected=%d fast=%d clipped=%d\n' ..
        '  walls: checked=%d skipped=%d cut=%d (skip ratio %.0f%%)\n' ..
        '  output: tris=%d meshes=%d\n',
        total, clip, mesh,
        stats.facesTotal, stats.facesRejected, stats.facesFast, stats.facesClipped,
        stats.planeChecked, stats.planeSkipped, stats.planeCut,
        stats.planeChecked > 0 and 100 * stats.planeSkipped / stats.planeChecked or 0,
        stats.outputTris, stats.meshes))
end)
