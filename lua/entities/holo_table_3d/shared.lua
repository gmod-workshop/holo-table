ENT.Type            = 'anim'
ENT.Base            = 'base_anim'

ENT.PrintName       = 'Holography Table'
ENT.Author          = 'Doctor'

ENT.Spawnable       = true
ENT.AdminSpawnable  = true
ENT.Editable        = true

function ENT:SetupDataTables()
    self:NetworkVar('Bool', 0, 'Entities', { KeyName = 'entities', Edit = { type = 'Boolean' }})
    self:NetworkVar('Bool', 1, 'Map', { KeyName = 'map', Edit = { type = 'Boolean' }})

    self:NetworkVar('Float', 0, 'Height', { KeyName = 'height', Edit = { type = 'Float', min = -500, max = 500 }})
    self:NetworkVar('Float', 1, 'Scale', { KeyName = 'scale', Edit = { type = 'Float', min = 1, max = 300 } })

    -- Pan offsets in BSP world coordinates: the cylinder is centered at
    -- (PanX, PanY) instead of the BSP origin, so the BSP point at that XY
    -- appears at the table center. Auto-center fills these from the
    -- worldspawn AABB centroid.
    self:NetworkVar('Float', 2, 'PanX', { KeyName = 'pan_x', Edit = { type = 'Float', min = -16384, max = 16384 } })
    self:NetworkVar('Float', 3, 'PanY', { KeyName = 'pan_y', Edit = { type = 'Float', min = -16384, max = 16384 } })

    -- Faction the table belongs to. 0 = neutral (every ghost reads as
    -- neutral), 1 / 2 = the two opposing factions. Compared against an
    -- LVS ghost's AITEAM to color the ghost friendly (blue), neutral
    -- (untinted) or hostile (red).
    self:NetworkVar('Int', 0, 'Team', { KeyName = 'team', Edit = { type = 'Int', min = 0, max = 2 } })
end
