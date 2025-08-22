gdebug.log_info("Apply Pressure OG: preload")
local mod = game.mod_runtime[game.current_mod]

-- Register the hook (5 turns duration is a hack to make sure we aren't applying pressure when moving, but also ends up being good balance. with higher skill you're unlikely to bleed out, but still possible)
gapi.add_on_every_x_hook(TimeDuration.from_turns(5), function() mod.bleed_stop() end)