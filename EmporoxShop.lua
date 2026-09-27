_addon.name = 'EmporoxShop'
_addon.author = 'n0gr1p + OpenAI'
_addon.version = '0.1.4'
_addon.commands = {'emps', 'emporoxshop'}

local packets = require('packets')
local res = require('resources')
local socket_ok, socket = pcall(require, 'socket')

local EMPOROX_NAME = 'Emporox'
local MAX_NPC_DISTANCE = 6.0
local PROGRESS_TIMEOUT_SECONDS = 4.00
local TICK_SECONDS = 0.05

local function now()
    if socket_ok and socket and socket.gettime then
        return socket.gettime()
    end
    return os.clock()
end

local function chat(message, color)
    windower.add_to_chat(color or 207, '[EmporoxShop] ' .. tostring(message))
end

local function fail(message)
    chat(message, 167)
end

local session = {
    mode = 'idle',
    item_id = nil,
    item_name = nil,
    requested = 0,
    sent_count = 0,
    acked_count = 0,
    npc_id = nil,
    npc_index = nil,
    zone_id = nil,
    candidate = nil,
    template = nil,
    template_verified = false,
    deadline = nil,
    last_tick = 0,
    last_potpourri = nil,
    started_inventory_count = 0,
}

local function clear_session()
    session.mode = 'idle'
    session.item_id = nil
    session.item_name = nil
    session.requested = 0
    session.sent_count = 0
    session.acked_count = 0
    session.npc_id = nil
    session.npc_index = nil
    session.zone_id = nil
    session.candidate = nil
    session.template = nil
    session.template_verified = false
    session.deadline = nil
    session.last_tick = 0
    session.started_inventory_count = 0
end

local function abort_session(reason)
    if session.mode ~= 'idle' then
        fail('Stopped: ' .. tostring(reason))
    end
    clear_session()
end

local function item_name_matches(item, wanted)
    return item and item.en and wanted and item.en:lower() == wanted:lower()
end

local function find_item(name)
    for id, item in pairs(res.items) do
        if item_name_matches(item, name) then
            return tonumber(id), item
        end
    end
    return nil, nil
end

local function inventory_item_count(item_id)
    local items = windower.ffxi.get_items()
    local inventory = items and items.inventory or nil
    if not inventory then
        return 0
    end

    local total = 0
    for _, slot in pairs(inventory) do
        if type(slot) == 'table' and tonumber(slot.id) == tonumber(item_id) then
            total = total + (tonumber(slot.count) or 0)
        end
    end
    return total
end

local function mob_distance(mob)
    if not mob then
        return nil
    end

    local me = windower.ffxi.get_mob_by_target('me')
    if me and me.x ~= nil and me.y ~= nil and mob.x ~= nil and mob.y ~= nil then
        local dx = tonumber(mob.x) - tonumber(me.x)
        local dy = tonumber(mob.y) - tonumber(me.y)
        return math.sqrt(dx * dx + dy * dy)
    end

    if mob.distance and mob.distance >= 0 then
        return math.sqrt(mob.distance)
    end

    return nil
end

local function find_emporox()
    local npc = windower.ffxi.get_mob_by_name(EMPOROX_NAME)
    if not npc then
        return nil, nil, 'Emporox is not available in this zone'
    end

    local distance = mob_distance(npc)
    if not distance then
        return nil, nil, 'could not determine distance to Emporox'
    end
    if distance >= MAX_NPC_DISTANCE then
        return nil, distance, string.format(
            'Emporox is %.2f yalms away; move within %.1f',
            distance,
            MAX_NPC_DISTANCE
        )
    end

    return npc, distance, nil
end

local function validate_session_npc()
    local info = windower.ffxi.get_info()
    if not info or not info.logged_in then
        return nil, nil, 'client is not logged in'
    end
    if tonumber(info.zone) ~= tonumber(session.zone_id) then
        return nil, nil, 'zone changed'
    end

    local npc = session.npc_id and windower.ffxi.get_mob_by_id(session.npc_id) or nil
    if not npc and session.npc_index then
        npc = windower.ffxi.get_mob_by_index(session.npc_index)
    end
    if not npc then
        return nil, nil, 'Emporox no longer resolves'
    end
    if npc.name ~= EMPOROX_NAME then
        return nil, nil, 'saved NPC is no longer Emporox'
    end
    if tonumber(npc.id) ~= tonumber(session.npc_id) or
       tonumber(npc.index) ~= tonumber(session.npc_index) then
        return nil, nil, 'Emporox identity changed'
    end

    local distance = mob_distance(npc)
    if not distance or distance >= MAX_NPC_DISTANCE then
        return nil, distance, 'moved out of range of Emporox'
    end

    return npc, distance, nil
end

local function copy_menu_packet(p)
    return {
        ['Target'] = p['Target'],
        ['Option Index'] = p['Option Index'],
        ['_unknown1'] = p['_unknown1'],
        ['Target Index'] = p['Target Index'],
        ['Automated Message'] = p['Automated Message'],
        ['_unknown2'] = p['_unknown2'],
        ['Zone'] = p['Zone'],
        ['Menu ID'] = p['Menu ID'],
    }
end

local function packet_summary(p)
    if not p then
        return 'none'
    end

    return string.format(
        'option=%s unknown1=%s auto=%s unknown2=%s zone=%s menu=%s',
        tostring(p['Option Index']),
        tostring(p['_unknown1']),
        tostring(p['Automated Message']),
        tostring(p['_unknown2']),
        tostring(p['Zone']),
        tostring(p['Menu ID'])
    )
end

local function finish_success()
    local current = inventory_item_count(session.item_id)
    chat(string.format(
        'Complete: received %d/%d x %s. Inventory count %d -> %d.',
        session.acked_count,
        session.requested,
        session.item_name,
        session.started_inventory_count,
        current
    ), 158)
    clear_session()
end

local function inject_next_purchase()
    local _, _, reason = validate_session_npc()
    if reason then
        abort_session(reason)
        return false
    end
    if not session.template then
        abort_session('no learned purchase packet is available')
        return false
    end
    if session.sent_count >= session.requested then
        return false
    end

    -- 0x05C for purchase N arrives before the inventory item packet for N.
    -- Permit exactly one not-yet-observed item while chaining. If the previous
    -- item ACK has fallen farther behind, fail closed instead of racing ahead.
    local unacked = session.sent_count - session.acked_count
    if unacked > 1 then
        abort_session(string.format(
            'inventory ACKs fell behind (%d sent, %d received)',
            session.sent_count,
            session.acked_count
        ))
        return false
    end

    local next_number = session.sent_count + 1
    packets.inject(packets.new('outgoing', 0x05B, session.template))
    session.sent_count = next_number
    session.mode = 'running'
    session.deadline = now() + PROGRESS_TIMEOUT_SECONDS

    chat(string.format(
        'Purchase %d/%d sent immediately from Emporox continuation.',
        session.sent_count,
        session.requested
    ))
    return true
end

local function begin_buy(item_name, quantity)
    if session.mode ~= 'idle' then
        fail('Addon is already busy. Use //emps stop first.')
        return
    end

    quantity = tonumber(quantity)
    if not quantity or quantity < 1 or quantity ~= math.floor(quantity) then
        fail('Quantity must be a positive whole number.')
        return
    end
    if quantity > 9999 then
        fail('Refusing quantities above 9999.')
        return
    end

    local item_id, item = find_item(item_name)
    if not item_id then
        fail('Unknown item: ' .. tostring(item_name))
        return
    end

    local npc, distance, reason = find_emporox()
    if not npc then
        fail(reason)
        return
    end

    local info = windower.ffxi.get_info()
    if not info or not info.logged_in or not info.zone then
        fail('You must be logged in.')
        return
    end

    session.mode = 'teaching'
    session.item_id = item_id
    session.item_name = item.en
    session.requested = quantity
    session.sent_count = 0
    session.acked_count = 0
    session.npc_id = npc.id
    session.npc_index = npc.index
    session.zone_id = tonumber(info.zone)
    session.candidate = nil
    session.template = nil
    session.template_verified = false
    session.deadline = nil
    session.started_inventory_count = inventory_item_count(item_id)

    chat(string.format(
        'Armed for %d x %s (item id %d). Emporox is %.2f yalms away.',
        quantity,
        item.en,
        item_id,
        distance
    ))
    chat('I will open Emporox. Navigate to the requested item and purchase ONE manually.')
    chat('After the Yes packet is captured, Emporox continuations will chain the remaining purchases.')

    packets.inject(packets.new('outgoing', 0x01A, {
        ['Target'] = npc.id,
        ['Target Index'] = npc.index,
    }))
end

local function show_status()
    if session.mode == 'idle' then
        local pot = session.last_potpourri and tostring(session.last_potpourri) or 'unknown'
        chat('Idle. Last observed Potpourri: ' .. pot .. '.')
        return
    end

    local current = inventory_item_count(session.item_id)
    local pot = session.last_potpourri and tostring(session.last_potpourri) or 'unknown'
    chat(string.format(
        'mode=%s item=%s sent=%d/%d received=%d/%d inventory=%d potpourri=%s verified=%s',
        session.mode,
        tostring(session.item_name),
        session.sent_count,
        session.requested,
        session.acked_count,
        session.requested,
        current,
        pot,
        tostring(session.template_verified)
    ))
end

local function show_help()
    chat('//emps buy <item name> <quantity> - learn one manual Emporox purchase, then repeat it.')
    chat('Example: //emps buy Ghastly Stone 200')
    chat('//emps status - show sent/received progress.')
    chat('//emps stop - immediately stop automation.')
    chat('Safety: Emporox 0x05C advances purchases; exact-item inventory packets audit every result.')
end

windower.register_event('addon command', function(...)
    local args = {...}
    local command = args[1] and tostring(args[1]):lower() or 'help'

    if command == 'buy' then
        if #args < 3 then
            show_help()
            return
        end

        local quantity = tonumber(args[#args])
        if not quantity then
            fail('The last argument must be the quantity.')
            return
        end

        local name_parts = {}
        for i = 2, #args - 1 do
            name_parts[#name_parts + 1] = tostring(args[i])
        end
        begin_buy(table.concat(name_parts, ' '), quantity)

    elseif command == 'status' then
        show_status()

    elseif command == 'stop' or command == 'cancel' then
        if session.mode == 'idle' then
            chat('Already idle.')
        else
            abort_session('cancelled by user')
        end

    else
        show_help()
    end
end)

windower.register_event('outgoing chunk', function(id, original, modified, injected, blocked)
    if id ~= 0x05B or session.mode == 'idle' or blocked then
        return
    end
    if injected then
        return
    end

    local ok, p = pcall(packets.parse, 'outgoing', original)
    if not ok or not p then
        return
    end

    local is_emporox =
        tonumber(p['Target']) == tonumber(session.npc_id) and
        tonumber(p['Target Index']) == tonumber(session.npc_index)

    if not is_emporox then
        return
    end

    local is_cleanup =
        tonumber(p['Option Index']) == 0 and
        tonumber(p['_unknown1']) == 16384 and
        not p['Automated Message']

    -- Intermediate 0x05C packets are blocked, so this normally never appears.
    -- Keep the guard as a second line of defense while purchases remain.
    if is_cleanup and session.sent_count < session.requested then
        chat('Blocked intermediate Emporox dialog cleanup.')
        return true
    end

    if session.mode == 'teaching' then
        session.candidate = copy_menu_packet(p)
        session.template = session.candidate
        session.sent_count = 1
        session.deadline = now() + PROGRESS_TIMEOUT_SECONDS

        chat('Observed manual Emporox purchase response: ' .. packet_summary(session.template))
        return
    end

    if session.mode == 'draining' and is_cleanup then
        return
    end

    abort_session('manual Emporox menu input detected during replay')
end)

windower.register_event('incoming chunk', function(id, data)
    if id == 0x118 then
        local ok, p = pcall(packets.parse, 'incoming', data)
        if ok and p and p['Potpourri'] ~= nil then
            session.last_potpourri = tonumber(p['Potpourri'])
        end
        return
    end

    if session.mode == 'idle' then
        return
    end

    -- Emporox sends 0x05C when the current Yes response has advanced.
    -- The known-working bulk sequence sends the next identical 0x05B directly
    -- from this callback, before allowing the client event script to consume
    -- the continuation.
    if id == 0x05C then
        if not session.template then
            abort_session('Emporox continued before a purchase response was learned')
            return true
        end

        local completed_number = session.sent_count
        session.deadline = now() + PROGRESS_TIMEOUT_SECONDS

        if completed_number < session.requested then
            chat(string.format(
                'Emporox continuation for purchase %d/%d; chaining next purchase now.',
                completed_number,
                session.requested
            ))

            inject_next_purchase()

            -- Keep the client in the confirmation event state. The next
            -- purchase has already been sent above.
            return true
        end

        -- The requested number of purchase responses has now been accepted.
        -- Let the final continuation reach the normal client so its menu can
        -- return to the item list while we wait for any trailing item ACK.
        session.mode = 'draining'
        chat('Final Emporox continuation received; allowing normal menu cleanup.')

        if session.acked_count >= session.requested then
            finish_success()
        end
        return
    end

    -- A new inventory stack is 0x01F; an existing stack update is 0x020.
    if id ~= 0x01F and id ~= 0x020 then
        return
    end

    local ok, p = pcall(packets.parse, 'incoming', data)
    if not ok or not p then
        return
    end
    if tonumber(p['Item']) ~= tonumber(session.item_id) then
        return
    end

    -- One exact-item packet is expected for each Emporox purchase. Never let
    -- acknowledgements outrun purchase responses.
    if session.acked_count < session.sent_count then
        session.acked_count = session.acked_count + 1
    end
    session.deadline = now() + PROGRESS_TIMEOUT_SECONDS

    if not session.template_verified then
        session.template_verified = true
        chat(string.format(
            'Learned purchase response verified by exact item packet 0x%03X.',
            id
        ))
    end

    chat(string.format(
        'Item ACK %d/%d for %s via 0x%03X (packet count=%s).',
        session.acked_count,
        session.requested,
        session.item_name,
        id,
        tostring(p['Count'])
    ))

    if session.mode == 'draining' and session.acked_count >= session.requested then
        finish_success()
    end
end)

windower.register_event('prerender', function()
    if session.mode == 'idle' or not session.deadline then
        return
    end

    local t = now()
    if t - (session.last_tick or 0) < TICK_SECONDS then
        return
    end
    session.last_tick = t

    if t >= session.deadline then
        abort_session(string.format(
            'no Emporox progress for %.2fs (sent %d/%d, received %d/%d)',
            PROGRESS_TIMEOUT_SECONDS,
            session.sent_count,
            session.requested,
            session.acked_count,
            session.requested
        ))
    end
end)

windower.register_event('zone change', function()
    if session.mode ~= 'idle' then
        abort_session('zone changed')
    end
end)

windower.register_event('unload', function()
    clear_session()
end)
