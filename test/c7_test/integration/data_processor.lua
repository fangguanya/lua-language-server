-- test/c7_test/integration/data_processor.lua
-- 数据处理模块

local DataProcessor = DefineClass("DataProcessor", {
    systems = {},
    processedData = {},
    reports = {}
})

-- 数据分析器类
local DataAnalyzer = DefineClass("DataAnalyzer", {
    name = nil,
    processingRules = {}
})

function DataAnalyzer:__init(name)
    self.name = name
    self.processingRules = {}
    print(string.format("📊 创建数据分析器: %s", name))
end

function DataAnalyzer:AddRule(ruleName, ruleFunction)
    self.processingRules[ruleName] = ruleFunction
    print(string.format("📋 分析器 %s 添加规则: %s", self.name, ruleName))
end

function DataAnalyzer:ProcessData(data)
    local results = {}
    for ruleName, ruleFunc in pairs(self.processingRules) do
        local result = ruleFunc(data)
        results[ruleName] = result
        print(string.format("⚡ 规则 %s 处理结果: %s", ruleName, tostring(result)))
    end
    return results
end

-- DataProcessor 方法实现
function DataProcessor:__init()
    self.systems = {}
    self.processedData = {}
    self.reports = {}
    
    -- 创建默认分析器
    self:InitializeAnalyzers()
    
    print("📈 数据处理器初始化完成")
end

function DataProcessor:InitializeAnalyzers()
    -- 用户数据分析器
    self.userAnalyzer = DataAnalyzer.new("UserAnalyzer")
    self.userAnalyzer:AddRule("experience_growth", function(data)
        return data.experience and data.experience > 0
    end)
    self.userAnalyzer:AddRule("level_check", function(data)
        return data.level and data.level >= 1
    end)
    
    -- 游戏数据分析器
    self.gameAnalyzer = DataAnalyzer.new("GameAnalyzer")
    self.gameAnalyzer:AddRule("score_validation", function(data)
        return data.score and data.score >= 0
    end)
    self.gameAnalyzer:AddRule("session_active", function(data)
        return data.isActive == true
    end)
    
    -- 跨系统数据分析器
    self.crossAnalyzer = DataAnalyzer.new("CrossSystemAnalyzer")
    self.crossAnalyzer:AddRule("user_game_correlation", function(data)
        return data.userStats and data.gameStats
    end)
end

function DataProcessor:RegisterSystem(name, system)
    self.systems[name] = system
    print(string.format("🔗 数据处理器注册系统: %s", name))
end

function DataProcessor:ProcessUserData(userData)
    print(string.format("👤 处理用户数据: %s", userData.name or "未知用户"))
    
    local analysisResult = self.userAnalyzer:ProcessData(userData)
    
    -- 存储处理结果
    local processedEntry = {
        type = "user",
        originalData = userData,
        analysisResult = analysisResult,
        timestamp = os.time()
    }
    
    table.insert(self.processedData, processedEntry)
    
    return analysisResult
end

function DataProcessor:ProcessGameData(gameData)
    print(string.format("🎮 处理游戏数据: 会话 %s", gameData.sessionId or "未知会话"))
    
    local analysisResult = self.gameAnalyzer:ProcessData(gameData)
    
    -- 存储处理结果
    local processedEntry = {
        type = "game",
        originalData = gameData,
        analysisResult = analysisResult,
        timestamp = os.time()
    }
    
    table.insert(self.processedData, processedEntry)
    
    return analysisResult
end

function DataProcessor:ProcessCrossSystemData(crossData)
    print("🔄 处理跨系统数据...")
    
    local analysisResult = self.crossAnalyzer:ProcessData(crossData)
    
    -- 深度分析：用户与游戏数据的关联
    local correlationData = self:AnalyzeCorrelation(crossData)
    
    local processedEntry = {
        type = "cross_system",
        originalData = crossData,
        analysisResult = analysisResult,
        correlationData = correlationData,
        timestamp = os.time()
    }
    
    table.insert(self.processedData, processedEntry)
    
    return {
        analysis = analysisResult,
        correlation = correlationData
    }
end

function DataProcessor:AnalyzeCorrelation(crossData)
    local correlation = {
        userGameRatio = 0,
        averageEngagement = 0,
        systemEfficiency = 0
    }
    
    if crossData.userStats and crossData.gameStats then
        -- 用户游戏比率分析
        if crossData.userStats.totalUsers > 0 and crossData.gameStats.totalSessions > 0 then
            correlation.userGameRatio = crossData.gameStats.totalSessions / crossData.userStats.totalUsers
        end
        
        -- 平均参与度分析
        if crossData.userStats.averageLevel > 0 and crossData.gameStats.averageScore > 0 then
            correlation.averageEngagement = (crossData.userStats.averageLevel + crossData.gameStats.averageScore / 100) / 2
        end
        
        -- 系统效率分析
        correlation.systemEfficiency = math.min(
            crossData.userStats.activeUsers / math.max(crossData.userStats.totalUsers, 1),
            crossData.gameStats.activeSessions / math.max(crossData.gameStats.totalSessions, 1)
        )
    end
    
    print(string.format("📊 关联分析结果: 比率=%.2f, 参与度=%.2f, 效率=%.2f", 
        correlation.userGameRatio, correlation.averageEngagement, correlation.systemEfficiency))
    
    return correlation
end

function DataProcessor:GenerateReport()
    local report = {
        timestamp = os.time(),
        totalProcessedEntries = #self.processedData,
        summary = {},
        details = {}
    }
    
    -- 统计各类型数据
    local typeCounts = {}
    for _, entry in ipairs(self.processedData) do
        typeCounts[entry.type] = (typeCounts[entry.type] or 0) + 1
    end
    
    report.summary = string.format("处理了 %d 条数据记录 (用户: %d, 游戏: %d, 跨系统: %d)", 
        report.totalProcessedEntries,
        typeCounts.user or 0,
        typeCounts.game or 0,
        typeCounts.cross_system or 0
    )
    
    -- 获取系统统计信息
    if self.systems.user then
        report.details.userStats = self.systems.user:GetUserStats()
    end
    
    if self.systems.game then
        report.details.gameStats = self.systems.game:GetGameStats()
    end
    
    table.insert(self.reports, report)
    
    print("📋 生成数据处理报告完成")
    return report
end

function DataProcessor:GetProcessingHistory()
    return {
        processedData = self.processedData,
        reports = self.reports,
        systemCount = self:CountRegisteredSystems()
    }
end

function DataProcessor:CountRegisteredSystems()
    local count = 0
    for _ in pairs(self.systems) do
        count = count + 1
    end
    return count
end

return DataProcessor 