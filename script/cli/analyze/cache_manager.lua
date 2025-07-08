---
--- Created by fanggang@2025/07/08
--- DateTime: 2025/07/08 11:12
---
-- analyze/cache_manager.lua
-- 分析器缓存管理器 - 支持4阶段分析的断点续传

local json = require 'json'
local fs = require 'bee.filesystem'
local furi = require 'file-uri'
local util = require 'utility'
local files = require 'files'
local SDBMHash = require 'SDBMHash'

local cache_manager = {}

-- 缓存版本，用于兼容性检查
local CACHE_VERSION = "1.0.0"

-- 创建hash实例
local hasher = SDBMHash()

-- 缓存文件名
local CACHE_FILE_NAME = "lua_analysis_cache.json"
local CACHE_METADATA_FILE = "cache_metadata.json"

-- 默认缓存配置
local DEFAULT_CONFIG = {
    enabled = true,
    cacheDir = ".lua_analysis_cache",
    maxCacheAge = 24 * 60 * 60, -- 24小时，单位：秒
    enableCompression = false,
    enableFileHashCheck = true,
    autoCleanup = true
}

-- 阶段定义
local PHASES = {
    PHASE1_SYMBOLS = "phase1_symbols",
    PHASE2_INFERENCE = "phase2_inference", 
    PHASE3_EXPORT = "phase3_export",
    PHASE4_CALLS = "phase4_calls"
}

-- 创建缓存管理器实例
function cache_manager.new(rootUri, config)
    local manager = {
        rootUri = rootUri,
        config = util.deepCopy(DEFAULT_CONFIG),
        cacheDir = nil,
        cachePath = nil,
        metadataPath = nil
    }
    
    -- 合并配置
    if config then
        for k, v in pairs(config) do
            manager.config[k] = v
        end
    end
    
    -- 初始化缓存目录
    manager.cacheDir = fs.path(furi.decode(rootUri)) / manager.config.cacheDir
    manager.cachePath = manager.cacheDir / CACHE_FILE_NAME
    manager.metadataPath = manager.cacheDir / CACHE_METADATA_FILE
    
    -- 确保缓存目录存在
    if not fs.exists(manager.cacheDir) then
        fs.create_directories(manager.cacheDir)
    end
    
    return manager
end

-- 生成文件指纹（用于变更检测）
function cache_manager.generateFileFingerprint(manager, uri)
    local path = furi.decode(uri)
    if not path or not fs.exists(fs.path(path)) then
        return nil
    end
    
    local stat = fs.status(fs.path(path))
    if not stat then
        return nil
    end
    
    local fingerprint = {
        uri = uri,
        size = stat.size,
        lastModified = stat.last_write_time,
    }
    
    -- 如果启用了hash检查，计算文件hash
    if manager.config.enableFileHashCheck then
        local content = util.loadFile(path)
        if content then
            fingerprint.hash = hasher:hash(content)
        end
    end
    
    return fingerprint
end

-- 生成项目文件指纹集合
function cache_manager.generateProjectFingerprint(manager, fileList)
    local fingerprints = {}
    
    for _, uri in ipairs(fileList) do
        local fingerprint = cache_manager.generateFileFingerprint(manager, uri)
        if fingerprint then
            fingerprints[uri] = fingerprint
        end
    end
    
    return fingerprints
end

-- 检查文件是否发生变更
function cache_manager.checkFileChanges(manager, cachedFingerprints, currentFingerprints)
    local changes = {
        modified = {},
        added = {},
        deleted = {}
    }
    
    -- 检查修改和新增的文件
    for uri, currentFp in pairs(currentFingerprints) do
        local cachedFp = cachedFingerprints[uri]
        if not cachedFp then
            table.insert(changes.added, uri)
        else
            -- 比较文件指纹
            local isModified = false
            if cachedFp.size ~= currentFp.size then
                isModified = true
            elseif cachedFp.lastModified ~= currentFp.lastModified then
                isModified = true
            elseif manager.config.enableFileHashCheck and cachedFp.hash ~= currentFp.hash then
                isModified = true
            end
            
            if isModified then
                table.insert(changes.modified, uri)
            end
        end
    end
    
    -- 检查删除的文件
    for uri, _ in pairs(cachedFingerprints) do
        if not currentFingerprints[uri] then
            table.insert(changes.deleted, uri)
        end
    end
    
    return changes
end

-- 安全序列化函数 - 过滤不能序列化的数据类型
local function safeSerialize(data, visited)
    visited = visited or {}
    
    if data == nil then
        return nil
    end
    
    local dataType = type(data)
    
    -- 基本类型直接返回
    if dataType == "string" or dataType == "number" or dataType == "boolean" then
        return data
    end
    
    -- 函数类型跳过
    if dataType == "function" or dataType == "thread" or dataType == "userdata" then
        return nil
    end
    
    -- 防止循环引用
    if visited[data] then
        return nil
    end
    visited[data] = true
    
    -- 处理表类型
    if dataType == "table" then
        local result = {}
        local hasNumericKeys = false
        local hasStringKeys = false
        
        -- 检查键的类型
        for k, v in pairs(data) do
            if type(k) == "number" then
                hasNumericKeys = true
            elseif type(k) == "string" then
                hasStringKeys = true
            end
        end
        
        -- 如果是混合键类型，只保留字符串键
        if hasNumericKeys and hasStringKeys then
            for k, v in pairs(data) do
                if type(k) == "string" then
                    local safeValue = safeSerialize(v, visited)
                    if safeValue ~= nil then
                        result[k] = safeValue
                    end
                end
            end
        else
            -- 正常处理
            for k, v in pairs(data) do
                local safeKey = safeSerialize(k, visited)
                local safeValue = safeSerialize(v, visited)
                if safeKey ~= nil and safeValue ~= nil then
                    result[safeKey] = safeValue
                end
            end
        end
        return result
    end
    
    return nil
end

-- 序列化上下文数据（过滤不需要缓存的数据）
function cache_manager.serializeContext(manager, ctx)
    local serializedCtx = {
        -- 基本信息
        rootUri = ctx.rootUri,
        nextId = ctx.nextId,
        
        -- 符号表 (Phase 1) - 安全序列化
        symbols = safeSerialize(ctx.symbols),
        classes = safeSerialize(ctx.classes),
        modules = safeSerialize(ctx.modules),
        asts = {}, -- AST对象不序列化，重新构建时会重新生成
        uriToModule = safeSerialize(ctx.uriToModule),
        fileList = safeSerialize(ctx.fileList),
        
        -- 类型信息 (Phase 2)
        types = safeSerialize(ctx.types),
        
        -- 实体和关系 (Phase 3)  
        entities = safeSerialize(ctx.entities),
        relations = safeSerialize(ctx.relations),
        
        -- 调用关系 (Phase 2 & 4)
        calls = safeSerialize(ctx.calls),
        
        -- 成员访问信息
        memberAccess = safeSerialize(ctx.memberAccess),
        
        -- 统计信息
        statistics = safeSerialize(ctx.statistics),
        
        -- 配置（只保存必要的配置）
        config = {
            requireFunctions = ctx.config.requireFunctions,
            classFunctions = ctx.config.classFunctions,
            excludeDirectories = ctx.config.excludeDirectories,
            excludePatterns = ctx.config.excludePatterns,
            debugMode = ctx.config.debugMode,
            enableNodeTracking = ctx.config.enableNodeTracking
        }
    }
    
    return serializedCtx
end

-- 反序列化上下文数据
function cache_manager.deserializeContext(manager, serializedCtx, originalCtx)
    -- 恢复基本信息
    originalCtx.nextId = serializedCtx.nextId or 1
    
    -- 恢复符号表
    originalCtx.symbols = serializedCtx.symbols or {}
    originalCtx.classes = serializedCtx.classes or {}
    originalCtx.modules = serializedCtx.modules or {}
    originalCtx.uriToModule = serializedCtx.uriToModule or {}
    originalCtx.fileList = serializedCtx.fileList or {}
    
    -- 恢复类型信息
    originalCtx.types = serializedCtx.types or {
        inferred = {},
        pending = {},
        statistics = { total = 0, inferred = 0, pending = 0 }
    }
    
    -- 恢复实体和关系
    originalCtx.entities = serializedCtx.entities or {}
    originalCtx.relations = serializedCtx.relations or {}
    
    -- 恢复调用关系
    originalCtx.calls = serializedCtx.calls or {
        functions = {},
        types = {},
        callInfos = {},
        callStatistics = { totalCalls = 0, resolvedCalls = 0, unresolvedCalls = 0, parameterTypes = {} }
    }
    
    -- 恢复成员访问信息
    originalCtx.memberAccess = serializedCtx.memberAccess or {
        accessInfos = {},
        accessStatistics = { totalAccesses = 0, fieldAccesses = 0, indexAccesses = 0 }
    }
    
    -- 恢复统计信息
    originalCtx.statistics = serializedCtx.statistics or {
        totalFiles = 0, totalSymbols = 0, totalEntities = 0, totalRelations = 0, processingTime = 0
    }
    
    -- 合并配置
    if serializedCtx.config then
        for k, v in pairs(serializedCtx.config) do
            originalCtx.config[k] = v
        end
    end
    
    return originalCtx
end

-- 保存缓存
function cache_manager.saveCache(manager, ctx, currentPhase, progress)
    if not manager.config.enabled then
        return true
    end
    
    local success, err = pcall(function()
        -- 生成文件指纹
        local fingerprints = cache_manager.generateProjectFingerprint(manager, ctx.fileList)
        
        -- 创建缓存数据
        local cacheData = {
            version = CACHE_VERSION,
            timestamp = os.time(),
            rootUri = ctx.rootUri,
            currentPhase = currentPhase,
            progress = progress or {},
            fingerprints = fingerprints,
            context = cache_manager.serializeContext(manager, ctx)
        }
        
        -- 序列化为JSON
        local jsonData = json.encode(cacheData)
        
        -- 保存到文件
        local file = io.open(manager.cachePath:string(), 'w')
        if not file then
            error("无法创建缓存文件: " .. manager.cachePath:string())
        end
        
        file:write(jsonData)
        file:close()
        
        -- 保存元数据
        local metadata = {
            version = CACHE_VERSION,
            timestamp = os.time(),
            size = #jsonData,
            phase = currentPhase
        }
        
        local metadataJson = json.encode(metadata)
        local metaFile = io.open(manager.metadataPath:string(), 'w')
        if metaFile then
            metaFile:write(metadataJson)
            metaFile:close()
        end
        
        print(string.format("✅ 缓存已保存: %s (阶段: %s)", manager.cachePath:string(), currentPhase))
    end)
    
    if not success then
        print(string.format("❌ 保存缓存失败: %s", err))
        return false
    end
    
    return true
end

-- 加载缓存
function cache_manager.loadCache(manager)
    if not manager.config.enabled then
        return nil
    end
    
    if not fs.exists(manager.cachePath) then
        return nil
    end
    
    local success, cacheData = pcall(function()
        local file = io.open(manager.cachePath:string(), 'r')
        if not file then
            return nil
        end
        
        local jsonData = file:read('*a')
        file:close()
        
        if not jsonData or jsonData == "" then
            return nil
        end
        
        return json.decode(jsonData)
    end)
    
    if not success or not cacheData then
        print("❌ 加载缓存失败")
        return nil
    end
    
    return cacheData
end

-- 验证缓存有效性
function cache_manager.validateCache(manager, cacheData, currentFileList)
    if not cacheData then
        return false, "缓存数据为空"
    end
    
    -- 检查版本兼容性
    if cacheData.version ~= CACHE_VERSION then
        return false, string.format("缓存版本不兼容: %s vs %s", cacheData.version, CACHE_VERSION)
    end
    
    -- 检查缓存年龄
    local currentTime = os.time()
    local cacheAge = currentTime - (cacheData.timestamp or 0)
    if cacheAge > manager.config.maxCacheAge then
        return false, string.format("缓存已过期: %d秒", cacheAge)
    end
    
    -- 检查根目录是否匹配
    if cacheData.rootUri ~= manager.rootUri then
        return false, "根目录不匹配"
    end
    
    -- 检查文件变更
    local currentFingerprints = cache_manager.generateProjectFingerprint(manager, currentFileList)
    local changes = cache_manager.checkFileChanges(manager, cacheData.fingerprints or {}, currentFingerprints)
    
    local hasChanges = #changes.modified > 0 or #changes.added > 0 or #changes.deleted > 0
    if hasChanges then
        return false, string.format("文件发生变更: 修改%d个，新增%d个，删除%d个", 
            #changes.modified, #changes.added, #changes.deleted), changes
    end
    
    return true, "缓存有效"
end

-- 清除缓存
function cache_manager.clearCache(manager)
    local success = true
    
    if fs.exists(manager.cachePath) then
        success = success and pcall(fs.remove, manager.cachePath)
    end
    
    if fs.exists(manager.metadataPath) then
        success = success and pcall(fs.remove, manager.metadataPath)
    end
    
    return success
end

-- 获取缓存信息
function cache_manager.getCacheInfo(manager)
    if not fs.exists(manager.cachePath) then
        return nil
    end
    
    local stat = fs.status(manager.cachePath)
    local info = {
        exists = true,
        size = stat and stat.size or 0,
        lastModified = stat and stat.last_write_time or 0
    }
    
    -- 尝试读取元数据
    if fs.exists(manager.metadataPath) then
        local success, metadata = pcall(function()
            local file = io.open(manager.metadataPath:string(), 'r')
            if file then
                local content = file:read('*a')
                file:close()
                return json.decode(content)
            end
            return nil
        end)
        
        if success and metadata then
            info.version = metadata.version
            info.timestamp = metadata.timestamp
            info.phase = metadata.phase
        end
    end
    
    return info
end

-- 导出阶段常量
cache_manager.PHASES = PHASES

return cache_manager 