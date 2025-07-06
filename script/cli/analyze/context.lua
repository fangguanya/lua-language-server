---
--- Created by fanggang
--- DateTime: 2025/7/6 17:27
---
-- analyze/context.lua
-- 全局上下文管理

local furi = require 'file-uri'
local files = require 'files'
local util = require 'utility'
local fs = require 'bee.filesystem'
local symbol = require 'cli.analyze.symbol'
local utils = require 'cli.analyze.utils'
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
        symbols = {},
        classes = {},   -- 对symbols的加速（name -> symbol对象
        modules = {},   -- 对symbols的加速（name -> symbol对象
        asts = {},      -- 对symbols的加速和查询（ast -> symbol对象
        uriToModule = {},  -- URI到模块对象的映射（uri -> module对象），避免重复获取AST
        fileList = {},     -- 文件URI列表缓存，避免重复扫描
        
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
        
        -- 调用关系 (Phase 2 & 4)
        calls = {
            functions = {},         -- 函数间调用关系
            types = {},             -- 类型间调用关系
            -- 第2阶段：Call信息记录
            callInfos = {},         -- 详细的调用信息列表
            callStatistics = {
                totalCalls = 0,
                resolvedCalls = 0,
                unresolvedCalls = 0,
                parameterTypes = {}
            }
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
            -- 目录过滤配置（支持多个目录和模式）
            excludeDirectories = {
                "Data/",      -- 数据配置目录
                "Data\\",     -- Windows路径分隔符
                ".git",             -- Git目录
                ".svn",             -- SVN目录
                ".vscode",          -- VSCode目录
                "node_modules"      -- Node.js模块目录
            },
            -- 目录过滤模式（支持通配符）
            excludePatterns = {
            },
            debugMode = options and options.debug or false,
            -- 节点处理跟踪（用于调试重复处理问题）
            enableNodeTracking = options and options.enableNodeTracking or false
        }
    }
    -- 不再使用applyMethods，避免函数引用导致JSON序列化问题
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
    -- 如果已经缓存了文件列表，直接返回
    if #ctx.fileList > 0 then
        return ctx.fileList
    end
    
    local uris = {}
        
    -- 将URI转换为路径
    local rootPath = furi.decode(ctx.rootUri)
    if not rootPath then
        return uris
    end
    
    -- 递归扫描.lua文件
    local function scanDirectory(path)
        local dirPath = fs.path(path)
        if not fs.exists(dirPath) or not fs.is_directory(dirPath) then
            return
        end
        
        -- 使用fs.pairs遍历目录
        for fullpath, status in fs.pairs(dirPath) do
            local pathString = fullpath:string()
            local st = status:type()
            
            if st == 'directory' or st == 'symlink' or st == 'junction' then
                -- 检查是否应该过滤此目录
                local shouldExclude, reason = context.shouldExcludeDirectory(ctx, pathString)
                if shouldExclude then
                    if ctx.config.debugMode then
                        print(string.format("🐛 跳过目录: %s (%s)", pathString, reason))
                    end
                    goto continue
                end
                
                -- 递归扫描子目录
                scanDirectory(pathString)
            elseif st == 'file' or st == 'regular' then
                -- 检查是否是.lua文件
                if pathString:match('%.lua$') then
                    local uri = furi.encode(pathString)
                    if uri then
                        table.insert(uris, uri)
                        -- 手动添加到files模块
                        files.setText(uri, util.loadFile(pathString) or "")
                    end
                end
            end
            
            ::continue::
        end
    end
    
    scanDirectory(rootPath)
    
    -- 缓存文件列表
    ctx.fileList = uris
    return uris
end

-- 调试输出
function context.debug(ctx, message, ...)
    if ctx.config.debugMode then
        print(string.format("🐛 " .. message, ...))
    end
end

-- 检查目录是否应该被过滤
function context.shouldExcludeDirectory(ctx, dirPath)
    local dirName = dirPath:match("([^/\\]+)$") or dirPath
    local normalizedPath = dirPath:gsub("\\", "/")
    
    -- 检查精确匹配
    for _, excludeDir in ipairs(ctx.config.excludeDirectories) do
        if dirName == excludeDir then
            return true, "精确匹配: " .. excludeDir
        end
        
        -- 检查路径结尾匹配
        local normalizedExclude = excludeDir:gsub("\\", "/")
        if normalizedPath:find(normalizedExclude .. "$") then
            return true, "路径匹配: " .. excludeDir
        end
    end
    
    -- 检查模式匹配
    for _, pattern in ipairs(ctx.config.excludePatterns) do
        if normalizedPath:match(pattern) then
            return true, "模式匹配: " .. pattern
        end
    end
    
    return false, nil
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

-- 添加符号
function context.addModule(ctx, name, filename, uri, ast)
    name = utils.getFormularModulePath(name)
    local module = ctx.modules[name]
    if module ~= nil then
        module.ast = ast
        ctx.asts[ast] = module
        if uri then
            ctx.uriToModule[uri] = module
        end
        return module 
    end
    
    local id = context.generateId(ctx, 'module')
    module = symbol.module.new(id, name, ast)
    context.addSymbol(ctx, module)
    ctx.modules[name] = module
    ctx.asts[ast] = module
    if uri then
        ctx.uriToModule[uri] = module
    end
    ctx.filename = filename
    ctx.uri = uri
    return module
end
function context.addClass(ctx, name, ast, parent)
    name = utils.getFormularModulePath(name)
    local cls = ctx.classes[name]
    if cls ~= nil then
        return cls
    end
    local id = context.generateId(ctx, 'class')
    cls = symbol.class.new(id, name, ast)
    cls.parent = parent
    parent:addClass(cls)
    context.addSymbol(ctx, cls)
    ctx.classes[name] = cls
    ctx.asts[ast] = cls
    return cls
end
function context.addMethod(ctx, name, ast, parent)
    local id = context.generateId(ctx, 'function')  -- 因为function是关键字，所以代码里面变量名为method
    local mtd = symbol.method.new(id, name, ast)
    mtd.parent = parent
    -- TODO：增加参数处理
    parent:addMethod(mtd)
    context.addSymbol(ctx, mtd)
    ctx.asts[ast] = mtd
    return mtd
end
function context.addVariable(ctx, name, ast, parent)
    local id = context.generateId(ctx, 'variable')
    local var = symbol.variable.new(id, name, ast)
    var.parent = parent
    parent:addVariable(var)
    context.addSymbol(ctx, var)
    ctx.asts[ast] = var
    return var
end
function context.addReference(ctx, name, ast, parent)
    if parent.type ~= SYMBOL_TYPE.MODULE then
        error("只能为module添加reference")
    end
    
    -- name就是所引用的模块名称
    name = utils.getFormularModulePath(name)
    
    -- 先找到目标模块的symbol符号信息
    local targetModule = ctx.modules[name]
    if targetModule == nil then
        targetModule = context.addModule(ctx, name, nil)
    end
    
    local id = context.generateId(ctx, 'require')
    local a = symbol.reference.new(id, name, ast)
    a.parent = parent
    -- 将找到的module-id进行处理
    a.target = targetModule.id
    parent:addReference(a)
    context.addSymbol(ctx, a)
    ctx.asts[ast] = a
    return a
end

function context.addSymbol(ctx, sym)
    ctx.symbols[sym.id] = sym
    ctx.statistics.totalSymbols = ctx.statistics.totalSymbols + 1
end

-- 查找符号：直接查找（不处理alias的情况）
function context.findSymbol(ctx, predicate)
    for id, symbol in pairs(ctx.symbols) do
        if predicate(symbol) then
            return id, symbol
        end
    end
    return nil
end

-- 递归解析别名，找到真正的类型，需要考虑alias的情况
function context.resolveSymbol(ctx, sym_id)
    local result = ctx.symbols[sym_id]
    if result == nil then
        return nil, nil
    end
    return result.id, result
end
function context.resolveName(ctx, name, scope)    
    if scope == nil or scope.container == false then
        context.debug(ctx, "⚠️  检查 %s 符号遇到非scope的类型：%s", name, tostring(scope))
        return nil, nil
    end
    
    -- 在当前作用域查找类
    for _, classId in ipairs(scope.classes) do
        local class = ctx.symbols[classId]
        if class and class.name == name then
            return context.resolveSymbol(ctx, classId)
        end
    end
    
    -- 在当前作用域查找方法
    for _, methodId in ipairs(scope.methods) do
        local method = ctx.symbols[methodId]
        if method and method.name == name then
            return context.resolveSymbol(ctx, methodId)
        end
    end
    
    -- 在当前作用域查找变量
    for _, varId in ipairs(scope.variables) do
        local var = ctx.symbols[varId]
        if var and var.name == name then
            return context.resolveSymbol(ctx, varId)
        end
    end
    
    -- 在父作用域查找
    if scope.parent then
        return context.resolveName(ctx, name, scope.parent)
    end
    
    -- 如果在作用域链中没有找到，尝试在全局模块中查找
    for moduleName, module in pairs(ctx.modules) do
        if module.name == name then
            return module.id, module
        end
    end
    
    -- 如果还没有找到，尝试在全局类中查找
    for className, class in pairs(ctx.classes) do
        if class.name == name then
            return class.id, class
        end
    end
    
    return nil, nil
end

-- 递归清理函数引用和不可序列化的内容
local function deepClean(obj, visited)
    visited = visited or {}
    
    if obj == nil then
        return nil
    end
    
    local objType = type(obj)
    
    -- 直接返回基本类型
    if objType == 'string' or objType == 'number' or objType == 'boolean' then
        return obj
    end
    
    -- 跳过函数类型
    if objType == 'function' then
        return nil
    end
    
    -- 跳过userdata和thread
    if objType == 'userdata' or objType == 'thread' then
        return nil
    end
    
    -- 处理表类型
    if objType == 'table' then
        -- 防止循环引用
        if visited[obj] then
            return nil
        end
        visited[obj] = true
        
        local cleaned = {}
        local hasStringKeys = false
        local hasNumberKeys = false
        
        -- 先检查键类型，避免混合键类型
        for key, value in pairs(obj) do
            local keyType = type(key)
            if keyType == 'string' then
                hasStringKeys = true
            elseif keyType == 'number' then
                hasNumberKeys = true
            end
        end
        
        -- 如果有混合键类型，只保留字符串键
        for key, value in pairs(obj) do
            local keyType = type(key)
            local shouldInclude = true
            
            -- 如果有混合键类型，优先保留字符串键
            if hasStringKeys and hasNumberKeys then
                shouldInclude = (keyType == 'string')
            end
            
            if shouldInclude then
                local cleanKey = deepClean(key, visited)
                local cleanValue = deepClean(value, visited)
                
                if cleanKey ~= nil then
                    -- 对于空表也要保留（如空的references或refs数组）
                    if cleanValue ~= nil or (type(value) == 'table' and next(value) == nil) then
                        cleaned[cleanKey] = cleanValue or {}
                    end
                end
            end
        end
        
        return cleaned
    end
    
    return nil
end

-- 根据URI获取模块对象（避免重复获取AST）
function context.getModuleByUri(ctx, uri)
    return ctx.uriToModule[uri]
end

-- 创建可序列化的符号数据（移除函数引用）
function context.getSerializableSymbols(ctx)
    local serializableSymbols = {}
    local reservedAst = {}
    for _, symbol in pairs(ctx.symbols) do
        reservedAst[symbol] = symbol.ast
        symbol.ast = nil
    end
    
    for id, symbol in pairs(ctx.symbols) do
        local cleanSymbol = serializableSymbols[id]
        if cleanSymbol == nil then
            cleanSymbol = deepClean(symbol)
            
            -- 移除AST引用（通常包含函数）
            if cleanSymbol then
                serializableSymbols[id] = cleanSymbol
            end
        end
    end
    
    for symbol, ast  in pairs(reservedAst) do
        symbol.ast = ast
    end
    return serializableSymbols
end

-- 辅助函数：查找当前作用域
function context.findCurrentScope(ctx, source)
    local current = source
    while current and current.parent do
        current = current.parent
        local symbol = ctx.asts[current]
        if symbol and symbol.container then
            return symbol
        end
    end
    
    -- 如果没有找到，返回当前模块
    local rootAst = source
    while rootAst.parent do
        rootAst = rootAst.parent
    end
    return ctx.asts[rootAst]
end

-- 辅助函数：查找当前方法
function context.findCurrentMethod(ctx, source)
    local current = source
    while current and current.parent do
        current = current.parent
        local symbol = ctx.asts[current]
        if symbol and symbol.type == SYMBOL_TYPE.METHOD then
            return symbol
        end
    end
    return nil
end

-- 查找AST节点对应的符号（可能在父节点中）
function context.findSymbolForNode(ctx, node)
    -- 首先检查节点本身
    local symbol = ctx.asts[node]
    if symbol then
        return symbol
    end
    
    -- 如果节点本身没有符号，检查父节点
    local parent = node.parent
    while parent do
        symbol = ctx.asts[parent]
        if symbol then
            return symbol
        end
        parent = parent.parent
    end
    
    return nil
end

-- 添加call信息记录
function context.addCallInfo(ctx, callInfo)
    local id = context.generateId(ctx, 'call')
    callInfo.id = id
    table.insert(ctx.calls.callInfos, callInfo)
    ctx.calls.callStatistics.totalCalls = ctx.calls.callStatistics.totalCalls + 1
    
    -- 更新统计信息
    if callInfo.targetSymbolId then
        ctx.calls.callStatistics.resolvedCalls = ctx.calls.callStatistics.resolvedCalls + 1
    else
        ctx.calls.callStatistics.unresolvedCalls = ctx.calls.callStatistics.unresolvedCalls + 1
    end
    
    -- 统计参数类型
    if callInfo.parameters then
        for _, param in ipairs(callInfo.parameters) do
            if param.type then
                ctx.calls.callStatistics.parameterTypes[param.type] = 
                    (ctx.calls.callStatistics.parameterTypes[param.type] or 0) + 1
            end
        end
    end
    
    return id
end

-- 查找函数符号
function context.findFunctionSymbol(ctx, name)
    for id, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.METHOD and symbol.name == name then
            return id, symbol
        end
    end
    return nil, nil
end

-- 查找变量符号
function context.findVariableSymbol(ctx, name, scope)
    -- 首先在指定作用域查找
    if scope then
        for _, varId in ipairs(scope.variables or {}) do
            local var = ctx.symbols[varId]
            if var and var.name == name then
                return varId, var
            end
        end
    end
    
    -- 在全局范围查找
    for id, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.VARIABLE and symbol.name == name then
            return id, symbol
        end
    end
    
    return nil, nil
end

return context 
