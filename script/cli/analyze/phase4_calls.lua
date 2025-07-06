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

local phase4 = {}

-- 节点跟踪器
local tracker4 = nil

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
        local resolvedCallName = resolveAliasedCallName(ctx, callInfo.callName)
        
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
        
        if callerEntity and calleeEntity then
            -- 创建函数调用关系
            context.addRelation(ctx, 'calls', callerEntity.id, calleeEntity.id, {
                relationship = 'function_call',
                originalCallName = callInfo.callName,
                resolvedCallName = resolvedCallName,
                parameterCount = #(callInfo.parameters or {}),
                sourceLocation = {
                    file = callInfo.location.uri and furi.decode(callInfo.location.uri) or nil,
                    line = callInfo.location.line,
                    column = callInfo.location.column
                }
            })
            
            functionCallCount = functionCallCount + 1
            context.debug(ctx, "函数调用关系: %s -> %s", callerEntity.name, calleeEntity.name)
        else
            context.debug(ctx, "未找到调用关系实体: %s -> %s (源ID: %s, 目标ID: %s)", 
                callInfo.callName, resolvedCallName, 
                callInfo.sourceSymbolId or "nil", callInfo.targetSymbolId or "nil")
        end
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