-- 测试增强的require和类定义功能

-- 测试kg_require
local player_module = kg_require("logic.player")
local weapon_module = require("logic.weapon")

-- 测试多种类定义方式
local BaseEntity = DefineClass("BaseEntity")
local GameObject = CreateClass("GameObject", "BaseEntity") -- 继承BaseEntity
local Player = DefineEntity("Player", "GameObject", "BaseEntity") -- 多重继承
local Enemy = DefineBriefEntity("Enemy", "GameObject")
local Item = DefineLocalEntity("Item", "BaseEntity")
local Weapon = DefineComponent("Weapon", "Item")
local GameManager = DefineSingletonClass("GameManager", "BaseEntity")

-- 测试构造函数调用
local player1 = Player:new()
local enemy1 = Enemy:new()
local weapon1 = Weapon:new()
local manager = GameManager:new()

-- 测试方法调用
player1:move(10, 20)
enemy1:attack(player1)
weapon1:upgrade()
manager:initialize()

-- 测试别名
local PlayerAlias = Player
local player2 = PlayerAlias:new()
player2:jump() 