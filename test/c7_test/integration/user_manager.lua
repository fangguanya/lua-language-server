-- test/c7_test/integration/user_manager.lua
-- 用户管理模块

local UserManager = DefineClass("UserManager", {
    users = {},
    gameEngine = nil,
    userCount = 0
})

-- 用户类定义
local User = DefineClass("User", {
    id = nil,
    name = nil,
    email = nil,
    level = 1,
    experience = 0,
    createdAt = nil
})

function User:__init(id, name, email)
    self.id = id
    self.name = name
    self.email = email
    self.createdAt = os.time()
    print(string.format("👤 创建用户: %s (%s)", name, email))
end

function User:AddExperience(amount)
    self.experience = self.experience + amount
    local newLevel = math.floor(self.experience / 100) + 1
    if newLevel > self.level then
        self.level = newLevel
        print(string.format("🎉 用户 %s 升级到 %d 级!", self.name, self.level))
    end
end

function User:GetInfo()
    return {
        id = self.id,
        name = self.name,
        level = self.level,
        experience = self.experience
    }
end

-- UserManager 方法实现
function UserManager:__init()
    self.users = {}
    self.userCount = 0
    print("📋 用户管理器初始化完成")
end

function UserManager:SetGameEngine(gameEngine)
    self.gameEngine = gameEngine
    print("🔗 用户管理器已连接到游戏引擎")
end

function UserManager:CreateUser(name, email)
    self.userCount = self.userCount + 1
    local userId = "user_" .. self.userCount
    
    local user = User.new(userId, name, email)
    self.users[userId] = user
    
    -- 通知游戏引擎
    if self.gameEngine then
        self.gameEngine:OnUserCreated(user)
    end
    
    return user
end

function UserManager:GetUser(identifier)
    -- 支持通过ID或名称查找用户
    if self.users[identifier] then
        return self.users[identifier]
    end
    
    for _, user in pairs(self.users) do
        if user.name == identifier then
            return user
        end
    end
    
    return nil
end

function UserManager:HandleGameEvent(gameData)
    if gameData.userId then
        local user = self.users[gameData.userId]
        if user and gameData.experience then
            user:AddExperience(gameData.experience)
        end
    end
end

function UserManager:GetUserStats()
    local stats = {
        totalUsers = self.userCount,
        totalExperience = 0,
        averageLevel = 0,
        activeUsers = 0
    }
    
    for _, user in pairs(self.users) do
        stats.totalExperience = stats.totalExperience + user.experience
        stats.averageLevel = stats.averageLevel + user.level
        stats.activeUsers = stats.activeUsers + 1
    end
    
    if stats.activeUsers > 0 then
        stats.averageLevel = stats.averageLevel / stats.activeUsers
    end
    
    return stats
end

function UserManager:GetAllUsers()
    local userList = {}
    for _, user in pairs(self.users) do
        table.insert(userList, user:GetInfo())
    end
    return userList
end

return UserManager 