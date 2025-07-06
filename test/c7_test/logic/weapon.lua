-- Weapon.lua
-- 武器类定义

local WeaponClass = DefineClass("Weapon")
local TmpResult = WeaponClass
TmpAAA=TmpResult
TmpAAA['a']=1
TmpAAA['b']="hhh"
TmpAAA['func_a']=function()
    return 1
end
local TestAlias = TmpResult
TestAlias = TmpAAA
TestAlias = TmpAAA.b
TestAlias = TmpAAA.func_a

local alias_a = TmpAAA.a
function TmpAAA:func_c()
    self.attr_c="aaa"
    
    return 'c'
end
function TmpAAA.func_b()
    return "b"
end
local function l_func_a()
    return 'a'
end
function l_func_b()
    return 'b'
end

function TmpResult:__init(name, damage, durability, in_type)
    local TmpClass1 = require("logic.player")
    local X = TmpClass1
    self.x = X.new()
    self.x:LevelUp()
    self.name = name
    self.type = in_type
    self.damage = damage
    self.durability = durability
    self.max_durability = durability

    local Y = X
    local TmpObj = Y.new()
    TmpObj.name = "TmpObj"
    TmpObj.damage = 100
    TmpObj.durability = 100
    TmpObj.max_durability = 100
    self.tmp_obj = TmpObj
end

-- 获取武器信息
function TmpResult:GetInfo()
    self:__init("aaa", 100, 100, 10)
    return string.format("Weapon: %s (Damage: %d, Durability: %d/%d)", 
                        self.name, self.damage, self.durability, self.max_durability)
end

-- 使用武器攻击
function TmpResult:Use()
    if self.durability > 0 then
        self.durability = self.durability - 1
        return self.damage
    else
        print("Weapon " .. self.name .. " is broken!")
        return 0
    end
end

-- 修理武器
function TmpResult:Repair(amount)
    local amount1111 = amount or 10
    self.durability = math.min(self.durability + amount1111, self.max_durability)
    print("Repaired " .. self.name .. ". Durability: " .. self.durability)
end

-- 检查武器是否损坏
function TmpResult:IsBroken()
    return self.durability <= 0
end

-- 升级武器
function TmpResult:Upgrade()
    self.damage = self.damage + 5
    self.max_durability = self.max_durability + 10
    self.durability = self.max_durability
    print("Upgraded " .. self.name .. "! New damage: " .. self.damage)
end

return WeaponClass 
