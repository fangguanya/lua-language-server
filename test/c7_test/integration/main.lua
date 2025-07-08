-- test/c7_test/integration/main.lua
-- 多重集成测试主入口

-- 引入各个模块
local UserManager = require("integration.user_manager")
local GameEngine = require("integration.game_engine")
local DataProcessor = require("integration.data_processor")
local EventSystem = require("integration.event_system")

-- 创建全局游戏实例
local Game = DefineClass("Game", {
    userManager = nil,
    gameEngine = nil,
    dataProcessor = nil,
    eventSystem = nil,
    isRunning = false
})

function Game:Initialize()
    print("🎮 初始化游戏系统...")
    
    -- 初始化各个子系统
    self.userManager = UserManager.new()
    self.gameEngine = GameEngine.new()
    self.dataProcessor = DataProcessor.new()
    self.eventSystem = EventSystem.new()
    
    -- 建立系统间的连接
    self:ConnectSystems()
    
    self.isRunning = true
    print("✅ 游戏系统初始化完成")
end

function Game:ConnectSystems()
    -- 用户管理器与游戏引擎的连接
    self.userManager:SetGameEngine(self.gameEngine)
    self.gameEngine:SetUserManager(self.userManager)
    
    -- 数据处理器与其他系统的连接
    self.dataProcessor:RegisterSystem("user", self.userManager)
    self.dataProcessor:RegisterSystem("game", self.gameEngine)
    
    -- 事件系统连接所有模块
    self.eventSystem:Subscribe("user_login", function(data)
        self.gameEngine:OnUserLogin(data)
        self.dataProcessor:ProcessUserData(data)
    end)
    
    self.eventSystem:Subscribe("game_event", function(data)
        self.userManager:HandleGameEvent(data)
        self.dataProcessor:ProcessGameData(data)
    end)
end

function Game:Run()
    if not self.isRunning then
        self:Initialize()
    end
    
    print("🚀 开始运行集成测试...")
    
    -- 模拟用户登录
    local user = self.userManager:CreateUser("TestPlayer", "test@example.com")
    self.eventSystem:Emit("user_login", user)
    
    -- 模拟游戏事件
    local gameData = self.gameEngine:CreateGameSession(user.id)
    self.eventSystem:Emit("game_event", gameData)
    
    -- 数据处理和分析
    local report = self.dataProcessor:GenerateReport()
    print("📊 集成测试报告:", report.summary)
    
    -- 系统间交互测试
    self:TestSystemInteractions()
    
    print("✅ 集成测试完成")
end

function Game:TestSystemInteractions()
    print("🔄 测试系统间交互...")
    
    -- 测试用户管理器与游戏引擎的交互
    local user = self.userManager:GetUser("TestPlayer")
    if user then
        local session = self.gameEngine:GetUserSession(user.id)
        if session then
            session:UpdateScore(100)
            user:AddExperience(50)
        end
    end
    
    -- 测试数据处理器的跨系统分析
    local crossData = {
        userStats = self.userManager:GetUserStats(),
        gameStats = self.gameEngine:GetGameStats(),
        eventHistory = self.eventSystem:GetEventHistory()
    }
    
    self.dataProcessor:ProcessCrossSystemData(crossData)
    
    print("✅ 系统间交互测试完成")
end

-- 运行集成测试
local gameInstance = Game.new()
gameInstance:Run()

return gameInstance 