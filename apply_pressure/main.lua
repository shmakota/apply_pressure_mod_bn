gdebug.log_info("Apply Pressure V2: main")
local mod = game.mod_runtime[game.current_mod]
-- DEBUG TEST: gapi.get_avatar():add_effect(EffectTypeId.new("bleed"), TimeDuration.from_hours(99), BodyPartTypeId.new("torso"), 3)

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

-- Track how many turns in a row we’ve been applying pressure. Resets if interrupted.
local pressure_turns = 0

-- https://github.com/nexusmrsep/Cataclysm-DDA/blob/a9255023a6e245c002ed65f8ab6d7d30f1442198/src/player.cpp#L813
-- Based on nexusmrsep's work, completely rewritten. Note that this is V2, which is intended to function more closely to the original.
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
    local dur = you:get_effect_dur(EffectTypeId.new("bleed"), worst_bp) -- Duration of bleed effect
    local int = you:get_effect_int(EffectTypeId.new("bleed"), worst_bp) -- Intensity of bleed

    -- Calculate encumbrance penalty from both hands. High encumbrance = less effective.
    local encumb = you:get_part_encumbrance(BodyPartTypeId.new("hand_r")) + you:get_part_encumbrance(BodyPartTypeId.new("hand_l"))
    local penalty = TimeDuration.from_seconds(1) * encumb

    local benefit = TimeDuration.from_seconds(5) + TimeDuration.from_seconds(10) * you:get_skill_level(fa_skill)
    local difference = -( benefit - penalty )

    -- Attempt heal: If successful, reduce bleeding time by a specified amount.
    if you:is_limb_broken(BodyPartTypeIntId.new(BodyPartTypeId.new("arm_l"))) or you:is_limb_broken(BodyPartTypeIntId.new(BodyPartTypeId.new("arm_r"))) then
        -- Apply broken arm penalty: If either arm is broken, chance is further reduced.
        penalty = penalty*4
        gapi.add_msg(MsgType.warning, "Your broken limb significantly hampers your efforts to put pressure on the bleeding wound!")
        mod_duration(dur - TimeDuration.from_seconds(1), int, worst_bp)
        you:practice(fa_skill, 1, 1, false)
    elseif benefit <= penalty then
        -- Too encumbered, chance is very poor.
        effective_chance = effective_chance * 0.1
        gapi.add_msg(MsgType.warning, "Your hands are too encumbered to effectively put pressure on the bleeding wound!")
        mod_duration(dur - TimeDuration.from_seconds(1), int, worst_bp)
        you:practice(fa_skill, 1, 1, false)
    else
        -- Apply pressure successfully.
        local part_name = body_part_names[part_id] or "limb" -- Fallback to generic if not mapped
        gapi.add_msg(MsgType.info, string.format(
            "You apply pressure to your %s in an attempt to stop the bleeding! (-%s)",
            part_name, tostring(difference)))
        mod_duration(dur + difference, int, worst_bp)
        -- Practice first aid (better XP on success).
        you:practice(fa_skill, 1, 2, false)
    end

    -- Keep track of turns applying pressure. Increases odds next turn.
    pressure_turns = pressure_turns + 1
end

-- We don't have this exposed yet, but we can recreate it.
function mod_duration(dur_penalty, int, worst_bp)
    you:remove_effect(EffectTypeId.new("bleed"), worst_bp)
    you:add_effect(EffectTypeId.new("bleed"), dur_penalty, worst_bp, int)
end