---
--- Created by fanggang
--- DateTime: 2025/7/6 17:27
---
-- analyze/phase4_calls.lua
-- 第四阶段：函数调用关系分析

local files = require 'files'
local guide = require 'parser.guide'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'
local furi = require 'file-uri'
local nodeTracker = require 'cli.analyze.node_tracker'
local symbol = require 'cli.analyze.symbol'
local SYMBOL_TYPE = symbol.SYMBOL_TYPE

local phase4 = {}

-- 节点跟踪器
local tracker4 = nil

-- Lua系统库列表
local LUA_SYSTEM_LIBRARIES = {
    ['print'] = true,
    ['table.insert'] = true,
    ['table.remove'] = true,
    ['table.concat'] = true,
    ['string.format'] = true,
    ['string.sub'] = true,
    ['string.find'] = true,
    ['string.match'] = true,
    ['string.gsub'] = true,
    ['math.min'] = true,
    ['math.max'] = true,
    ['math.abs'] = true,
    ['math.floor'] = true,
    ['math.ceil'] = true,
    ['os.time'] = true,
    ['os.date'] = true,
    ['io.open'] = true,
    ['io.read'] = true,
    ['io.write'] = true,
    ['require'] = true,
    ['pairs'] = true,
    ['ipairs'] = true,
    ['next'] = true,
    ['type'] = true,
    ['tonumber'] = true,
    ['tostring'] = true,
    ['getmetatable'] = true,
    ['setmetatable'] = true,
    ['rawget'] = true,
    ['rawset'] = true,
    ['DefineClass'] = true,
    ['DefineEntity'] = true,
}

-- 检查是否为系统库调用
local function isSystemLibraryCall(callName)
    return LUA_SYSTEM_LIBRARIES[callName] == true
end

-- 获取符号的所有可能类型名称（通用版本）
local function getAllPossibleTypeNames(ctx, symbolId, options)
    options = options or {}
    local includeMethodFormat = options.includeMethodFormat or false  -- 是否包含"类名.方法名"格式
    local cleanMethodName = options.cleanMethodName or false  -- 是否清理方法名中的类名前缀
    
    if not symbolId then
        return {}
    end
    
    local symbol = ctx.symbols[symbolId]
    if not symbol then
        return {}
    end
    
    local possibleTypes = {}
    
    -- 如果有别名目标名称，使用别名目标名称
    if symbol.aliasTargetName then
        table.insert(possibleTypes, symbol.aliasTargetName)
    end
    
    -- 如果是方法或函数，查找其所属的类或模块
    if symbol.type == SYMBOL_TYPE.METHOD then
        -- 查找父符号
        local parent = symbol.parent
        while parent do
            local parentSymbol = ctx.symbols[parent]
            if parentSymbol then
                if parentSymbol.type == SYMBOL_TYPE.CLASS then
                    local className = parentSymbol.aliasTargetName or parentSymbol.name
                    local methodName = symbol.name
                    
                    if includeMethodFormat then
                        -- 清理方法名，移除类名前缀
                        if cleanMethodName and methodName:find(className .. '%.') then
                            methodName = methodName:gsub(className .. '%.', '')
                        end
                        
                        if methodName:find(className .. '%.') then
                            -- 如果方法名已经包含类名，直接返回
                            table.insert(possibleTypes, methodName)
                        else
                            -- 否则组合类名和方法名
                            table.insert(possibleTypes, className .. "." .. methodName)
                        end
                    else
                        table.insert(possibleTypes, className)
                    end
                elseif parentSymbol.type == SYMBOL_TYPE.MODULE then
                    local moduleName = parentSymbol.aliasTargetName or parentSymbol.name
                    local methodName = symbol.name
                    
                    if includeMethodFormat then
                        -- 清理方法名，移除模块名前缀
                        if cleanMethodName and methodName:find(moduleName .. '%.') then
                            methodName = methodName:gsub(moduleName .. '%.', '')
                        end
                        
                        if methodName:find(moduleName .. '%.') then
                            -- 如果方法名已经包含模块名，直接返回
                            table.insert(possibleTypes, methodName)
                        else
                            -- 否则组合模块名和方法名
                            table.insert(possibleTypes, moduleName .. "." .. methodName)
                        end
                    else
                        table.insert(possibleTypes, moduleName)
                    end
                end
            end
            parent = parentSymbol and parentSymbol.parent
        end
    end
    
    -- 如果是类，直接返回类名
    if symbol.type == SYMBOL_TYPE.CLASS then
        table.insert(possibleTypes, symbol.aliasTargetName or symbol.name)
    end
    
    -- 如果是变量，查找其所有可能类型
    if symbol.type == SYMBOL_TYPE.VARIABLE then
        -- 检查是否有类型推断信息
        if symbol.possibles and next(symbol.possibles) then
            for possibleType, _ in pairs(symbol.possibles) do
                table.insert(possibleTypes, possibleType)
            end
        end
        
        -- 检查是否是类的别名
        if symbol.aliasTargetName then
            table.insert(possibleTypes, symbol.aliasTargetName)
        end
        
        -- 查找关联的类符号
        if symbol.related and next(symbol.related) then
            for relatedId, _ in pairs(symbol.related) do
                local relatedSymbol = ctx.symbols[relatedId]
                if relatedSymbol and relatedSymbol.type == SYMBOL_TYPE.CLASS then
                    table.insert(possibleTypes, relatedSymbol.aliasTargetName or relatedSymbol.name)
                elseif relatedSymbol and relatedSymbol.type == SYMBOL_TYPE.MODULE then
                    table.insert(possibleTypes, relatedSymbol.aliasTargetName or relatedSymbol.name)
                end
            end
        end
    end
    
    -- 如果是模块，返回模块名
    if symbol.type == SYMBOL_TYPE.MODULE then
        table.insert(possibleTypes, symbol.aliasTargetName or symbol.name)
    end
    
    -- 如果没有找到任何类型，返回符号名称
    if #possibleTypes == 0 then
        table.insert(possibleTypes, symbol.aliasTargetName or symbol.name)
    end
    
    return possibleTypes
end

-- 解析调用名称为真实类型名
local function resolveCallNameToRealType(ctx, callName, sourceSymbolId)
    -- 首先检查是否为系统库调用
    if isSystemLibraryCall(callName) then
        return nil, 'system_library'
    end
    
    -- 解析调用名称
    local className, methodName = callName:match('([^.:]+)[.:](.+)')
    if className and methodName then

        -- 查找当前项目中的类（直接匹配类名）
        for id, symbol in pairs(ctx.symbols) do
            if symbol.type == SYMBOL_TYPE.CLASS then
                local realClassName = symbol.aliasTargetName or symbol.name
                if symbol.name == className or symbol.aliasTargetName == className then
                    local separator = callName:find(':') and ':' or '.'
                    return realClassName .. separator .. methodName, 'class_method'
                end
            end
        end
        
        -- 查找当前项目中的变量，看是否引用了类或模块
        for id, symbol in pairs(ctx.symbols) do
            if symbol.type == SYMBOL_TYPE.VARIABLE and symbol.name == className then
                -- 优先检查变量的别名目标
                if symbol.aliasTargetName then

                    -- 查找别名目标是否是类名
                    for classId, classSymbol in pairs(ctx.symbols) do
                        if classSymbol.type == SYMBOL_TYPE.CLASS then
                            local realClassName = classSymbol.aliasTargetName or classSymbol.name
                            if realClassName == symbol.aliasTargetName then
                                local separator = callName:find(':') and ':' or '.'
                                return realClassName .. separator .. methodName, 'class_method'
                            end
                        end
                    end
                    -- 如果别名目标不是类名，可能是模块名，查找该模块中的类
                    for moduleId, moduleSymbol in pairs(ctx.symbols) do
                        if moduleSymbol.type == SYMBOL_TYPE.MODULE and moduleSymbol.name == symbol.aliasTargetName then
                            -- 查找该模块中的类
                            for classId, classSymbol in pairs(ctx.symbols) do
                                if classSymbol.type == SYMBOL_TYPE.CLASS and classSymbol.parent == moduleId then
                                    local realClassName = classSymbol.aliasTargetName or classSymbol.name
                                    local separator = callName:find(':') and ':' or '.'
                                    return realClassName .. separator .. methodName, 'class_method'
                                end
                            end
                        end
                    end
                    
                    -- 如果别名目标本身就是模块名，尝试直接使用
                    if symbol.aliasTargetName then
                        local separator = callName:find(':') and ':' or '.'
                        return symbol.aliasTargetName .. separator .. methodName, 'external_call'
                    end
                end
                -- 深度追踪变量的真实类型
                local function resolveVariableType(varSymbol, visited)
                    visited = visited or {}
                    if visited[varSymbol.id] then
                        return nil -- 避免循环引用
                    end
                    visited[varSymbol.id] = true
                    
                    -- 检查变量的可能类型
                    if varSymbol.possibles then
                        for possibleType, _ in pairs(varSymbol.possibles) do
                            -- 查找这个类型是否是项目中的类
                            for classId, classSymbol in pairs(ctx.symbols) do
                                if classSymbol.type == SYMBOL_TYPE.CLASS then
                                    local realClassName = classSymbol.aliasTargetName or classSymbol.name
                                    if realClassName == possibleType then
                                        return realClassName
                                    end
                                end
                            end
                        end
                    end
                    
                    -- 检查变量的关联关系
                    if varSymbol.related then
                        for relatedId, _ in pairs(varSymbol.related) do
                            local relatedSymbol = ctx.symbols[relatedId]
                            if relatedSymbol then
                                if relatedSymbol.type == SYMBOL_TYPE.CLASS then
                                    return relatedSymbol.aliasTargetName or relatedSymbol.name
                                elseif relatedSymbol.type == SYMBOL_TYPE.VARIABLE then
                                    local result = resolveVariableType(relatedSymbol, visited)
                                    if result then
                                        return result
                                    end
                                end
                            end
                        end
                    end
                    
                    -- 检查变量的引用关系
                    if varSymbol.refs then
                        for refId, _ in pairs(varSymbol.refs) do
                            local refSymbol = ctx.symbols[refId]
                            if refSymbol then
                                if refSymbol.type == SYMBOL_TYPE.VARIABLE then
                                    local result = resolveVariableType(refSymbol, visited)
                                    if result then
                                        return result
                                    end
                                end
                            end
                        end
                    end
                    
                    -- 反向查找：查找引用了当前变量的其他变量
                    for otherId, otherSymbol in pairs(ctx.symbols) do
                        if otherSymbol.type == SYMBOL_TYPE.VARIABLE and otherSymbol.refs then
                            for refId, _ in pairs(otherSymbol.refs) do
                                if refId == varSymbol.id then
                                    -- 找到了引用当前变量的其他变量，递归解析
                                    local result = resolveVariableType(otherSymbol, visited)
                                    if result then
                                        return result
                                    end
                                end
                            end
                        end
                    end
                    
                    -- 检查变量的别名目标
                    if varSymbol.aliasTargetName then
                        for classId, classSymbol in pairs(ctx.symbols) do
                            if classSymbol.type == SYMBOL_TYPE.CLASS then
                                local realClassName = classSymbol.aliasTargetName or classSymbol.name
                                if realClassName == varSymbol.aliasTargetName then
                                    return realClassName
                                end
                            end
                        end
                    end
                    
                    -- 检查是否是require导入的模块
                    -- 通过查找同名的require导入来追踪
                    if varSymbol.parent then
                        for requireId, requireSymbol in pairs(ctx.symbols) do
                            if requireSymbol.type == SYMBOL_TYPE.REFERENCE and requireSymbol.localName == varSymbol.name then
                                -- 找到了对应的require导入
                                local targetModuleId = requireSymbol.target
                                if targetModuleId then
                                    local targetModule = ctx.symbols[targetModuleId]
                                    if targetModule and targetModule.type == SYMBOL_TYPE.MODULE then
                                        -- 查找该模块中的类
                                        for classId, classSymbol in pairs(ctx.symbols) do
                                            if classSymbol.type == SYMBOL_TYPE.CLASS and classSymbol.parent == targetModuleId then
                                                local realClassName = classSymbol.aliasTargetName or classSymbol.name
                                                return realClassName
                                            end
                                        end
                                        -- 如果没有找到类，返回模块本身
                                        return targetModule.name
                                    end
                                end
                            end
                        end
                    end
                    
                    return nil
                end
                
                local realClassName = resolveVariableType(symbol)
                if realClassName then
                    local separator = callName:find(':') and ':' or '.'
                    return realClassName .. separator .. methodName, 'class_method'
                end
                
                -- 检查是否是模块变量（通过require导入的）
                for moduleId, moduleSymbol in pairs(ctx.symbols) do
                    if moduleSymbol.type == SYMBOL_TYPE.MODULE then
                        local moduleName = moduleSymbol.name or ""
                        -- 检查模块名是否包含变量名（如 logic.player 包含 player）
                        if moduleName:find(className) then
                            -- 查找该模块中是否有同名的类
                            for classId, classSymbol in pairs(ctx.symbols) do
                                if classSymbol.type == SYMBOL_TYPE.CLASS and classSymbol.parent == moduleId then
                                    -- 检查类名是否与变量名匹配（忽略大小写）
                                    local realClassName = classSymbol.aliasTargetName or classSymbol.name
                                    if realClassName:lower() == className:lower() then
                                        local separator = callName:find(':') and ':' or '.'
                                        return realClassName .. separator .. methodName, 'class_method'
                                    end
                                end
                            end
                        end
                    end
                end
                
                -- 更直接的方法：检查变量名是否与已知类名匹配
                for classId, classSymbol in pairs(ctx.symbols) do
                    if classSymbol.type == SYMBOL_TYPE.CLASS then
                        local realClassName = classSymbol.aliasTargetName or classSymbol.name
                        if realClassName:lower() == className:lower() then
                            local separator = callName:find(':') and ':' or '.'
                            return realClassName .. separator .. methodName, 'class_method'
                        end
                    end
                end
            end
        end
        
        -- 查找当前项目中的模块
        for id, symbol in pairs(ctx.symbols) do
            if symbol.type == SYMBOL_TYPE.MODULE then
                local realModuleName = symbol.aliasTargetName or symbol.name
                if symbol.name == className or symbol.aliasTargetName == className then
                    local separator = callName:find(':') and ':' or '.'
                    return realModuleName .. separator .. methodName, 'module_method'
                end
            end
        end
        
        -- 如果不是当前项目的class或module，视为外部调用
        return callName, 'external_call'
    end
    
    -- 简单函数调用 - 检查是否属于当前项目
    -- 查找当前项目中是否有这个函数
    for id, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.METHOD and symbol.name == callName then
            -- 检查函数是否属于当前项目的module或class
            if symbol.parent then
                local parentSymbol = ctx.symbols[symbol.parent]
                if parentSymbol and (parentSymbol.type == SYMBOL_TYPE.CLASS or parentSymbol.type == SYMBOL_TYPE.MODULE) then
                    return callName, 'internal_function'
                end
            end
        end
    end
    
    -- 不属于当前项目，视为外部调用
    return callName, 'external_call'
end

-- 获取调用者的第一个真实类型名（为了兼容性保留）
local function getCallerRealTypeName(ctx, sourceSymbolId)
    local possibleTypes = getAllPossibleTypeNames(ctx, sourceSymbolId, {includeMethodFormat = true, cleanMethodName = true})
    return possibleTypes[1]
end

-- 解析别名调用名称
local function resolveAliasedCallName(ctx, callName)
    if not ctx.symbols.aliases then
        return callName
    end
    
    for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
        if aliasInfo.type == "class_alias" then
            local targetClassName = aliasInfo.targetName
            
            -- 处理静态函数调用 (aliasName.functionName -> targetClassName.functionName)
            local aliasPrefix = aliasName .. "."
            if callName:sub(1, #aliasPrefix) == aliasPrefix then
                local functionName = callName:sub(#aliasPrefix + 1)
                return targetClassName .. "." .. functionName
            end
            
            -- 处理方法调用 (aliasName:methodName -> targetClassName:methodName)
            local aliasMethodPrefix = aliasName .. ":"
            if callName:sub(1, #aliasMethodPrefix) == aliasMethodPrefix then
                local methodName = callName:sub(#aliasMethodPrefix + 1)
                return targetClassName .. ":" .. methodName
            end
        end
    end
    
    return callName
end

-- 查找实体通过符号ID
local function findEntityBySymbolId(ctx, symbolId)
    for _, entity in ipairs(ctx.entities) do
        if entity.symbolId == symbolId then
            return entity
        end
    end
    return nil
end

-- 查找实体通过名称和类型
local function findEntityByNameAndType(ctx, name, entityType)
    for _, entity in ipairs(ctx.entities) do
        if entity.type == entityType and entity.name == name then
            return entity
        end
    end
    return nil
end

-- 处理函数调用关系
local function processFunctionCalls(ctx)
    local functionCallCount = 0
    
    context.debug(ctx, "处理函数调用关系，共 %d 个调用记录", #ctx.calls.callInfos)
    
    for _, callInfo in ipairs(ctx.calls.callInfos) do
        -- 解析调用名称为真实类型名
        local resolvedCallName, callType = resolveCallNameToRealType(ctx, callInfo.callName, callInfo.sourceSymbolId)
        
        -- 跳过系统库调用
        if callType == 'system_library' then
            goto continue
        end
        
        -- 获取调用者的所有可能真实类型名
        local callerPossibleTypeNames = getAllPossibleTypeNames(ctx, callInfo.sourceSymbolId, {includeMethodFormat = true, cleanMethodName = true})
        
        -- 获取被调用者的所有可能真实类型名
        local calleePossibleTypeNames = {}
        if callInfo.targetSymbolId then
            calleePossibleTypeNames = getAllPossibleTypeNames(ctx, callInfo.targetSymbolId, {includeMethodFormat = true, cleanMethodName = false})
        else
            table.insert(calleePossibleTypeNames, resolvedCallName)
        end
        
        -- 查找调用者实体
        local callerEntity = nil
        if callInfo.sourceSymbolId then
            callerEntity = findEntityBySymbolId(ctx, callInfo.sourceSymbolId)
        end
        
        -- 查找被调用者实体
        local calleeEntity = nil
        if callInfo.targetSymbolId then
            calleeEntity = findEntityBySymbolId(ctx, callInfo.targetSymbolId)
        else
            -- 如果没有直接的目标符号ID，尝试通过名称查找
            calleeEntity = findEntityByNameAndType(ctx, resolvedCallName, 'function')
        end
        
        -- 为每个可能的类型组合创建调用关系
        if callerEntity and calleeEntity then
            -- 创建所有可能的类型组合关系
            for _, callerTypeName in ipairs(callerPossibleTypeNames) do
                for _, calleeTypeName in ipairs(calleePossibleTypeNames) do
                    context.addRelation(ctx, 'calls', callerEntity.id, calleeEntity.id, {
                        relationship = 'function_call',
                        fromName = callerTypeName,
                        toName = calleeTypeName,
                        callName = resolvedCallName or callInfo.callName,
                        callType = callType,
                        parameterCount = #(callInfo.parameters or {}),
                        parameterTypes = callInfo.parameters or {},
                        sourceLocation = {
                            uri = callInfo.location.uri,
                            module = callInfo.location.module,
                            file = callInfo.location.uri and furi.decode(callInfo.location.uri) or nil,
                            line = callInfo.location.line,
                            column = callInfo.location.column
                        }
                    })
                    
                    functionCallCount = functionCallCount + 1
                    context.debug(ctx, "函数调用关系: %s -> %s", callerTypeName, calleeTypeName)
                end
            end
        elseif callerEntity and (callType == 'external_call' or callType == 'class_method') then
            -- 处理外部调用和类方法调用
            local relationshipType = callType == 'class_method' and 'class_method_call' or 'external_call'
            for _, callerTypeName in ipairs(callerPossibleTypeNames) do
                context.addRelation(ctx, 'calls', callerEntity.id, 'external', {
                    relationship = relationshipType,
                    fromName = callerTypeName,
                    toName = resolvedCallName or callInfo.callName,
                    callName = resolvedCallName or callInfo.callName,
                    callType = callType,
                    parameterCount = #(callInfo.parameters or {}),
                    parameterTypes = callInfo.parameters or {},
                    sourceLocation = {
                        uri = callInfo.location.uri,
                        module = callInfo.location.module,
                        file = callInfo.location.uri and furi.decode(callInfo.location.uri) or nil,
                        line = callInfo.location.line,
                        column = callInfo.location.column
                    }
                })
                
                functionCallCount = functionCallCount + 1
                local callTypeDesc = callType == 'class_method' and "类方法调用" or "外部函数调用"
                context.debug(ctx, "%s: %s -> %s", callTypeDesc, callerTypeName, resolvedCallName or callInfo.callName)
            end
        else
            context.debug(ctx, "未找到调用关系实体: %s -> %s (源ID: %s, 目标ID: %s, 调用类型: %s)", 
                callInfo.callName, resolvedCallName or "nil", 
                callInfo.sourceSymbolId or "nil", callInfo.targetSymbolId or "nil", callType or "unknown")
        end
        
        ::continue::
    end
    
    context.debug(ctx, "处理了 %d 个函数调用关系", functionCallCount)
    return functionCallCount
end

-- 处理类型实例化关系
local function processTypeInstantiations(ctx)
    local instantiationCount = 0
    
    for _, callInfo in ipairs(ctx.calls.callInfos) do
        local callName = callInfo.callName
        
        -- 检查是否为构造函数调用
        if callName:find(':new') or callName:find('%.new') then
            local className = nil
            if callName:find(':new') then
                className = callName:match('([^:]+):new')
            elseif callName:find('%.new') then
                className = callName:match('([^.]+)%.new')
            end
            
            if className then
                -- 解析别名
                local resolvedClassName = className
                if ctx.symbols.aliases then
                    for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
                        if aliasInfo.type == "class_alias" and aliasName == className then
                            resolvedClassName = aliasInfo.targetName
                            break
                        end
                    end
                end
                
                -- 查找类实体
                local classEntity = findEntityByNameAndType(ctx, resolvedClassName, 'class')
                
                -- 查找调用者实体
                local callerEntity = nil
                if callInfo.sourceSymbolId then
                    callerEntity = findEntityBySymbolId(ctx, callInfo.sourceSymbolId)
                end
                
                if classEntity and callerEntity then
                    -- 创建类型实例化关系
                    context.addRelation(ctx, 'instantiates', callerEntity.id, classEntity.id, {
                        relationship = 'type_instantiation',
                        originalClassName = className,
                        resolvedClassName = resolvedClassName,
                        sourceLocation = {
                            file = callInfo.location.uri and furi.decode(callInfo.location.uri) or nil,
                            line = callInfo.location.line,
                            column = callInfo.location.column
                        }
                    })
                    
                    instantiationCount = instantiationCount + 1
                    context.debug(ctx, "类型实例化关系: %s -> %s", callerEntity.name, classEntity.name)
                end
            end
        end
    end
    
    context.debug(ctx, "处理了 %d 个类型实例化关系", instantiationCount)
    return instantiationCount
end

-- 处理模块依赖关系
local function processModuleDependencies(ctx)
    local dependencyCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.REFERENCE then
            -- 查找源模块实体
            local sourceModuleEntity = nil
            if symbol.parent then
                sourceModuleEntity = findEntityBySymbolId(ctx, symbol.parent.id)
            end
            
            -- 查找目标模块实体
            local targetModuleEntity = nil
            if symbol.target then
                targetModuleEntity = findEntityBySymbolId(ctx, symbol.target)
            end
            
            if sourceModuleEntity and targetModuleEntity then
                -- 创建模块依赖关系
                context.addRelation(ctx, 'depends_on', sourceModuleEntity.id, targetModuleEntity.id, {
                    relationship = 'module_dependency',
                    requireType = 'require', -- 可以从AST中获取更精确的类型
                    modulePath = symbol.name,
                    sourceLocation = {
                        file = nil, -- 需要从AST中获取
                        line = 1,
                        column = 1
                    }
                })
                
                dependencyCount = dependencyCount + 1
                context.debug(ctx, "模块依赖关系: %s -> %s", sourceModuleEntity.name, targetModuleEntity.name)
            end
        end
    end
    
    context.debug(ctx, "处理了 %d 个模块依赖关系", dependencyCount)
    return dependencyCount
end

-- 处理变量赋值关系
local function processVariableAssignments(ctx)
    local assignmentCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.VARIABLE and symbol.related and next(symbol.related) then
            -- 查找变量实体
            local variableEntity = findEntityBySymbolId(ctx, symbolId)
            
            if variableEntity then
                for relatedId, _ in pairs(symbol.related) do
                    -- 查找相关实体
                    local relatedEntity = findEntityBySymbolId(ctx, relatedId)
                    
                    if relatedEntity then
                        -- 创建变量赋值关系
                        context.addRelation(ctx, 'assigned_from', variableEntity.id, relatedEntity.id, {
                            relationship = 'variable_assignment',
                            sourceLocation = {
                                file = nil, -- 需要从AST中获取
                                line = 1,
                                column = 1
                            }
                        })
                        
                        assignmentCount = assignmentCount + 1
                        context.debug(ctx, "变量赋值关系: %s <- %s", variableEntity.name, relatedEntity.name)
                    end
                end
            end
        end
    end
    
    context.debug(ctx, "处理了 %d 个变量赋值关系", assignmentCount)
    return assignmentCount
end

-- 主分析函数
function phase4.analyze(ctx)
    print("🔍 第四阶段：函数调用关系分析")
    
    -- 重置节点去重状态
    context.resetProcessedNodes(ctx, "Phase4")
    
    -- 初始化节点跟踪器
    if ctx.config.enableNodeTracking then
        tracker4 = nodeTracker.new("phase4_calls")
    end
    
    print("  分析调用关系...")
    
    -- 处理各类关系
    local functionCallCount = processFunctionCalls(ctx)
    local instantiationCount = processTypeInstantiations(ctx)
    local dependencyCount = processModuleDependencies(ctx)
    local assignmentCount = processVariableAssignments(ctx)
    
    -- 统计信息
    local totalRelations = #ctx.relations
    
    print(string.format("  ✅ 函数调用关系分析完成:"))
    print(string.format("    新增关系: %d", functionCallCount + instantiationCount + dependencyCount + assignmentCount))
    print(string.format("    函数调用: %d, 类型实例化: %d, 模块依赖: %d, 变量赋值: %d", 
        functionCallCount, instantiationCount, dependencyCount, assignmentCount))
    print(string.format("    总关系数: %d", totalRelations))
    
    -- 打印节点跟踪统计
    if ctx.config.enableNodeTracking and tracker4 then
        nodeTracker.printStatistics(tracker4)
    end
end

return phase4 