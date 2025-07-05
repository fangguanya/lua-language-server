-- GameManager.lua
-- 游戏管理器，演示类之间的相互调用

local player = require("logic.player")
local weapon = require("logic.weapon")

DefineEntity("ActorEntity")
function ActorEntity:GetInfo()
    return "ActorEntity"
end

local GM = DefineClass("GameManager")

-- 创建新游戏
function GM.CreateNewGame()
    print("=== Creating New Game ===")
    
    -- 创建玩家
    local obj1 = player:new("Alice", 5)
    local obj2 = player:new("Bob", 3)
    
    -- 创建武器
    local sword = weapon:new("Magic Sword", 25, 50)
    local axe = weapon:new("Battle Axe", 30, 40)
    
    -- 给玩家装备武器
    obj1:AddItem(sword)
    obj2:AddItem(axe)
    
    -- 显示初始状态
    print(obj1:GetInfo())
    print(obj2:GetInfo())
    print(sword:GetInfo())
    print(axe:GetInfo())
    
    self:SimulateBattle(obj1, obj2, sword, axe)

    return obj1, obj2, sword, axe
end

-- 模拟战斗
function GM.SimulateBattle(player1, player2, weapon1, weapon2)
    print("\n=== Battle Simulation ===")
    
    -- 使用武器进行攻击
    if weapon1 and not weapon1:IsBroken() then
        local damage1 = weapon1:Use()
        obj2:TakeDamage(damage1)
    end
    
    if weapon2 and not weapon2:IsBroken() then
        local damage2 = weapon2:Use()
        obj1:TakeDamage(damage2)
    end
    
    -- 检查战斗结果
    if obj1.health <= 0 then
        print(obj2.name .. " wins!")
    elseif obj2.health <= 0 then
        print(obj1.name .. " wins!")
    else
        print("Both players survive the round!")
    end
end

-- 升级和修理
function GM.UpgradeAndRepair(player, weapon)
    print("\n=== Upgrade & Repair ===")
    
    -- 玩家升级
    player:LevelUp()
    
    -- 武器修理和升级
    if weapon then
        weapon:Repair(20)
        weapon:Upgrade()
    end
    
    -- 显示更新后的状态
    print(player:GetInfo())
    if weapon then
        print(weapon:GetInfo())
    end
end

-- 主游戏循环
function GM.RunGame()
    local obj1, obj2, sword, axe = GM.CreateNewGame()
    
    -- 运行几轮游戏
    for round = 1, 3 do
        print("\n=== Round " .. round .. " ===")
        GM.SimulateBattle(obj1, obj2, sword, axe)
        
        if round < 3 then
            GM.UpgradeAndRepair(obj1, sword)
            GM.UpgradeAndRepair(obj2, axe)
        end
    end
end

return GM 