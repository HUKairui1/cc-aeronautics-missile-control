-- ==========================================
-- Missile Control Console v2  (26 x 20)
-- 密码 -> 绑定(24) -> LAUNCH / MANAGE / INFO
-- MANAGE: 列表/多选/改名/配置/编组
-- ==========================================

local W, H = 26, 20
local MAXIDS = 24
local FLEET_FILE = "fleet.cfg"
local OLD_FILE = "console.cfg"
local VIS_MANAGE = 10
local VIS_GROUP = 10

local C = {
    bg      = colors.lightGray,
    fg      = colors.white,
    dim     = colors.gray,
    tabOff  = colors.white,
    tabOn   = colors.yellow,
    ok      = colors.lime,
    danger  = colors.red,
    warn    = colors.orange,
    field   = colors.black,
    btn     = colors.white,
    btnText = colors.black,
    line    = colors.white,
}

-- ==========================================
-- 屏幕
-- ==========================================
local out = term
local offX, offY = 0, 0
local scrW, scrH = 51, 19

local function setupScreen()
    local m = peripheral.find("monitor")
    local w, h
    if m then
        local best = 0.5
        for _, s in ipairs({ 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5 }) do
            if pcall(m.setTextScale, s) then
                local tw, th = m.getSize()
                if tw >= W and th >= H then best = s end
            end
        end
        pcall(m.setTextScale, best)
        out = m
        w, h = m.getSize()
    else
        out = term
        w, h = term.getSize()
    end
    scrW, scrH = w, h
    offX = math.max(0, math.floor((w - W) / 2))
    offY = math.max(0, math.floor((h - H) / 2))
end

local buttons = {}

local function fill(x1, y1, x2, y2, bg)
    local vw, vh = scrW - offX, scrH - offY
    x1, y1 = math.max(1, x1), math.max(1, y1)
    x2, y2 = math.min(vw, x2), math.min(vh, y2)
    if x2 < x1 or y2 < y1 then return end
    out.setBackgroundColor(bg or C.bg)
    local line = (" "):rep(x2 - x1 + 1)
    for y = y1, y2 do
        out.setCursorPos(offX + x1, offY + y)
        out.write(line)
    end
end

local function put(x, y, s, fg, bg)
    local vw, vh = scrW - offX, scrH - offY
    if y < 1 or y > vh or x < 1 or x > vw then return end
    if #s > vw - x + 1 then s = s:sub(1, vw - x + 1) end
    out.setCursorPos(offX + x, offY + y)
    out.setBackgroundColor(bg or C.bg)
    out.setTextColor(fg or C.fg)
    out.write(s)
end

local function btn(x1, y1, x2, y2, id, label)
    buttons[#buttons + 1] = { x1, y1, x2, y2, id, label }
end

local function drawSep(y)
    put(1, y, ("-"):rep(W), C.line, C.bg)
end

-- 普通按钮: 白底黑字
local function box(x, y, w, label, id, bg, fg)
    bg = bg or C.btn
    fg = fg or C.btnText
    fill(x, y, x + w - 1, y, bg)
    local pad = math.floor((w - #label) / 2)
    put(x + pad, y, label, fg, bg)
    btn(x, y, x + w - 1, y, id, label)
end

-- 翻页箭头: 和背景同色
local function arrow(x, y, label, id)
    fill(x, y, x, y, C.bg)
    put(x, y, label, C.fg, C.bg)
    btn(x, y, x, y, id, label)
end

-- ==========================================
-- 数据
-- ==========================================
local function defaultCfg()
    return {
        ascent = 1000,
        tx = nil, ty = nil, tz = nil,
        kp = 0.010, ki = 0.00011, kd = 0.040,
        maxthr = 15,
        trig = "IMPACT",
        trigh = -50,
        dive = 0.40,
        lead = 2.0,
        loft = 0.32,
    }
end

local FIELDS = {
    { k = "ascent", l = "ASCENT",  t = "int", min = 0, max = 20000 },
    { k = "tx",     l = "TGT X",   t = "int", min = -30000000, max = 30000000 },
    { k = "ty",     l = "TGT Y",   t = "int", min = -30000000, max = 30000000 },
    { k = "tz",     l = "TGT Z",   t = "int", min = -30000000, max = 30000000 },
    { k = "kp",     l = "PID KP",  t = "num", min = 0, max = 1 },
    { k = "ki",     l = "PID KI",  t = "num", min = 0, max = 1 },
    { k = "kd",     l = "PID KD",  t = "num", min = 0, max = 5 },
    { k = "maxthr", l = "MAXTHR",  t = "int", min = 7, max = 15 },
    { k = "trig",   l = "TRIGGER", t = "toggle" },
    { k = "trigh",  l = "TRIG H",  t = "int", min = -30000000, max = 30000000 },
    { k = "dive",   l = "DIVE",    t = "num", min = 0, max = 1 },
    { k = "lead",   l = "LEAD",    t = "num", min = -90, max = 90 },
    { k = "loft",   l = "LOFT",    t = "num", min = 0, max = 1 },
}

local fleet = { pass = nil, missiles = {}, groups = {}, pos = {} }

local function copy(t)
    local r = {}
    for k, v in pairs(t) do r[k] = v end
    return r
end

local function findMissile(id)
    for _, m in ipairs(fleet.missiles) do
        if m.id == id then return m end
    end
end

local function saveFleet()
    local f = fs.open(FLEET_FILE, "w")
    if f then
        f.write(textutils.serialize(fleet))
        f.close()
    end
end

local function loadFleet()
    if fs.exists(FLEET_FILE) then
        local f = fs.open(FLEET_FILE, "r")
        if f then
            local d = f.readAll()
            f.close()
            local ok, t = pcall(textutils.unserialize, d)
            if ok and type(t) == "table" then
                fleet = t
                fleet.missiles = fleet.missiles or {}
                fleet.groups = fleet.groups or {}
                fleet.pos = fleet.pos or {}
                for _, m in ipairs(fleet.missiles) do
                    if m.group then
                        m.groups = m.groups or {}
                        m.groups[m.group] = true
                        m.group = nil
                    end
                    m.groups = m.groups or {}
                end
                fleet.status = fleet.status or {}
                -- 清理空组 / 成员都不存在的组
                local drop = {}
                for name, g in pairs(fleet.groups) do
                    local valid = {}
                    for _, id in ipairs(g.order or {}) do
                        if findMissile(id) then valid[#valid + 1] = id end
                    end
                    if #valid == 0 then
                        drop[#drop + 1] = name
                    else
                        g.order = valid
                    end
                end
                for _, name in ipairs(drop) do fleet.groups[name] = nil end
                return
            end
        end
    end
    -- 从旧版 console.cfg 迁移密码和 id
    if fs.exists(OLD_FILE) then
        local f = fs.open(OLD_FILE, "r")
        if f then
            local d = f.readAll()
            f.close()
            fleet.pass = d:match("pass=(%d%d%d%d)")
            local list = d:match("ids=([%d,]+)")
            if list then
                for n in list:gmatch("%d+") do
                    if #fleet.missiles < MAXIDS then
                        fleet.missiles[#fleet.missiles + 1] = {
                            id = tonumber(n), name = n, group = nil, cfg = defaultCfg(),
                        }
                    end
                end
            end
            saveFleet()
        end
    end
end

-- ==========================================
-- 状态
-- ==========================================
local screen = "pass"    -- pass / bind / main / cfg / group
local passBuf = ""
local passMode = "lock"  -- set / lock / chg_old / chg_new
local slots = {}
local slotCount = 0
local focus = 1
local cursorOn = true
local blinkId = nil
local tab = 1
local dirty = true
local msgText = ""
local logLines = {}

local sel = {}           -- 选中: sel[id] = true
local listTop = 0        -- 管理页滚动
local launchTop = 0
local launchMode = "SINGLE"   -- SINGLE / GROUP / ALL
local grpArmed = false
local groupSel = {}
local groupTop = 0
local infoTop = 0
local infoId = nil
local lastClickId, lastClickT = nil, 0

local edit = nil         -- 编辑框 { label, buf, kind, min, max, maxlen, onDone }
local flash = nil        -- 按下高亮的按钮 { x1,y1,x2,y2,id,label }
local flashId = nil
local houseTimer = nil
local cfgEdit = nil      -- { ids = {}, cfg = {}, scope = "THIS" }
local cfgTop = 0
local grpEdit = nil      -- { name = , interval = , members = {} }

local setMsg, addLog
local modemOk = false
for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then
        if pcall(rednet.open, n) then modemOk = true end
    end
end

local function sendCfg(id, cfg)
    if not modemOk then return false end
    return pcall(rednet.send, id, { cmd = "cfg", cfg = cfg }, "cfg")
end

local function hasTarget(m)
    return m and m.cfg and m.cfg.tx and m.cfg.ty and m.cfg.tz
end

local function launchNow(id, keep)
    local m = findMissile(id)
    if not m or m.deadAt then return end
    if not hasTarget(m) then
        addLog("SKIP #" .. id .. " NO TGT")
        setMsg("NO TARGET #" .. id)
        return
    end
    if not modemOk then setMsg("NO MODEM") return end
    sendCfg(m.id, m.cfg)
    pcall(rednet.send, m.id, "launch", "ks")
    addLog(("FIRE #%s @%d"):format(tostring(m.id), math.floor(os.epoch("utc") / 1000) % 1000))
    for name in pairs(m.groups or {}) do
        if keep ~= name then m.groups[name] = nil end
    end
    saveFleet()
end

-- 发射队列: 按时间轮询, 不依赖 timer id
local lq = {}
local lqTimer = nil

local function lqPush(items)
    local t = os.epoch("utc") / 1000
    for _, it in ipairs(items) do
        lq[#lq + 1] = { id = it.id, keep = it.keep, at = t }
        t = t + (it.delay or 0)
    end
end

local function lqPump()
    if #lq == 0 then return false end
    local nowt = os.epoch("utc") / 1000
    local fired = false
    while #lq > 0 and nowt >= lq[1].at do
        local it = table.remove(lq, 1)
        launchNow(it.id, it.keep)
        fired = true
    end
    if #lq > 0 and not lqTimer then
        lqTimer = os.startTimer(0.1)
    end
    return fired
end

local function groupNames()
    local names = {}
    for name in pairs(fleet.groups) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function launchCount()
    if launchMode == "GROUP" then
        return #groupNames()
    end
    return #fleet.missiles
end

-- 当前模式下"一键"作用到的导弹
local function modeIds()
    local ids = {}
    if launchMode == "GROUP" then
        for _, name in ipairs(groupNames()) do
            if groupSel[name] then
                local g = fleet.groups[name]
                for _, id in ipairs(g.order or {}) do
                    ids[#ids + 1] = id
                end
            end
        end
    else
        for _, m in ipairs(fleet.missiles) do
            ids[#ids + 1] = m.id
        end
    end
    return ids
end

local function detonateList()
    local ids = {}
    local bcast = false
    if launchMode == "GROUP" then
        for _, name in ipairs(groupNames()) do
            if groupSel[name] then
                local g = fleet.groups[name]
                for _, id in ipairs(g.order or {}) do
                    ids[#ids + 1] = id
                end
            end
        end
    else
        local seen = {}
        for _, m in ipairs(fleet.missiles) do
            if not seen[m.id] then
                seen[m.id] = true
                ids[#ids + 1] = m.id
            end
        end
        for id in pairs(fleet.status or {}) do
            if not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
        -- 单/全模式直接广播, 保证天上的弹都能收到
        bcast = pcall(rednet.broadcast, "detonate", "det")
    end
    local n, armedN = 0, 0
    for _, id in ipairs(ids) do
        local m = findMissile(id)
        if not (m and m.deadAt) then
            local s = fleet.status and fleet.status[id]
            if (m and m.armed) or (s and s.armed == 1) then
                armedN = armedN + 1
            end
            pcall(rednet.send, id, "detonate", "det")
            n = n + 1
        end
    end
    if bcast or n > 0 then
        setMsg(("DET x%d B%s A%d"):format(n, bcast and "1" or "0", armedN))
        addLog(("DET x%d A%d"):format(n, armedN))
    else
        setMsg("NO MISSILE")
    end
end

local function fireGroups()
    local names = groupNames()
    local picked = {}
    for _, name in ipairs(names) do
        if groupSel[name] then picked[#picked + 1] = name end
    end
    if #picked == 0 then setMsg("NO GROUP SELECTED") return end
    local items = {}
    for _, name in ipairs(picked) do
        local g = fleet.groups[name]
        if g and g.order then
            local d = g.interval or 1
            if d < 1 then d = 1 end
            for _, id in ipairs(g.order) do
                items[#items + 1] = { id = id, delay = d, keep = name }
            end
        end
    end
    if #items == 0 then setMsg("EMPTY GROUP") return end
    local tag = {}
    for _, it in ipairs(items) do tag[#tag + 1] = tostring(it.id) end
    addLog("Q:" .. table.concat(tag, ","):sub(1, 22))
    setMsg("GROUP FIRE x" .. #items)
    lqPush(items)
end

local function fireAll()
    local items = {}
    local gap = fleet.allInterval or 1
    for _, m in ipairs(fleet.missiles) do
        if not m.deadAt then
            items[#items + 1] = { id = m.id, delay = gap, keep = nil }
        end
    end
    if #items == 0 then setMsg("NO MISSILE") return end
    setMsg("FIRE ALL x" .. #items)
    lqPush(items)
end

-- ==========================================
-- 小工具
-- ==========================================
setMsg = function(s) msgText = s end

addLog = function(s)
    logLines[#logLines + 1] = s
    while #logLines > 7 do table.remove(logLines, 1) end
end

local function selectedIds()
    local t = {}
    for _, m in ipairs(fleet.missiles) do
        if sel[m.id] then t[#t + 1] = m.id end
    end
    return t
end

local function selCount()
    return #selectedIds()
end

-- 选区正好等于某个组(不能少)时返回组名
local function exactGroup(ids)
    if #ids == 0 then return nil end
    for name, g in pairs(fleet.groups) do
        local members = {}
        for _, id in ipairs(g.order or {}) do
            if findMissile(id) then members[#members + 1] = id end
        end
        if #members == #ids then
            local s1, s2 = {}, {}
            for _, id in ipairs(members) do s1[id] = true end
            for _, id in ipairs(ids) do s2[id] = true end
            local same = true
            for id in pairs(s1) do if not s2[id] then same = false end end
            for id in pairs(s2) do if not s1[id] then same = false end end
            if same then return name end
        end
    end
    return nil
end

local function openEdit(label, buf, kind, opt)
    edit = {
        label = label, buf = buf or "", kind = kind,
        min = opt and opt.min, max = opt and opt.max,
        maxlen = opt and opt.maxlen, onDone = opt and opt.onDone,
    }
end

local function commitEdit()
    local e = edit
    if not e then return end
    local v = e.buf
    if e.kind == "text" then
        if #v > 0 and e.onDone then e.onDone(v) end
    else
        local n = tonumber(v)
        if n and e.onDone then
            if e.min and n < e.min then n = e.min end
            if e.max and n > e.max then n = e.max end
            e.onDone(n)
        else
            setMsg("BAD NUMBER")
            return
        end
    end
    edit = nil
end

local function editChar(ch)
    if not edit then return end
    if edit.kind == "text" then
        if ch:match("[%w_]") then
            if #edit.buf < (edit.maxlen or 6) then
                edit.buf = edit.buf .. ch
            end
        end
    else
        if ch:match("[%d%.%-]") then
            if #edit.buf < 10 then edit.buf = edit.buf .. ch end
        end
    end
end

-- ==========================================
-- 密码页
-- ==========================================
local function afterPass()
    if #fleet.missiles > 0 then
        screen = "main"
        tab = 1
        setMsg("READY")
    else
        screen = "bind"
        slots = {}
        slotCount = 1
        focus = 1
        slots[1] = ""
        setMsg("TYPE COMPUTER ID")
    end
end

local function passSubmit()
    if #passBuf ~= 4 then setMsg("NEED 4 DIGITS") return end
    if passMode == "set" then
        fleet.pass = passBuf
        saveFleet()
        passBuf = ""
        addLog("CODE SET")
        afterPass()
    elseif passMode == "chg_old" then
        if passBuf == fleet.pass then
            passBuf = ""
            passMode = "chg_new"
            setMsg("ENTER NEW CODE")
        else
            passBuf = ""
            setMsg("WRONG CODE")
        end
    elseif passMode == "chg_new" then
        fleet.pass = passBuf
        saveFleet()
        passBuf = ""
        passMode = "lock"
        setMsg("CODE CHANGED")
        addLog("CODE CHANGED")
    else
        if passBuf == fleet.pass then
            passBuf = ""
            addLog("UNLOCKED")
            afterPass()
        else
            passBuf = ""
            setMsg("WRONG CODE")
            addLog("WRONG CODE")
        end
    end
end

local function passKey(d)
    if #passBuf < 4 then passBuf = passBuf .. d end
    if #passBuf == 4 then passSubmit() end
end

-- ==========================================
-- 绑定页 (24)
-- ==========================================
local function bindDone()
    local list = {}
    local seen = {}
    for i = 1, slotCount do
        local s = (slots[i] or ""):gsub("%D", "")
        local n = tonumber(s)
        if n and n >= 1 and n <= 999 and not seen[n] then
            seen[n] = true
            list[#list + 1] = n
        end
    end
    if #list == 0 then setMsg("ENTER AT LEAST ONE ID") return end

    local old = {}
    for _, m in ipairs(fleet.missiles) do old[m.id] = m end
    local new = {}
    for _, id in ipairs(list) do
        local m = old[id]
        if m then
            new[#new + 1] = m
        else
            new[#new + 1] = { id = id, name = tostring(id), group = nil, cfg = defaultCfg() }
        end
    end
    fleet.missiles = new
    saveFleet()

    sel = {}
    screen = "main"
    tab = 1
    setMsg("BOUND " .. #new .. " MISSILE(S)")
    addLog("BIND OK: " .. #new)
end

-- ==========================================
-- 管理页
-- ==========================================
local function toggleSel(id)
    sel[id] = (not sel[id]) or nil
end

local function selectAll()
    local all = true
    for _, m in ipairs(fleet.missiles) do
        if not sel[m.id] then all = false end
    end
    sel = {}
    if not all then
        for _, m in ipairs(fleet.missiles) do sel[m.id] = true end
    end
end

local function openRename()
    local ids = selectedIds()
    if #ids ~= 1 then return end
    local m = findMissile(ids[1])
    if not m then return end
    openEdit("NAME #" .. m.id, m.name or tostring(m.id), "text", {
        maxlen = 6,
        onDone = function(v)
            m.name = v
            saveFleet()
            setMsg("RENAMED")
        end,
    })
end

local function openCfg()
    local ids = selectedIds()
    if #ids == 0 then return end
    local m = findMissile(ids[1])
    if not m then return end
    cfgEdit = { ids = ids, cfg = copy(m.cfg or defaultCfg()), scope = "THIS" }
    cfgTop = 0
    screen = "cfg"
    setMsg("EDIT CONFIG")
end

local function openGroupByName(name)
    local g = fleet.groups[name]
    if not g then return end
    local members = {}
    for _, id in ipairs(g.order or {}) do
        if findMissile(id) then members[#members + 1] = id end
    end
    grpEdit = { name = name, interval = g.interval or 1, members = members }
    groupTop = 0
    screen = "group"
    setMsg("GROUP EDIT")
end

local function dissolveGroup(name)
    if not name then return end
    fleet.groups[name] = nil
    for _, m in ipairs(fleet.missiles) do
        if m.groups then m.groups[name] = nil end
    end
    groupSel[name] = nil
    saveFleet()
    setMsg("GROUP DISSOLVED")
    addLog("DISSOLVE " .. name)
end

local function openGroup()
    local ids = selectedIds()
    if #ids < 1 then return end
    local ex = exactGroup(ids)
    if ex then
        openGroupByName(ex)
        return
    end
    local name = ""
    local first = findMissile(ids[1])
    if first and first.groups then
        for gname in pairs(first.groups) do
            name = gname
            break
        end
    end
    if name == "" then
        name = "G" .. tostring(ids[1])
    end
    local members = {}
    local g = fleet.groups[name]
    if g and g.order then
        for _, id in ipairs(g.order) do
            for _, x in ipairs(ids) do
                if x == id then members[#members + 1] = id end
            end
        end
        for _, x in ipairs(ids) do
            local found = false
            for _, id in ipairs(members) do if id == x then found = true end end
            if not found then members[#members + 1] = x end
        end
    else
        members = ids
    end
    grpEdit = {
        name = name,
        interval = (g and g.interval) or 1,
        members = members,
    }
    groupTop = 0
    screen = "group"
    setMsg("GROUP EDIT")
end

local function groupSave()
    local name = grpEdit.name
    if name == "" then setMsg("NEED GROUP NAME") return end
    fleet.groups[name] = { interval = grpEdit.interval, order = copy(grpEdit.members) }
    local inList = {}
    for _, id in ipairs(grpEdit.members) do inList[id] = true end
    for _, m in ipairs(fleet.missiles) do
        m.groups = m.groups or {}
        if inList[m.id] then
            m.groups[name] = true
        else
            m.groups[name] = nil
        end
    end
    saveFleet()
    setMsg("GROUP SAVED")
    addLog("GROUP " .. name)
    screen = "main"
    tab = 2
end

-- ==========================================
-- 配置页
-- ==========================================
local function cfgValueText(k)
    local v = cfgEdit.cfg[k]
    if v == nil then return "NIL" end
    if k == "trig" then return v end
    if type(v) == "number" then
        if math.floor(v) == v then return tostring(v) end
        return string.format("%.4g", v)
    end
    return tostring(v)
end

local function cfgFieldClick(f, idx)
    local k = f.k
    if f.t == "toggle" then
        cfgEdit.cfg[k] = (cfgEdit.cfg[k] == "HEIGHT") and "IMPACT" or "HEIGHT"
        setMsg("TRIGGER: " .. cfgEdit.cfg[k])
        return
    end
    openEdit(f.l, cfgEdit.cfg[k] == nil and "" or cfgValueText(k), f.t == "int" and "int" or "num", {
        min = f.min, max = f.max,
        onDone = function(v)
            cfgEdit.cfg[k] = v
            setMsg(f.l .. " = " .. tostring(v))
        end,
    })
end

local function cfgSave()
    local ids = {}
    if cfgEdit.scope == "ALL" then
        for _, m in ipairs(fleet.missiles) do ids[#ids + 1] = m.id end
    elseif cfgEdit.scope == "GROUP" then
        local m0 = findMissile(cfgEdit.ids[1])
        local g = m0 and m0.group
        for _, m in ipairs(fleet.missiles) do
            if g and m.group == g then ids[#ids + 1] = m.id end
        end
    else
        ids = cfgEdit.ids
    end
    if #ids == 0 then setMsg("NO TARGET") return end
    for _, id in ipairs(ids) do
        local m = findMissile(id)
        if m then
            m.cfg = copy(cfgEdit.cfg)
            sendCfg(id, m.cfg)
        end
    end
    saveFleet()
    setMsg("SAVED -> " .. #ids .. " MISSILE(S)")
    addLog("CFG SAVE " .. #ids)
    screen = "main"
    tab = 2
end

local function cfgReset()
    cfgEdit.cfg = defaultCfg()
    setMsg("RESET TO DEFAULT")
end

-- ==========================================
-- 绘制
-- ==========================================
local function drawTabs()
    local tabs = {
        { 2, 7, "LAUNCH", 1 },
        { 8, 13, "MANAGE", 2 },
        { 14, 19, "INFO", 3 },
        { 20, 25, "BIND", 4 },
    }
    for _, t in ipairs(tabs) do
        local on = (tab == t[4])
        local bg = on and C.tabOn or C.tabOff
        local fg = colors.black
        fill(t[1], 1, t[2], 1, bg)
        local pad = math.floor(((t[2] - t[1] + 1) - #t[3]) / 2)
        put(t[1] + pad, 1, t[3], fg, bg)
        btn(t[1], 1, t[2], 1, "tab" .. t[4], t[3])
    end
end

local function dots(n)
    local t = {}
    for i = 1, 4 do t[i] = (i <= n) and "*" or "_" end
    return table.concat(t, " ")
end

local function drawPad(y0)
    local pad = {
        { "1", "2", "3" },
        { "4", "5", "6" },
        { "7", "8", "9" },
        { "CLR", "0", "OK" },
    }
    local xs = { 1, 10, 19 }
    for r = 1, 4 do
        for c = 1, 3 do
            local lbl = pad[r][c]
            local x, y = xs[c], y0 + r - 1
            local id
            if lbl == "CLR" then id = "clr"
            elseif lbl == "OK" then id = "ok"
            else id = "num" .. lbl end
            fill(x, y, x + 7, y, C.field)
            put(x + math.floor((8 - #lbl) / 2), y, lbl, C.fg, C.field)
            btn(x, y, x + 7, y, id, lbl)
        end
    end
end

local function drawPass()
    put(3, 2, "MISSILE CONTROL SYSTEM", C.fg)
    drawSep(3)
    local titles = {
        set = "SET 4-DIGIT CODE",
        lock = "ENTER CODE",
        chg_old = "OLD CODE",
        chg_new = "NEW CODE",
    }
    local title = titles[passMode] or "ENTER CODE"
    put(1 + math.floor((W - #title) / 2), 4, title, C.tabOn)
    local d = dots(#passBuf)
    put(1 + math.floor((W - #d) / 2), 5, d, C.fg)
    drawPad(7)
    put(1, 11, msgText:sub(1, W), C.warn)
    drawSep(12)
    for i = 1, 4 do
        if logLines[i] then put(1, 12 + i, logLines[i]:sub(1, W), C.dim) end
    end
    if passMode == "lock" then
        box(8, 18, 11, "NEW CODE", "chgpass")
    end
    put(1, 20, (passMode == "set" or passMode == "chg_new") and "SET YOUR CODE" or "ENTER TO UNLOCK", C.warn)
end

local function drawBind()
    put(3, 2, "MISSILE CONTROL SYSTEM", C.fg)
    drawSep(3)
    put(7, 4, "BIND MISSILES", C.tabOn)
    put(2, 5, "COUNT: " .. slotCount, C.fg)
    box(19, 5, 3, "+", "plus")
    box(23, 5, 3, "-", "minus")

    for i = 1, slotCount do
        local row = math.floor((i - 1) / 3)
        local col = (i - 1) % 3
        local x = 2 + col * 8
        local y = 6 + row
        put(x, y, ("%02d"):format(i), C.dim)
        local s = slots[i] or ""
        local shown = s
        if focus == i then shown = s .. (cursorOn and "_" or " ") end
        shown = shown:sub(1, 3)
        shown = shown .. (" "):rep(3 - #shown)
        fill(x + 3, y, x + 5, y, C.field)
        put(x + 3, y, shown, C.fg, C.field)
        btn(x + 3, y, x + 5, y, "slot" .. i, shown)
    end

    put(1, 14, msgText:sub(1, W), C.warn)
    drawSep(15)
    for i = 1, 2 do
        if logLines[#logLines - 2 + i] then
            put(1, 14 + i, logLines[#logLines - 2 + i]:sub(1, W), C.dim)
        end
    end
    box(9, 18, 8, "  DONE  ", "done")
    put(1, 19, "CLICK BOX, TYPE ID", C.dim)
    put(1, 20, "ENTER = NEXT / DONE", C.warn)
end

local function drawLaunch()
    drawTabs()
    drawSep(2)
    local function mb(x, w, label, mode)
        local on = (launchMode == mode)
        box(x, 3, w, label, mode, on and C.tabOn or C.btn, on and colors.black or C.btnText)
    end
    mb(1, 8, "SINGLE", "SINGLE")
    mb(9, 8, "GROUP", "GROUP")
    mb(17, 8, "ALL", "ALL")

    local total = #fleet.missiles

    if launchMode == "SINGLE" then
        put(1, 4, "NAME", C.dim)
        put(13, 4, "SAFETY", C.dim)
        put(20, 4, "FIRE", C.dim)
        for r = 0, 4 do
            local m = fleet.missiles[launchTop + r + 1]
            if m then
                local y = 5 + r
                put(1, y, (m.name or tostring(m.id)):sub(1, 6), C.fg)
                put(8, y, tostring(m.id), C.dim)
                local on = m.armed
                local sbg = on and C.ok or C.btn
                local sfg = on and colors.black or C.btnText
                fill(13, y, 18, y, sbg)
                put(13, y, on and "[ ON ]" or "[OFF ]", sfg, sbg)
                btn(13, y, 18, y, "arm" .. m.id, on and "[ ON ]" or "[OFF ]")
                fill(20, y, 25, y, C.btn)
                put(20, y, "[FIRE]", on and C.btnText or C.dim, C.btn)
                btn(20, y, 25, y, "fire" .. m.id, "[FIRE]")
            end
        end
        if total > 5 then
            put(2, 10, ("%d-%d/%d"):format(launchTop + 1, math.min(launchTop + 5, total), total), C.dim)
            if launchTop > 0 then arrow(25, 10, "^", "lup") end
            if launchTop + 5 < total then arrow(25, 11, "v", "ldn") end
        end

    elseif launchMode == "GROUP" then
        put(1, 4, "GROUP", C.dim)
        put(13, 4, "N", C.dim)
        put(21, 4, "SEL", C.dim)
        local names = groupNames()
        for r = 0, 4 do
            local name = names[launchTop + r + 1]
            if name then
                local y = 5 + r
                local g = fleet.groups[name]
                put(1, y, name:sub(1, 10), C.fg)
                put(13, y, tostring(#(g.order or {})), C.dim)
                local on = groupSel[name]
                fill(21, y, 24, y, C.btn)
                put(21, y, on and "[x]" or "[ ]", C.btnText, C.btn)
                btn(21, y, 24, y, "gsel" .. name, on and "[x]" or "[ ]")
            end
        end
        if #names > 5 then
            put(2, 10, ("%d-%d/%d"):format(launchTop + 1, math.min(launchTop + 5, #names), #names), C.dim)
            if launchTop > 0 then arrow(25, 10, "^", "lup") end
            if launchTop + 5 < #names then arrow(25, 11, "v", "ldn") end
        end

    else
        put(1, 4, "ALL MISSILES", C.dim)
        for r = 0, 4 do
            local m = fleet.missiles[launchTop + r + 1]
            if m then
                local y = 5 + r
                put(1, y, (m.name or tostring(m.id)):sub(1, 6), C.fg)
                put(8, y, tostring(m.id), C.dim)
                if m.deadAt then
                    put(14, y, "DEAD", C.warn)
                elseif not hasTarget(m) then
                    put(14, y, "NO TGT", C.dim)
                end
            end
        end
        if total > 5 then
            put(2, 10, ("%d-%d/%d"):format(launchTop + 1, math.min(launchTop + 5, total), total), C.dim)
            if launchTop > 0 then arrow(25, 10, "^", "lup") end
            if launchTop + 5 < total then arrow(25, 11, "v", "ldn") end
        end
    end

    put(1, 11, msgText:sub(1, W), C.warn)
    if #lq > 0 then
        local left = math.ceil(lq[1].at - os.epoch("utc") / 1000)
        put(1, 10, ("NEXT %ds #%s (%d)"):format(math.max(0, left), tostring(lq[1].id), #lq), C.warn)
    end
    drawSep(12)
    for i = 1, 5 do
        if logLines[i] then put(1, 12 + i, logLines[i]:sub(1, W), C.dim) end
    end
    box(17, 18, 9, "DETONATE", "det", C.danger, colors.white)

    if launchMode ~= "SINGLE" then
        local abg = grpArmed and C.ok or C.btn
        local afg = grpArmed and colors.black or C.btnText
        fill(1, 19, 8, 19, abg)
        put(1, 19, grpArmed and "[ARM ON ]" or "[ARM OFF]", afg, abg)
        btn(1, 19, 8, 19, "garm", grpArmed and "[ARM ON ]" or "[ARM OFF]")
        fill(10, 19, 17, 19, C.btn)
        put(10, 19, "[ FIRE ]", grpArmed and C.btnText or C.dim, C.btn)
        btn(10, 19, 17, 19, "gfire", "[ FIRE ]")
        if launchMode == "GROUP" then
            box(19, 19, 7, "ALLSEL", "gselall")
        end
    end

    if launchMode == "ALL" then
        put(1, 20, "GAP", C.dim)
        box(6, 20, 3, "-", "ivm")
        put(10, 20, tostring(fleet.allInterval or 0) .. "s", C.fg)
        box(14, 20, 3, "+", "ivp")
    else
        put(1, 20, ("%d MISSILES"):format(total), C.ok)
    end
end

local function drawManage()
    drawTabs()
    drawSep(2)
    put(1, 3, "NAME", C.dim)
    put(8, 3, "ID", C.dim)
    put(17, 3, "SEL", C.dim)
    box(22, 3, 4, "ALL", "selall")

    local total = #fleet.missiles
    for r = 0, VIS_MANAGE - 1 do
        local idx = listTop + r + 1
        local m = fleet.missiles[idx]
        if m then
            local y = 4 + r
            put(1, y, (m.name or tostring(m.id)):sub(1, 6), C.fg)
            put(8, y, tostring(m.id), C.dim)
            local on = sel[m.id]
            fill(22, y, 25, y, C.btn)
            put(22, y, on and "[x] " or "[ ] ", C.btnText, C.btn)
            btn(22, y, 25, y, "sel" .. m.id, on and "[x] " or "[ ] ")
        end
    end

    if total > VIS_MANAGE then
        put(2, 14, ("%d-%d/%d"):format(listTop + 1, math.min(listTop + VIS_MANAGE, total), total), C.dim)
        if listTop > 0 then arrow(25, 14, "^", "mup") end
        if listTop + VIS_MANAGE < total then arrow(25, 15, "v", "mdn") end
    end

    local n = selCount()
    if n == 1 then
        box(1, 16, 9, "RENAME", "rename")
        box(11, 16, 9, "CONFIG", "config")
    elseif n > 1 then
        if exactGroup(selectedIds()) then
            box(1, 16, 9, "GRP CFG", "grpcfg")
            box(11, 16, 9, "DISSOLVE", "dissolve")
        else
            box(1, 16, 9, "GROUP", "group")
            box(11, 16, 9, "CONFIG", "none", C.btn, C.dim)
        end
    else
        box(1, 16, 9, "RENAME", "none", C.btn, C.dim)
        box(11, 16, 9, "CONFIG", "none", C.btn, C.dim)
    end

    put(1, 18, msgText:sub(1, W), C.warn)
    put(1, 20, ("%d SELECTED"):format(n), C.ok)
end

local function drawCfg()
    local m = findMissile(cfgEdit.ids[1])
    local name = (m and m.name) or "?"
    put(1, 2, ("CFG  #%s  %s"):format(tostring(cfgEdit.ids[1]), name), C.fg)
    local pos = fleet.pos[cfgEdit.ids[1]]
    local ptxt = pos and ("%d,%d,%d"):format(pos[1], pos[2], pos[3]) or "N/A"
    put(1, 3, "POS  " .. ptxt, C.dim)
    drawSep(4)

    for r = 0, 9 do
        local idx = cfgTop + r + 1
        local f = FIELDS[idx]
        if f then
            local y = 5 + r
            put(1, y, f.l, C.dim)
            local v = cfgValueText(f.k)
            put(10, y, v:sub(1, 14), C.fg)
            btn(1, y, 24, y, "field" .. idx, f.l .. " " .. v)
        end
    end

    if #FIELDS > 10 then
        put(2, 15, ("%d-%d/%d"):format(cfgTop + 1, math.min(cfgTop + 10, #FIELDS), #FIELDS), C.dim)
        if cfgTop > 0 then arrow(25, 15, "^", "cup") end
        if cfgTop + 10 < #FIELDS then arrow(25, 16, "v", "cdn") end
    end

    box(1, 16, 7, " BACK", "cback")
    box(9, 16, 7, "RESET", "creset")
    box(17, 16, 8, "SAVE", "csave")

    drawSep(17)

    local s = cfgEdit.scope
    box(1, 18, 6, "THIS", "sTHIS", s == "THIS" and C.tabOn or C.btn, s == "THIS" and colors.black or C.btnText)
    box(8, 18, 8, "ALL", "sALL", s == "ALL" and C.tabOn or C.btn, s == "ALL" and colors.black or C.btnText)
    box(17, 18, 8, "GROUP", "sGROUP", s == "GROUP" and C.tabOn or C.btn, s == "GROUP" and colors.black or C.btnText)

    put(1, 19, msgText:sub(1, W), C.warn)
    put(1, 20, ("%d TARGET(S)"):format(#cfgEdit.ids), C.ok)
end

local function drawGroup()
    put(3, 2, "GROUP CONFIG", C.fg)
    drawSep(3)
    put(1, 4, "NAME", C.dim)
    put(7, 4, (grpEdit.name or ""):sub(1, 6), C.fg)
    btn(7, 4, 12, 4, "gname", grpEdit.name)
    put(15, 4, "GAP", C.dim)
    put(19, 4, tostring(grpEdit.interval) .. "s", C.fg)
    btn(19, 4, 22, 4, "gint", tostring(grpEdit.interval))

    drawSep(5)

    local total = #fleet.missiles
    for r = 0, VIS_GROUP - 1 do
        local idx = groupTop + r + 1
        local m = fleet.missiles[idx]
        if m then
            local y = 6 + r
            local member = false
            local order = 0
            for i, id in ipairs(grpEdit.members) do
                if id == m.id then member = true order = i end
            end
            fill(1, y, 3, y, C.btn)
            put(1, y, member and "[x]" or "[ ]", C.btnText, C.btn)
            btn(1, y, 3, y, "gsel" .. m.id, member and "[x]" or "[ ]")
            put(5, y, (m.name or tostring(m.id)):sub(1, 7), C.fg)
            put(13, y, tostring(m.id), C.dim)
            if member then
                put(19, y, ("%02d"):format(order), C.dim)
                box(21, y, 2, "^", "gup" .. m.id)
                box(24, y, 2, "v", "gdn" .. m.id)
            end
        end
    end

    if total > VIS_GROUP then
        put(2, 16, ("%d-%d/%d"):format(groupTop + 1, math.min(groupTop + VIS_GROUP, total), total), C.dim)
        if groupTop > 0 then arrow(25, 16, "^", "gprev") end
        if groupTop + VIS_GROUP < total then arrow(25, 17, "v", "gnext") end
    end

    box(1, 18, 7, " BACK", "gbback")
    box(9, 18, 8, " SAVE ", "gbsave")
    put(1, 20, msgText:sub(1, W), C.warn)
end

-- 编辑浮层
local function drawEdit()
    fill(1, 13, 26, 19, C.bg)
    drawSep(13)
    put(1, 14, "EDIT " .. (edit.label or ""), C.tabOn)
    fill(1, 15, 24, 15, C.field)
    put(1, 15, (edit.buf .. "_"):sub(1, 24), C.fg, C.field)
    box(1, 17, 6, " OK ", "eok")
    box(8, 17, 8, "CANCEL", "ecancel")
    put(1, 19, edit.kind == "text" and "A-Z a-z 0-9 _" or "0-9 . -", C.dim)
end

local function drawWip(name)
    drawTabs()
    drawSep(2)
    put(3, 3, "MISSILE CONTROL SYSTEM", C.fg)
    put(1, 6, name .. " PAGE", C.tabOn)
    put(1, 8, "WORK IN PROGRESS", C.dim)
    put(1, 20, "TAB: LAUNCH", C.ok)
end

local function drawInfo()
    drawTabs()
    drawSep(2)
    put(1, 3, "NAME", C.dim)
    put(8, 3, "ID", C.dim)
    put(12, 3, "STATE", C.dim)
    put(18, 3, "POS X,Z", C.dim)

    local total = #fleet.missiles
    local nowt = os.epoch("utc") / 1000
    for r = 0, 9 do
        local m = fleet.missiles[infoTop + r + 1]
        if m then
            local y = 4 + r
            put(1, y, (m.name or tostring(m.id)):sub(1, 6), C.fg)
            put(8, y, tostring(m.id), C.dim)
            local st, sc = "NO LNK", C.dim
            local s = fleet.status[m.id]
            if m.deadAt then
                st, sc = "DEAD", C.warn
            elseif s and (nowt - s.t) < 6 then
                st = (s.armed == 1) and "ARMED" or "SAFE"
                sc = (s.armed == 1) and C.ok or C.fg
            end
            put(12, y, st, sc)
            if s and s.x then
                put(18, y, ("%d,%d"):format(s.x, s.z), C.dim)
            end
            btn(1, y, 25, y, "info" .. m.id)
        end
    end

    if total > 10 then
        put(2, 15, ("%d-%d/%d"):format(infoTop + 1, math.min(infoTop + 10, total), total), C.dim)
        if infoTop > 0 then arrow(25, 15, "^", "iup") end
        if infoTop + 10 < total then arrow(25, 16, "v", "idn") end
    end

    put(1, 18, "DOUBLE CLICK = DETAIL", C.dim)
    put(1, 19, msgText:sub(1, W), C.warn)
    put(1, 20, ("%d MISSILES"):format(total), C.ok)
end

local function drawInfoDetail()
    local m = findMissile(infoId)
    if not m then
        screen = "main"
        tab = 3
        return
    end
    local s = fleet.status[m.id]
    local nowt = os.epoch("utc") / 1000
    local st = "NO LINK"
    if m.deadAt then
        st = "DEAD"
    elseif s and (nowt - s.t) < 6 then
        st = (s.armed == 1) and "ARMED" or "SAFE"
    end
    put(1, 2, ("MISSILE #%d  %s"):format(m.id, (m.name or ""):sub(1, 8)), C.fg)
    drawSep(3)
    put(1, 4, "STATE  " .. st, (st == "ARMED") and C.ok or C.fg)
    put(1, 5, "POS    " .. (s and ("%d,%d,%d"):format(s.x, s.y, s.z) or "N/A"), C.dim)
    local c = m.cfg or {}
    local tgt = "NIL"
    if c.tx and c.ty and c.tz then
        tgt = ("%d,%d,%d"):format(c.tx, c.ty, c.tz)
    end
    put(1, 6, "TGT    " .. tgt, C.dim)
    put(1, 7, "DIST   " .. (s and tostring(s.dist) or "?"), C.dim)
    put(1, 8, "FUEL   " .. ((s and s.fn ~= "" and s.fn) or "N/A"), C.dim)
    put(1, 9, "AMOUNT " .. (s and ("%d/%d"):format(s.fa or 0, s.fc or 0) or "N/A"), C.dim)
    drawSep(10)
    put(1, 11, "LAST SEEN " .. (s and ("%ds"):format(math.floor(nowt - s.t)) or "never"), C.dim)
    box(1, 18, 7, " BACK", "iback")
end

local function draw()
    buttons = {}
    out.setBackgroundColor(C.bg)
    out.setTextColor(C.fg)
    out.clear()

    if screen == "pass" then
        drawPass()
    elseif screen == "bind" then
        drawBind()
    elseif screen == "cfg" then
        drawCfg()
    elseif screen == "group" then
        drawGroup()
    elseif screen == "info" then
        drawInfoDetail()
    elseif tab == 1 then
        drawLaunch()
    elseif tab == 2 then
        drawManage()
    elseif tab == 3 then
        drawInfo()
    else
        drawWip("BIND")
    end

    if edit then drawEdit() end

    if flash then
        fill(flash[1], flash[2], flash[3], flash[4], colors.yellow)
        if flash[6] then
            local pad = math.floor(((flash[3] - flash[1] + 1) - #flash[6]) / 2)
            put(flash[1] + pad, flash[2], flash[6], colors.black, colors.yellow)
        end
    end
end

-- ==========================================
-- 输入
-- ==========================================
local function clampTop(top, total, vis)
    if top < 0 then top = 0 end
    if top > math.max(0, total - vis) then top = math.max(0, total - vis) end
    return top
end

local function doAction(id)
    dirty = true

    if edit then
        if id == "eok" then commitEdit()
        elseif id == "ecancel" then edit = nil
        elseif id:sub(1, 3) == "num" then editChar(id:sub(4))
        elseif id == "clr" then edit.buf = ""
        end
        return
    end

    if screen == "pass" then
        if id == "clr" then passBuf = ""
        elseif id == "ok" then passSubmit()
        elseif id == "chgpass" and passMode == "lock" then
            passBuf = ""
            passMode = "chg_old"
            setMsg("ENTER OLD CODE")
        elseif id:sub(1, 3) == "num" then passKey(id:sub(4)) end

    elseif screen == "bind" then
        if id == "plus" then
            if slotCount < MAXIDS then
                slotCount = slotCount + 1
                slots[slotCount] = slots[slotCount] or ""
                focus = slotCount
            end
        elseif id == "minus" then
            if slotCount > 1 then
                slots[slotCount] = nil
                slotCount = slotCount - 1
                if focus > slotCount then focus = slotCount end
            end
        elseif id == "done" then bindDone()
        elseif id:sub(1, 4) == "slot" then focus = tonumber(id:sub(5)) or 1 end

    elseif screen == "main" then
        if id:sub(1, 3) == "tab" then
            local n = tonumber(id:sub(4)) or 1
            if n == 4 then
                -- 重新绑定
                slots = {}
                slotCount = 0
                for _, m in ipairs(fleet.missiles) do
                    slotCount = slotCount + 1
                    slots[slotCount] = tostring(m.id)
                end
                if slotCount == 0 then slotCount = 1 slots[1] = "" end
                focus = 1
                screen = "bind"
                setMsg("REBIND")
            else
                tab = n
            end

        elseif tab == 1 then
            if id == "SINGLE" or id == "GROUP" or id == "ALL" then
                launchMode = id
                launchTop = 0
                setMsg("MODE " .. id)
            elseif id == "det" then
                detonateList()
            elseif launchMode == "SINGLE" then
                if id:sub(1, 3) == "arm" then
                    local mid = tonumber(id:sub(4)) or 0
                    local m = findMissile(mid)
                    if m then
                        m.armed = not m.armed
                        setMsg(m.armed and "SAFETY ON" or "SAFETY OFF")
                        addLog((m.armed and "ARM ON #" or "ARM OFF #") .. mid)
                    end
                elseif id:sub(1, 4) == "fire" then
                    local mid = tonumber(id:sub(5)) or 0
                    local m = findMissile(mid)
                    if m and m.armed then
                        launchNow(mid, nil)
                    elseif m then
                        setMsg("SAFETY IS OFF")
                    end
                elseif id == "lup" then
                    launchTop = clampTop(launchTop - 5, launchCount(), 5)
                elseif id == "ldn" then
                    launchTop = clampTop(launchTop + 5, launchCount(), 5)
                end
            else
                if id == "garm" then
                    grpArmed = not grpArmed
                    setMsg(grpArmed and "SAFETY ON" or "SAFETY OFF")
                elseif id == "gfire" then
                    if not grpArmed then
                        setMsg("SAFETY IS OFF")
                    elseif launchMode == "GROUP" then
                        fireGroups()
                    else
                        fireAll()
                    end
                elseif id == "gselall" then
                    local names = groupNames()
                    local all = true
                    for _, n in ipairs(names) do
                        if not groupSel[n] then all = false end
                    end
                    groupSel = {}
                    if not all then
                        for _, n in ipairs(names) do groupSel[n] = true end
                    end
                elseif id:sub(1, 4) == "gsel" then
                    local name = id:sub(5)
                    groupSel[name] = (not groupSel[name]) or nil
                elseif id == "ivm" then
                    fleet.allInterval = math.max(0, (fleet.allInterval or 0) - 1)
                    saveFleet()
                elseif id == "ivp" then
                    fleet.allInterval = math.min(60, (fleet.allInterval or 0) + 1)
                    saveFleet()
                elseif id == "lup" then
                    launchTop = clampTop(launchTop - 5, launchCount(), 5)
                elseif id == "ldn" then
                    launchTop = clampTop(launchTop + 5, launchCount(), 5)
                end
            end

        elseif tab == 2 then
            if id == "selall" then selectAll()
            elseif id == "mup" then listTop = clampTop(listTop - 5, #fleet.missiles, VIS_MANAGE)
            elseif id == "mdn" then listTop = clampTop(listTop + 5, #fleet.missiles, VIS_MANAGE)
            elseif id == "rename" then openRename()
            elseif id == "config" then openCfg()
            elseif id == "group" then openGroup()
            elseif id == "grpcfg" then
                local gname = exactGroup(selectedIds())
                if gname then openGroupByName(gname) end
            elseif id == "dissolve" then
                local gname = exactGroup(selectedIds())
                if gname then dissolveGroup(gname) end
            elseif id:sub(1, 3) == "sel" then toggleSel(tonumber(id:sub(4)) or 0)
            end
        elseif tab == 3 then
            if id:sub(1, 4) == "info" then
                local mid = tonumber(id:sub(5)) or 0
                local nowt = os.epoch("utc") / 1000
                if lastClickId == mid and (nowt - lastClickT) < 0.6 then
                    infoId = mid
                    screen = "info"
                else
                    lastClickId, lastClickT = mid, nowt
                end
            elseif id == "iup" then
                infoTop = clampTop(infoTop - 5, #fleet.missiles, 10)
            elseif id == "idn" then
                infoTop = clampTop(infoTop + 5, #fleet.missiles, 10)
            end
        end

    elseif screen == "info" then
        if id == "iback" then
            screen = "main"
            tab = 3
        end

    elseif screen == "cfg" then
        if id == "cback" then
            screen = "main"
            tab = 2
        elseif id == "creset" then
            cfgReset()
        elseif id == "csave" then
            cfgSave()
        elseif id == "sTHIS" then cfgEdit.scope = "THIS"
        elseif id == "sALL" then cfgEdit.scope = "ALL"
        elseif id == "sGROUP" then cfgEdit.scope = "GROUP"
        elseif id == "cup" then cfgTop = math.max(0, cfgTop - 10)
        elseif id == "cdn" then cfgTop = math.min(#FIELDS - 10, cfgTop + 10)
        elseif id:sub(1, 5) == "field" then
            local idx = tonumber(id:sub(6)) or 0
            local f = FIELDS[idx]
            if f then cfgFieldClick(f, idx) end
        end

    elseif screen == "group" then
        if id == "gbback" then
            screen = "main"
            tab = 2
        elseif id == "gbsave" then
            groupSave()
        elseif id == "gname" then
            openEdit("GROUP NAME", grpEdit.name, "text", {
                maxlen = 6,
                onDone = function(v) grpEdit.name = v setMsg("NAME OK") end,
            })
        elseif id == "gint" then
            openEdit("GAP (S)", tostring(grpEdit.interval), "int", {
                min = 0, max = 60,
                onDone = function(v) grpEdit.interval = v setMsg("GAP " .. v) end,
            })
        elseif id == "gprev" then groupTop = clampTop(groupTop - 5, #fleet.missiles, VIS_GROUP)
        elseif id == "gnext" then groupTop = clampTop(groupTop + 5, #fleet.missiles, VIS_GROUP)
        elseif id:sub(1, 4) == "gsel" then
            local mid = tonumber(id:sub(5)) or 0
            local pos
            for i, x in ipairs(grpEdit.members) do if x == mid then pos = i end end
            if pos then table.remove(grpEdit.members, pos) else grpEdit.members[#grpEdit.members + 1] = mid end
        elseif id:sub(1, 3) == "gup" then
            local mid = tonumber(id:sub(4)) or 0
            for i, x in ipairs(grpEdit.members) do
                if x == mid and i > 1 then
                    grpEdit.members[i], grpEdit.members[i - 1] = grpEdit.members[i - 1], grpEdit.members[i]
                    break
                end
            end
        elseif id:sub(1, 3) == "gdn" then
            local mid = tonumber(id:sub(4)) or 0
            for i, x in ipairs(grpEdit.members) do
                if x == mid and i < #grpEdit.members then
                    grpEdit.members[i], grpEdit.members[i + 1] = grpEdit.members[i + 1], grpEdit.members[i]
                    break
                end
            end
        end
    end
end

-- ==========================================
-- 启动
-- ==========================================
local function housekeeping()
    local nowt = os.epoch("utc") / 1000
    local changed = false
    for i = #fleet.missiles, 1, -1 do
        local m = fleet.missiles[i]
        if m.deadAt and (nowt - m.deadAt) > 40 then
            table.remove(fleet.missiles, i)
            sel[m.id] = nil
            changed = true
            addLog("REMOVE #" .. m.id)
        end
    end
    if changed then saveFleet() end
    return changed
end

setupScreen()
loadFleet()

if fleet.pass then
    passMode = "lock"
    setMsg("ENTER CODE")
else
    passMode = "set"
    setMsg("SET A 4-DIGIT CODE")
end
screen = "pass"
addLog("CONSOLE READY")
if not modemOk then addLog("WARN: NO MODEM") end

local function hit(x, y)
    for _, b in ipairs(buttons) do
        if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then
            return b
        end
    end
end

while true do
    if lqPump() then dirty = true end
    if not houseTimer then houseTimer = os.startTimer(1) end
    if (screen == "bind") and not blinkId then
        blinkId = os.startTimer(0.4)
    end
    if dirty then
        draw()
        dirty = false
    end

    local ev, p1, p2, p3 = os.pullEvent()

    if ev == "monitor_touch" or ev == "mouse_click" then
        local x, y = p2 - offX, p3 - offY
        local b = hit(x, y)
        if b then
            flash = b
            flashId = os.startTimer(0.15)
            doAction(b[5])
        end

    elseif ev == "mouse_scroll" then
        local dir, y = p1, p3
        if screen == "main" and tab == 2 then
            listTop = clampTop(listTop + dir, #fleet.missiles, VIS_MANAGE)
            dirty = true
        elseif screen == "cfg" then
            cfgTop = math.max(0, math.min(#FIELDS - 10, cfgTop + dir))
            dirty = true
        elseif screen == "group" then
            groupTop = clampTop(groupTop + dir, #fleet.missiles, VIS_GROUP)
            dirty = true
        elseif screen == "main" and tab == 1 then
            launchTop = clampTop(launchTop + dir, #fleet.missiles, 5)
            dirty = true
        elseif screen == "main" and tab == 3 then
            infoTop = clampTop(infoTop + dir, #fleet.missiles, 10)
            dirty = true
        end

    elseif ev == "char" then
        if edit then
            editChar(p1)
            dirty = true
        elseif screen == "pass" then
            local d = p1:match("%d")
            if d then passKey(d) dirty = true end
        elseif screen == "bind" then
            local d = p1:match("%d")
            if d then
                local s = slots[focus] or ""
                if #s < 3 then slots[focus] = s .. d end
                cursorOn = true
                dirty = true
            end
        end

    elseif ev == "key" then
        if p1 == keys.backspace then
            if edit then
                edit.buf = edit.buf:sub(1, -2)
            elseif screen == "pass" then
                passBuf = passBuf:sub(1, -2)
            elseif screen == "bind" then
                local s = slots[focus] or ""
                slots[focus] = s:sub(1, -2)
            end
            dirty = true
        elseif p1 == keys.enter then
            if edit then
                commitEdit()
            elseif screen == "pass" then
                passSubmit()
            elseif screen == "bind" then
                if focus < slotCount then focus = focus + 1 else bindDone() end
            end
            dirty = true
        elseif p1 == keys.escape then
            if edit then edit = nil dirty = true end
        end

    elseif ev == "timer" and p1 == blinkId then
        blinkId = nil
        cursorOn = not cursorOn
        if screen == "bind" then dirty = true end

    elseif ev == "timer" and p1 == flashId then
        flashId = nil
        flash = nil
        dirty = true

    elseif ev == "timer" and p1 == lqTimer then
        lqTimer = nil
        dirty = true

    elseif ev == "timer" and p1 == houseTimer then
        houseTimer = nil
        if housekeeping() then dirty = true end

    elseif ev == "rednet_message" then
        local sender, msg, proto = p1, p2, p3
        if proto == "status" and type(msg) == "table" and msg.cmd == "status" then
            local sid = msg.id or sender
            fleet.status[sid] = {
                t = os.epoch("utc") / 1000,
                x = msg.x, y = msg.y, z = msg.z,
                armed = msg.armed, dist = msg.dist,
                fn = msg.fn, fa = msg.fa, fc = msg.fc,
            }
            if (screen == "main" and tab == 3) or screen == "info" then
                dirty = true
            end
        elseif proto == "boom" then
            local m = findMissile(sender)
            if m and not m.deadAt then
                m.deadAt = os.epoch("utc") / 1000
                for name in pairs(m.groups or {}) do m.groups[name] = nil end
                saveFleet()
                addLog("BOOM #" .. sender)
                dirty = true
            end
        elseif type(msg) == "table" and type(msg[1]) == "number" then
            fleet.pos[sender] = { msg[1], msg[2], msg[3] }
            if screen == "cfg" then dirty = true end
        end

    elseif ev == "monitor_resize" or ev == "term_resize" then
        setupScreen()
        dirty = true
    end
end
