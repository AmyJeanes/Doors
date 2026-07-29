@{
    WikiBaseUrl = 'https://github.com/AmyJeanes/Doors/wiki'
    Categories = @(
        @{ Title = 'Interior Reference'; File = 'Interior-Reference'; Roots = @('gmod_door_interior'); Class = 'gmod_door_interior'; Source = 'lua/entities/gmod_door_interior' }
        @{ Title = 'Exterior Reference'; File = 'Exterior-Reference'; Roots = @('gmod_door_exterior'); Class = 'gmod_door_exterior'; Source = 'lua/entities/gmod_door_exterior' }
        @{ Title = 'Portals Reference';  File = 'Portals-Reference';  Roots = @('doors_portal_side', 'doors_custom_portal') }
        # Without a category the sound types render as bare unlinked names on Functions Reference, so the
        # whole authoring surface of Doors:PlaySound is documented nowhere.
        # doors_managed_sound is the Class rather than a Root on purpose: as a Root it would dump every
        # field of the handle's internal state onto a public page. Class renders its ---@api methods only.
        @{ Title = 'Sound Reference';    File = 'Sound-Reference';    Roots = @('doors_sound_opts'); Class = 'doors_managed_sound'; Source = 'lua/doors/libraries/sound'; Global = 'doors_managed_sound' }
        @{ Title = 'Functions Reference'; File = 'Functions-Reference'; Kind = 'functions'; Class = 'Doors' }
        @{ Title = 'Hooks Reference';    File = 'Hooks-Reference';    Kind = 'hooks'; CommonEntities = @('gmod_door_exterior', 'gmod_door_interior') }
        @{ Title = 'ConVars Reference';  File = 'ConVars-Reference';  Kind = 'convars' }
    )
    OwnedPrefix = @('doors_', 'gmod_door_')
}
