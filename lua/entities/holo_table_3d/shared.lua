ENT.Type            = 'anim'
ENT.Base            = 'base_anim'

ENT.PrintName       = 'Holography Table'
ENT.Author          = 'Doctor'

ENT.Spawnable       = true
ENT.AdminSpawnable  = true
ENT.Editable        = true

--- Declares the holo table's NetworkVars (layer toggles, view params, team).
function ENT:SetupDataTables()
    self:NetworkVar('Bool', 0, 'Entities', { KeyName = 'entities', Edit = { type = 'Boolean' }})
    self:NetworkVar('Bool', 1, 'Map', { KeyName = 'map', Edit = { type = 'Boolean' }})

    self:NetworkVar('Float', 0, 'Height', { KeyName = 'height', Edit = { type = 'Float', min = -500, max = 500 }})
    self:NetworkVar('Float', 1, 'Scale', { KeyName = 'scale', Edit = { type = 'Float', min = 1, max = 300 } })

    -- BSP-space pan: cylinder center lands at (PanX, PanY) instead of the BSP origin.
    self:NetworkVar('Float', 2, 'PanX', { KeyName = 'pan_x', Edit = { type = 'Float', min = -16384, max = 16384 } })
    self:NetworkVar('Float', 3, 'PanY', { KeyName = 'pan_y', Edit = { type = 'Float', min = -16384, max = 16384 } })

    -- 0 = neutral, 1 / 2 = opposing factions; compared against LVS AITEAM for ghost tinting.
    self:NetworkVar('Int', 0, 'Team', { KeyName = 'team', Edit = { type = 'Int', min = 0, max = 2 } })
end
