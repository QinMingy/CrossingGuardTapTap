-- ============================================================
-- 《过街警卫乔》— 队列护送版
-- Street Guard Joe - Queue Escort Edition
-- ============================================================

require "LuaScripts/Utilities/Sample"

-- ======================== 可配置参数 ========================
local SPAWN_INTERVAL = 1.0        -- a: 小孩入场间隔（秒）
local MAX_CHILDREN = 4            -- b: 最大同时存在的小孩数量
local STOP_DISTANCE = 40          -- n: 停止距离阈值（像素）
local RESUME_DISTANCE = 60        -- m: 恢复移动距离阈值（像素）
local LANE_COUNT = 3              -- 车道数
local GAME_DURATION = 60          -- 游戏时长（秒）
local HIGHLIGHT_THRESHOLD = 30    -- 高亮距离阈值（像素）
local CHILD_SPEED = 80            -- 小孩移动速度（像素/秒）
local GUARD_SPEED = 250           -- 警卫移动速度（像素/秒）
local CAR_BASE_SPEED = 90         -- 车辆基础速度（像素/秒）
local CAR_MAX_SPEED = 200         -- 车辆最大速度（像素/秒）
local CAR_BASE_INTERVAL = 2.8     -- 车辆基础生成间隔（秒）
local CAR_MIN_INTERVAL = 0.9      -- 车辆最小生成间隔（秒）

-- ======================== 游戏世界参数 ========================
local WORLD_W = 1280
local WORLD_H = 720
local LEFT_EDGE = 180             -- 左侧安全区宽度（小孩在此生成）
local RIGHT_EDGE = WORLD_W - 120  -- 右侧安全区边界
local CHILD_Y = 0
local GUARD_Y = 0
local LANE_X = {}
local LANE_WIDTH = 0

-- ======================== 游戏状态 ========================
local score = 0
local timeLeft = GAME_DURATION
local gameOver = false
local spawnTimer = 0
local spaceWasDown = false

local children = {}
local cars = {}
local guardX = WORLD_W / 2
local highlightedIdx = nil

local carLaneTimers = {}

-- ======================== 撞击特效状态 ========================
local debris = {}            -- 飞散的肢体碎片
local bloodParticles = {}    -- 血液粒子
local bloodStains = {}       -- 地面血迹（永久）
local hitFreezeTimer = 0     -- 停帧计时器
local HIT_FREEZE_DURATION = 0.08  -- 停帧时长
local screenShakeTimer = 0   -- 屏幕抖动计时器
local SCREEN_SHAKE_DURATION = 0.35
local SCREEN_SHAKE_INTENSITY = 8   -- 抖动强度(像素)
local flashAlpha = 0         -- 闪白Alpha
local flashNode = nil        -- 全屏闪白节点
local cameraBasePos = nil    -- 相机原始位置
local BLOOD_STAIN_Z = 5.5   -- 血迹层级（在道路表面之上）

-- ======================== 场景节点引用 ========================
local scene_ = nil
local cameraNode = nil
local gameNode = nil
local guardNode = nil
local guardHighlightNode = nil

-- UI 引用
local scoreText = nil
local timeText = nil
local instructionText = nil
local gameOverPanel = nil
local gameOverText = nil
local finalScoreText = nil
local restartText = nil

-- ======================== 工具函数 ========================
local function createColorMaterial(r, g, b, a)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, a or 1.0)))
    return mat
end

local function createBox(parent, x, y, w, h, mat, zOrder)
    local node = parent:CreateChild("")
    node.position = Vector3(x, y, zOrder or 0)
    node.scale = Vector3(w, h, 1)
    local model = node:CreateComponent("StaticModel")
    model.model = cache:GetResource("Model", "Models/Box.mdl")
    model.material = mat
    return node
end

-- ======================== 车道方向（必须在使用前定义） ========================
local function getLaneDirection(laneIndex)
    if laneIndex % 2 == 1 then
        return 1   -- 从下到上（Y增加方向）
    else
        return -1  -- 从上到下（Y减少方向）
    end
end

-- ======================== 布局初始化 ========================
local function initLayout()
    local roadLeft = LEFT_EDGE + 20
    local roadRight = RIGHT_EDGE - 20
    local roadWidth = roadRight - roadLeft
    LANE_WIDTH = roadWidth / LANE_COUNT

    LANE_X = {}
    for i = 1, LANE_COUNT do
        LANE_X[i] = roadLeft + (i - 0.5) * LANE_WIDTH
    end

    CHILD_Y = 0
    GUARD_Y = CHILD_Y + 50
end

-- ======================== 背景构建（必须在createScene前定义） ========================
local function createBackground()
    -- 左侧安全区（亮绿色，明显可见）
    local leftZoneMat = createColorMaterial(0.18, 0.45, 0.18, 1.0)
    createBox(gameNode, LEFT_EDGE / 2, 0, LEFT_EDGE, WORLD_H, leftZoneMat, 5)
    -- 安全区边界线（白色竖线）
    local borderMat = createColorMaterial(1.0, 1.0, 1.0, 0.5)
    createBox(gameNode, LEFT_EDGE, 0, 4, WORLD_H, borderMat, 4.5)

    -- 右侧安全区（亮绿色）
    local rightZoneMat = createColorMaterial(0.18, 0.45, 0.18, 1.0)
    local rightW = WORLD_W - RIGHT_EDGE
    createBox(gameNode, RIGHT_EDGE + rightW / 2, 0, rightW, WORLD_H, rightZoneMat, 5)
    -- 右侧边界线
    createBox(gameNode, RIGHT_EDGE, 0, 4, WORLD_H, borderMat, 4.5)

    -- 道路背景（深灰）
    local roadLeft = LEFT_EDGE + 20
    local roadRight = RIGHT_EDGE - 20
    local roadW = roadRight - roadLeft
    local roadMat = createColorMaterial(0.25, 0.25, 0.28, 1.0)
    createBox(gameNode, (roadLeft + roadRight) / 2, 0, roadW, WORLD_H, roadMat, 6)

    -- 车道分隔线（虚线）
    local lineMat = createColorMaterial(0.7, 0.7, 0.7, 0.6)
    for i = 1, LANE_COUNT - 1 do
        local lx = roadLeft + i * LANE_WIDTH
        local dashCount = 15
        local dashH = 20
        local gap = 28
        local totalH = (dashH + gap) * dashCount
        local startY = -totalH / 2
        for d = 1, dashCount do
            local dy = startY + (d - 1) * (dashH + gap) + dashH / 2
            createBox(gameNode, lx, dy, 3, dashH, lineMat, 4.9)
        end
    end

    -- 小孩通道指示线（黄色）
    local pathMat = createColorMaterial(0.9, 0.9, 0.3, 0.3)
    createBox(gameNode, WORLD_W / 2, CHILD_Y + 18, WORLD_W - 200, 2, pathMat, 4.8)
    createBox(gameNode, WORLD_W / 2, CHILD_Y - 18, WORLD_W - 200, 2, pathMat, 4.8)

    -- 车道方向箭头指示
    local arrowMat = createColorMaterial(0.7, 0.7, 0.7, 0.3)
    for i = 1, LANE_COUNT do
        local lx = LANE_X[i]
        local dir = getLaneDirection(i)
        for a = 1, 3 do
            local ay = (a - 2) * 120 * dir
            local arrowNode = gameNode:CreateChild("")
            arrowNode.position = Vector3(lx, ay, 4.7)
            arrowNode.scale = Vector3(8, 12, 1)
            if dir == 1 then
                arrowNode.rotation = Quaternion(45, Vector3.FORWARD)
            else
                arrowNode.rotation = Quaternion(-45, Vector3.FORWARD)
            end
            local mdl = arrowNode:CreateComponent("StaticModel")
            mdl.model = cache:GetResource("Model", "Models/Box.mdl")
            mdl.material = arrowMat
        end
    end
end

-- ======================== 场景构建 ========================
local function createScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")

    -- 摄像机
    cameraNode = scene_:CreateChild("Camera")
    local camera = cameraNode:CreateComponent("Camera")
    camera.orthographic = true
    camera.orthoSize = WORLD_H
    camera.nearClip = 0.1
    camera.farClip = 100
    cameraNode.position = Vector3(WORLD_W / 2, 0, -50)
    cameraNode:LookAt(Vector3(WORLD_W / 2, 0, 0))

    -- 视口
    local viewport = Viewport:new(scene_, camera)
    renderer:SetViewport(0, viewport)
    renderer.defaultZone.fogColor = Color(0.15, 0.15, 0.18, 1.0)

    -- 游戏对象父节点
    gameNode = scene_:CreateChild("Game")

    -- 绘制静态背景
    createBackground()
end

-- ======================== 警卫节点 ========================
local function createGuardNode()
    guardNode = gameNode:CreateChild("Guard")
    guardNode.position = Vector3(guardX, GUARD_Y, 1)

    -- 身体（深蓝）
    local bodyMat = createColorMaterial(0.15, 0.2, 0.5, 1.0)
    createBox(guardNode, 0, -5, 28, 32, bodyMat, 0)

    -- 头（肤色）
    local headMat = createColorMaterial(1.0, 0.85, 0.7, 1.0)
    createBox(guardNode, 0, 14, 18, 18, headMat, -0.1)

    -- 帽子（深蓝）
    local hatMat = createColorMaterial(0.1, 0.1, 0.4, 1.0)
    createBox(guardNode, 0, 24, 22, 8, hatMat, -0.2)

    -- 帽徽（金色）
    local badgeMat = createColorMaterial(1.0, 0.84, 0.0, 1.0)
    createBox(guardNode, 0, 24, 6, 6, badgeMat, -0.3)

    -- 高亮指示线（初始隐藏）
    guardHighlightNode = guardNode:CreateChild("Highlight")
    guardHighlightNode.position = Vector3(0, -40, -0.5)
    guardHighlightNode.scale = Vector3(4, 30, 1)
    local hlMat = createColorMaterial(1.0, 0.84, 0.0, 0.5)
    local hlModel = guardHighlightNode:CreateComponent("StaticModel")
    hlModel.model = cache:GetResource("Model", "Models/Box.mdl")
    hlModel.material = hlMat
    guardHighlightNode.enabled = false
end

-- ======================== 撞击特效系统 ========================

-- 创建全屏闪白覆盖层（初始隐藏，在场景最前方）
local function createFlashOverlay()
    flashNode = gameNode:CreateChild("Flash")
    flashNode.position = Vector3(WORLD_W / 2, 0, -5)
    flashNode.scale = Vector3(WORLD_W * 2, WORLD_H * 2, 1)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 0)))
    local model = flashNode:CreateComponent("StaticModel")
    model.model = cache:GetResource("Model", "Models/Box.mdl")
    model.material = mat
    flashNode.enabled = false
end

-- 触发闪白
local function triggerFlash()
    flashAlpha = 0.6
    flashNode.enabled = true
end

-- 更新闪白衰减
local function updateFlash(dt)
    if flashAlpha > 0 then
        flashAlpha = flashAlpha - dt * 4.0  -- 快速衰减
        if flashAlpha <= 0 then
            flashAlpha = 0
            flashNode.enabled = false
        else
            local model = flashNode:GetComponent("StaticModel")
            local mat = model.material
            mat:SetShaderParameter("MatDiffColor", Variant(Color(1, 0.9, 0.9, flashAlpha)))
        end
    end
end

-- 触发屏幕抖动
local function triggerScreenShake()
    screenShakeTimer = SCREEN_SHAKE_DURATION
end

-- 更新屏幕抖动
local function updateScreenShake(dt)
    if screenShakeTimer > 0 then
        screenShakeTimer = screenShakeTimer - dt
        local intensity = SCREEN_SHAKE_INTENSITY * (screenShakeTimer / SCREEN_SHAKE_DURATION)
        local offX = (math.random() - 0.5) * 2 * intensity
        local offY = (math.random() - 0.5) * 2 * intensity
        cameraNode.position = Vector3(cameraBasePos.x + offX, cameraBasePos.y + offY, cameraBasePos.z)
    else
        cameraNode.position = cameraBasePos
    end
end

-- 生成血液粒子
local function spawnBloodParticles(x, y, dirX, dirY, count)
    for i = 1, count do
        local angle = math.atan(dirY, dirX) + (math.random() - 0.5) * 2.5
        local speed = 80 + math.random() * 120
        local size = 2 + math.random() * 5
        local particle = {
            x = x + (math.random() - 0.5) * 6,
            y = y + (math.random() - 0.5) * 6,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed,
            life = 0.8 + math.random() * 0.6,
            maxLife = 0.8 + math.random() * 0.6,
            size = size,
            node = nil,
            gravity = 60 + math.random() * 40,
        }
        particle.maxLife = particle.life

        particle.node = gameNode:CreateChild("Blood")
        particle.node.position = Vector3(particle.x, particle.y, 0.5)
        particle.node.scale = Vector3(particle.size, particle.size, 1)
        -- 深红色 + 随机明暗
        local brightness = 0.5 + math.random() * 0.5
        local bloodMat = createColorMaterial(0.7 * brightness, 0.05 * brightness, 0.05 * brightness, 1.0)
        local model = particle.node:CreateComponent("StaticModel")
        model.model = cache:GetResource("Model", "Models/Box.mdl")
        model.material = bloodMat

        table.insert(bloodParticles, particle)
    end
end

-- 创建地面血迹（永久不消失）
local function spawnBloodStain(x, y)
    local size = 4 + math.random() * 8
    local stainNode = gameNode:CreateChild("Stain")
    stainNode.position = Vector3(x, y, BLOOD_STAIN_Z)
    -- 随机扁平/圆形
    local sx = size * (0.6 + math.random() * 0.8)
    local sy = size * (0.6 + math.random() * 0.8)
    stainNode.scale = Vector3(sx, sy, 1)
    stainNode.rotation = Quaternion(math.random() * 360, Vector3.FORWARD)

    local brightness = 0.3 + math.random() * 0.3
    local mat = createColorMaterial(0.5 * brightness, 0.02 * brightness, 0.02 * brightness, 0.8)
    local model = stainNode:CreateComponent("StaticModel")
    model.model = cache:GetResource("Model", "Models/Box.mdl")
    model.material = mat

    table.insert(bloodStains, stainNode)
end

-- 更新血液粒子
local function updateBloodParticles(dt)
    for i = #bloodParticles, 1, -1 do
        local p = bloodParticles[i]
        p.life = p.life - dt
        if p.life <= 0 then
            -- 粒子消亡时生成地面血迹
            if p.spawnsStain or math.random() < 0.4 then
                spawnBloodStain(p.x + (math.random() - 0.5) * 4, p.y + (math.random() - 0.5) * 4)
            end
            p.node:Remove()
            table.remove(bloodParticles, i)
        else
            -- 物理运动
            p.vy = p.vy - p.gravity * dt
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            -- 减速：有decel字段用加速度减速，否则用drag系数
            if p.decel then
                local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                if spd > 1 then
                    local reduction = p.decel * dt
                    local newSpd = math.max(0, spd - reduction)
                    local ratio = newSpd / spd
                    p.vx = p.vx * ratio
                    p.vy = p.vy * ratio
                else
                    p.vx, p.vy = 0, 0
                end
            else
                p.vx = p.vx * 0.96
                p.vy = p.vy * 0.96
            end

            p.node.position = Vector3(p.x, p.y, p.spawnsStain and 0.3 or 0.5)

            -- 缩小：前60%生命保持原大小，后40%逐渐缩小
            local t = p.life / p.maxLife  -- 1→0
            local scaleFactor
            if t > 0.4 then
                scaleFactor = 1.0
            else
                scaleFactor = t / 0.4
            end
            p.node.scale = Vector3(p.size * scaleFactor, p.size * scaleFactor, 1)

            -- 颜色：前50%不透明，后50%淡出
            local alpha = math.min(1.0, t * 2.0)
            local model = p.node:GetComponent("StaticModel")
            local brightness = 0.5 + 0.5 * t
            local mat = Material:new()
            mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            local r, g, b
            if p.spawnsStain then
                -- DEBUG: 血柱粒子用绿色
                r, g, b = 0.04 * brightness, 0.9 * brightness, 0.04 * brightness
            else
                r, g, b = 0.8 * brightness, 0.05 * brightness, 0.05 * brightness
            end
            mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, alpha)))
            model.material = mat
        end
    end
end

-- 创建肢体碎片（解体后飞出的部件）
-- dirX/dirY 为归一化方向（-1~1），函数内部计算速度
local function spawnDebris(x, y, w, h, mat, dirX, dirY, angularSpeed, showCrossSection)
    local speed = 120 + math.random() * 100
    local initAngle = math.random() * 360
    local piece = {
        x = x,
        y = y,
        vx = dirX * speed,
        vy = dirY * speed,
        angle = initAngle,
        angularVel = angularSpeed,
        life = 1.5 + math.random() * 0.8,
        maxLife = 1.5 + math.random() * 0.8,
        node = nil,
        gravity = 80,
        bleedTimer = 0,         -- 截面喷血计时
        bleedInterval = 0.05,   -- 每0.05秒喷一次
        hasCrossSection = showCrossSection or false,
        bleedAngle = initAngle, -- 喷血方向固定为创建时的角度
        bleedOffsetX = 0,       -- 断面相对碎片中心的局部偏移
        bleedOffsetY = h * 0.5, -- 断面在肢体顶部（连接处）
    }
    piece.maxLife = piece.life
    -- 默认血柱继承速度 = 创建时速度（外部可覆盖）
    piece.bleedVx = piece.vx
    piece.bleedVy = piece.vy

    piece.node = gameNode:CreateChild("Debris")
    piece.node.position = Vector3(x, y, 0.8)

    -- 肢体本体
    local limbNode = piece.node:CreateChild("")
    limbNode.scale = Vector3(w, h, 1)
    local model = limbNode:CreateComponent("StaticModel")
    model.model = cache:GetResource("Model", "Models/Box.mdl")
    model.material = mat

    -- 截面：在连接处显示红色截面（模拟断裂面）
    if showCrossSection then
        local sectionMat = createColorMaterial(0.6, 0.1, 0.1, 1.0)
        local sectionNode = piece.node:CreateChild("Section")
        -- 截面在肢体的顶部（连接处）
        sectionNode.position = Vector3(0, h * 0.5, -0.1)
        sectionNode.scale = Vector3(w * 0.9, 2, 1)
        local sModel = sectionNode:CreateComponent("StaticModel")
        sModel.model = cache:GetResource("Model", "Models/Box.mdl")
        sModel.material = sectionMat

        -- 内层（更亮的肉色）模拟骨骼/内部
        local innerMat = createColorMaterial(0.9, 0.6, 0.5, 1.0)
        local innerNode = piece.node:CreateChild("Inner")
        innerNode.position = Vector3(0, h * 0.5, -0.15)
        innerNode.scale = Vector3(w * 0.4, 1.5, 1)
        local iModel = innerNode:CreateComponent("StaticModel")
        iModel.model = cache:GetResource("Model", "Models/Box.mdl")
        iModel.material = innerMat
    end

    table.insert(debris, piece)
    return piece
end

-- 生成截面喷血粒子（血柱：高速射出、方向固定、散射<15度、无重力、逐渐减速变小）
local function spawnCrossSectionBlood(x, y, fixedAngle, debrisVx, debrisVy)
    -- 方向固定为初始法线方向，不随碎片旋转变化
    local rad = math.rad(fixedAngle + 90)
    local count = 2 + math.random(0, 3)  -- 每次2~5个粒子形成血柱
    debrisVx = debrisVx or 0
    debrisVy = debrisVy or 0
    for i = 1, count do
        -- 散射限制在±15度以内
        local scatter = (math.random() - 0.5) * math.rad(30)
        local a = rad + scatter
        local speed = 80 + math.random() * 100   -- 射出速度(80~180)
        local size = 4 + math.random() * 6       -- 粒子大小(4~10)
        local life = 0.8 + math.random() * 0.6   -- 寿命(0.8~1.4s)
        local particle = {
            x = x + (math.random() - 0.5) * 2,
            y = y + (math.random() - 0.5) * 2,
            vx = math.cos(a) * speed + debrisVx,  -- 继承碎片动量
            vy = math.sin(a) * speed + debrisVy,  -- 继承碎片动量
            life = life,
            maxLife = life,
            size = size,
            node = nil,
            gravity = 0,        -- 无重力，保持直线柱状轨迹
            decel = 40 + math.random() * 40,   -- 减速(40~80)，飞行距离≈40~200单位
            spawnsStain = true,  -- 截面粒子100%生成血迹
        }
        particle.maxLife = particle.life

        particle.node = gameNode:CreateChild("CBlood")
        particle.node.position = Vector3(particle.x, particle.y, 0.3)  -- z=0.3 在碎片(0.8)前面
        particle.node.scale = Vector3(particle.size, particle.size, 1)
        local brightness = 0.5 + math.random() * 0.5
        local bloodMat = createColorMaterial(0.04 * brightness, 0.9 * brightness, 0.04 * brightness, 1.0)  -- DEBUG: 绿色
        local model = particle.node:CreateComponent("StaticModel")
        model.model = cache:GetResource("Model", "Models/Box.mdl")
        model.material = bloodMat

        table.insert(bloodParticles, particle)
    end
end

-- 更新碎片运动
local function updateDebris(dt)
    for i = #debris, 1, -1 do
        local d = debris[i]
        d.life = d.life - dt
        if d.life <= 0 then
            d.node:Remove()
            table.remove(debris, i)
        else
            -- 物理运动
            d.vy = d.vy - d.gravity * dt
            d.x = d.x + d.vx * dt
            d.y = d.y + d.vy * dt
            d.angle = d.angle + d.angularVel * dt
            -- 减速
            d.vx = d.vx * 0.99
            d.vy = d.vy * 0.99

            d.node.position = Vector3(d.x, d.y, 0.8)
            d.node.rotation = Quaternion(d.angle, Vector3.FORWARD)

            -- 截面持续喷血：从断面位置喷出，方向固定
            if d.hasCrossSection and d.life > d.maxLife * 0.2 then
                d.bleedTimer = d.bleedTimer + dt
                if d.bleedTimer >= d.bleedInterval then
                    d.bleedTimer = d.bleedTimer - d.bleedInterval
                    -- 根据碎片当前旋转角度，将断面局部偏移转换为世界坐标
                    local angleRad = math.rad(d.angle)
                    local cosA = math.cos(angleRad)
                    local sinA = math.sin(angleRad)
                    local worldOffX = d.bleedOffsetX * cosA - d.bleedOffsetY * sinA
                    local worldOffY = d.bleedOffsetX * sinA + d.bleedOffsetY * cosA
                    local bleedX = d.x + worldOffX
                    local bleedY = d.y + worldOffY
                    spawnCrossSectionBlood(bleedX, bleedY, d.bleedAngle, d.bleedVx or 0, d.bleedVy or 0)
                    -- 碎片轨迹下方30%概率滴落血迹
                    if math.random() < 0.3 then
                        spawnBloodStain(bleedX + (math.random() - 0.5) * 10, bleedY + (math.random() - 0.5) * 10)
                    end
                end
            end

            -- 淡出
            if d.life < d.maxLife * 0.3 then
                -- 最后30%时间淡出
                local s = d.life / (d.maxLife * 0.3)
                d.node.scale = Vector3(s, s, s)
            end
        end
    end
end

-- 执行撞击效果（核心函数）
local function performHitEffect(child, car)
    local hitX = child.x
    local hitY = CHILD_Y

    -- 车辆运动方向作为主要飞散方向
    local carDirX = 0
    local carDirY = car.direction
    -- 加一点随机水平偏移
    local spreadX = (math.random() - 0.5) * 0.6

    -- 1. 触发停帧
    hitFreezeTimer = HIT_FREEZE_DURATION

    -- 2. 触发屏幕抖动
    triggerScreenShake()

    -- 3. 触发闪白
    triggerFlash()

    -- 4. 生成血液粒子（从撞击点喷射）
    spawnBloodParticles(hitX, hitY, spreadX + carDirX * 0.5, carDirY, 25)
    -- 连接处额外喷血
    spawnBloodParticles(hitX, hitY + 5, spreadX, carDirY * 0.8, 10)
    spawnBloodParticles(hitX, hitY - 8, spreadX, carDirY * 1.2, 8)

    -- 5. 随机选择解体的肢体（2~4个部件飞出）
    local detachCount = 2 + math.random(0, 2)
    local parts = {"head", "leftArm", "rightArm", "leftLeg", "rightLeg", "body"}
    -- 打乱顺序
    for k = #parts, 2, -1 do
        local j = math.random(1, k)
        parts[k], parts[j] = parts[j], parts[k]
    end

    local armMat = createColorMaterial(1.0, 0.85, 0.68, 1.0)
    local legMat = createColorMaterial(0.2, 0.25, 0.5, 1.0)
    local bodyMat = createColorMaterial(0.3, 0.5, 0.9, 1.0)
    local headMat = createColorMaterial(1.0, 0.87, 0.72, 1.0)

    for idx = 1, math.min(detachCount, #parts) do
        local part = parts[idx]
        local pw, ph, pmat, px, py
        local angSpeed = (300 + math.random() * 400) * (math.random() > 0.5 and 1 or -1)

        if part == "head" then
            pw, ph, pmat = 14, 14, headMat
            px, py = hitX, hitY + 14
        elseif part == "leftArm" then
            pw, ph, pmat = 5, 14, armMat
            px, py = hitX - 11, hitY + 5
        elseif part == "rightArm" then
            pw, ph, pmat = 5, 14, armMat
            px, py = hitX + 11, hitY + 5
        elseif part == "leftLeg" then
            pw, ph, pmat = 6, 13, legMat
            px, py = hitX - 4, hitY - 10
        elseif part == "rightLeg" then
            pw, ph, pmat = 6, 13, legMat
            px, py = hitX + 4, hitY - 10
        else -- body
            pw, ph, pmat = 16, 18, bodyMat
            px, py = hitX, hitY
        end

        -- 飞散方向：车辆方向 + 随机偏移（归一化值）
        local flyX = spreadX + (math.random() - 0.5) * 1.2
        local flyY = carDirY * (0.8 + math.random() * 0.6)

        local piece = spawnDebris(px, py, pw, ph, pmat, flyX, flyY, angSpeed, true)
        -- 碎片额外随机初速
        piece.vx = piece.vx + (math.random() - 0.5) * 40
        piece.vy = piece.vy + carDirY * 30
        -- 保存碎片初速度（固定值），血柱粒子继承此动量
        piece.bleedVx = piece.vx
        piece.bleedVy = piece.vy

        -- 每个断裂处喷出少量血
        spawnBloodParticles(px, py, flyX, flyY, 5)
    end
end

-- ======================== 小孩管理 ========================
local function createLimbPivot(parent, px, py, pz, boxOffsetY, boxW, boxH, mat)
    -- 创建枢轴节点（旋转中心在肩膀/胯部）
    local pivot = parent:CreateChild("")
    pivot.position = Vector3(px, py, pz)
    -- 肢体方块挂在枢轴下方，旋转时像钟摆
    local limb = pivot:CreateChild("")
    limb.position = Vector3(0, boxOffsetY, 0)
    limb.scale = Vector3(boxW, boxH, 1)
    local model = limb:CreateComponent("StaticModel")
    model.model = cache:GetResource("Model", "Models/Box.mdl")
    model.material = mat
    return pivot
end

local function createChildEntity()
    local child = {
        x = LEFT_EDGE / 2,
        manualRequest = "move",
        autoBlocked = false,
        node = nil,
        bodyNode = nil,
        headNode = nil,
        indicatorNode = nil,
        highlightNode = nil,
        -- 枢轴节点（用于旋转动画）
        leftArmPivot = nil,
        rightArmPivot = nil,
        leftLegPivot = nil,
        rightLegPivot = nil,
        -- 动画计时器
        animTime = math.random() * 6.28,
    }

    child.node = gameNode:CreateChild("Child")
    child.node.position = Vector3(child.x, CHILD_Y, 2)

    -- 身体（蓝色=移动中，略窄的躯干）
    local bodyMat = createColorMaterial(0.3, 0.5, 0.9, 1.0)
    child.bodyNode = createBox(child.node, 0, 0, 16, 18, bodyMat, 0)

    -- 头（肤色圆脸）
    local headMat = createColorMaterial(1.0, 0.87, 0.72, 1.0)
    child.headNode = createBox(child.node, 0, 14, 14, 14, headMat, -0.1)

    -- 头发（深棕色）
    local hairMat = createColorMaterial(0.3, 0.2, 0.1, 1.0)
    createBox(child.node, 0, 19, 15, 5, hairMat, -0.2)

    -- 四肢用枢轴结构：pivot在肩膀/胯部，limb向下偏移
    local armMat = createColorMaterial(1.0, 0.85, 0.68, 1.0)
    local legMat = createColorMaterial(0.2, 0.25, 0.5, 1.0)

    -- 左臂 pivot 在左肩 (-10, 6)，手臂向下延伸
    child.leftArmPivot = createLimbPivot(child.node, -11, 5, -0.05, -8, 5, 14, armMat)
    -- 右臂 pivot 在右肩 (10, 6)
    child.rightArmPivot = createLimbPivot(child.node, 11, 5, -0.05, -8, 5, 14, armMat)

    -- 左腿 pivot 在左胯 (-4, -9)，腿向下延伸
    child.leftLegPivot = createLimbPivot(child.node, -4, -10, -0.05, -7, 6, 13, legMat)
    -- 右腿 pivot 在右胯 (4, -9)
    child.rightLegPivot = createLimbPivot(child.node, 4, -10, -0.05, -7, 6, 13, legMat)

    -- 状态指示器（头顶）
    local indMat = createColorMaterial(0.2, 0.9, 0.2, 1.0)
    child.indicatorNode = createBox(child.node, 0, 25, 8, 8, indMat, -0.2)

    -- 高亮框（金色）
    local hlMat = createColorMaterial(1.0, 0.84, 0.0, 0.7)
    child.highlightNode = createBox(child.node, 0, 0, 34, 55, hlMat, 0.1)
    child.highlightNode.enabled = false

    return child
end

local function spawnChild()
    if #children >= MAX_CHILDREN then return end
    local child = createChildEntity()
    table.insert(children, child)
end

local function removeChild(idx)
    local child = children[idx]
    if child.node then
        child.node:Remove()
    end
    table.remove(children, idx)
end

local function getEffectiveState(child)
    if child.manualRequest == "stop" then return "stop" end
    if child.autoBlocked then return "stop" end
    return "move"
end

-- ======================== 自动阻挡逻辑 ========================
local function updateAutoBlocking()
    local sorted = {}
    for i = 1, #children do
        sorted[i] = i
    end
    table.sort(sorted, function(a, b)
        return children[a].x > children[b].x
    end)

    -- 多次迭代确保递归传播
    for pass = 1, #sorted do
        for _, i in ipairs(sorted) do
            local child = children[i]

            local frontChild = nil
            local minDist = math.huge
            for j = 1, #children do
                if j ~= i then
                    local other = children[j]
                    local dist = other.x - child.x
                    if dist > 0 and dist < minDist then
                        minDist = dist
                        frontChild = other
                    end
                end
            end

            if frontChild then
                local frontState = getEffectiveState(frontChild)
                if frontState == "stop" and minDist < STOP_DISTANCE then
                    child.autoBlocked = true
                elseif minDist >= RESUME_DISTANCE then
                    child.autoBlocked = false
                elseif frontState == "move" then
                    child.autoBlocked = false
                end
            else
                child.autoBlocked = false
            end
        end
    end
end

-- ======================== 车辆管理 ========================
local function getCarSpeed()
    local progress = 1 - (timeLeft / GAME_DURATION)
    return CAR_BASE_SPEED + (CAR_MAX_SPEED - CAR_BASE_SPEED) * progress
end

local function getCarInterval()
    local progress = 1 - (timeLeft / GAME_DURATION)
    return CAR_BASE_INTERVAL - (CAR_BASE_INTERVAL - CAR_MIN_INTERVAL) * progress
end

local function createCar(laneIndex)
    local dir = getLaneDirection(laneIndex)
    local speed = getCarSpeed() * (0.8 + math.random() * 0.4)

    local car = {
        x = LANE_X[laneIndex],
        y = 0,
        width = 32,
        height = 55,
        lane = laneIndex,
        direction = dir,
        speed = speed,
        node = nil,
    }

    if dir == 1 then
        car.y = -WORLD_H / 2 - 60
    else
        car.y = WORLD_H / 2 + 60
    end

    car.node = gameNode:CreateChild("Car")
    car.node.position = Vector3(car.x, car.y, 3)

    -- 车身（随机红色系）
    local r = 0.6 + math.random() * 0.4
    local g = math.random() * 0.3
    local b = math.random() * 0.3
    local carMat = createColorMaterial(r, g, b, 1.0)
    createBox(car.node, 0, 0, car.width, car.height, carMat, 0)

    -- 车窗（浅蓝）
    local winMat = createColorMaterial(0.6, 0.8, 1.0, 0.8)
    createBox(car.node, 0, -dir * 8, car.width * 0.7, car.height * 0.2, winMat, -0.1)

    -- 车灯（黄色）
    local lightMat = createColorMaterial(1.0, 1.0, 0.4, 1.0)
    local headY = dir * car.height * 0.4
    createBox(car.node, -car.width * 0.3, headY, 5, 5, lightMat, -0.1)
    createBox(car.node, car.width * 0.3, headY, 5, 5, lightMat, -0.1)

    return car
end

-- ======================== UI 创建 ========================
local function createUI()
    local uiStyle = cache:GetResource("XMLFile", "UI/DefaultStyle.xml")
    ui.root.defaultStyle = uiStyle

    -- 分数
    scoreText = ui.root:CreateChild("Text")
    scoreText:SetFont(cache:GetResource("Font", "Fonts/MiSans-Regular.ttf"), 22)
    scoreText:SetAlignment(HA_LEFT, VA_TOP)
    scoreText:SetPosition(20, 15)
    scoreText.color = Color(1, 1, 1, 1)
    scoreText.text = "分数: 0"

    -- 倒计时
    timeText = ui.root:CreateChild("Text")
    timeText:SetFont(cache:GetResource("Font", "Fonts/MiSans-Regular.ttf"), 26)
    timeText:SetAlignment(HA_CENTER, VA_TOP)
    timeText:SetPosition(0, 15)
    timeText.color = Color(1, 1, 0.4, 1)
    timeText.text = "时间: 60s"

    -- 操作说明
    instructionText = ui.root:CreateChild("Text")
    instructionText:SetFont(cache:GetResource("Font", "Fonts/MiSans-Regular.ttf"), 16)
    instructionText:SetAlignment(HA_CENTER, VA_BOTTOM)
    instructionText:SetPosition(0, -15)
    instructionText.color = Color(0.8, 0.8, 0.8, 1)
    instructionText.text = "← → / A D 移动警卫 | 对准小孩后按空格切换 移动/停止"

    -- 游戏结束面板
    gameOverPanel = ui.root:CreateChild("BorderImage")
    gameOverPanel:SetAlignment(HA_CENTER, VA_CENTER)
    gameOverPanel:SetSize(400, 250)
    gameOverPanel:SetColor(Color(0, 0, 0, 0.85))
    gameOverPanel.visible = false

    gameOverText = gameOverPanel:CreateChild("Text")
    gameOverText:SetFont(cache:GetResource("Font", "Fonts/MiSans-Regular.ttf"), 36)
    gameOverText:SetAlignment(HA_CENTER, VA_TOP)
    gameOverText:SetPosition(0, 30)
    gameOverText.color = Color(1, 0.3, 0.3, 1)
    gameOverText.text = "时间到!"

    finalScoreText = gameOverPanel:CreateChild("Text")
    finalScoreText:SetFont(cache:GetResource("Font", "Fonts/MiSans-Regular.ttf"), 28)
    finalScoreText:SetAlignment(HA_CENTER, VA_CENTER)
    finalScoreText:SetPosition(0, -10)
    finalScoreText.color = Color(1, 1, 1, 1)
    finalScoreText.text = "最终得分: 0"

    restartText = gameOverPanel:CreateChild("Text")
    restartText:SetFont(cache:GetResource("Font", "Fonts/MiSans-Regular.ttf"), 20)
    restartText:SetAlignment(HA_CENTER, VA_BOTTOM)
    restartText:SetPosition(0, -30)
    restartText.color = Color(0.7, 0.7, 0.7, 1)
    restartText.text = "按 R 键重新开始"
end

-- ======================== 游戏重置 ========================
local function resetGame()
    for i = #children, 1, -1 do
        if children[i].node then children[i].node:Remove() end
    end
    children = {}

    for i = #cars, 1, -1 do
        if cars[i].node then cars[i].node:Remove() end
    end
    cars = {}

    -- 清理特效残留
    for i = #debris, 1, -1 do
        if debris[i].node then debris[i].node:Remove() end
    end
    debris = {}
    for i = #bloodParticles, 1, -1 do
        if bloodParticles[i].node then bloodParticles[i].node:Remove() end
    end
    bloodParticles = {}
    for i = #bloodStains, 1, -1 do
        if bloodStains[i] then bloodStains[i]:Remove() end
    end
    bloodStains = {}
    hitFreezeTimer = 0
    screenShakeTimer = 0
    flashAlpha = 0
    if flashNode then flashNode.enabled = false end
    if cameraBasePos then cameraNode.position = cameraBasePos end

    score = 0
    timeLeft = GAME_DURATION
    gameOver = false
    guardX = WORLD_W / 2
    highlightedIdx = nil
    spawnTimer = 0
    spaceWasDown = false

    carLaneTimers = {}
    for i = 1, LANE_COUNT do
        carLaneTimers[i] = math.random() * CAR_BASE_INTERVAL
    end

    if guardNode then
        guardNode.position = Vector3(guardX, GUARD_Y, 1)
    end

    if gameOverPanel then gameOverPanel.visible = false end
    if scoreText then scoreText.text = "分数: 0" end
    if timeText then
        timeText.text = "时间: 60s"
        timeText.color = Color(1, 1, 0.4, 1)
    end
end

-- ======================== 游戏主更新 ========================
local function updateGame(dt)
    -- 特效始终更新（即使停帧/游戏结束时也要播放）
    updateBloodParticles(dt)
    updateDebris(dt)
    updateFlash(dt)
    updateScreenShake(dt)

    if gameOver then
        if input:GetKeyDown(KEY_R) then
            resetGame()
        end
        return
    end

    -- 停帧：撞击瞬间短暂冻结游戏逻辑
    if hitFreezeTimer > 0 then
        hitFreezeTimer = hitFreezeTimer - dt
        return  -- 冻结所有游戏逻辑，但特效继续播放
    end

    -- 倒计时
    timeLeft = timeLeft - dt
    if timeLeft <= 0 then
        timeLeft = 0
        gameOver = true
        gameOverPanel.visible = true
        finalScoreText.text = "最终得分: " .. score
        return
    end

    -- UI更新
    timeText.text = "时间: " .. math.ceil(timeLeft) .. "s"
    if timeLeft < 15 then
        timeText.color = Color(1, 0.3 + 0.7 * (timeLeft / 15), 0.2, 1)
    end
    scoreText.text = "分数: " .. score

    -- 警卫移动
    if input:GetKeyDown(KEY_LEFT) or input:GetKeyDown(KEY_A) then
        guardX = guardX - GUARD_SPEED * dt
    end
    if input:GetKeyDown(KEY_RIGHT) or input:GetKeyDown(KEY_D) then
        guardX = guardX + GUARD_SPEED * dt
    end
    guardX = math.max(30, math.min(WORLD_W - 30, guardX))
    guardNode.position = Vector3(guardX, GUARD_Y, 1)

    -- 高亮逻辑
    highlightedIdx = nil
    local minDist = HIGHLIGHT_THRESHOLD
    for i, child in ipairs(children) do
        local dist = math.abs(guardX - child.x)
        if dist < minDist then
            minDist = dist
            highlightedIdx = i
        end
    end

    guardHighlightNode.enabled = (highlightedIdx ~= nil)

    -- 空格键切换
    local spaceDown = input:GetKeyDown(KEY_SPACE)
    if spaceDown and not spaceWasDown then
        if highlightedIdx and children[highlightedIdx] then
            local child = children[highlightedIdx]
            if child.manualRequest == "move" then
                child.manualRequest = "stop"
            else
                child.manualRequest = "move"
            end
        end
    end
    spaceWasDown = spaceDown

    -- 小孩入场
    if #children < MAX_CHILDREN then
        spawnTimer = spawnTimer + dt
        if spawnTimer >= SPAWN_INTERVAL then
            spawnTimer = 0
            spawnChild()
        end
    end

    -- 自动阻挡
    updateAutoBlocking()

    -- 移动小孩并更新视觉
    for i = #children, 1, -1 do
        local child = children[i]
        local state = getEffectiveState(child)

        if state == "move" then
            child.x = child.x + CHILD_SPEED * dt
        end

        -- 更新动画计时器
        child.animTime = child.animTime + dt

        child.node.position = Vector3(child.x, CHILD_Y, 2)

        -- 身体颜色
        local bodyModel = child.bodyNode:GetComponent("StaticModel")
        if state == "stop" then
            bodyModel.material = createColorMaterial(0.9, 0.55, 0.2, 1.0)
        else
            bodyModel.material = createColorMaterial(0.3, 0.5, 0.9, 1.0)
        end

        -- 四肢旋转动画
        if state == "move" then
            -- 行走：四肢绕枢轴(Z轴)交替摆动，像钟摆
            local walkFreq = 9.0
            local armAngle = math.sin(child.animTime * walkFreq) * 35  -- 手臂摆幅±35°
            local legAngle = math.sin(child.animTime * walkFreq) * 28  -- 腿摆幅±28°

            -- 左右手臂反向摆
            child.leftArmPivot.rotation = Quaternion(armAngle, Vector3.FORWARD)
            child.rightArmPivot.rotation = Quaternion(-armAngle, Vector3.FORWARD)

            -- 腿与手臂反向（自然步态）
            child.leftLegPivot.rotation = Quaternion(-legAngle, Vector3.FORWARD)
            child.rightLegPivot.rotation = Quaternion(legAngle, Vector3.FORWARD)

            -- 身体轻微前倾+弹跳
            local bounce = math.abs(math.sin(child.animTime * walkFreq)) * 1.2
            child.bodyNode.position = Vector3(0, bounce, 0)
            child.headNode.position = Vector3(0, 14 + bounce, -0.1)
            -- 身体轻微左右摇摆
            local sway = math.sin(child.animTime * walkFreq * 0.5) * 3
            child.bodyNode.rotation = Quaternion(sway, Vector3.FORWARD)
        else
            -- Idle：缓慢呼吸感+轻微摇摆
            local idleFreq = 2.5
            local breathe = math.sin(child.animTime * idleFreq)

            -- 身体微微上下+轻微倾斜
            child.bodyNode.position = Vector3(0, breathe * 0.8, 0)
            child.headNode.position = Vector3(0, 14 + breathe * 0.8, -0.1)
            child.bodyNode.rotation = Quaternion(math.sin(child.animTime * 1.2) * 2, Vector3.FORWARD)

            -- 手臂自然下垂，轻微晃动
            local armIdle = math.sin(child.animTime * 1.5) * 5
            child.leftArmPivot.rotation = Quaternion(armIdle, Vector3.FORWARD)
            child.rightArmPivot.rotation = Quaternion(-armIdle * 0.7, Vector3.FORWARD)

            -- 腿静止
            child.leftLegPivot.rotation = Quaternion(0, Vector3.FORWARD)
            child.rightLegPivot.rotation = Quaternion(0, Vector3.FORWARD)
        end

        -- 指示器颜色
        local indModel = child.indicatorNode:GetComponent("StaticModel")
        if child.manualRequest == "stop" then
            indModel.material = createColorMaterial(1.0, 0.2, 0.2, 1.0)
        else
            indModel.material = createColorMaterial(0.2, 0.9, 0.2, 1.0)
        end

        -- 高亮
        child.highlightNode.enabled = (i == highlightedIdx)

        -- 到达安全区
        if child.x >= RIGHT_EDGE then
            score = score + 10
            removeChild(i)
            spawnChild()
        end
    end

    -- 车辆生成
    local interval = getCarInterval()
    for i = 1, LANE_COUNT do
        carLaneTimers[i] = carLaneTimers[i] - dt
        if carLaneTimers[i] <= 0 then
            carLaneTimers[i] = interval * (0.7 + math.random() * 0.6)
            local car = createCar(i)
            table.insert(cars, car)
        end
    end

    -- 移动车辆
    for i = #cars, 1, -1 do
        local car = cars[i]
        car.y = car.y + car.direction * car.speed * dt
        car.node.position = Vector3(car.x, car.y, 3)

        if car.y > WORLD_H / 2 + 100 or car.y < -WORLD_H / 2 - 100 then
            car.node:Remove()
            table.remove(cars, i)
        end
    end

    -- 碰撞检测
    for ci = #children, 1, -1 do
        local child = children[ci]
        local cx1 = child.x - 10
        local cy1 = CHILD_Y - 15
        local cx2 = child.x + 10
        local cy2 = CHILD_Y + 15

        for _, car in ipairs(cars) do
            local ax1 = car.x - car.width / 2
            local ay1 = car.y - car.height / 2
            local ax2 = car.x + car.width / 2
            local ay2 = car.y + car.height / 2

            if cx1 < ax2 and cx2 > ax1 and cy1 < ay2 and cy2 > ay1 then
                -- 触发撞击特效
                performHitEffect(child, car)
                removeChild(ci)
                spawnChild()
                break
            end
        end
    end
end

-- ======================== 引擎入口 ========================
function Start()
    math.randomseed(os.time())

    initLayout()

    for i = 1, LANE_COUNT do
        carLaneTimers[i] = math.random() * CAR_BASE_INTERVAL
    end

    createScene()
    createGuardNode()
    createFlashOverlay()
    createUI()

    -- 记录相机原始位置（用于屏幕抖动）
    cameraBasePos = Vector3(cameraNode.position)

    SubscribeToEvent("Update", "HandleUpdate")
end

function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    updateGame(dt)
end
