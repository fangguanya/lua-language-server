-- analyze/context.lua
-- 全局上下文管理

local furi = require 'file-uri'
local files = require 'files'

local context = {}

-- 创建新的分析上下文
function context.new(rootUri, options)
    local ctx = {
        -- 基本信息
        rootUri = rootUri,
        options = options or {},
        
        -- 全局ID计数器
        nextId = 1,
        
        -- 符号表 (Phase 1)
        symbols = {
            modules = {},           -- 模块定义 {moduleId -> {name, uri, exports, ...}}
            classes = {},           -- 类定义 {classId -> {name, module, members, ...}}
            functions = {},         -- 函数定义 {funcId -> {name, scope, params, ...}}
            variables = {},         -- 变量定义 {varId -> {name, scope, type, ...}}
            aliases = {},           -- 别名映射 {aliasName -> targetId}
        },
        
        -- 类型信息 (Phase 2)
        types = {
            inferred = {},          -- 推断出的类型 {symbolId -> typeInfo}
            pending = {},           -- 待推断的符号列表
            statistics = {
                total = 0,
                inferred = 0,
                pending = 0
            }
        },
        
        -- 实体和关系 (Phase 3)
        entities = {},              -- 导出的实体列表
        relations = {},             -- 导出的关系列表
        
        -- 调用关系 (Phase 4)
        calls = {
            functions = {},         -- 函数间调用关系
            types = {},             -- 类型间调用关系
        },
        
        -- 统计信息
        statistics = {
            totalFiles = 0,
            totalSymbols = 0,
            totalEntities = 0,
            totalRelations = 0,
            processingTime = 0
        },
        
        -- 配置
        config = {
            requireFunctions = {"require", "kg_require"},
            classFunctions = {
                "DefineClass", "CreateClass", "DefineEntity",
                "DefineBriefEntity", "DefineLocalEntity", 
                "DefineComponent", "DefineSingletonClass"
            },
            debugMode = options and options.debug or false
        }
    }
    
    return ctx
end

-- 生成唯一ID
function context.generateId(ctx, prefix)
    local id = string.format("%s_%d", prefix or "id", ctx.nextId)
    ctx.nextId = ctx.nextId + 1
    return id
end

-- 获取文件列表
function context.getFiles(ctx)
    local uris = {}
    
    if ctx.options.files then
        -- 分析指定文件
        for _, filePath in ipairs(ctx.options.files) do
            local uri = furi.encode(filePath)
            if uri then
                table.insert(uris, uri)
            end
        end
    else
        -- 分析目录下所有文件
        uris = files.getChildFiles(ctx.rootUri)
    end
    
    return uris
end

-- 调试输出
function context.debug(ctx, message, ...)
    if ctx.config.debugMode then
        print(string.format("🐛 " .. message, ...))
    end
end

-- 添加符号
function context.addSymbol(ctx, symbolType, symbolData)
    local id = context.generateId(ctx, symbolType)
    symbolData.id = id
    
    -- 确保符号表存在
    local symbolTable = ctx.symbols[symbolType .. 's']
    if not symbolTable then
        ctx.symbols[symbolType .. 's'] = {}
        symbolTable = ctx.symbols[symbolType .. 's']
    end
    
    symbolTable[id] = symbolData
    ctx.statistics.totalSymbols = ctx.statistics.totalSymbols + 1
    return id
end

-- 查找符号
function context.findSymbol(ctx, symbolType, predicate)
    local symbolTable = ctx.symbols[symbolType .. 's']
    if not symbolTable then
        return nil
    end
    
    for id, symbol in pairs(symbolTable) do
        if predicate(symbol) then
            return id, symbol
        end
    end
    return nil
end

-- 添加实体
function context.addEntity(ctx, entityType, entityData)
    local id = context.generateId(ctx, "entity")
    entityData.id = id
    entityData.type = entityType
    table.insert(ctx.entities, entityData)
    ctx.statistics.totalEntities = ctx.statistics.totalEntities + 1
    return id
end

-- 添加关系
function context.addRelation(ctx, relationType, fromId, toId, metadata)
    local id = context.generateId(ctx, "relation")
    local relation = {
        id = id,
        type = relationType,
        from = fromId,
        to = toId,
        metadata = metadata or {}
    }
    table.insert(ctx.relations, relation)
    ctx.statistics.totalRelations = ctx.statistics.totalRelations + 1
    return id
end

return context 