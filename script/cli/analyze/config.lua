-- analyze/config.lua
-- 配置管理模块

local config = {}

-- 默认配置
config.defaults = {
    -- 支持的require函数
    requireFunctions = {"require", "kg_require"},
    
    -- 支持的类定义函数
    classFunctions = {
        "DefineClass", "CreateClass", "DefineEntity",
        "DefineBriefEntity", "DefineLocalEntity", 
        "DefineComponent", "DefineSingletonClass"
    },
    
    -- 调试模式
    debugMode = false,
    
    -- 输出格式
    outputFormats = {"json", "markdown"},
    
    -- 文件过滤
    filePatterns = {"*.lua"},
    
    -- 忽略的目录
    ignoreDirs = {".git", "node_modules", "build", "dist"},
    
    -- 分析选项
    analyzeOptions = {
        includeBuiltins = true,     -- 包含内置函数和库
        crossFileAnalysis = true,   -- 跨文件分析
        deepInference = true,       -- 深度类型推断
        callGraphAnalysis = true    -- 调用图分析
    }
}

-- 合并配置
function config.merge(base, override)
    local result = {}
    
    -- 复制基础配置
    for k, v in pairs(base) do
        if type(v) == "table" then
            result[k] = config.merge(v, {})
        else
            result[k] = v
        end
    end
    
    -- 覆盖配置
    if override then
        for k, v in pairs(override) do
            if type(v) == "table" and type(result[k]) == "table" then
                result[k] = config.merge(result[k], v)
            else
                result[k] = v
            end
        end
    end
    
    return result
end

-- 从环境变量加载配置
function config.fromEnv()
    local envConfig = {}
    
    -- 调试模式
    if ANALYZE_DEBUG then
        envConfig.debugMode = ANALYZE_DEBUG == "true" or ANALYZE_DEBUG == "1"
    end
    
    -- 指定文件
    if ANALYZE_FILES then
        envConfig.files = {}
        for file in string.gmatch(ANALYZE_FILES, "[^,]+") do
            table.insert(envConfig.files, file:match("^%s*(.-)%s*$")) -- trim
        end
    end
    
    -- 指定目录
    if ANALYZE_FOLDERS then
        envConfig.folders = {}
        for folder in string.gmatch(ANALYZE_FOLDERS, "[^,]+") do
            table.insert(envConfig.folders, folder:match("^%s*(.-)%s*$")) -- trim
        end
    end
    
    return envConfig
end

-- 创建配置
function config.create(options)
    local envConfig = config.fromEnv()
    local finalConfig = config.merge(config.defaults, envConfig)
    finalConfig = config.merge(finalConfig, options or {})
    
    return finalConfig
end

return config 