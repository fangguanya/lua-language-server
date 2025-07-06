-- analyze/context.lua
-- 全局上下文管理

local furi = require 'file-uri'
local files = require 'files'
local util = require 'utility'

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
            members = {},           -- 成员变量定义 {memberId -> {name, ownerObject, memberType, ...}}
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
            -- 目录过滤配置（支持多个目录和模式）
            excludeDirectories = {
                "Config",           -- 配置目录
                "config",           -- 小写配置目录
                "Data/Config",      -- 数据配置目录
                "Data\\Config",     -- Windows路径分隔符
                "Assets/Config",    -- 资源配置目录
                "Assets\\Config",   -- Windows路径分隔符
                "Temp",             -- 临时目录
                "temp",             -- 小写临时目录
                ".git",             -- Git目录
                ".svn",             -- SVN目录
                ".vscode",          -- VSCode目录
                "node_modules"      -- Node.js模块目录
            },
            -- 目录过滤模式（支持通配符）
            excludePatterns = {
                ".*[/\\\\][Cc]onfig$",         -- 任何以Config结尾的目录
                ".*[/\\\\][Dd]ata[/\\\\][Cc]onfig$", -- Data/Config目录
                ".*[/\\\\][Aa]ssets[/\\\\][Cc]onfig$", -- Assets/Config目录
                ".*[/\\\\][Tt]emp$",           -- 任何以Temp结尾的目录
                ".*[/\\\\]%..*$"               -- 任何以.开头的隐藏目录
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
    
    -- 手动扫描文件并添加到workspace
    local fs = require 'bee.filesystem'
    local furi = require 'file-uri'
    local files = require 'files'
    
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

-- 添加符号
function context.addSymbol(ctx, symbolType, symbolData)
    local id = context.generateId(ctx, symbolType)
    symbolData.id = id
    
    -- 符号表名称映射
    local symbolTableNames = {
        module = "modules",
        class = "classes", 
        ["function"] = "functions",
        variable = "variables",
        member = "members"
    }
    
    local tableName = symbolTableNames[symbolType] or (symbolType .. 's')
    
    -- 确保符号表存在
    local symbolTable = ctx.symbols[tableName]
    if not symbolTable then
        ctx.symbols[tableName] = {}
        symbolTable = ctx.symbols[tableName]
    end
    
    symbolTable[id] = symbolData
    ctx.statistics.totalSymbols = ctx.statistics.totalSymbols + 1
    return id
end

-- 查找符号
function context.findSymbol(ctx, symbolType, predicate)
    -- 符号表名称映射
    local symbolTableNames = {
        module = "modules",
        class = "classes", 
        ["function"] = "functions",
        variable = "variables",
        member = "members"
    }
    
    local tableName = symbolTableNames[symbolType] or (symbolType .. 's')
    local symbolTable = ctx.symbols[tableName]
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

-- =======================================
-- 符号操作封装函数
-- =======================================

-- 递归解析别名，找到真正的类型
function context.resolveAlias(ctx, aliasName, visited)
    visited = visited or {}
    
    -- 防止循环引用
    if visited[aliasName] then
        context.debug(ctx, "⚠️  检测到循环别名引用: %s", aliasName)
        return nil, nil
    end
    visited[aliasName] = true
    
    local alias = ctx.symbols.aliases[aliasName]
    if not alias then
        return nil, nil
    end
    
    -- 如果是类定义别名，直接返回
    if alias.type == 'class_definition' then
        return alias.symbolId, alias.targetClass
    end
    
    -- 如果是模块导入别名，需要进一步查找
    if alias.type == 'module_import' then
        local targetModule = alias.targetModule
        if targetModule then
            -- 递归查找模块对应的类
            return context.resolveAlias(ctx, targetModule, visited)
        end
    end
    
    -- 如果是变量别名，查找变量指向的类型
    if alias.type == 'variable_alias' then
        local targetName = alias.targetName
        if targetName then
            return context.resolveAlias(ctx, targetName, visited)
        end
    end
    
    return nil, nil
end

-- 查找全局类定义（支持多模块）
function context.findGlobalClass(ctx, className)
    -- 方法1：直接通过类名查找
    for classId, classSymbol in pairs(ctx.symbols.classes) do
        if classSymbol.name == className then
            return classId, classSymbol
        end
    end
    
    -- 方法2：通过别名查找
    local classId, resolvedClassName = context.resolveAlias(ctx, className)
    if classId then
        return classId, ctx.symbols.classes[classId]
    end
    
    -- 方法3：反向查找别名（处理多层别名的情况）
    for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
        if aliasInfo.type == 'class_definition' and aliasInfo.targetClass == className then
            return aliasInfo.symbolId, ctx.symbols.classes[aliasInfo.symbolId]
        end
    end
    
    return nil, nil
end

-- 查找类的所有别名
function context.findClassAliases(ctx, className)
    local aliases = {}
    
    for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
        if aliasInfo.type == 'class_definition' and aliasInfo.targetClass == className then
            table.insert(aliases, {
                name = aliasName,
                symbolId = aliasInfo.symbolId,
                info = aliasInfo
            })
        end
    end
    
    return aliases
end

-- 合并同类型的别名（解决TmpResult和WeaponClass都指向Weapon的问题）
function context.mergeClassAliases(ctx, className)
    local aliases = context.findClassAliases(ctx, className)
    if #aliases <= 1 then
        return -- 没有需要合并的别名
    end
    
    -- 找到主要的类定义
    local mainClassId, mainClassSymbol = context.findGlobalClass(ctx, className)
    if not mainClassId or not mainClassSymbol then
        context.debug(ctx, "⚠️  未找到主要类定义: %s", className)
        return
    end
    
    context.debug(ctx, "🔄 合并类别名: %s (%d个别名)", className, #aliases)
    
    -- 合并所有别名的成员和方法到主类中
    for _, alias in ipairs(aliases) do
        if alias.symbolId ~= mainClassId then
            local aliasClassSymbol = ctx.symbols.classes[alias.symbolId]
            if aliasClassSymbol then
                -- 合并成员
                for _, memberId in ipairs(aliasClassSymbol.members or {}) do
                    if not context.containsValue(mainClassSymbol.members, memberId) then
                        table.insert(mainClassSymbol.members, memberId)
                    end
                end
                
                -- 合并方法
                for _, methodId in ipairs(aliasClassSymbol.methods or {}) do
                    if not context.containsValue(mainClassSymbol.methods, methodId) then
                        table.insert(mainClassSymbol.methods, methodId)
                    end
                end
                
                context.debug(ctx, "  ✅ 合并别名 %s -> %s", alias.name, className)
            end
        end
    end
    
    -- 更新所有别名指向主类
    for _, alias in ipairs(aliases) do
        ctx.symbols.aliases[alias.name] = {
            type = 'class_definition',
            targetClass = className,
            symbolId = mainClassId
        }
    end
end

-- 检查数组是否包含某个值
function context.containsValue(array, value)
    for _, v in ipairs(array) do
        if v == value then
            return true
        end
    end
    return false
end

-- 获取类的完整信息（包括所有别名的成员和方法）
function context.getCompleteClassInfo(ctx, className)
    local classId, classSymbol = context.findGlobalClass(ctx, className)
    if not classId then
        return nil
    end
    
    -- 合并别名信息
    context.mergeClassAliases(ctx, className)
    
    -- 返回更新后的类信息
    return classId, ctx.symbols.classes[classId]
end

-- 添加变量别名
function context.addVariableAlias(ctx, aliasName, targetName)
    ctx.symbols.aliases[aliasName] = {
        type = 'variable_alias',
        targetName = targetName
    }
    context.debug(ctx, "变量别名: %s -> %s", aliasName, targetName)
end

return context 