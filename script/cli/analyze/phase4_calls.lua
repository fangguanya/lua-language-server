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

-- 处理函数调用关系
local function processFunctionCalls(ctx)
    local functionCallCount = 0
    
    context.debug(ctx, "处理函数调用关系，共 %d 个调用记录", #ctx.calls.callInfos)
    
    for _, callInfo in ipairs(ctx.calls.callInfos) do
        -- 简化处理：直接使用符号ID进行关系建立
        
        -- 查找调用者实体
        local callerEntity = nil
        if callInfo.sourceSymbolId then
            callerEntity = findEntityBySymbolId(ctx, callInfo.sourceSymbolId)
        end
        
        -- 查找被调用者实体
        local calleeEntity = nil
        if callInfo.targetSymbolId then
            calleeEntity = findEntityBySymbolId(ctx, callInfo.targetSymbolId)
        end
        -- 如果没有目标符号ID，跳过这个调用（可能是外部函数调用）
        
        -- 创建调用关系（简化版本，不重复创建相同关系）
        if callerEntity and calleeEntity then
            context.addRelation(ctx, 'calls', callerEntity.symbolId, calleeEntity.symbolId)
            functionCallCount = functionCallCount + 1
            context.debug(ctx, "函数调用关系: %s -> %s", callerEntity.symbolId, calleeEntity.symbolId)
        else
            context.debug(ctx, "未找到调用关系实体: %s (源ID: %s, 目标ID: %s)", 
                callInfo.callName, 
                callInfo.sourceSymbolId or "nil", callInfo.targetSymbolId or "nil")
        end
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
                
                -- 查找调用者实体
                local callerEntity = nil
                if callInfo.sourceSymbolId then
                    callerEntity = findEntityBySymbolId(ctx, callInfo.sourceSymbolId)
                    context.debug(ctx, "查找调用者实体: %s -> %s", callInfo.sourceSymbolId, callerEntity and callerEntity.symbolId or "nil")
                end
                
                if classEntity and callerEntity then
                    -- 创建类型引用关系（而不是实例化关系）
                    context.addRelation(ctx, 'references', callerEntity.symbolId, classEntity.symbolId)
                    
                    referenceCount = referenceCount + 1
                    context.debug(ctx, "类型引用关系: %s -> %s (构造函数调用: %s)", callerEntity.symbolId, classEntity.symbolId, constructorType)
                else
                    context.debug(ctx, "未能创建类型引用关系 - 类实体: %s, 调用者实体: %s", 
                        classEntity and classEntity.symbolId or "nil", 
                        callerEntity and callerEntity.symbolId or "nil")
                end
            end
        end
    end
    
    context.debug(ctx, "处理了 %d 个类型引用关系", referenceCount)
    return referenceCount
end

-- 处理模块依赖关系
local function processModuleDependencies(ctx)
    local dependencyCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.REFERENCE then
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
                context.addRelation(ctx, 'depends_on', sourceModuleEntity.symbolId, targetModuleEntity.symbolId)
                
                dependencyCount = dependencyCount + 1
                context.debug(ctx, "模块依赖关系: %s -> %s", sourceModuleEntity.symbolId, targetModuleEntity.symbolId)
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
                        context.addRelation(ctx, 'assigned_from', variableEntity.symbolId, relatedEntity.symbolId)
                        
                        assignmentCount = assignmentCount + 1
                        context.debug(ctx, "变量赋值关系: %s <- %s", variableEntity.symbolId, relatedEntity.symbolId)
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
    local dependencyCount = processModuleDependencies(ctx)
    local assignmentCount = processVariableAssignments(ctx)
    
    -- 统计信息
    local totalRelations = #ctx.relations
    
    print(string.format("  ✅ 函数调用关系分析完成:"))
    print(string.format("    新增关系: %d", functionCallCount + referenceCount + dependencyCount + assignmentCount))
    print(string.format("    函数调用: %d, 类型引用: %d, 模块依赖: %d, 变量赋值: %d", 
        functionCallCount, referenceCount, dependencyCount, assignmentCount))
    print(string.format("    总关系数: %d", totalRelations))
    
    -- 打印节点跟踪统计
    if ctx.config.enableNodeTracking and tracker4 then
        nodeTracker.printStatistics(tracker4)
    end
end

return phase4 