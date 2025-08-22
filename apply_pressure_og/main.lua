gdebug.log_info("Apply Pressure: main")
local mod = game.mod_runtime[game.current_mod]

-- Useful variables we will access alot.
local you = gapi.get_avatar()
local last_pos = you:get_pos_ms()
local fa_skill = SkillId.new("firstaid")

-- Mapping of body part ids to display names. Used for readable messages.
local body_part_names = {
    torso = "torso",
    head = "head",
    arm_r = "right arm",
    arm_l = "left arm",
    leg_r = "right leg",
    leg_l = "left leg"
}

-- List of body parts to check, in priority order. Torso/head first for realism.
local body_parts = {
    "torso",
    "head",
    "arm_r",
    "arm_l",
    "leg_r",
    "leg_l"
}

-- Utility: Get readable bleeding status from intensity. Used for message flavor.
local function get_bleeding_status(intensity)
    if intensity > 2 then
        return "heavy bleeding"
    elseif intensity > 1 then
        return "bad bleeding"
    else
        return "bleeding"
    end
end

-- Utility: Calculate chance to stop bleeding.
-- Returns a percent chance (0-100) based on skill and intensity.
local function get_stop_chance(int)
    -- At level 0: 1% chance with normal bleeding, 0.333% chance with heavy bleeding.
    -- Turns on average: 100 turns, 300 turns
    -- At level 5: 5% chance with normal bleeding, 1.667% chance with heavy bleeding.
    -- Turns on average: 20 turns, 60 turns
    -- At level 10 (vanilla max): 10% chance with normal bleeding, 3.333% chance with heavy bleeding.
    -- Turns on average: 10 turns, 30 turns
    local algorithm = (1 + (0.5 * you:get_skill_level(fa_skill)))/int
    -- This is a probability, not a percent. Multiply by 100 for percent if needed.
    return algorithm
end

-- Track how many turns in a row we’ve been applying pressure. Resets if interrupted.
local pressure_turns = 0

-- https://github.com/nexusmrsep/Cataclysm-DDA/blob/a9255023a6e245c002ed65f8ab6d7d30f1442198/src/player.cpp#L813
-- Based on nexusmrsep's work, completely rewritten. Note that this is not identical, this is chance based to lower intensity where as the original is duration based to lower intensity.
-- Stand still for 5 turns to attempt to apply pressure. Hand encumbrance, hauling, or a very low first aid skill hinder this action.
-- Can train up to first aid level 1, and will show percentage chance for each turn spent applying pressure.
-- Main function: Called every turn to attempt to stop bleeding if conditions are met.
function mod.bleed_stop()
    local wielding_item = you:is_armed() -- Are we holding something? Can't apply pressure if so.
    local pos = you:get_pos_ms() -- Current position for movement check

    -- Early return if player can't apply pressure, and update our variables.
    if pos ~= last_pos or wielding_item or you:is_hauling() then
        pressure_turns = 0
        last_pos = pos
        return
    end

    -- If multiple parts are tied for intensity, use the first in body_parts (priority: torso/head).
    local most_int = 0
    local worst_bp = nil
    for _, part in ipairs(body_parts) do
        local bp = BodyPartTypeId.new(part)
        local int = you:get_effect_int(EffectTypeId.new("bleed"), bp)
        if int and int > 0 then
            if int > most_int then
                most_int = int
                worst_bp = bp
            elseif int == most_int and not worst_bp then
                -- If tied, keep the first in body_parts order (priority)
                worst_bp = bp
            end
        end
    end

    -- Early return for no bleeding parts.
    if worst_bp == nil then
        return
    end

    -- Found a bleeding part to work on.
    local part_id = worst_bp:str() -- Get string id for lookup
    local part_name = body_part_names[part_id] or "limb" -- Fallback to generic if not mapped
    local dur = you:get_effect_dur(EffectTypeId.new("bleed"), worst_bp) -- Duration of bleed effect
    local int = you:get_effect_int(EffectTypeId.new("bleed"), worst_bp) -- Intensity of bleed
    gapi.add_msg(tostring(dur))
    gapi.add_msg(tostring(dur-TimeDuration.from_hours(1)))

    -- Calculate encumbrance penalty from both hands. High encumbrance = less effective.
    local penalty = you:get_part_encumbrance(BodyPartTypeId.new("hand_r")) 
                    + you:get_part_encumbrance(BodyPartTypeId.new("hand_l"))

    -- Base chance from skill and bleed intensity. Higher skill, lower intensity = better odds.
    local base_chance = get_stop_chance(int)

    -- Time bonus: Each consecutive turn applying pressure increases odds, up to a cap.
    -- Example: +0.02% per turn, capped at +3%.
    local time_bonus = math.min(pressure_turns * 0.02, 3) -- Related to the 5 turns hack.

    -- Apply encumbrance effect: If hands are too encumbered, chance is greatly reduced.
    local effective_chance = base_chance
    if penalty >= (8 + 10 * you:get_skill_level(fa_skill)) then
        -- Too encumbered, chance is very poor.
        effective_chance = effective_chance * 0.1
        gapi.add_msg(MsgType.warning, "Your hands are too encumbered to effectively put pressure on the bleeding wound!")
    end

    -- Apply broken arm penalty: If either arm is broken, chance is further reduced.
    if you:is_limb_broken(BodyPartTypeIntId.new(BodyPartTypeId.new("arm_l"))) or you:is_limb_broken(BodyPartTypeIntId.new(BodyPartTypeId.new("arm_r"))) then
        effective_chance = effective_chance * 0.25
        gapi.add_msg(MsgType.warning, "Your broken limb significantly hampers your efforts to put pressure on the bleeding wound!")
    end

    -- Add time bonus to final chance.
    local stop_chance = effective_chance + time_bonus

    -- Attempt roll: If successful, reduce or stop bleeding. Otherwise, message and try again next turn.
    if math.random(1, 100) <= stop_chance then
        you:remove_effect(EffectTypeId.new("bleed"), worst_bp)
        if int - 1 > 0 then
            local bleeding_status = get_bleeding_status(int)
            gapi.add_msg(MsgType.good, "You reduce the " .. bleeding_status .. " from your " .. part_name .. "!")
            you:add_effect(EffectTypeId.new("bleed"), dur, worst_bp, int - 1)
            -- DEBUG TEST: gapi.get_avatar():add_effect(EffectTypeId.new("bleed"), TimeDuration.from_hours(99), BodyPartTypeId.new("torso"), 3)
            pressure_turns = 0 -- Reset pressure turns, since bleeding intensity changed
        else
            gapi.add_msg(MsgType.good, "You manage to stop the bleeding from your " .. part_name .. "!")
            -- Reset pressure turns, since we're moving to a different limb
            pressure_turns = 0
        end
        -- Practice first aid (better XP on success).
        you:practice(fa_skill, 2, 3, false)
    else
        gapi.add_msg(MsgType.info, string.format(
            "You apply pressure to your %s in an attempt to stop the bleeding from your wound! (%.2f%%)",
            part_name, stop_chance))
        -- Practice first aid (always, but less XP on failure).
        you:practice(fa_skill, 1, 3, false)
    end

    -- Keep track of turns applying pressure. Increases odds next turn.
    pressure_turns = pressure_turns + 1
end