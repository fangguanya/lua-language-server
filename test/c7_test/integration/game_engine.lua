-- test/c7_test/integration/game_engine.lua
-- 游戏引擎模块

local GameEngine = DefineClass("GameEngine", {
    sessions = {},
    userManager = nil,
    sessionCount = 0,
    totalScore = 0
})

-- 游戏会话类
local GameSession = DefineClass("GameSession", {
    id = nil,
    userId = nil,
    score = 0,
    startTime = nil,
    isActive = true
})

function GameSession:__init(id, userId)
    self.id = id
    self.userId = userId
    self.startTime = os.time()
    self.score = 0
    print(string.format("🎮 创建游戏会话: %s (用户: %s)", id, userId))
end

function GameSession:UpdateScore(points)
    self.score = self.score + points
    print(string.format("⭐ 会话 %s 得分更新: +%d (总分: %d)", self.id, points, self.score))
    return self.score
end

function GameSession:EndSession()
    self.isActive = false
    local duration = os.time() - self.startTime
    print(string.format("🏁 会话 %s 结束，持续时间: %d秒，最终得分: %d", self.id, duration, self.score))
    return {
        score = self.score,
        duration = duration,
        userId = self.userId
    }
end

-- GameEngine 方法实现
function GameEngine:__init()
    self.sessions = {}
    self.sessionCount = 0
    self.totalScore = 0
    print("🎮 游戏引擎初始化完成")
end

function GameEngine:SetUserManager(userManager)
    self.userManager = userManager
    print("🔗 游戏引擎已连接到用户管理器")
end

function GameEngine:OnUserCreated(user)
    print(string.format("📢 游戏引擎收到用户创建通知: %s", user.name))
    -- 可以在这里做一些初始化工作
end

function GameEngine:CreateGameSession(userId)
    self.sessionCount = self.sessionCount + 1
    local sessionId = "session_" .. self.sessionCount
    
    local session = GameSession.new(sessionId, userId)
    self.sessions[sessionId] = session
    
    return {
        sessionId = sessionId,
        userId = userId,
        startTime = session.startTime
    }
end

function GameEngine:GetUserSession(userId)
    for _, session in pairs(self.sessions) do
        if session.userId == userId and session.isActive then
            return session
        end
    end
    return nil
end

function GameEngine:OnUserLogin(userData)
    print(string.format("🔐 游戏引擎处理用户登录: %s", userData.name))
    
    -- 为用户创建新的游戏会话
    local gameData = self:CreateGameSession(userData.id)
    
    -- 给新用户一些初始奖励
    local session = self.sessions[gameData.sessionId]
    if session then
        session:UpdateScore(10) -- 登录奖励
    end
    
    return gameData
end

function GameEngine:ProcessGameLogic()
    print("⚙️ 处理游戏逻辑...")
    
    local activeSessionCount = 0
    local totalActiveScore = 0
    
    for _, session in pairs(self.sessions) do
        if session.isActive then
            activeSessionCount = activeSessionCount + 1
            totalActiveScore = totalActiveScore + session.score
            
            -- 模拟游戏逻辑：随机给活跃会话加分
            if math.random() > 0.5 then
                session:UpdateScore(math.random(1, 10))
            end
        end
    end
    
    print(string.format("📊 活跃会话: %d, 总活跃得分: %d", activeSessionCount, totalActiveScore))
    return {
        activeSessionCount = activeSessionCount,
        totalActiveScore = totalActiveScore
    }
end

function GameEngine:GetGameStats()
    local stats = {
        totalSessions = self.sessionCount,
        activeSessions = 0,
        totalScore = 0,
        averageScore = 0
    }
    
    for _, session in pairs(self.sessions) do
        stats.totalScore = stats.totalScore + session.score
        if session.isActive then
            stats.activeSessions = stats.activeSessions + 1
        end
    end
    
    if self.sessionCount > 0 then
        stats.averageScore = stats.totalScore / self.sessionCount
    end
    
    return stats
end

function GameEngine:EndAllSessions()
    local results = {}
    for sessionId, session in pairs(self.sessions) do
        if session.isActive then
            local result = session:EndSession()
            table.insert(results, result)
        end
    end
    return results
end

return GameEngine 