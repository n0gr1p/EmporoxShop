_addon.name = 'EmporoxShop'
_addon.author = 'n0gr1p + OpenAI'
_addon.version = '0.1.3'
_addon.commands = {'emps', 'emporoxshop'}

local packets = require('packets')
local res = require('resources')
local socket_ok, socket = pcall(require, 'socket')

local EMPOROX_NAME = 'Emporox'
local MAX_NPC_DISTANCE = 6.0
local PURCHASE_DELAY_SECONDS = 0.10
local ACK_TIMEOUT_SECONDS = 4.00
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
    purchased = 0,
    npc_id = nil,
    npc_index = nil,
    zone_id = nil,
    candidate = nil,
    template = nil,
    next_send_at = nil,
    ack_deadline = nil,
    last_tick = 0,
    last_potpourri = nil,
    started_inventory_count = 0,
    last_ack_packet = nil,
    item_ack_seen = false,
    dialog_ready_seen = false,
    active_purchase_number = nil,
}

local function clear_session()
    session.mode = 'idle'
    session.item_id = nil
    session.item_name = nil
    session.requested = 0
    session.purchased = 0
    session.npc_id = nil
    session.npc_index = nil
    session.zone_id = nil
    session.candidate = nil
    session.template = nil
    session.next_send_at = nil
    session.ack_deadline = nil
    session.last_tick = 0
    session.started_inventory_count = 0
    session.last_ack_packet = nil
    session.item_ack_seen = false
    session.dialog_ready_seen = false
    session.active_purchase_number = nil
end

local function abort_session(reason)
    if session.mode ~= 'idle' then
        fail('Stopped: ' .. tostring(reason))
    end
    clear_session()
end

local function item_name_matches(item, wanted)
    if not item or not item.en or not wanted then
        return false
    end
    return item.en:lower() == wanted:lower()
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
        return nil, distance, string.format('Emporox is %.2f yalms away; move within %.1f', distance, MAX_NPC_DISTANCE)
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
    if tonumber(npc.id) ~= tonumber(session.npc_id) or tonumber(npc.index) ~= tonumber(session.npc_index) then
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
        'Complete: purchased %d x %s. Inventory count %d -> %d.',
        session.purchased,
        session.item_name,
        session.started_inventory_count,
        current
    ), 158)
    clear_session()
end

local function maybe_schedule_next()
    if not session.item_ack_seen or not session.dialog_ready_seen then
        return
    end

    if session.purchased >= session.requested then
        finish_success()
        return
    end

    -- The item receipt proves the purchase succeeded. Incoming 0x05C proves
    -- Emporox's dialog event has advanced and is ready to accept the next
    -- identical menu response. Only advance when both have happened.
    session.mode = 'settling'
    session.next_send_at = now() + PURCHASE_DELAY_SECONDS
    session.ack_deadline = nil
end

local function inject_purchase()
    local _, _, reason = validate_session_npc()
    if reason then
        abort_session(reason)
        return
    end
    if not session.template then
        abort_session('no learned purchase packet is available')
        return
    end

    local before = inventory_item_count(session.item_id)
    session.item_ack_seen = false
    session.dialog_ready_seen = false
    session.active_purchase_number = session.purchased + 1

    local packet = packets.new('outgoing', 0x05B, session.template)
    packets.inject(packet)

    session.mode = 'waiting'
    session.ack_deadline = now() + ACK_TIMEOUT_SECONDS

    chat(string.format(
        'Purchase %d/%d sent for %s; waiting for item ACK (inventory=%d).',
        session.purchased + 1,
        session.requested,
        session.item_name,
        before
    ))
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
    session.purchased = 0
    session.npc_id = npc.id
    session.npc_index = npc.index
    session.zone_id = tonumber(info.zone)
    session.candidate = nil
    session.template = nil
    session.next_send_at = nil
    session.ack_deadline = nil
    session.started_inventory_count = inventory_item_count(item_id)
    session.item_ack_seen = false
    session.dialog_ready_seen = false
    session.active_purchase_number = 1

    chat(string.format(
        'Armed for %d x %s (item id %d). Emporox is %.2f yalms away.',
        quantity, item.en, item_id, distance
    ))
    chat('I will open Emporox. Navigate to the requested item and purchase ONE manually.')
    chat('The addon will learn only the menu packet that immediately precedes the verified item receive packet.')

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
        'mode=%s item=%s purchased=%d/%d inventory=%d potpourri=%s',
        session.mode,
        tostring(session.item_name),
        session.purchased,
        session.requested,
        current,
        pot
    ))

    if session.mode == 'teaching' then
        chat('Last manual Emporox menu packet: ' .. packet_summary(session.candidate))
    elseif session.template then
        chat('Learned purchase packet: ' .. packet_summary(session.template))
    end
end

local function show_help()
    chat('//emps buy <item name> <quantity> - learn one manual Emporox purchase, then safely repeat it.')
    chat('Example: //emps buy Ghastly Stone 200')
    chat('//emps status - show current state.')
    chat('//emps stop - immediately stop automation.')
    chat('Safety: every repeated purchase waits for exact-item 0x01F/0x020 inventory acknowledgement; timeouts never auto-retry.')
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

    elseif command == 'help' then
        show_help()

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

    -- When Emporox's 0x05C continuation reaches the normal client, the event
    -- script emits this cleanup/return-to-list response. During an intermediate
    -- bulk purchase that would leave the confirmation state we deliberately
    -- preserve, so block it. Check this before teaching capture so cleanup can
    -- never replace the learned Yes packet.
    local is_cleanup =
        tonumber(p['Option Index']) == 0 and
        tonumber(p['_unknown1']) == 16384 and
        not p['Automated Message']

    if is_cleanup and session.active_purchase_number and
       session.active_purchase_number < session.requested then
        chat('Blocked intermediate Emporox dialog cleanup.')
        return true
    end

    if session.mode == 'teaching' then
        session.candidate = copy_menu_packet(p)
        -- This manual menu response begins the transaction we are learning.
        -- Reset both completion signals so only packets following this choice
        -- can release the next automated purchase.
        session.item_ack_seen = false
        session.dialog_ready_seen = false
        session.active_purchase_number = 1
        session.ack_deadline = now() + ACK_TIMEOUT_SECONDS
        chat('Observed manual Emporox menu selection: ' .. packet_summary(session.candidate))
        return
    end

    if session.mode == 'settling' then
        chat('Ignoring post-purchase Emporox menu traffic: ' .. packet_summary(p))
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

    -- Emporox keeps the event menu open between purchases. 0x05C is the
    -- server-side continuation/refresh signal used by this style of dialog.
    -- Do not send another purchase merely because the inventory item arrived;
    -- wait until this continuation has also arrived.
    if id == 0x05C and session.mode ~= 'idle' then
        if session.mode == 'teaching' or session.mode == 'waiting' then
            session.dialog_ready_seen = true

            local purchase_number = session.active_purchase_number or (session.purchased + 1)
            local intermediate = purchase_number < session.requested

            if intermediate then
                chat(string.format(
                    'Emporox dialog continuation received (0x05C); holding confirmation state for purchase %d/%d.',
                    purchase_number,
                    session.requested
                ))
            else
                chat('Final Emporox dialog continuation received (0x05C); allowing normal menu cleanup.')
            end

            maybe_schedule_next()

            -- Critical for bulk replay: do not let the normal client consume
            -- intermediate continuations. If it does, its event script returns
            -- to the item list and the learned Yes packet is no longer valid.
            -- Allow the final continuation through so the UI returns to normal.
            if intermediate then
                return true
            end
        end
        return
    end

    -- A brand-new inventory stack arrives as 0x01F (Item Assign). Updates to an
    -- existing stack arrive as 0x020 (Item Update). Emporox can legitimately
    -- produce either depending on whether this is the first stone in the slot.
    if (id ~= 0x01F and id ~= 0x020) or session.mode == 'idle' then
        return
    end

    local ok, p = pcall(packets.parse, 'incoming', data)
    if not ok or not p then
        return
    end

    if tonumber(p['Item']) ~= tonumber(session.item_id) then
        return
    end

    session.last_ack_packet = id

    if session.mode == 'teaching' then
        if not session.candidate then
            abort_session('received the requested item, but no Emporox menu packet was captured')
            return
        end

        session.template = session.candidate
        session.candidate = nil
        session.purchased = 1
        session.item_ack_seen = true

        chat(string.format(
            'Teaching purchase verified by exact item receive packet 0x%03X.',
            id
        ))
        chat('Learned purchase packet: ' .. packet_summary(session.template))

        maybe_schedule_next()
        return
    end

    if session.mode == 'waiting' then
        if session.item_ack_seen then
            return
        end

        session.item_ack_seen = true
        session.purchased = session.purchased + 1
        chat(string.format(
            'ACK %d/%d: received %s via 0x%03X (packet count=%s).',
            session.purchased,
            session.requested,
            session.item_name,
            id,
            tostring(p['Count'])
        ))
        maybe_schedule_next()
    end
end)

windower.register_event('prerender', function()
    if session.mode == 'idle' then
        return
    end

    local t = now()
    if t - (session.last_tick or 0) < TICK_SECONDS then
        return
    end
    session.last_tick = t

    if session.mode == 'settling' and session.next_send_at and t >= session.next_send_at then
        inject_purchase()
        return
    end

    if (session.mode == 'waiting' or session.mode == 'teaching') and
       session.ack_deadline and t >= session.ack_deadline then
        local missing = {}
        if not session.item_ack_seen then
            missing[#missing + 1] = 'item ACK'
        end
        if not session.dialog_ready_seen then
            missing[#missing + 1] = '0x05C dialog continuation'
        end

        abort_session(string.format(
            'timed out waiting %.2fs for %s (%s); no retry was sent',
            ACK_TIMEOUT_SECONDS,
            session.item_name,
            table.concat(missing, ' + ')
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
