-- EUI DoT Projection tracker: which of your DoTs are on which mob, and how much damage they still have to deal.
-- Ported from DoesItDie by Joe Greive (MIT, see LICENSE-DoesItDie): spell descriptions give the DoT, base damage
-- and duration; UNIT_COMBAT hits give the real tick sizes. Health stays secret, so nothing here touches it.
-- Changes from DoesItDie: no target frame display, settings in F.db, F.Breakdown(unit) for Plates.lua.
-- Synced with DoesItDie v0.9.3: hidden-amount ticks matched on school and timing, tick sizes learned from the
-- damage meter after combat, bleeds kept on the cast schedule, per-DoT size snapshots.

local addonName, addon = ...
local F = addon.GetFeature("DotProjection")
if not F then return end

local UPDATE_INTERVAL = 0.1
local DEFAULT_TICK_INTERVAL = 3
-- Seconds either side of an expected tick time. Observed on Forever: the first tick lands within ~0.1s of one
-- interval after the cast, and later ticks within ~0.1s of the first tick's rhythm. Tight windows keep melee
-- auto-attacks (same Physical school as bleeds, similar size, ~1s rhythm) from passing as ticks.
local TICK_MATCH_WINDOW = 0.45
local TICK_MATCH_WINDOW_ANCHORED = 0.25
local MISSED_TICKS_BEFORE_DROP = 2  -- a DoT that never ticks was resisted/immune
-- Projectile DoTs start when the projectile lands, not on the cast event: Serpent Sting's first tick came
-- 3.6-3.9s after the cast instead of 3s (log 253548.7, 12 casts). Their first tick may be this much later.
local PROJECTILE_TRAVEL = 1.5
local PROJECTILE_DOTS = {
    ["Serpent Sting"] = true, ["Fireball"] = true, ["Pyroblast"] = true, ["Frostfire Bolt"] = true,
}
-- Once a DoT's tick size is known, same-school hits further off than this are someone else's (the Imp's
-- Firebolt next to Immolate, white hits next to Rip). Ticks within one cast barely vary (15,15,15,16);
-- the minimum slack of 1 covers rounding (3 vs 4).
local TICK_AMOUNT_TOLERANCE = 0.25
-- Check for the first tick against a size learned on an earlier cast (gear/AP may have changed a little).
local FIRST_TICK_AMOUNT_TOLERANCE = 0.3
-- A crit tick is 1.5-2x a normal one; anything else flagged as a crit (white-hit crits) isn't this DoT.
local CRIT_MIN_RATIO, CRIT_MAX_RATIO = 1.3, 2.3
local DB_VERSION = 5                -- bump to discard learned data from older, buggier versions

-- Tick intervals that differ from the 3s default and aren't stated in the description.
local KNOWN_TICK_INTERVALS = {
    ["Insect Swarm"] = 2,
    ["Curse of Agony"] = 2,
    ["Bane of Agony"] = 2, -- Forever's name for Curse of Agony
    ["Fireball"] = 2,
    ["Holy Fire"] = 2,
    ["Rip"] = 2,
    ["Rupture"] = 2,
}

-- DoTs whose ticks aren't even: each tick is the average tick times its factor (factors average 1, so the
-- tooltip total still holds). Agony is back-loaded; seen in-game on Forever (log 166015.8, 72 over 24s):
-- ticks 3,3,3,3 then 6,6,... then 9s. Everything else ticks evenly.
local AGONY_SHAPE = { 0.5, 0.5, 0.5, 0.5, 1, 1, 1, 1, 1.5, 1.5, 1.5, 1.5 }
local TICK_SHAPES = {
    ["Bane of Agony"] = AGONY_SHAPE, -- Forever's name
    ["Curse of Agony"] = AGONY_SHAPE,
}

-- Descriptions that don't name their school.
local SCHOOL_BY_NAME = {
    ["Siphon Life"] = 32,
}

-- Read like DoTs but aren't one on the current target: ground/area effects, channels, traps, and
-- delayed damage (Wyvern Sting only starts after the sleep).
local IGNORED_SPELLS = {
    ["Rain of Fire"] = true, ["Hellfire"] = true, ["Blizzard"] = true, ["Flamestrike"] = true,
    ["Consecration"] = true, ["Hurricane"] = true, ["Volley"] = true,
    ["Drain Life"] = true, ["Drain Soul"] = true, ["Drain Mana"] = true, ["Health Funnel"] = true,
    ["Mind Flay"] = true, ["Arcane Missiles"] = true, ["Starshards"] = true,
    ["Immolation Trap"] = true, ["Explosive Trap"] = true, ["Wyvern Sting"] = true,
}

local SCHOOL_MASKS = {
    Physical = 1, Holy = 2, Fire = 4, Nature = 8, Frost = 16, Shadow = 32, Arcane = 64,
    Frostfire = 4 + 16, -- Forever's Frostfire Bolt: combined schools report as the OR of their masks
}

-- "Wait for first tick": whether a DoT counts toward the projection before its first tick has landed.
-- "unsure" = only when the starting estimate is shaky (finisher with unknown combo points, or no tick size
-- learned yet for that spell). Options.lua lists these.
F.WAIT_MODES = {
    values = { off = "Never", unsure = "When unsure", always = "Always" },
    order = { "off", "unsure", "always" },
}

local MAX_TRACE_LINES = 2000

local db
local dotsByTarget = {}     -- targetKey -> { [spellName] = dot }
local warnedSecretGuid = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local print = function(msg) F.Say(msg) end

-- Always recorded to SavedVariables (db.log) for diagnosing accuracy; echoed to chat with /dotp debug.
local function trace(msg)
    if not db then return end
    table.insert(db.log, string.format("%.1f %s", GetTime(), msg))
    if #db.log > MAX_TRACE_LINES then table.remove(db.log, 1) end
    if db.debug then print("|cff888888" .. msg .. "|r") end
end

local function isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r or false
end

-- Stable key for the mob behind a unit token, or nil if the unit can't be tracked.
-- The same hit arrives for target, nameplateN and softenemy, and their GUIDs may not all be readable,
-- so a hidden GUID only affects that one unit token.
local function unitKey(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if ok and not isSecret(guid) then return guid end
    if unit ~= "target" then return nil end
    if not warnedSecretGuid then
        warnedSecretGuid = true
        trace("Target GUID is secret; tracking DoTs on the current target only")
    end
    return "target"
end

-- Last hex block of a GUID (the spawn id), enough to tell mobs apart in the log.
local function shortKey(key)
    if type(key) ~= "string" then return tostring(key) end
    return key:match("%-(%x+)$") or key
end

local function spellNameAndDescription(spellID)
    local name, desc
    if C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(spellID)
    else
        name = GetSpellInfo(spellID)
    end
    local descFn = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
    if descFn then desc = descFn(spellID) end
    return name, desc
end

local function schoolFromWords(words)
    local school = SCHOOL_MASKS.Physical
    for word in words:gmatch("%a+") do
        if SCHOOL_MASKS[word] then school = SCHOOL_MASKS[word] end
    end
    return school
end

-- Finishers (Rip, Rupture) list their DoT per combo point:
--   "1 point : 243 damage over 12 sec. 2 points: 396 damage over 12 sec. ..."   (Rip; note the stray space)
--   "1 point: 25 damage over 8 secs\n ... 5 points: 87 damage over 16 secs"      (Rupture)
-- Returns total, school, duration for the given points (clamped to the listed range), or nil if the
-- finisher has no per-point DoT (e.g. Eviscerate).
local function parseFinisher(desc, comboPoints)
    local byPoints, highest = {}, 0
    for pointsText, amount, secs in desc:gmatch("(%d+) points?%s*:%s*(%d+) damage over (%d+%.?%d*) sec") do
        local points = tonumber(pointsText)
        byPoints[points] = { total = tonumber(amount), duration = tonumber(secs) }
        highest = math.max(highest, points)
    end
    if highest == 0 then return nil end
    local entry = byPoints[math.max(1, math.min(comboPoints, highest))] or byPoints[highest]
    return entry.total, SCHOOL_MASKS.Physical, entry.duration
end

-- Returns total damage, school mask, duration and (if the description states it) tick interval.
--   "... 10 Nature damage over 15 sec."  Takes the last such clause, so Immolate's
--       "11 Fire damage and then an additional 20 Fire damage over 15 sec" yields the periodic part.
--   "Transfers 15 health from the target to the caster every 3 sec. Lasts 30 sec."  (Siphon Life)
-- comboPoints is only used for finishers. (Rake/Garrote merely award a combo point, so finishers are
-- recognised by "Finishing move", not "combo point".)
local function parseDot(desc, comboPoints)
    if type(desc) ~= "string" or isSecret(desc) then return nil end
    if desc:find("Finishing move") then return parseFinisher(desc, comboPoints or 5) end
    -- Weapon enchants (rogue poisons) describe a proc DoT but aren't cast on the target. Match the enchant
    -- wording only: Lacerate's tooltip also mentions "weapon damage".
    if desc:find("[Cc]oats a weapon") then return nil end
    -- Heals over time: Forever's Renew reads "Heals the target of 830 damage over 15 sec".
    if desc:find("^Heals") then return nil end

    local total, school, duration
    for amount, words, secs in desc:gmatch("(%d+)%s*([%a ]-)%s*damage over (%d+%.?%d*) sec") do
        total, school, duration = tonumber(amount), schoolFromWords(words), tonumber(secs)
    end
    if total and duration > 0 then return total, school, duration end

    local amount, words, every = desc:match("(%d+)%s*([%a ]-)%s*damage every (%d+%.?%d*) sec")
    if not amount then
        amount, every = desc:match("(%d+) health.-every (%d+%.?%d*) sec")
        words = ""
    end
    local lasts = desc:match("[Ll]asts (%d+%.?%d*) sec")
    if amount and every and lasts then
        every, lasts = tonumber(every), tonumber(lasts)
        if every > 0 and lasts > 0 then
            return tonumber(amount) * math.floor(lasts / every + 0.5), schoolFromWords(words), lasts, every
        end
    end
end

-- The upfront hit of a spell that also leaves a DoT: the damage named before the DoT's own clause, averaged for a
-- range. "11 Fire damage and then an additional 20 Fire damage over 15 sec" (Immolate) -> 11; "19 to 23 damage and
-- an additional 39 damage over 9 sec" -> 21. 0 when there is none. The damage meter's total holds it too, so
-- learnFromMeter takes it out before dividing by the ticks.
local function parseDirectPart(desc)
    if type(desc) ~= "string" or isSecret(desc) then return 0 end
    local clauseAt
    for at in desc:gmatch("()%d+[%a ]-damage over %d") do clauseAt = at end
    if not clauseAt then return 0 end
    local head = desc:sub(1, clauseAt - 1)
    local lo, hi = head:match("(%d+) to (%d+)")
    if lo then return (tonumber(lo) + tonumber(hi)) / 2 end
    return tonumber(head:match("(%d+)[^%d]-damage")) or 0
end

---------------------------------------------------------------------------
-- DoT tracking
---------------------------------------------------------------------------

-- Best known average damage per tick: observed average of non-crit ticks, else learned from earlier casts,
-- else the description. Crits are one-offs, so they never raise the expectation for later ticks. For shaped
-- DoTs (TICK_SHAPES) ticks are stored divided by their factor, so this is the average tick, not the latest.
-- Before its own first readable tick a DoT keeps the size it was applied with (learnedAtApply): the store is shared
-- by every mob, so learning mid-fight must not move a running DoT's marker. A DoT applied with nothing learned still
-- picks up a size learned since; reset and relearn drop the snapshot (dropSnapshots). (DoesItDie v0.9.3)
local function expectedTick(dot)
    if dot.normalTicks > 0 then return dot.tickSum / dot.normalTicks end
    return dot.learnedAtApply or (dot.tickKey and db.ticks[dot.tickKey]) or (dot.total / dot.totalTicks)
end

-- Which tick of the DoT (1 = first) lands around `when`.
local function tickNumberAt(dot, when)
    return math.max(1, math.floor((when - dot.appliedAt) / dot.interval + 0.5))
end

-- The factor for tick `number` (1 for evenly ticking DoTs). Shapes are stretched to the DoT's tick count.
local function tickShape(dot, number)
    local shape = dot.shape
    if not shape then return 1 end
    local i = math.ceil(math.min(math.max(number, 1), dot.totalTicks) / dot.totalTicks * #shape)
    return shape[math.max(1, math.min(i, #shape))]
end

-- A waiting DoT doesn't count toward the marker until its first tick lands (see WAIT_MODES).
-- A doubtful DoT (an avoid right after the cast that may not have been its own) always waits.
local function isWaiting(dot)
    if dot.ticksSeen > 0 then return false end
    if dot.doubtful or db.waitFirstTick == "always" then return true end
    return db.waitFirstTick == "unsure" and dot.unsure
end

-- Real tick sizes from Blizzard's damage meter (DoesItDie v0.9.1). Forever hides UNIT_COMBAT amounts in combat, so
-- ticks are matched on school and timing and teach no size: the estimate was stuck on the description, which leaves
-- out attack/spell power (Rend 6548: description 59 over 18s, real ticks 14-18 each, ~96). After combat the meter's
-- per-spell totals are readable, so each DoT's total over the ticks counted this combat is its real average tick
-- (shaped DoTs weighted by their factors). An upfront hit (Immolate) is in the same total: it's split off in the
-- description's proportion. combatTally: learned-size key -> what this combat counted; combatUntracked: spells cast
-- at no known mob; combatReadable: keys a readable tick taught this combat. The meter counts every mob, the tally
-- only what was seen, so learnFromMeter only learns when the two can match.
local combatTally, combatUntracked, combatReadable = {}, {}, {}

-- This combat's tally, and a fresh one for the next (a new pull right after must not mix into it).
local function takeCombatTally()
    local counted = { keys = combatTally, untracked = combatUntracked, readable = combatReadable }
    combatTally, combatUntracked, combatReadable = {}, {}, {}
    return counted
end

local function tallyFor(dot)
    if not dot.tickKey then return nil end
    local t = combatTally[dot.tickKey]
    if not t then
        t = { spellID = dot.spellID, name = dot.name, factors = 0, ticks = 0, direct = 0,
            descTick = dot.total / dot.totalTicks, dots = {} }
        combatTally[dot.tickKey] = t
    end
    return t
end

local function tallyCast(dot, direct)
    local t = tallyFor(dot)
    if not t then return end
    t.dots[#t.dots + 1] = dot
    t.direct = t.direct + (direct or 0)
end

local function tallyHiddenTick(dot, factor)
    local t = tallyFor(dot)
    if t then
        t.factors = t.factors + factor
        t.ticks = t.ticks + 1
    end
end

-- Combo points, for finishers. By UNIT_SPELLCAST_SUCCEEDED they're already spent, so they're read when the
-- cast is sent. They were unreadable in combat on the Forever beta, so the addon also counts them itself:
-- builders say "Awards N combo point(s)" in their tooltips; a dodge/parry/miss right after takes them back;
-- a finisher or a target change resets the count. If neither source knows, finishers assume the lowest
-- entry, so the estimate errs low (no false skull) and nothing is learned from that cast.
local COMBO_CAP = 5
local COMBO_CACHE_SECONDS = 3
local comboAtSend, lastComboPoints, lastComboAt = nil, nil, 0
local countedPoints = 0

-- Cast outcomes. UNIT_COMBAT reports a dodge/parry/miss/resist/immune on the target, but not which attack it
-- belongs to. A cast's own result arrives almost at once (same frame in the logs), so the first outcome on the
-- target right after a cast decides: a hit means it landed, an avoid means it didn't. A melee auto-attack
-- avoided in that instant is rare; it makes the addon drop a DoT that landed, which errs low (never a false
-- kill). Results can also arrive just before the cast event, hence the short look-back.
local OUTCOME_WINDOW = 0.4
local OUTCOME_LOOKBACK = 0.25
local AVOIDED_ACTIONS = {
    MISS = true, DODGE = true, PARRY = true, EVADE = true, IMMUNE = true, DEFLECT = true, RESIST = true, REFLECT = true,
}
-- Spells can't be dodged or parried: next to a spell DoT, these were someone's melee (usually the pet's).
local MELEE_ONLY_AVOIDS = { DODGE = true, PARRY = true, DEFLECT = true }
local lastBuilder    -- { key, points, at }: builder whose outcome isn't known yet
local lastDotCast    -- { key, name, dot, previous, at }: DoT cast whose outcome isn't known yet
local lastOutcome    -- { key, avoided, action, school, at }: most recent outcome on a mob
-- The mob each cast was aimed at, by cast GUID, taken when the cast is sent. An instant DoT's
-- UNIT_SPELLCAST_SUCCEEDED comes a server round trip later, and a player who tabs to the next mob straight
-- away has changed target by then: the DoT used to be put on the new target.
local sentTargets = {} -- castGUID -> { key, at }
local SENT_TARGET_SECONDS = 10

local function describeReading(ok, value)
    if not ok then return "error" end
    if value == nil then return "nil" end
    if isSecret(value) then return "secret" end
    return tostring(value)
end

-- Returns the best plain reading (or nil) and a description of what each API returned, for the log.
local function readComboPoints()
    local best, parts = nil, {}
    local function consider(label, ok, points)
        table.insert(parts, label .. "=" .. describeReading(ok, points))
        if ok and type(points) == "number" and not isSecret(points) then best = math.max(best or 0, points) end
    end
    if GetComboPoints then consider("GetComboPoints", pcall(GetComboPoints, "player", "target")) end
    if UnitPower and Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
        consider("UnitPower", pcall(UnitPower, "player", Enum.PowerType.ComboPoints))
    end
    return best, table.concat(parts, " ")
end

local function rememberComboPoints()
    local points = readComboPoints()
    if points and points > 0 then lastComboPoints, lastComboAt = points, GetTime() end
    return points
end

local function isFinisherDescription(desc)
    return type(desc) == "string" and not isSecret(desc) and desc:find("Finishing move") ~= nil
end

local function onCastSent(spellID, castGUID)
    local now = GetTime()
    for guid, sent in pairs(sentTargets) do
        if now - sent.at > SENT_TARGET_SECONDS then sentTargets[guid] = nil end
    end
    if castGUID and not isSecret(castGUID) then sentTargets[castGUID] = { key = unitKey("target"), at = now } end
    local ok, _, desc = pcall(spellNameAndDescription, spellID)
    if not ok or not isFinisherDescription(desc) then return end
    local points, readings = readComboPoints()
    comboAtSend = points
    trace("COMBO at send: " .. readings .. ", counted=" .. countedPoints)
end

-- The mob a cast went to: the target when it was sent, else (no send seen) the target now.
local function castTargetKey(castGUID)
    local sent = castGUID and not isSecret(castGUID) and sentTargets[castGUID]
    if not sent then return unitKey("target") end
    sentTargets[castGUID] = nil
    return sent.key
end

-- An avoid on `key` that arrived just before the cast event (see OUTCOME_LOOKBACK), or nil.
local function avoidJustBefore(key)
    if lastOutcome and lastOutcome.avoided and lastOutcome.key == key
        and GetTime() - lastOutcome.at <= OUTCOME_LOOKBACK then
        return lastOutcome
    end
end

-- A builder was cast: count its points unless it was already avoided, else wait for its outcome.
local function onBuilderCast(key, points)
    local avoided = avoidJustBefore(key)
    if avoided then
        trace("COMBO builder " .. avoided.action .. " (before cast event), counted=" .. countedPoints)
        return
    end
    countedPoints = math.min(COMBO_CAP, countedPoints + points)
    lastBuilder = { key = key, points = points, at = GetTime() }
end

-- A DoT cast whose result was avoided isn't on the target: drop it. (Waiting for a first tick to prove it
-- instead doesn't work for bleeds: melee white hits look just like ticks.) A recast replaced a DoT that is
-- still ticking, so that one is put back.
-- Spell DoTs are different: the pet and other players' melee miss all the time, and their ticks are told apart
-- from melee by school. So an avoid that can't be the spell's is ignored, and one that might not be (not
-- reported in the spell's school) makes a new DoT wait for its first tick instead of dropping it.
-- Returns false if the avoid was ignored, so the cast's own outcome may still come.
local function removeAvoidedDot(cast, action, school)
    local dot = cast.dot
    local dots = dotsByTarget[cast.key]
    if not dots or dots[cast.name] ~= dot then return true end
    local spellSchool = type(school) == "number" and not isSecret(school) and school == dot.school
    if dot.school ~= SCHOOL_MASKS.Physical and not spellSchool then
        if MELEE_ONLY_AVOIDS[action] then
            trace(string.format("AVOID %s (school %s) right after %s: not the spell, ignored", action,
                tostring(school), cast.name))
            return false
        end
        if not cast.previous then
            dot.doubtful = true
            trace(string.format("AVOID %s (school %s) right after %s: may be someone else's, waiting for its first tick",
                action, tostring(school), cast.name))
            return true
        end
    end
    if cast.previous then
        dots[cast.name] = cast.previous
        trace(string.format("AVOID %s (school %s) right after %s recast; keeping the earlier one", action,
            tostring(school), cast.name))
    else
        dots[cast.name] = nil
        trace(string.format("AVOID %s (school %s) right after %s; dropped", action, tostring(school), cast.name))
    end
    return true
end

local function onAvoided(key, action, school)
    local now = GetTime()
    lastOutcome = { key = key, avoided = true, action = action, school = school, at = now }
    if lastBuilder and lastBuilder.key == key then
        if now - lastBuilder.at <= OUTCOME_WINDOW then
            countedPoints = math.max(0, countedPoints - lastBuilder.points)
            trace("COMBO builder " .. action .. ", counted=" .. countedPoints)
        end
        lastBuilder = nil
    end
    if lastDotCast and lastDotCast.key == key then
        if now - lastDotCast.at > OUTCOME_WINDOW or removeAvoidedDot(lastDotCast, action, school) then
            lastDotCast = nil
        end
    end
end

-- A hit on a mob: the pending casts on it landed (a later avoid belongs to something else). For a spell DoT
-- only a hit in its school says so (Immolate's direct damage); a melee hit is someone else's.
local function onHit(key, school)
    lastOutcome = { key = key, avoided = false, at = GetTime() }
    if lastBuilder and lastBuilder.key == key then lastBuilder = nil end
    if lastDotCast and lastDotCast.key == key
        and (lastDotCast.dot.school == SCHOOL_MASKS.Physical or lastDotCast.dot.school == school) then
        lastDotCast = nil
    end
end

local function resetComboCount()
    countedPoints, lastBuilder = 0, nil
end

-- Returns points and where they came from, or nil and "unknown".
local function comboPointsForCast()
    local points, source = comboAtSend, "read"
    if not (points and points > 0) then
        if lastComboPoints and GetTime() - lastComboAt <= COMBO_CACHE_SECONDS then
            points, source = lastComboPoints, "cached"
        elseif countedPoints > 0 then
            points, source = countedPoints, "counted"
        else
            points, source = nil, "unknown"
        end
    end
    comboAtSend = nil
    resetComboCount()
    return points, source
end

-- Returns the target key the DoT was applied to, or nil if the cast wasn't a tracked DoT.
local function onPlayerCast(spellID, castGUID)
    local key = castTargetKey(castGUID)
    local ok, name, desc = pcall(spellNameAndDescription, spellID)
    if not ok or not name or isSecret(name) then return end
    if type(desc) == "string" and not isSecret(desc) then
        local awarded = tonumber(desc:match("Awards (%d+) combo point"))
        if awarded then onBuilderCast(key, awarded) end
    end
    if IGNORED_SPELLS[name] then return end
    local isFinisher = isFinisherDescription(desc)
    local comboPoints, comboSource
    if isFinisher then comboPoints, comboSource = comboPointsForCast() end
    -- Unknown points: parse the lowest entry (errs low), and don't use or teach learned tick sizes.
    local total, school, duration, statedInterval = parseDot(desc, comboPoints or 1)
    if not total then return end
    -- A finisher's tick size depends on the points spent, so learned sizes are kept per point count.
    local tickKey = spellID
    if isFinisher then tickKey = comboPoints and (spellID .. "x" .. comboPoints) or nil end

    if not key then
        combatUntracked[spellID] = true -- the damage meter still counts what this cast deals
        return
    end

    local now = GetTime()
    local interval = statedInterval or KNOWN_TICK_INTERVALS[name] or DEFAULT_TICK_INTERVAL
    school = SCHOOL_BY_NAME[name] or school
    dotsByTarget[key] = dotsByTarget[key] or {}
    local previous = dotsByTarget[key][name]
    dotsByTarget[key][name] = {
        spellID = spellID,
        name = name,
        tickKey = tickKey,
        -- The size learned before this cast (expectedTick, referenceTickSize).
        learnedAtApply = tickKey and db.ticks[tickKey] or nil,
        school = school,
        total = total,
        duration = duration,
        interval = interval,
        totalTicks = math.max(1, math.floor(duration / interval + 0.5)),
        shape = TICK_SHAPES[name],
        travel = PROJECTILE_DOTS[name] and PROJECTILE_TRAVEL or nil,
        appliedAt = now,
        expiresAt = now + duration,
        nextTickAt = now + interval,
        tickSum = 0,        -- non-crit ticks only
        normalTicks = 0,
        ticksSeen = 0,      -- including crits
        missed = 0,
        readableHits = 0,   -- hits on the mob during this DoT, for the log
        blindHits = 0,      -- ...and those whose amount/school was secret
    }
    local dot = dotsByTarget[key][name]
    lastDotCast = { key = key, name = name, dot = dot, previous = previous, at = now }
    tallyCast(dot, isFinisher and 0 or parseDirectPart(desc)) -- a finisher's point table is no upfront hit
    local learned = tickKey and db.ticks[tickKey]
    -- The starting estimate is shaky without a learned tick size (description numbers leave out spell power
    -- and attack power) or, for finishers, without knowing the combo points.
    dot.unsure = not learned
    trace(string.format("CAST %s (id %d)%s on %s: %d dmg over %ss, school %d, tick every %ss, per-tick %s%s%s%s", name,
        spellID, isFinisher and string.format(" %s combo points (%s)", comboPoints or "?", comboSource) or "",
        shortKey(key), total, duration, school, interval, learned and ("learned " .. learned) or "from description",
        previous and string.format(", refreshing one cast %.1fs ago", now - previous.appliedAt) or "",
        isWaiting(dot) and ", waiting for first tick" or "",
        key ~= unitKey("target") and (" on " .. tostring(key) .. ", the target when sent") or ""))
    local avoided = avoidJustBefore(key)
    if avoided and removeAvoidedDot(lastDotCast, avoided.action, avoided.school) then
        lastDotCast = nil
        if dotsByTarget[key] and dotsByTarget[key][name] == dot then return key, isWaiting(dot) end
        return nil
    end
    return key, isWaiting(dot)
end

-- Seconds between now and the nearest expected tick time, and that tick's index. Anchored on the first tick
-- once seen (ticks keep its rhythm; anchoring on the latest tick would let jitter add up), else on the cast.
-- Using the nearest multiple of the interval means one missed tick doesn't lose the DoT.
local function distanceToExpectedTick(dot, now)
    local anchor = dot.firstTickAt or dot.appliedAt
    if not dot.firstTickAt and dot.travel then
        -- Still in flight: the DoT started anywhere up to `travel` seconds after the cast.
        local late = now - (anchor + dot.interval)
        if late > 0 then anchor = anchor + math.min(late, dot.travel) end
    end
    local k =math.max(1, math.floor((now - anchor) / dot.interval + 0.5))
    return math.abs(now - (anchor + k * dot.interval)), k
end

local function plausibleTickAmount(dot, amount, isCrit, number)
    local known, tolerance
    if dot.normalTicks > 0 then
        known, tolerance = dot.tickSum / dot.normalTicks, TICK_AMOUNT_TOLERANCE
    else
        known, tolerance = dot.tickKey and db.ticks[dot.tickKey], FIRST_TICK_AMOUNT_TOLERANCE
    end
    if not known then return true end
    known = known * tickShape(dot, number)
    if isCrit then
        return amount >= known * CRIT_MIN_RATIO - 1 and amount <= known * CRIT_MAX_RATIO + 1
    end
    return math.abs(amount - known) <= math.max(1, known * tolerance)
end

-- Tick size to judge a same-slot collision by: the average of the DoT's earlier ticks, or with fewer than two
-- ticks the size learned before this cast, else the description's per-tick share. Not the live learned size, which
-- is what the disputed tick just wrote. Learned first: descriptions leave out spell and attack power, so their share
-- sits far below real ticks, and judging by it took a white hit for the tick.
local function referenceTickSize(dot)
    if dot.normalTicks > 1 then
        return (dot.tickSum - dot.lastTickAmount / dot.lastTickShape) / (dot.normalTicks - 1)
    end
    return dot.learnedAtApply or (dot.total / dot.totalTicks)
end

local function saveLearnedTick(dot)
    if dot.tickKey and dot.normalTicks > 0 then
        db.ticks[dot.tickKey] = math.floor(dot.tickSum / dot.normalTicks * 10 + 0.5) / 10
        combatReadable[dot.tickKey] = true -- the meter's total then holds ticks the tally didn't count
    end
end

-- A running DoT that has not ticked readably keeps the size it was applied with (expectedTick). When the store is
-- reset or relearned, that snapshot is as wrong as the store was: drop it so the DoT follows the store again.
-- key nil = every DoT.
local function dropSnapshots(key)
    for _, dots in pairs(dotsByTarget) do
        for _, dot in pairs(dots) do
            if dot.normalTicks == 0 and (key == nil or dot.tickKey == key) then dot.learnedAtApply = nil end
        end
    end
end
F.DropSnapshots = dropSnapshots

-- Moves a DoT's tick bookkeeping to the tick in slot `index` that landed at `now`.
local function anchorTick(dot, index, now)
    dot.missed = 0
    if dot.firstTickAt then
        dot.lastTickIndex = index
    else
        dot.firstTickAt, dot.lastTickIndex = now, 0
        -- A projectile DoT started when it landed: count its ticks from there.
        if dot.travel then dot.appliedAt = now - index * dot.interval end
    end
    dot.lastTickAt = now
    dot.nextTickAt = now + dot.interval
    -- Re-anchor expiry on the observed tick: ticks arrive slightly after their nominal time, and an
    -- expiry based on the cast event would otherwise cut off the final tick.
    local tickIndex = math.max(1, math.floor((now - dot.appliedAt) / dot.interval + 0.5))
    dot.expiresAt = now + (dot.totalTicks - tickIndex) * dot.interval
    return tickIndex
end

-- Two same-school hits in one tick slot (e.g. Shadow Bolt landing with a Corruption tick, log 123506.4): the
-- first one was taken as the tick. If this one is closer to the expected size, it was the real tick.
local SAME_SLOT_SECONDS = 0.2
local function trySwapSameSlot(dot, name, amount, isCrit, now)
    if isCrit or dot.lastTickCrit or not dot.lastTickAt or now - dot.lastTickAt > SAME_SLOT_SECONDS then
        return false
    end
    local factor = dot.lastTickShape
    local reference = referenceTickSize(dot) * factor
    if math.abs(amount - reference) >= math.abs(dot.lastTickAmount - reference) then return false end
    trace(string.format("SWAP %s tick: %d was another hit, %d is the tick", name, dot.lastTickAmount, amount))
    dot.tickSum = dot.tickSum + (amount - dot.lastTickAmount) / factor
    dot.lastTickAmount = amount
    saveLearnedTick(dot)
    return true
end

-- A learned size that's wrong rejects every real tick (log: Corruption learned 29 from Shadow Bolts, real ticks
-- 10-11, every cast dropped). Hits rejected only on size, but landing on the DoT's rhythm in two consecutive
-- slots and agreeing with each other, are the real ticks: relearn from them.
local function tryRelearn(dot, name, amount, isCrit, index, distance, now)
    local window = dot.firstTickAt and TICK_MATCH_WINDOW_ANCHORED or TICK_MATCH_WINDOW
    local freshSlot = not dot.firstTickAt or index > dot.lastTickIndex
    if isCrit or not freshSlot or distance > window then return false end
    local previous = dot.offBeatCandidate
    local factor = tickShape(dot, tickNumberAt(dot, now))
    local average = amount / factor
    dot.offBeatCandidate = { index = index, amount = amount, average = average, at = now }
    if not previous or index ~= previous.index + 1
        or math.abs(average - previous.average) > math.max(1, previous.average * TICK_AMOUNT_TOLERANCE) then
        return false
    end
    trace(string.format("RELEARN %s: ticks of %d and %d on its rhythm didn't fit %.1f/tick", name,
        previous.amount, amount, expectedTick(dot)))
    dot.offBeatCandidate = nil
    dot.tickSum, dot.normalTicks = previous.average + average, 2
    dot.ticksSeen = dot.ticksSeen + 2
    dot.lastTickAmount, dot.lastTickShape, dot.lastTickCrit = amount, factor, false
    saveLearnedTick(dot)
    if dot.tickKey then dropSnapshots(dot.tickKey) end -- other mobs' DoTs that haven't ticked must not keep the old size
    if not dot.firstTickAt then
        dot.firstTickAt, dot.lastTickIndex = previous.at, 0
        index = 1
    end
    anchorTick(dot, index, now)
    return true
end

-- Hidden hits: Forever hides UNIT_COMBAT damage amounts in combat (secret), while the action and school stay readable.
-- The addon used to give up then and run DoTs on their timer, so it never learned a real tick size. Now (DoesItDie
-- v0.9.1/v0.9.3) a hidden hit is matched on school and timing alone: one in a DoT's school, on its rhythm, in a slot
-- not yet taken, is its tick. That keeps the DoT (a resisted one still gets no ticks and is dropped), counts the
-- tick for the damage meter tally (learnFromMeter), but teaches no size by itself.

local function combatState()
    return InCombatLockdown() and "in combat" or "out of combat"
end

-- Logs each switch between readable and hidden hit amounts, so the log shows when (and whether) they're secret.
local hitsBlind -- nil until the first hit; then whether the latest one was unreadable
local function noteReadability(blind, unit, amount, school)
    if hitsBlind == blind then return end
    hitsBlind = blind
    trace(string.format("%s hits (on %s: amount=%s, school=%s, %s)%s", blind and "BLIND" or "READABLE", unit,
        describeReading(true, amount), describeReading(true, school), combatState(),
        blind and ": ticks matched on school and timing, sizes learned from the damage meter after combat" or ""))
end

-- The same hit arrives once per unit token showing the mob (target, nameplateN, focus...) and must count once. But
-- two DoTs of one school can tick in the same instant: those are two hits from the same token. So within an instant
-- each signature (mob, amount, school) remembers its token and the DoTs it fed: a repeat from the same token feeds
-- another DoT, one from another token is a copy (returns nil).
local combatFrameAt
local combatFrameHits = {}
local function hitRecord(signature, unit, now)
    if combatFrameAt ~= now then
        combatFrameHits = {}
        combatFrameAt = now
    end
    local hit = combatFrameHits[signature]
    if hit then
        if hit.unit ~= unit then return nil end
    else
        hit = { unit = unit, fed = {} }
        combatFrameHits[signature] = hit
    end
    return hit
end

-- Physical bleeds can take a white hit landing in the window for a tick, so their hidden hits never move the rhythm:
-- they stay on the schedule from the cast (first ticks land within ~0.1s of it). Anchoring on white hits let Rend's
-- schedule drift a little earlier with each one, until the marker ran out a tick before Rend did (DoesItDie v0.9.3).
local function countHiddenTickOnSchedule(dot, index)
    dot.missed = 0
    dot.hiddenSlot = index
    local nextTickAt = dot.appliedAt + (index + 1) * dot.interval
    if nextTickAt > dot.nextTickAt then dot.nextTickAt = nextTickAt end
    return index
end

-- Returns the target key when this hit was the first tick of a DoT that was waiting for it, else nil.
local function onHiddenAmountHit(key, unit, school)
    local dots = dotsByTarget[key]
    if not dots then return end
    local now = GetTime()
    local hit = hitRecord(key .. ":hidden:" .. school, unit, now)
    if not hit then return end
    for _, dot in pairs(dots) do dot.blindHits = dot.blindHits + 1 end
    local best, bestName, bestDistance, bestIndex
    for name, dot in pairs(dots) do
        if not hit.fed[name] and dot.school == school then
            local distance, index = distanceToExpectedTick(dot, now)
            local window = dot.firstTickAt and TICK_MATCH_WINDOW_ANCHORED or TICK_MATCH_WINDOW
            local freshSlot
            if dot.firstTickAt then
                freshSlot = index > dot.lastTickIndex
            else
                freshSlot = index > (dot.hiddenSlot or 0)
            end
            if freshSlot and distance <= window and (not bestDistance or distance < bestDistance) then
                best, bestName, bestDistance, bestIndex = dot, name, distance, index
            end
        end
    end
    if not best then
        trace(string.format("HIT (amount hidden) school %d on %s not matched to a DoT", school, unit))
        return
    end
    local wasWaiting = isWaiting(best)
    best.ticksSeen = best.ticksSeen + 1
    best.lastTickAmount, best.lastTickShape, best.lastTickCrit = 0, tickShape(best, tickNumberAt(best, now)), false
    best.offBeatCandidate = nil
    local tickIndex
    if school == SCHOOL_MASKS.Physical and not best.firstTickAt then
        tickIndex = countHiddenTickOnSchedule(best, bestIndex)
    else
        tickIndex = anchorTick(best, bestIndex, now)
    end
    hit.fed[bestName] = true
    tallyHiddenTick(best, best.lastTickShape)
    trace(string.format("TICK %s (amount hidden) on %s (tick %d/%d, +%.2fs after cast, expecting %.1f for this tick)%s",
        bestName, unit, tickIndex, best.totalTicks, now - best.appliedAt, expectedTick(best) * best.lastTickShape,
        wasWaiting and ", now shown" or ""))
    if wasWaiting then return key end
end

local LEARN_MIN_FACTORS = 2                       -- at least two (average) ticks' worth this combat
local LEARN_RATIO_MIN, LEARN_RATIO_MAX = 0.5, 2.5 -- real vs description outside this: something else got mixed in
local LEARN_WEIGHT_CAP = 20                       -- older fights count as at most this many ticks, so gear catches up

-- Why a key isn't learned from this combat, or nil. "" skips quietly (nothing was counted).
local function meterSkipReason(key, t, counted, totals, keysPerSpell)
    if t.factors < LEARN_MIN_FACTORS then
        return t.ticks > 0 and string.format("only %d tick(s) counted", t.ticks) or ""
    end
    if counted.readable[key] then return "a readable tick already taught it" end
    -- Ticks of a DoT cast before this combat: the casts that fed the meter aren't in this tally.
    if #t.dots == 0 then return "not cast this combat" end
    if counted.untracked[t.spellID] then return "a cast had no known target, so the meter has damage not counted here" end
    for _, dot in ipairs(t.dots) do
        if dot.ticksSeen == 0 then return "a cast's DoT never showed a tick (out of sight, or the mob died first)" end
    end
    if not totals[t.spellID] then return "no readable damage meter total" end
    if keysPerSpell[t.spellID] > 1 then return "several combo point sizes share one meter total" end
end

-- spells: the damage meter's per-spell rows for the combat that just ended ({ spellID, totalAmount }); counted: that
-- combat's tally (takeCombatTally). Learns a real average tick for every DoT whose ticks were counted. Returns how
-- many sizes were learned.
local function learnFromMeter(spells, counted)
    counted = counted or takeCombatTally()
    db.tickWeights = db.tickWeights or {}
    local totals = {}
    for _, sp in ipairs(spells or {}) do
        local id, amount = sp.spellID, sp.totalAmount
        if not isSecret(id) and not isSecret(amount) and type(amount) == "number" then totals[id] = amount end
    end
    local keysPerSpell = {}
    for _, t in pairs(counted.keys) do keysPerSpell[t.spellID] = (keysPerSpell[t.spellID] or 0) + 1 end
    local learned = 0
    for key, t in pairs(counted.keys) do
        local total, name = totals[t.spellID], t.name or tostring(t.spellID)
        local skip = meterSkipReason(key, t, counted, totals, keysPerSpell)
        if skip then
            if skip ~= "" then trace(string.format("LEARN %s skipped: %s", name, skip)) end
        else
            local ratio = total / (t.direct + t.descTick * t.factors)
            if ratio < LEARN_RATIO_MIN or ratio > LEARN_RATIO_MAX then
                trace(string.format("LEARN %s skipped: meter %d over %d tick(s) is %.2fx the description", name,
                    total, t.ticks, ratio))
            else
                local tick = ratio * t.descTick
                local old, weight = db.ticks[key], math.min(db.tickWeights[key] or 0, LEARN_WEIGHT_CAP)
                if not old then weight = 0 end
                local blended = (((old or 0) * weight) + tick * t.factors) / (weight + t.factors)
                db.ticks[key] = math.floor(blended * 10 + 0.5) / 10
                db.tickWeights[key] = weight + t.factors
                dropSnapshots(key)
                learned = learned + 1
                trace(string.format("LEARN %s: meter %d over %d tick(s)%s = %.1f per tick (description %.1f), saved %.1f",
                    name, total, t.ticks, t.direct > 0 and " minus upfront hit" or "", tick, t.descTick, db.ticks[key]))
            end
        end
    end
    return learned
end
F.LearnFromMeter = learnFromMeter

-- Returns the target key when this hit was the first tick of a DoT that was waiting for it (so the display
-- can flash now that the DoT shows), else nil.
local function onUnitCombat(unit, action, flag, amount, school)
    if isSecret(action) then return end
    if not AVOIDED_ACTIONS[action] and action ~= "WOUND" then return end
    local key = unitKey(unit)
    if not key then return end
    if AVOIDED_ACTIONS[action] then return onAvoided(key, action, school) end
    local schoolKnown = not isSecret(school) and type(school) == "number"
    -- A secret school can't even be compared, so onHit only gets a readable one.
    onHit(key, schoolKnown and school or nil)
    local readable = schoolKnown and not isSecret(amount) and type(amount) == "number"
    noteReadability(not readable, unit, amount, school)
    if not readable then
        if schoolKnown then return onHiddenAmountHit(key, unit, school) end
        return
    end
    local dots = dotsByTarget[key]
    if not dots then return end

    -- The same hit fires for target, nameplateN, softenemy...: handle it once (see hitRecord).
    local now = GetTime()
    local hit = hitRecord(key .. ":" .. amount .. ":" .. school, unit, now)
    if not hit then return end
    local isCrit = not isSecret(flag) and flag == "CRITICAL"
    for _, dot in pairs(dots) do dot.readableHits = dot.readableHits + 1 end

    local best, bestName, bestDistance, bestIndex
    for name, dot in pairs(dots) do
        if not hit.fed[name] and dot.school == school
            and plausibleTickAmount(dot, amount, isCrit, tickNumberAt(dot, now)) then
            local distance, index = distanceToExpectedTick(dot, now)
            local window = dot.firstTickAt and TICK_MATCH_WINDOW_ANCHORED or TICK_MATCH_WINDOW
            -- Each tick slot takes one hit: a second hit near an already-matched tick is someone else's.
            local freshSlot = not dot.firstTickAt or index > dot.lastTickIndex
            if freshSlot and distance <= window and (not bestDistance or distance < bestDistance) then
                best, bestName, bestDistance, bestIndex = dot, name, distance, index
            end
        end
    end
    if not best then
        -- Not a tick as things stand; it may still correct one (same-slot swap, or a wrong learned size).
        for name, dot in pairs(dots) do
            if not hit.fed[name] and dot.school == school then
                local distance, index = distanceToExpectedTick(dot, now)
                local wasWaiting = isWaiting(dot)
                if trySwapSameSlot(dot, name, amount, isCrit, now) then
                    hit.fed[name] = true
                    return
                end
                if tryRelearn(dot, name, amount, isCrit, index, distance, now) then
                    hit.fed[name] = true
                    return wasWaiting and key or nil
                end
            end
        end
        trace(string.format("HIT %d%s school %d on %s not matched to a DoT", amount, isCrit and " (crit)" or "",
            school, unit))
        return
    end

    local wasWaiting = isWaiting(best)
    local factor = tickShape(best, tickNumberAt(best, now))
    best.ticksSeen = best.ticksSeen + 1
    best.lastTickAmount, best.lastTickShape, best.lastTickCrit = amount, factor, isCrit
    best.offBeatCandidate = nil
    if not isCrit then
        best.tickSum = best.tickSum + amount / factor
        best.normalTicks = best.normalTicks + 1
        saveLearnedTick(best)
    end
    hit.fed[bestName] = true
    local tickIndex = anchorTick(best, bestIndex, now)
    trace(string.format("TICK %s %d%s on %s (tick %d/%d, expecting %.1f for this tick)%s", bestName, amount,
        isCrit and " CRIT" or "", unit, tickIndex, best.totalTicks, expectedTick(best) * factor,
        wasWaiting and ", now shown" or ""))
    if wasWaiting then return key end
end

-- Whether hits on a mob reach the addon right now. UNIT_COMBAT only reports unit tokens (the target, focus and
-- visible nameplates), so a mob you tabbed away from, with nameplates off or out of their range, ticks unseen.
-- Its DoTs used to be dropped as "never ticked", which lost every earlier mob when chain pulling.
local function isObservable(key)
    if unitKey("target") == key or unitKey("focus") == key then return true end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and unitKey(unit) == key then return true end
    end
    return false
end

local function dotStats(key, dot)
    return string.format("on %s: ticks %d, hits on mob %d readable / %d unreadable", shortKey(key), dot.ticksSeen,
        dot.readableHits, dot.blindHits)
end

local function housekeep(now)
    -- Only a tick that could have been seen counts as missed: the mob on a unit token. Hidden hits are matched on
    -- school and timing now (onHiddenAmountHit), so a DoT that never ticks is still dropped as resisted.
    for key, dots in pairs(dotsByTarget) do
        for name, dot in pairs(dots) do
            local late = (dot.ticksSeen == 0 and dot.travel) or 0
            while dot.nextTickAt < now - TICK_MATCH_WINDOW - late and dot.nextTickAt <= dot.expiresAt do
                dot.nextTickAt = dot.nextTickAt + dot.interval
                if dot.ticksSeen == 0 and isObservable(key) then dot.missed = dot.missed + 1 end
            end
            if now > dot.expiresAt + TICK_MATCH_WINDOW then
                dots[name] = nil
                trace(string.format("EXPIRE %s (%s)", name, dotStats(key, dot)))
            elseif dot.ticksSeen == 0 and dot.missed >= MISSED_TICKS_BEFORE_DROP then
                dots[name] = nil
                trace(string.format("DROP %s never ticked, resisted or immune? (%s)", name, dotStats(key, dot)))
            end
        end
        if next(dots) == nil then dotsByTarget[key] = nil end
    end
end

-- A tick counts as dealt this long before it's due, not when housekeep gives up on it (TICK_MATCH_WINDOW after).
-- Counting it late shows damage the mob already took: after the last Rend tick the plate still promised 7 more
-- for ~0.5s, a skull on a mob that then survived (log 3106.2: ticks due +3.0s, plate dropped them at +3.6s).
-- Early errs low: for an instant the projection misses a tick that's about to land.
local TICK_EARLY = 0.15

local function remainingDamage(dot, now)
    local nextTick = dot.nextTickAt
    if now >= nextTick - TICK_EARLY then nextTick = nextTick + dot.interval end
    if nextTick > dot.expiresAt + dot.interval / 2 then return 0 end
    local ticksLeft = math.floor((dot.expiresAt - nextTick) / dot.interval + 0.5) + 1
    if not dot.shape then return ticksLeft * expectedTick(dot) end
    local average, total = expectedTick(dot), 0
    for number = math.max(1, dot.totalTicks - ticksLeft + 1), dot.totalTicks do
        total = total + average * tickShape(dot, number)
    end
    return total
end

-- Remaining damage per DoT on a mob (by unitKey), oldest application first. DoTs still waiting for their first
-- tick are left out.
local function dotBreakdown(key)
    local dots = key and dotsByTarget[key]
    local list = {}
    if not dots then return list end
    local now = GetTime()
    for name, dot in pairs(dots) do
        if not isWaiting(dot) then
            table.insert(list, { name = name, school = dot.school, appliedAt = dot.appliedAt,
                damage = remainingDamage(dot, now) })
        end
    end
    table.sort(list, function(a, b) return a.appliedAt < b.appliedAt end)
    return list
end

---------------------------------------------------------------------------
-- What Plates.lua and Init.lua use
---------------------------------------------------------------------------

F.trace = trace
F.UnitKey = unitKey
F.ShortKey = shortKey

-- The DoTs on a mob (by F.UnitKey): per-DoT breakdown and total remaining damage.
function F.BreakdownKey(key)
    local list = dotBreakdown(key)
    local total = 0
    for _, entry in ipairs(list) do total = total + entry.damage end
    return list, total
end

-- The DoTs on the mob behind `unit` (e.g. "nameplate3").
function F.Breakdown(unit)
    return F.BreakdownKey(unitKey(unit))
end

-- Mobs with tracked DoTs (read only; Plates.lua uses it to log DoTs no plate shows).
function F.TrackedKeys()
    return pairs(dotsByTarget)
end

-- The mob died (Plates.lua sees its plate go): its DoTs are gone with it.
function F.ForgetMob(key)
    if not (key and dotsByTarget[key]) then return end
    for name, dot in pairs(dotsByTarget[key]) do
        trace(string.format("DIED with %s still ticking (%s)", name, dotStats(key, dot)))
    end
    dotsByTarget[key] = nil
end

-- F.db is ready (Init.lua, onLoad).
function F.TrackerInit()
    db = F.db
    local version, build, _, interface = GetBuildInfo()
    local metadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local addonVersion = metadata and metadata(addonName, "Version") or "?"
    trace(string.format("===== session start: client %s.%s, interface %s, addon %s =====", tostring(version),
        tostring(build), tostring(interface), tostring(addonVersion)))
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")   -- combo points, before a finisher spends them
frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")   -- keeps a recent combo point reading as backup
frame:RegisterEvent("UNIT_COMBAT")
-- Never register COMBAT_LOG_EVENT_UNFILTERED: Forever forbids it and shows a "blocked" popup.

frame:SetScript("OnEvent", function(_, event, ...)
    if not db then return end
    if event == "PLAYER_TARGET_CHANGED" then
        dotsByTarget.target = nil -- only used when the target's GUID is secret
        resetComboCount() -- combo points belong to the target they were built on
    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, _, castGUID, spellID = ...
        onCastSent(spellID, castGUID)
    elseif event == "UNIT_POWER_FREQUENT" then
        local _, powerType = ...
        if not isSecret(powerType) and powerType == "COMBO_POINTS" then rememberComboPoints() end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, castGUID, spellID = ...
        onPlayerCast(spellID, castGUID)
    elseif event == "UNIT_COMBAT" then
        onUnitCombat(...)
    end
end)

-- After combat: read this combat's per-spell totals from the damage meter and learn tick sizes from them. The totals
-- can take a few seconds to show up and stop being secret, so it tries again for a while ("wait"). Every table is
-- checked before it's read (a row can be secret or off limits), all under one pcall.
local METER_TRIES, METER_RETRY_SECONDS = 20, 0.5

local function readableTable(v)
    if isSecret(v) or type(v) ~= "table" then return false end
    if type(canaccesstable) ~= "function" then return true end
    local ok, allowed = pcall(canaccesstable, v)
    return ok and allowed == true
end

local function meterSpellsNow()
    local DM = C_DamageMeter
    if type(DM) ~= "table" or type(DM.GetCombatSessionSourceFromType) ~= "function" then return nil, "no damage meter" end
    if type(DM.IsDamageMeterAvailable) == "function" then
        local okAvailable, available = pcall(DM.IsDamageMeterAvailable)
        if okAvailable and available == false then return nil, "switched off" end
    end
    local dmgType = Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone or 0
    local current = Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current or 1
    local ok, spells, why = pcall(function()
        local src = DM.GetCombatSessionSourceFromType(current, dmgType, UnitGUID("player"))
        if not readableTable(src) or not readableTable(src.combatSpells) then return nil, "wait" end
        local list = src.combatSpells
        local n = #list
        if isSecret(n) or type(n) ~= "number" or n == 0 then return nil, "wait" end
        local rows = {}
        for i = 1, n do
            local sp = list[i]
            if readableTable(sp) then
                if isSecret(sp.totalAmount) or isSecret(sp.spellID) then return nil, "wait" end
                rows[#rows + 1] = { spellID = sp.spellID, totalAmount = sp.totalAmount }
            end
        end
        return rows
    end)
    if not ok then return nil, "unreadable" end
    return spells, why
end

local function learnAfterCombat(counted, triesLeft)
    if not db then return end
    if InCombatLockdown() then
        trace("LEARN skipped: a new fight started before the damage meter could be read")
        return
    end
    local spells, why = meterSpellsNow()
    if not spells and why == "wait" and triesLeft > 0 then
        C_Timer.After(METER_RETRY_SECONDS, function() learnAfterCombat(counted, triesLeft - 1) end)
        return
    end
    if not spells then
        trace("LEARN skipped: damage meter " .. (why == "wait" and "still empty or hidden" or tostring(why)))
        return
    end
    learnFromMeter(spells, counted)
end

local meterFrame = CreateFrame("Frame")
meterFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
meterFrame:SetScript("OnEvent", function()
    local counted = takeCombatTally()
    if not db or next(counted.keys) == nil then return end
    C_Timer.After(METER_RETRY_SECONDS, function() learnAfterCombat(counted, METER_TRIES) end)
end)

-- DoesItDie ran housekeeping inside its display refresh; here it gets its own tick.
local sinceHousekeep = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    sinceHousekeep = sinceHousekeep + elapsed
    if sinceHousekeep < UPDATE_INTERVAL or not db then return end
    sinceHousekeep = 0
    housekeep(GetTime())
end)
