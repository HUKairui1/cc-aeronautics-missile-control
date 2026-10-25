-- ==========================================
-- 姿态PID控制器
-- 控制俯仰(pitch)和偏航(roll)
-- ==========================================

local PID = {
    -- 俯仰
    kp_n = 10,
    ki_n = 0.11,
    kd_n = 40,

    pitch_integral = 0,
    pitch_lasterror = 0,
    pitch_lasttime = 0,

    roll_integral = 0,
    roll_lasterror = 0,
    roll_lasttime = 0,
    
    -- 限幅
    integral_limit = 30,
    output_limit = 15,
    
    -- 死区
    deadband = 0.1
}

--- 角度误差归一化到 -π ~ π
local function normalizeAngle(error)
    while error > math.pi do
        error = error - 2 * math.pi
    end
    while error < -math.pi do
        error = error + 2 * math.pi
    end
    return error
end

--- 四元数: 机体 -> 世界
local function qrot(qx, qy, qz, qw, vx, vy, vz)
    local tx = 2 * (qy * vz - qz * vy)
    local ty = 2 * (qz * vx - qx * vz)
    local tz = 2 * (qx * vy - qy * vx)
    return vx + qw * tx + (qy * tz - qz * ty),
           vy + qw * ty + (qz * tx - qx * tz),
           vz + qw * tz + (qx * ty - qy * tx)
end

--- 角度归一化到 -180 ~ 180
local function wrap180(a)
    a = (a + 180) % 360
    if a < 0 then a = a + 360 end
    return a - 180
end

local function clampNum(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- 方位修正方向: 实飞转反了就改成 -1
local AZ_SIGN = 1

-- ===== 动力俯冲参数 =====
local DIVE_BASE = 0.40    -- 二段基准节流(四台一起); 推重比不够就往上加
local DIVE_KP   = 0.006   -- 二段增益(原来 0.0005 等于没有权限)
local DIVE_KD   = 0.025
local GRAV_LEAD = 2.0     -- 末端重力前置角(度): 落点偏近就加大, 偏远就减小

-- ===== 抛物线(中段抬高) =====
local LOFT_K     = 0.32   -- 每远 1 格抬高多少
local LOFT_MAX   = 1200    -- 最大抬高(格)
local LOFT_FLOOR = 600    -- 水平距离小于此值就不再抬高

-- ===== 地面站下发配置 =====
local GUIDE_H   = 1000    -- 上升高度, 超过它才开制导
local MAXTHR    = 15      -- 最大推力(继电器 7..15)
local TRIG      = "IMPACT"  -- HEIGHT / IMPACT
local TRIG_H    = -50     -- 高度引爆的高度
local DET_SIDE  = "back"  -- 引爆输出: 电脑后面
local BUMP_SIDE = "top"   -- 撞击输出: 电脑顶面
local DETONATED = false
local ARMED     = false   -- 解开保险(收到发射指令后)

local function applyCfg(c)
    if type(c) ~= "table" then return end
    if c.tx and c.ty and c.tz then
        targetPosition = { x = c.tx, y = c.ty, z = c.tz }
    end
    if c.ascent then GUIDE_H = c.ascent end
    if c.kp then PID.kp_n = c.kp * 1000 end
    if c.ki then PID.ki_n = c.ki * 1000 end
    if c.kd then PID.kd_n = c.kd * 1000 end
    if c.maxthr then MAXTHR = math.max(7, math.min(15, math.floor(c.maxthr))) end
    if c.trig == "HEIGHT" or c.trig == "IMPACT" then TRIG = c.trig end
    if c.trigh then TRIG_H = c.trigh end
    if c.dive then DIVE_BASE = c.dive end
    if c.lead then GRAV_LEAD = c.lead end
    if c.loft then LOFT_K = c.loft end
end

local function readFuel()
    local name, amt, cap = nil, 0, 0
    for _, p in ipairs(tanks or {}) do
        local ok, t = pcall(p.tanks)
        if ok and type(t) == "table" then
            for _, e in pairs(t) do
                if type(e) == "table" then
                    local a = e.amount or 0
                    amt = amt + a
                    cap = cap + (e.capacity or 0)
                    if a > 0 and not name then name = e.name end
                end
            end
        end
    end
    return name, amt, cap
end

local function sendStatus()
    if not targetPosition then return end
    local ddx, ddy, ddz = dx or 0, dy or 0, dz or 0
    local d3 = math.sqrt(ddx*ddx + ddy*ddy + ddz*ddz)
    local fn, fa, fc = readFuel()
    pcall(rednet.send, 1, {
        cmd = "status",
        id = os.getComputerID(),
        x = math.floor(position.x), y = math.floor(position.y), z = math.floor(position.z),
        armed = ARMED and 1 or 0,
        dist = math.floor(d3),
        fn = fn or "", fa = fa, fc = fc,
    }, "status")
end

local function detonate(reason)
    if DETONATED then return end
    DETONATED = true
    print("BOOM " .. tostring(reason))
    pcall(function() jl.write("|BOOM " .. tostring(reason)) end)
    local okd, errd = pcall(function() redstone.setOutput(DET_SIDE, true) end)
    if not okd then print("DET ERR " .. tostring(errd)) end
    pcall(function() redrelay.setAnalogOutput("right", 0) end)
    pcall(function() rednet.send(1, { cmd = "boom", id = os.getComputerID() }, "boom") end)
    for _, th in ipairs({ thruster_f_l, thruster_f_r, thruster_b_l, thruster_b_r }) do
        if th then pcall(th.setPowerNormalized, 0) end
    end
end

local function crash()
    pcall(function() redstone.setOutput(BUMP_SIDE, true) end)
    if ARMED then
        detonate("CRASH")
    end
end

--- 俯仰PID
function pitchPID(targetPitch, currentPitch)
    local now = os.clock()
    local dt = now - PID.pitch_lasttime
    if dt <= 0 then dt = 0.01 end
    
    local error = targetPitch - currentPitch
    errorS = error
    if math.abs(error) < PID.deadband then
        PID.pitch_lasterror = error
        return 0
    end
    
    local p = kp * error
    
    PID.pitch_integral = PID.pitch_integral + error * dt
    PID.pitch_integral = math.max(-PID.integral_limit, math.min(PID.integral_limit, PID.pitch_integral))
    local i = ki * PID.pitch_integral
    
    local derivative = (error - PID.pitch_lasterror) / dt
    local d = kd * derivative
    
    local output = p + i + d
    
    PID.pitch_lasterror = error
    PID.pitch_lasttime = now
    
    return output
end

--- 偏航PID
function rollPID(targetRoll, currentRoll)
    local now = os.clock()
    local dt = now - PID.roll_lasttime
    if dt <= 0 then dt = 0.01 end
    
    local error = targetRoll - currentRoll
    
    if math.abs(error) < PID.deadband then
        PID.roll_lasterror = error
        return 0
    end
    
    local p = kp * error
    
    PID.roll_integral = PID.roll_integral + error * dt
    PID.roll_integral = math.max(-PID.integral_limit, math.min(PID.integral_limit, PID.roll_integral))
    local i = ki * PID.roll_integral
    
    local derivative = (error - PID.roll_lasterror) / dt
    local d = kd * derivative
    
    local output = p + i + d
    
    PID.roll_lasterror = error
    PID.roll_lasttime = now
    
    return output
end

--- 重置PID状态
function resetPID()
    PID.pitch_integral = 0
    PID.pitch_lasterror = 0
    PID.pitch_lasttime = os.clock()
    PID.roll_integral = 0
    PID.roll_lasterror = 0
    PID.roll_lasttime = os.clock()
end

function cs()
    while true do
        for i = 1, 4, 1 do
            thruster_f_l.setPowerNormalized(Max_Power)
            sleep(1)
            thruster_f_l.setPowerNormalized(0)
            thruster_f_r.setPowerNormalized(Max_Power)
            sleep(1)
            thruster_f_r.setPowerNormalized(0)
            thruster_b_l.setPowerNormalized(Max_Power)
            sleep(1)
            thruster_b_l.setPowerNormalized(0)
            thruster_b_r.setPowerNormalized(Max_Power)
            sleep(1)
            thruster_b_r.setPowerNormalized(0)
            sleep(10)
        end
    end
end

function getTailPosition(nosePos, length, pitch, yaw)
    local p = math.rad(pitch)
    local y = math.rad(yaw)
    
    local dx = -math.sin(y) * math.cos(p)
    local dy =  math.cos(y) * math.cos(p)
    local dz =  math.sin(p)
    
    return {
        x = nosePos.x - dx * length,
        y = nosePos.y - dy * length,
        z = nosePos.z - dz * length
    }
end

--连接外设 (不需要姿态传感器)
redrelay = peripheral.find("redstone_relay")
peripheral.find("modem", rednet.open)
thrusters = {peripheral.find("liquid_vector_thruster")}
--thrusters = {peripheral.find("creative_vector_thruster")}
thruster_f_l = thrusters[2]
thruster_f_r = thrusters[1]
thruster_b_l = thrusters[3]
thruster_b_r = thrusters[4]

-- 绑定流体储罐(最多 2 个)
tanks = {}
for _, n in ipairs(peripheral.getNames()) do
    local ty = tostring(peripheral.getType(n)):lower()
    if ty:find("tank") then
        tanks[#tanks + 1] = peripheral.wrap(n)
    end
end
if #tanks == 0 then
    for _, n in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(n)
        if p and p ~= thruster_f_l and p ~= thruster_f_r and p ~= thruster_b_l and p ~= thruster_b_r then
            local ok, t = pcall(p.tanks)
            if ok and type(t) == "table" then
                tanks[#tanks + 1] = p
            end
        end
    end
end
while #tanks > 2 do
    tanks[#tanks] = nil
end

--cs()
--设置变量
targetPosition = nil
Vector = 1
Max_Power = 1
baseThrust = 0
guidanceActivation = false
kp = PID.kp_n/1000
ki = PID.ki_n/1000
kd = PID.kd_n/1000

--初始化
thruster_f_l.setVector(-Vector, -Vector)
thruster_f_r.setVector(-Vector, Vector)
thruster_b_l.setVector(Vector, -Vector)
thruster_b_r.setVector(Vector, Vector)
redstone.setOutput("left", true)
redstone.setOutput("right", true)
redrelay.setOutput("right", false)
redrelay.setOutput("top",true)


--afns.setChannelValue("targetPitch",0)
--afns.setChannelValue("targetRoll",0)
--sleep(1)
pose = sublevel.getLogicalPose()
position = pose.position
initialHeight = position.y
rednet.send(0,position)

-- 等目标配置 + 发射指令; 期间到达的 cfg 不会被丢掉
print("MSL v3 DET-READY  ID " .. os.getComputerID())
print("WAIT TARGET")
while true do
    local _, message, proto = rednet.receive(nil, 1)
    if proto == "cfg" and type(message) == "table" and message.cfg then
        applyCfg(message.cfg)
        if targetPosition then print("TARGET OK") end
    elseif proto == "det" then
        print("DET PRELAUNCH - BOOM")
        detonate("REMOTE")
        while true do os.sleep(1) end
    elseif proto == "ks" then
        if targetPosition and targetPosition.x then
            ARMED = true
            print("LAUNCH")
            break
        else
            print("NO TARGET - IGNORE")
        end
    end
end
redrelay.setAnalogOutput("right", MAXTHR)
new = os.clock()

jl = fs.open("jl.log", "w")
jl.write("记录开始")
-- 撞机检测的采样初值
lastPos = { x = position.x, y = position.y, z = position.z }
lastT = os.epoch("utc") / 1000
launchT = lastT
lastSpeed = nil
crashHits = 0
while true do
    if redstone.getInput("back") then
        os.reboot()
    end
    -- 定时收配置/引爆指令(每 5 帧一次)
    cfgPoll = (cfgPoll or 0) + 1
    if cfgPoll >= 5 then
        cfgPoll = 0
        local _, cmsg, cproto = rednet.receive(nil, 0)
        if cproto == "cfg" and type(cmsg) == "table" and cmsg.cfg then
            applyCfg(cmsg.cfg)
        elseif cproto == "det" then
            print("DET RCVD - BOOM")
            detonate("REMOTE")
        end
    end
    --获取当前状态信息
    --id , targetPosition = rednet.receive("pos")
    pose = sublevel.getLogicalPose()
    position = pose.position

    -- 撞机检测: 优先速度 API; 否则每 0.1 秒用位置差分算一次(避免按 tick 抖动误判)
    local spd = nil
    local okv, vel = pcall(sublevel.getVelocity)
    if okv and type(vel) == "table" then
        local vx = vel.x or vel[1] or 0
        local vy = vel.y or vel[2] or 0
        local vz = vel.z or vel[3] or 0
        spd = math.sqrt(vx*vx + vy*vy + vz*vz)
    end
    if not spd then
        local nowt = os.epoch("utc") / 1000
        if nowt - lastT >= 0.1 then
            local ddx = position.x - lastPos.x
            local ddy = position.y - lastPos.y
            local ddz = position.z - lastPos.z
            local dt = nowt - lastT
            if dt > 1e-3 then
                spd = math.sqrt(ddx*ddx + ddy*ddy + ddz*ddz) / dt
            end
            lastPos = { x = position.x, y = position.y, z = position.z }
            lastT = nowt
        end
    end
    if spd then
        local nowt = os.epoch("utc") / 1000
        if nowt - launchT > 1 and lastSpeed and lastSpeed > 8 and spd < lastSpeed * 0.3 then
            crashHits = crashHits + 1
            if crashHits >= 2 then crash() end
        else
            crashHits = 0
        end
        lastSpeed = spd
    end
    if DETONATED then break end
    
    ori = pose.orientation
    q = quaternion.fromComponents(ori.v.x, ori.v.y, ori.v.z, ori.a)
    

    currentPitch, currentYaw, currentRoll = q:toEuler()
    currentPitch = math.deg(currentPitch)
    currentYaw = math.deg(currentYaw)
    currentRoll = math.deg(currentRoll)
    if not csPitch then
        csPitch = currentPitch
        csRoll = currentRoll
    end

    --计算距离
    dx = position.x - targetPosition.x
    dy = position.y - targetPosition.y
    dz = position.z - targetPosition.z

    -- 引爆判定(必须已解保险)
    local dist3 = math.sqrt(dx*dx + dy*dy + dz*dz)
    if ARMED and not DETONATED then
        if TRIG == "HEIGHT" and position.y <= TRIG_H then
            detonate("HEIGHT")
        elseif TRIG == "IMPACT" and dist3 < 8 then
            detonate("IMPACT")
        end
    end
    if DETONATED then break end

    local yaw_rad = math.rad(currentYaw)
    local local_dx = dx * math.cos(yaw_rad) - dz * math.sin(yaw_rad)
    local local_dz = dx * math.sin(yaw_rad) + dz * math.cos(yaw_rad)

    horizontalDistance = math.sqrt(dy*dy + local_dz*local_dz)
    Distance = math.sqrt(dz*dz + dx*dx)
    -- ===== 姿态误差: 四元数直接算倾斜角/方位角, 不经过欧拉角(±90 会翻面) =====
    -- 抛物线: 远距离瞄"目标上方", 近了把抬高量收回, 形成先抬后压的弧线
    local horizD = math.sqrt(dx*dx + dz*dz)
    local loft = clampNum((horizD - LOFT_FLOOR) * LOFT_K, 0, LOFT_MAX)
    local dyAim = dy - loft
    local distAim = math.sqrt(dx*dx + dyAim*dyAim + dz*dz)

    -- 机体 +Y(推力方向) 在世界中的指向
    local ux, uy, uz = qrot(ori.v.x, ori.v.y, ori.v.z, ori.a, 0, 1, 0)
    local tiltBody = math.deg(math.acos(math.max(-1, math.min(1, uy))))
    local azBody = math.deg(math.atan2(ux, uz))

    -- 瞄点方向的倾斜角/方位角
    local lx, ly, lz = 0, -1, 0
    if distAim > 1e-6 then
        lx, ly, lz = -dx / distAim, -dyAim / distAim, -dz / distAim
    end
    local tiltLos = math.deg(math.acos(math.max(-1, math.min(1, ly))))
    local azLos = math.deg(math.atan2(lx, lz))

    -- 俯仰误差: 还差多少倾斜(负=继续往目标压, 能一直压到 180=正下方)
    -- +GRAV_LEAD: 再抬头一点, 抵消重力造成的落点偏近
    local errTilt = clampNum(tiltBody - tiltLos + GRAV_LEAD, -80, 80)

    -- 方位误差: 机体越接近竖直或倒扣, 方位越没意义, 按水平分量自动衰减
    local hb = math.sqrt(ux*ux + uz*uz)      -- sin(tiltBody)
    local hl = math.sqrt(lx*lx + lz*lz)      -- sin(tiltLos)
    local wAz = math.min(1, hb / 0.25) * math.min(1, hl / 0.20)
    local errAz = AZ_SIGN * clampNum(wrap180(azLos - azBody), -80, 80) * wAz

    -- 直接当误差喂给原来的 PID(目标 = 当前 + 误差)
    targetPitch = currentPitch + errTilt
    targetRoll  = currentRoll + errAz

    ue = 0
    --判断是否开启制导
    if position.y - initialHeight > GUIDE_H then
        guidanceActivation = true
    end

    --判断是否启动二段推进
    if Distance < 1000 then
        redrelay.setAnalogOutput("right", 0)
        redstone.setOutput("left", false)
        redstone.setOutput("right", false)
        baseThrust = DIVE_BASE
        State = 2
        Vector = 0
        --thruster_f_l.setVector(-Vector, -Vector)
        --thruster_f_r.setVector(-Vector, Vector)
        --thruster_b_l.setVector(Vector, -Vector)
        --thruster_b_r.setVector(Vector, Vector)
        thruster_f_l.setVector(Vector, Vector)
        thruster_f_r.setVector(Vector, -Vector)
        thruster_b_l.setVector(-Vector, Vector)
        thruster_b_r.setVector(-Vector, -Vector)
    elseif Distance < 2000 then
        redrelay.setAnalogOutput("right", 1)
    end
    if not guidanceActivation then
        targetRoll = 0
        targetPitch = 0
        kp = 0.02
        ki = 0
        kd = 0.06
        new = os.clock()
    else
        if State == 1 then
            kp = PID.kp_n/1000
            ki = PID.ki_n/1000
            kd = PID.kd_n/1000
            redrelay.setAnalogOutput("right", MAXTHR)
        elseif State == 2 then
            -- 动力俯冲: 四台推进器要有真正的控制权限
            kp = DIVE_KP
            ki = 0
            kd = DIVE_KD
            ue = os.clock()
        end
    end

    --获取控制量
    pitchCorrection = pitchPID(targetPitch, currentPitch)
    rollCorrection = rollPID(targetRoll, currentRoll)

    --发送给终端
    rednet.send(1,{math.floor(position.x), math.floor(position.y), math.floor(position.z)})
    rednet.send(0,{math.floor(currentPitch), math.floor(currentYaw), math.floor(currentRoll).."   ", math.floor(targetPitch), math.floor(targetRoll).."   ", 0, 0, " ",math.floor(position.x), math.floor(position.y), math.floor(position.z),math.floor(ue)}) 

    -- 应用到推进器
    thruster_f_l.setPowerNormalized(math.max(0, math.min(Max_Power, baseThrust - pitchCorrection + rollCorrection)))
    thruster_f_r.setPowerNormalized(math.max(0, math.min(Max_Power, baseThrust + pitchCorrection + rollCorrection)))
    thruster_b_l.setPowerNormalized(math.max(0, math.min(Max_Power, baseThrust - pitchCorrection - rollCorrection)))
    thruster_b_r.setPowerNormalized(math.max(0, math.min(Max_Power, baseThrust + pitchCorrection - rollCorrection)))
    statTick = (statTick or 0) + 1
    if statTick >= 20 then
        statTick = 0
        sendStatus()
    end
    jl.write()
    jl.write(currentPitch.." "..currentYaw.." "..currentRoll.." "..targetPitch.." "..targetRoll.." "..position.x.." "..position.y.." "..position.z.." "..pitchCorrection.." "..rollCorrection)
end