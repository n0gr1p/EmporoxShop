_addon.name = 'EmporoxShop'
_addon.author = 'n0gr1p + OpenAI'
_addon.version = '0.2.0'
_addon.commands = {'emps','emporoxshop'}

local packets = require('packets')
local res = require('resources')
local socket_ok, socket = pcall(require, 'socket')

local ZONE = 291
local MENU = 9751
local ITEM_ID = 3954
local OPTION = 3
local UNKNOWN1 = 6
local MAX_DISTANCE = 6
local TIMEOUT = 4
local OPEN_RETRY = 1.5
local MAX_OPEN = 4

local s = {
    mode='idle', qty=0, sent=0, acks=0, cleanup=false,
    npc_id=nil, npc_index=nil, menu=nil, deadline=nil,
    open_attempts=0, last_open=nil, last_tick=0, last_raw={},
    start_count=0, last_potpourri=nil,
}

local function now()
    if socket_ok and socket and socket.gettime then return socket.gettime() end
    return os.clock()
end

local function chat(msg,color)
    windower.add_to_chat(color or 207,'[EmporoxShop] '..tostring(msg))
end

local function item_count()
    local items = windower.ffxi.get_items()
    local inv = items and items.inventory
    if not inv then return 0 end
    local n = 0
    for _,slot in pairs(inv) do
        if type(slot)=='table' and tonumber(slot.id)==ITEM_ID then
            n = n + (tonumber(slot.count) or 0)
        end
    end
    return n
end

local function reset()
    local pot = s.last_potpourri
    s = {
        mode='idle', qty=0, sent=0, acks=0, cleanup=false,
        npc_id=nil, npc_index=nil, menu=nil, deadline=nil,
        open_attempts=0, last_open=nil, last_tick=0, last_raw={},
        start_count=0, last_potpourri=pot,
    }
end

local function distance(mob)
    local me = windower.ffxi.get_mob_by_target('me')
    if me and mob and me.x and me.y and mob.x and mob.y then
        local dx,dy = mob.x-me.x,mob.y-me.y
        return math.sqrt(dx*dx+dy*dy)
    end
    if mob and mob.distance and mob.distance >= 0 then return math.sqrt(mob.distance) end
end

local function get_emporox()
    local info = windower.ffxi.get_info()
    if not info or not info.logged_in then return nil,'not logged in' end
    if tonumber(info.zone) ~= ZONE then return nil,'not in Reisenjima' end
    local npc = windower.ffxi.get_mob_by_name('Emporox')
    if not npc then return nil,'Emporox not found' end
    local d = distance(npc)
    if not d or d >= MAX_DISTANCE then return nil,'move within 6 yalms of Emporox' end
    return npc
end

local function same_packet(id,data)
    if s.last_raw[id] == data then return true end
    s.last_raw[id] = data
    return false
end

local function valid_target()
    local npc,err = get_emporox()
    if not npc then return nil,err end
    if s.npc_id and (npc.id ~= s.npc_id or npc.index ~= s.npc_index) then
        return nil,'Emporox identity changed'
    end
    return npc
end

local function cleanup()
    if s.cleanup or not s.menu then return end
    packets.inject(packets.new('outgoing',0x05B,{
        ['Target']=s.npc_id,
        ['Option Index']=0,
        ['_unknown1']=16384,
        ['Target Index']=s.npc_index,
        ['Automated Message']=false,
        ['_unknown2']=0,
        ['Zone']=ZONE,
        ['Menu ID']=s.menu,
    }))
    s.cleanup = true
    s.mode = 'closing'
    s.deadline = now()+TIMEOUT
    chat('Sent menu cleanup.')
end

local function stop(reason)
    if s.mode=='idle' then return end
    chat('Stopped: '..tostring(reason),167)
    if s.menu and not s.cleanup then cleanup() end
    reset()
end

local function send_next()
    local _,err = valid_target()
    if err then stop(err) return end

    if s.sent >= s.qty then
        cleanup()
        return
    end

    packets.inject(packets.new('outgoing',0x05B,{
        ['Target']=s.npc_id,
        ['Option Index']=OPTION,
        ['_unknown1']=UNKNOWN1,
        ['Target Index']=s.npc_index,
        ['Automated Message']=true,
        ['_unknown2']=0,
        ['Zone']=ZONE,
        ['Menu ID']=s.menu,
    }))

    s.sent = s.sent + 1
    s.mode = 'running'
    s.deadline = now()+TIMEOUT
    chat(string.format('Sent Ghastly Stone purchase %d/%d.',s.sent,s.qty))
end

local function poke()
    local _,err = valid_target()
    if err then stop(err) return end

    packets.inject(packets.new('outgoing',0x01A,{
        ['Target']=s.npc_id,
        ['Target Index']=s.npc_index,
        ['Category']=0,
        ['Param']=0,
    }))

    s.open_attempts = s.open_attempts + 1
    s.last_open = now()
    chat(string.format('Opening Emporox menu (%d/%d).',s.open_attempts,MAX_OPEN))
end

local function start(qty)
    if s.mode ~= 'idle' then chat('Already busy. Use //emps stop.',167) return end
    qty = tonumber(qty)
    if not qty or qty < 1 or qty ~= math.floor(qty) then chat('Quantity must be a positive integer.',167) return end

    local npc,err = get_emporox()
    if not npc then chat(err,167) return end

    s.mode = 'opening'
    s.qty = qty
    s.sent = 0
    s.acks = 0
    s.cleanup = false
    s.npc_id = npc.id
    s.npc_index = npc.index
    s.menu = nil
    s.deadline = nil
    s.open_attempts = 0
    s.last_raw = {}
    s.start_count = item_count()

    chat(string.format('Starting %d x Ghastly Stone using Silmaril sequence.',qty))
    chat('No manual menu selection is required.')
    poke()
end

windower.register_event('addon command',function(...)
    local a={...}
    local cmd=a[1] and tostring(a[1]):lower() or 'help'
    if cmd=='buy' then
        local qty=tonumber(a[#a])
        local name={}
        for i=2,#a-1 do name[#name+1]=tostring(a[i]) end
        if table.concat(name,' '):lower() ~= 'ghastly stone' then
            chat('Currently supported: //emps buy Ghastly Stone <quantity>',167)
            return
        end
        start(qty)
    elseif cmd=='status' then
        chat(string.format('mode=%s sent=%d/%d acks=%d inventory=%d menu=%s cleanup=%s',
            s.mode,s.sent,s.qty,s.acks,item_count(),tostring(s.menu),tostring(s.cleanup)))
    elseif cmd=='stop' or cmd=='cancel' then
        stop('cancelled by user')
    else
        chat('//emps buy Ghastly Stone <quantity>')
        chat('//emps status')
        chat('//emps stop')
    end
end)

windower.register_event('outgoing chunk',function(id,original,modified,injected,blocked)
    if s.mode=='idle' or id~=0x05B or injected or blocked then return end
    local ok,p=pcall(packets.parse,'outgoing',original)
    if not ok or not p then return end
    if tonumber(p['Target'])==tonumber(s.npc_id) and tonumber(p['Target Index'])==tonumber(s.npc_index) then
        stop('manual Emporox menu input during automation')
        return true
    end
end)

windower.register_event('incoming chunk',function(id,data)
    if id==0x118 then
        local ok,p=pcall(packets.parse,'incoming',data)
        if ok and p and p['Potpourri']~=nil then s.last_potpourri=tonumber(p['Potpourri']) end
        return
    end
    if s.mode=='idle' then return end

    if id==0x032 or id==0x033 or id==0x034 then
        if same_packet(id,data) then return true end
        local ok,p=pcall(packets.parse,'incoming',data)
        if not ok or not p then return end
        if tonumber(p['NPC'])~=tonumber(s.npc_id) or tonumber(p['NPC Index'])~=tonumber(s.npc_index) then return end

        s.menu=tonumber(p['Menu ID'])
        if s.menu~=MENU then
            stop('unexpected Emporox menu '..tostring(s.menu))
            return true
        end

        if s.mode=='opening' then
            chat('Captured Emporox menu 9751; starting queue.')
            send_next()
        end

        return true
    end

    if id==0x05C and (s.mode=='running' or s.mode=='closing') then
        if same_packet(id,data) then return end
        s.deadline=now()+TIMEOUT

        if not s.cleanup then
            send_next()
        else
            s.mode='await_release'
        end

        return
    end

    if id==0x01F or id==0x020 then
        local ok,p=pcall(packets.parse,'incoming',data)
        if ok and p and tonumber(p['Item'])==ITEM_ID then
            s.acks=s.acks+1
            s.deadline=now()+TIMEOUT
            chat(string.format('Item ACK %d/%d via 0x%03X.',s.acks,s.qty,id))
        end
        return
    end

    if id==0x052 and (s.mode=='running' or s.mode=='closing' or s.mode=='await_release') then
        local current=item_count()
        chat(string.format('Complete: sent %d/%d, item ACKs %d/%d, inventory %d -> %d.',
            s.sent,s.qty,s.acks,s.qty,s.start_count,current),158)
        reset()
    end
end)

windower.register_event('prerender',function()
    if s.mode=='idle' then return end
    local t=now()
    if t-(s.last_tick or 0)<0.05 then return end
    s.last_tick=t

    if s.mode=='opening' and s.last_open and t-s.last_open>=OPEN_RETRY then
        if s.open_attempts>=MAX_OPEN then stop('Emporox did not return an opening menu') else poke() end
        return
    end

    if s.mode~='opening' and s.deadline and t>=s.deadline then
        stop(string.format('no Emporox progress for %.1fs (mode=%s sent=%d/%d acks=%d)',
            TIMEOUT,s.mode,s.sent,s.qty,s.acks))
    end
end)

windower.register_event('zone change',function()
    if s.mode~='idle' then reset() end
end)

windower.register_event('unload',function()
    if s.mode~='idle' and s.menu and not s.cleanup then cleanup() end
end)
