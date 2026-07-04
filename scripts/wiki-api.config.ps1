@{
    WikiBaseUrl = 'https://github.com/AmyJeanes/Doors/wiki'
    Categories = @(
        @{ Title = 'Interior Reference'; File = 'Interior-Reference'; Roots = @('gmod_door_interior') }
        @{ Title = 'Exterior Reference'; File = 'Exterior-Reference'; Roots = @('gmod_door_exterior') }
        @{ Title = 'Portals Reference';  File = 'Portals-Reference';  Roots = @('doors_portal_side', 'doors_custom_portal') }
        @{ Title = 'Functions Reference'; File = 'Functions-Reference'; Kind = 'functions'; Class = 'Doors' }
        @{ Title = 'gmod_door_exterior'; File = 'gmod_door_exterior'; Kind = 'functions'; Class = 'gmod_door_exterior'; Source = 'lua/entities/gmod_door_exterior' }
        @{ Title = 'gmod_door_interior'; File = 'gmod_door_interior'; Kind = 'functions'; Class = 'gmod_door_interior'; Source = 'lua/entities/gmod_door_interior' }
        @{ Title = 'Hooks Reference';    File = 'Hooks-Reference';    Kind = 'hooks'; CommonEntities = @('gmod_door_exterior', 'gmod_door_interior') }
        @{ Title = 'ConVars Reference';  File = 'ConVars-Reference';  Kind = 'convars' }
    )
    OwnedPrefix = @('doors_', 'gmod_door_')
}
