@{
    WikiBaseUrl = 'https://github.com/AmyJeanes/Doors/wiki'
    Categories = @(
        @{ Title = 'Interior Reference'; File = 'Interior-Reference'; Roots = @('gmod_door_interior') }
        @{ Title = 'Exterior Reference'; File = 'Exterior-Reference'; Roots = @('gmod_door_exterior') }
        @{ Title = 'Portals Reference';  File = 'Portals-Reference';  Roots = @('doors_portal_side', 'doors_custom_portal') }
        @{ Title = 'Hooks Reference';    File = 'Hooks-Reference';    Kind = 'hooks'; CommonEntities = @('gmod_door_exterior', 'gmod_door_interior') }
        @{ Title = 'ConVars Reference';  File = 'ConVars-Reference';  Kind = 'convars' }
    )
    OwnedPrefix = @('doors_', 'gmod_door_')
}
