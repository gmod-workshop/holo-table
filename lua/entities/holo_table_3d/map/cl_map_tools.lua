local math_sqrt = math.sqrt
local math_max = math.max
local math_ceil = math.ceil

--- Fits the worldspawn AABB inside the cylinder. Pads the half-diagonal
--- ~5%, lands the BSP floor 1 unit above the table top to avoid z-fighting.
--- @return number? scale
--- @return number? panX BSP X centroid.
--- @return number? panY BSP Y centroid.
--- @return number? height
function ENT:ComputeAutoCenter()
    local bsp = bsp2 and bsp2.GetCurrent()
    if not bsp or not bsp.models or not bsp.models[1] then return end
    local m = bsp.models[1]

    local centerX = (m.mins.x + m.maxs.x) * 0.5
    local centerY = (m.mins.y + m.maxs.y) * 0.5
    local halfDX = (m.maxs.x - m.mins.x) * 0.5
    local halfDY = (m.maxs.y - m.mins.y) * 0.5

    local needRadius = math_sqrt(halfDX * halfDX + halfDY * halfDY) * 1.05
    local scale = math_max(1, math_ceil(needRadius / 90))

    -- Lands BSP mins.z (lowest map face along table-up) on the table top
    -- plus 1 unit clearance to dodge the floor clip plane.
    local axis = self:GetUp()
    local pivotZ = self:GetPos():Dot(axis)
    local minsAlong = m.mins:Dot(axis)
    local clearance = 1
    local height = 25 + clearance - (minsAlong - pivotZ) / scale

    return scale, centerX, centerY, height
end



--- Picks a target holo table for the profiling concommand: crosshair entity,
--- falling back to nearest. Distinct from sh_controls.findControlTarget
--- so the dev tool stays decoupled from the control module.
--- @return Entity?
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

-- Synchronous BuildClippedMap with stage-by-stage timings; bypasses the
-- coroutine and 150 ms debounce, frees its temporary meshes without
-- touching the live build pipeline.
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
