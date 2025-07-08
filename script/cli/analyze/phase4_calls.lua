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

-- 删除了系统库检查函数

-- 删除了复杂的类型推断函数，现在直接使用符号ID进行关系建立

-- 删除了复杂的调用解析函数

-- 删除了不再使用的复杂类型推断函数

-- 删除了别名解析函数

-- 查找实体通过符号ID
local function findEntityBySymbolId(ctx, symbolId)
    for _, entity in ipairs(ctx.entities) do
        if entity.symbolId == symbolId then
            return entity
        end
    end
    return nil
end

-- 查找实体通过符号名称和类型（通过符号表查找）
local function findEntityByNameAndType(ctx, name, entityType)
    -- 通过符号表查找对应的符号ID，然后查找entity
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.name == name and 
           ((entityType == 'function' and symbol.type == SYMBOL_TYPE.METHOD) or
            (entityType == 'class' and symbol.type == SYMBOL_TYPE.CLASS) or
            (entityType == 'module' and symbol.type == SYMBOL_TYPE.MODULE) or
            (entityType == 'variable' and symbol.type == SYMBOL_TYPE.VARIABLE)) then
            return findEntityBySymbolId(ctx, symbolId)
        end
    end
    return nil
end

-- 追溯local变量的类型，返回类型对应的entity
local function traceLocalVariableType(ctx, localSymbol)
    if not localSymbol or not localSymbol.isLocal then
        return nil
    end
    
    context.debug(ctx, "追溯local变量类型: %s (参数: %s)", localSymbol.name, tostring(localSymbol.isParameter))
    
    -- 方法1: 检查possibles字段（类型推断结果）
    if localSymbol.possibles and next(localSymbol.possibles) then
        for possibleType, _ in pairs(localSymbol.possibles) do
            context.debug(ctx, "  可能类型: %s", possibleType)
            
            -- 查找对应的类型entity
            local typeEntity = findEntityByNameAndType(ctx, possibleType, 'class')
            if typeEntity then
                context.debug(ctx, "  找到类型entity: %s -> %s", possibleType, typeEntity.id)
                return typeEntity
            end
        end
    end
    
    -- 方法2: 检查related关系（赋值关系）
    if localSymbol.related and next(localSymbol.related) then
        for relatedId, _ in pairs(localSymbol.related) do
            local relatedSymbol = ctx.symbols[relatedId]
            if relatedSymbol then
                context.debug(ctx, "  相关符号: %s (类型: %s)", relatedSymbol.name, relatedSymbol.type)
                
                -- 如果相关符号是类，直接返回其entity
                if relatedSymbol.type == SYMBOL_TYPE.CLASS then
                    local classEntity = findEntityBySymbolId(ctx, relatedId)
                    if classEntity then
                        context.debug(ctx, "  通过related找到类型: %s -> %s", relatedSymbol.name, classEntity.id)
                        return classEntity
                    end
                end
                
                -- 如果相关符号有类型信息，递归查找
                if relatedSymbol.possibles and next(relatedSymbol.possibles) then
                    for possibleType, _ in pairs(relatedSymbol.possibles) do
                        local typeEntity = findEntityByNameAndType(ctx, possibleType, 'class')
                        if typeEntity then
                            context.debug(ctx, "  通过related的类型找到: %s -> %s", possibleType, typeEntity.id)
                            return typeEntity
                        end
                    end
                end
            end
        end
    end
    
    -- 方法3: 检查aliasTargetName
    if localSymbol.aliasTargetName then
        context.debug(ctx, "  别名目标: %s", localSymbol.aliasTargetName)
        local typeEntity = findEntityByNameAndType(ctx, localSymbol.aliasTargetName, 'class')
        if typeEntity then
            context.debug(ctx, "  通过别名找到类型: %s -> %s", localSymbol.aliasTargetName, typeEntity.id)
            return typeEntity
        end
    end
    
    context.debug(ctx, "  未找到local变量的类型: %s", localSymbol.name)
    return nil
end

-- 处理函数调用关系
local function processFunctionCalls(ctx)
    local functionCallCount = 0
    
    context.debug(ctx, "处理函数调用关系，共 %d 个调用记录", #ctx.calls.callInfos)
    
    for _, callInfo in ipairs(ctx.calls.callInfos) do
        -- 处理调用者（源符号）
        local callerEntity = nil
        if callInfo.sourceSymbolId then
            local sourceSymbol = ctx.symbols[callInfo.sourceSymbolId]
            if sourceSymbol then
                if sourceSymbol.isLocal then
                    -- 如果是local变量，尝试追溯到其类型
                    callerEntity = traceLocalVariableType(ctx, sourceSymbol)
                    if callerEntity then
                        context.debug(ctx, "local变量调用追溯到类型: %s -> %s", sourceSymbol.name, callerEntity.id)
                    else
                        context.debug(ctx, "跳过无法追溯类型的local符号调用: %s", sourceSymbol.name)
                        goto continue
                    end
                else
                    -- 非local变量，直接查找entity
                    callerEntity = findEntityBySymbolId(ctx, callInfo.sourceSymbolId)
                end
            end
        end
        
        -- 处理被调用者（目标符号）
        local calleeEntity = nil
        if callInfo.targetSymbolId then
            local targetSymbol = ctx.symbols[callInfo.targetSymbolId]
            if targetSymbol then
                if targetSymbol.isLocal then
                    -- 如果是local变量，尝试追溯到其类型
                    callerEntity = traceLocalVariableType(ctx, targetSymbol)
                    if callerEntity then
                        context.debug(ctx, "local变量调用《》追溯到类型: %s -> %s", targetSymbol.name, callerEntity.id)
                    else
                        context.debug(ctx, "跳过无法追溯类型《》的local符号调用: %s", targetSymbol.name)
                        goto continue
                    end
                else
                    -- 非local符号，直接查找entity
                    calleeEntity = findEntityBySymbolId(ctx, callInfo.targetSymbolId)
                end
            end
        end
        
        -- 创建调用关系
        if callerEntity and calleeEntity then
            context.addRelation(ctx, 'calls', callerEntity.id, calleeEntity.id)
            functionCallCount = functionCallCount + 1
            context.debug(ctx, "函数调用关系: %s -> %s", callerEntity.id, calleeEntity.id)
        else
            context.debug(ctx, "未找到调用关系实体: %s (源ID: %s, 目标ID: %s)", 
                callInfo.callName, 
                callInfo.sourceSymbolId or "nil", callInfo.targetSymbolId or "nil")
        end
        
        ::continue::
    end
    
    context.debug(ctx, "处理了 %d 个函数调用关系", functionCallCount)
    return functionCallCount
end

-- 处理类型引用关系（原类型实例化关系）
local function processTypeReferences(ctx)
    local referenceCount = 0
    
    context.debug(ctx, "处理类型引用关系，共 %d 个调用记录", #ctx.calls.callInfos)
    
    for _, callInfo in ipairs(ctx.calls.callInfos) do
        local callName = callInfo.callName
        
        context.debug(ctx, "检查调用: %s", callName)
        
        -- 检查是否为构造函数调用 (xxx.new 或 xxx:new)
        if callName:find(':new') or callName:find('%.new') then
            local className = nil
            local constructorType = nil
            
            if callName:find(':new') then
                className = callName:match('([^:]+):new')
                constructorType = 'method_constructor'
                context.debug(ctx, "发现方法构造函数调用: %s -> %s", callName, className)
            elseif callName:find('%.new') then
                className = callName:match('([^.]+)%.new')
                constructorType = 'static_constructor'
                context.debug(ctx, "发现静态构造函数调用: %s -> %s", callName, className)
            end
            
            if className then
                -- 解析别名
                local resolvedClassName = className
                if ctx.symbols.aliases then
                    for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
                        if aliasInfo.type == "class_alias" and aliasName == className then
                            resolvedClassName = aliasInfo.targetName
                            context.debug(ctx, "解析类别名: %s -> %s", className, resolvedClassName)
                            break
                        end
                    end
                end
                
                -- 查找类实体
                local classEntity = findEntityByNameAndType(ctx, resolvedClassName, 'class')
                if not classEntity then
                    -- 尝试查找原始类名
                    classEntity = findEntityByNameAndType(ctx, className, 'class')
                    context.debug(ctx, "尝试查找原始类名: %s", className)
                end
                
                -- 处理调用者实体
                local callerEntity = nil
                if callInfo.sourceSymbolId then
                    local sourceSymbol = ctx.symbols[callInfo.sourceSymbolId]
                    if sourceSymbol then
                        if sourceSymbol.isLocal then
                            -- 如果是local变量，尝试追溯到其类型
                            callerEntity = traceLocalVariableType(ctx, sourceSymbol)
                            if callerEntity then
                                context.debug(ctx, "local变量类型引用追溯到类型: %s -> %s", sourceSymbol.name, callerEntity.id)
                            else
                                context.debug(ctx, "跳过无法追溯类型的local符号类型引用: %s", sourceSymbol.name)
                                goto continue_type_ref
                            end
                        else
                            -- 非local变量，直接查找entity
                            callerEntity = findEntityBySymbolId(ctx, callInfo.sourceSymbolId)
                            context.debug(ctx, "查找调用者实体: %s -> %s", callInfo.sourceSymbolId, callerEntity and callerEntity.id or "nil")
                        end
                    end
                end
                
                if classEntity and callerEntity then
                    -- 创建类型引用关系（而不是实例化关系）
                    context.addRelation(ctx, 'references', callerEntity.id, classEntity.id)
                    
                    referenceCount = referenceCount + 1
                    context.debug(ctx, "类型引用关系: %s -> %s (构造函数调用: %s)", callerEntity.id, classEntity.id, constructorType)
                else
                    context.debug(ctx, "未能创建类型引用关系 - 类实体: %s, 调用者实体: %s", 
                        classEntity and classEntity.id or "nil", 
                        callerEntity and callerEntity.id or "nil")
                end
            end
        end
        
        ::continue_type_ref::
    end
    
    context.debug(ctx, "处理了 %d 个类型引用关系", referenceCount)
    return referenceCount
end

-- 处理模块依赖关系
local function processModuleDependencies(ctx)
    local dependencyCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.REFERENCE then
            -- 排除local引用（通常不会有local的require，直接跳过）
            if symbol.isLocal then
                context.debug(ctx, "跳过local引用的依赖关系: %s", symbol.name)
                goto continue
            end
            
            -- 查找源模块实体
            local sourceModuleEntity = nil
            if symbol.parent then
                sourceModuleEntity = findEntityBySymbolId(ctx, symbol.parent)
            end
            
            -- 查找目标模块实体
            local targetModuleEntity = nil
            if symbol.target then
                targetModuleEntity = findEntityBySymbolId(ctx, symbol.target)
            end
            
            if sourceModuleEntity and targetModuleEntity then
                -- 创建模块依赖关系
                context.addRelation(ctx, 'depends_on', sourceModuleEntity.id, targetModuleEntity.id)
                
                dependencyCount = dependencyCount + 1
                context.debug(ctx, "模块依赖关系: %s -> %s", sourceModuleEntity.id, targetModuleEntity.id)
            end
        end
        
        ::continue::
    end
    
    context.debug(ctx, "处理了 %d 个模块依赖关系", dependencyCount)
    return dependencyCount
end

-- 处理变量赋值关系
local function processVariableAssignments(ctx)
    local assignmentCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.VARIABLE and symbol.related and next(symbol.related) then
            -- 处理变量实体
            local variableEntity = nil
            if symbol.isLocal then
                -- 如果是local变量，尝试追溯到其类型
                variableEntity = traceLocalVariableType(ctx, symbol)
                if not variableEntity then
                    context.debug(ctx, "跳过无法追溯类型的local变量赋值关系: %s", symbol.name)
                    goto continue
                end
            else
                -- 非local变量，直接查找entity
                variableEntity = findEntityBySymbolId(ctx, symbolId)
            end
            
            if variableEntity then
                for relatedId, _ in pairs(symbol.related) do
                    -- 检查相关符号是否是local
                    local relatedSymbol = ctx.symbols[relatedId]
                    if relatedSymbol and relatedSymbol.isLocal then
                        context.debug(ctx, "跳过与local符号的赋值关系: %s <- %s", symbol.name, relatedSymbol.name)
                        goto continue_related
                    end
                    
                    -- 查找相关实体
                    local relatedEntity = findEntityBySymbolId(ctx, relatedId)
                    
                    if relatedEntity then
                        -- 创建变量赋值关系
                        context.addRelation(ctx, 'assigned_from', variableEntity.id, relatedEntity.id)
                        
                        assignmentCount = assignmentCount + 1
                        context.debug(ctx, "变量赋值关系: %s <- %s", variableEntity.id, relatedEntity.id)
                    end
                    
                    ::continue_related::
                end
            end
        end
        
        ::continue::
    end
    
    context.debug(ctx, "处理了 %d 个变量赋值关系", assignmentCount)
    return assignmentCount
end

-- 处理成员访问关系
local function processMemberAccess(ctx)
    local accessCount = 0
    
    context.debug(ctx, "处理成员访问关系，共 %d 个访问记录", #ctx.memberAccess.accessInfos)
    
    for _, accessInfo in ipairs(ctx.memberAccess.accessInfos) do
        -- 处理对象实体
        local objectEntity = nil
        if accessInfo.objectSymbolId then
            local objectSymbol = ctx.symbols[accessInfo.objectSymbolId]
            if objectSymbol then
                if objectSymbol.isLocal then
                    -- 如果是local变量，尝试追溯到其类型
                    objectEntity = traceLocalVariableType(ctx, objectSymbol)
                    if objectEntity then
                        context.debug(ctx, "local变量成员访问追溯到类型: %s.%s -> %s", objectSymbol.name, accessInfo.memberName, objectEntity.id)
                    else
                        context.debug(ctx, "跳过无法追溯类型的local符号成员访问: %s.%s", objectSymbol.name, accessInfo.memberName)
                        goto continue
                    end
                else
                    -- 非local变量，直接查找entity
                    objectEntity = findEntityBySymbolId(ctx, accessInfo.objectSymbolId)
                end
            end
        end
        
        -- 处理成员实体
        local memberEntity = nil
        if accessInfo.memberSymbolId then
            local memberSymbol = ctx.symbols[accessInfo.memberSymbolId]
            if memberSymbol then
                if memberSymbol.isLocal then
                    -- 对local成员的访问直接跳过
                    context.debug(ctx, "跳过对local成员的访问: %s", memberSymbol.name)
                    goto continue
                else
                    -- 非local成员，直接查找entity
                    memberEntity = findEntityBySymbolId(ctx, accessInfo.memberSymbolId)
                end
            end
        end
        
        -- 创建成员访问关系
        if objectEntity and memberEntity then
            context.addRelation(ctx, 'accesses', objectEntity.id, memberEntity.id)
            accessCount = accessCount + 1
            context.debug(ctx, "成员访问关系: %s -> %s (类型: %s, 成员: %s)", 
                objectEntity.id, memberEntity.id, accessInfo.accessType, accessInfo.memberName)
        else
            context.debug(ctx, "未找到成员访问实体: %s.%s (对象ID: %s, 成员ID: %s)", 
                accessInfo.objectSymbolId or "nil", accessInfo.memberName or "nil",
                accessInfo.objectSymbolId or "nil", accessInfo.memberSymbolId or "nil")
        end
        
        ::continue::
    end
    
    context.debug(ctx, "处理了 %d 个成员访问关系", accessCount)
    return accessCount
end

-- 主分析函数
function phase4.analyze(ctx)
    print("🔍 第四阶段：函数调用关系分析")
    
    -- 获取缓存管理器（如果有的话）
    local cacheManager = ctx.cacheManager
    
    -- 重置节点去重状态
    context.resetProcessedNodes(ctx, "Phase4")
    
    -- 初始化节点跟踪器
    if ctx.config.enableNodeTracking then
        tracker4 = nodeTracker.new("phase4_calls")
    end
    
    print("  分析调用关系...")
    
    -- 调试：输出所有调用信息
    context.debug(ctx, "=== 调试：所有调用信息 ===")
    for i, callInfo in ipairs(ctx.calls.callInfos) do
        context.debug(ctx, "调用 %d: %s (源: %s, 目标: %s)", 
            i, callInfo.callName or "nil", 
            callInfo.sourceSymbolId or "nil", 
            callInfo.targetSymbolId or "nil")
    end
    context.debug(ctx, "=== 调试结束 ===")
    
    -- 处理各类关系
    local functionCallCount = processFunctionCalls(ctx)
    local referenceCount = processTypeReferences(ctx)
    
    -- 保存调用分析第一轮完成后的缓存
    if cacheManager and cacheManager.config.enabled then
        local progress = {
            step = "phase4_calls_complete",
            description = "函数调用分析完成",
            functionCallCount = functionCallCount,
            referenceCount = referenceCount
        }
        local cache_manager = require 'cli.analyze.cache_manager'
        cache_manager.saveCache(cacheManager, ctx, "phase4_calls", progress)
    end
    
    local dependencyCount = processModuleDependencies(ctx)
    local assignmentCount = processVariableAssignments(ctx)
    local memberAccessCount = processMemberAccess(ctx)
    
    -- 保存所有关系分析完成后的缓存
    if cacheManager and cacheManager.config.enabled then
        local progress = {
            step = "phase4_all_complete",
            description = "所有关系分析完成",
            functionCallCount = functionCallCount,
            referenceCount = referenceCount,
            dependencyCount = dependencyCount,
            assignmentCount = assignmentCount,
            memberAccessCount = memberAccessCount,
            totalRelations = #ctx.relations
        }
        local cache_manager = require 'cli.analyze.cache_manager'
        cache_manager.saveCache(cacheManager, ctx, "phase4_calls", progress)
    end
    
    -- 统计信息
    local totalRelations = #ctx.relations
    
    print(string.format("  ✅ 函数调用关系分析完成:"))
    print(string.format("    新增关系: %d", functionCallCount + referenceCount + dependencyCount + assignmentCount + memberAccessCount))
    print(string.format("    函数调用: %d, 类型引用: %d, 模块依赖: %d, 变量赋值: %d, 成员访问: %d", 
        functionCallCount, referenceCount, dependencyCount, assignmentCount, memberAccessCount))
    print(string.format("    总关系数: %d", totalRelations))
    
    -- 打印节点跟踪统计
    if ctx.config.enableNodeTracking and tracker4 then
        nodeTracker.printStatistics(tracker4)
    end
end

return phase4 