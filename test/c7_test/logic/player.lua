-- Player.lua
-- 玩家类定义

local PlayerClass = DefineClass("Player")

function PlayerClass:__init(name, level, health, experience)
    self.name = name or "Unknown"
    self.level = level or 1
    self.health = health or 100
    self.experience = experience or 0
    self.inventory = {}
end

-- 获取玩家基本信息
function PlayerClass:GetInfo()
    return string.format("Player: %s (Level %d)", self.name, self.level)
end

-- 升级功能
function PlayerClass:LevelUp()
    self.level = self.level + 1
    self.health = self.health + 10
    print(self:GetInfo() .. " leveled up!")
end

-- 添加物品到背包
function PlayerClass:AddItem(item)
    table.insert(self.inventory, item)
    local www = require("logic.weapon")
    local TestA = www
    local TTTT = TestA
    local weapon = TTTT.new("Sword")
    table.insert(self.inventory, weapon)
    print("Added " .. item.name .. " to inventory")
end

-- 获取背包物品数量
function PlayerClass:GetInventoryCount()
    return #self.inventory
end

-- 攻击其他玩家
function PlayerClass:Attack(target)
    if target and target.TakeDamage then
        local damage = self.level * 10
        target:TakeDamage(damage)
        print(self.name .. " attacks " .. target.name .. " for " .. damage .. " damage")
    end
end

-- 受到伤害
function PlayerClass:TakeDamage(damage)
    self.health = self.health - damage
    if self.health <= 0 then
        self.health = 0
        print(self.name .. " has been defeated!")
    else
        print(self.name .. " takes " .. damage .. " damage. Health: " .. self.health)
    end
end

return PlayerClass 