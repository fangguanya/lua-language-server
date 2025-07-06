---
--- Created by fanggang
--- DateTime: 2025/7/6 17:27
---
-- analyze/phase2_inference.lua
-- 第二阶段：类型推断和call信息记录

local files = require 'files'
local guide = require 'parser.guide'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'
local nodeTracker = require 'cli.analyze.node_tracker'

local phase2 = {}

-- 节点跟踪器
local tracker1 = nil
local tracker2 = nil

-- 记录call信息
local function recordCallInfo(ctx, uri, moduleId, source)
    local callName = utils.getCallName(source)
    if not callName then
        return
    end
    
    local position = utils.getNodePosition(source)
    
    -- 查找调用者的符号ID
    local sourceSymbolId = nil
    local currentScope = context.findCurrentScope(ctx, source)
    local currentMethod = context.findCurrentMethod(ctx, source)
    
    if currentMethod then
        sourceSymbolId = currentMethod.id
    elseif currentScope then
        sourceSymbolId = currentScope.id
    end
    
    -- 查找目标函数的符号ID
    local targetSymbolId, targetSymbol = context.findFunctionSymbol(ctx, callName)
    
    -- 如果直接查找失败，尝试通过别名查找
    if not targetSymbolId then
        local className, methodName = callName:match('([^.]+)%.(.+)')
        if className and methodName then
            -- 查找类别名（从第1阶段的符号表中查找）
            local classId, classSymbol = context.findSymbol(ctx, function(symbol)
                return symbol.type == SYMBOL_TYPE.CLASS and symbol.name == className
            end)
            
            if classSymbol then
                local realFuncName = classSymbol.name .. '.' .. methodName
                targetSymbolId, targetSymbol = context.findFunctionSymbol(ctx, realFuncName)
            end
        end
    end
    
    -- 分析参数信息
    local parameters = {}
    if source.args then
        for i, arg in ipairs(source.args) do
            local param = {
                index = i,
                type = nil,
                symbolId = nil,
                value = nil
            }
            
            -- 分析参数类型
            if arg.type == 'getlocal' or arg.type == 'getglobal' then
                param.type = 'variable_reference'
                local varName = utils.getNodeName(arg)
                if varName then
                    param.symbolId, _ = context.findVariableSymbol(ctx, varName, currentScope)
                    param.value = varName
                end
            elseif arg.type == 'string' then
                param.type = 'string_literal'
                param.value = arg[1]
            elseif arg.type == 'number' then
                param.type = 'number_literal'
                param.value = arg[1]
            elseif arg.type == 'boolean' then
                param.type = 'boolean_literal'
                param.value = arg[1]
            elseif arg.type == 'table' then
                param.type = 'table_literal'
                param.value = 'table'
            elseif arg.type == 'call' then
                param.type = 'function_call'
                param.value = utils.getCallName(arg)
            else
                param.type = 'other'
                param.value = arg.type
            end
            
            table.insert(parameters, param)
        end
    end
    
    -- 创建call信息记录
    local callInfo = {
        callName = callName,
        sourceSymbolId = sourceSymbolId,
        targetSymbolId = targetSymbolId,
        parameters = parameters,
        location = {
            uri = uri,
            module = moduleId,
            line = position.line,
            column = position.column
        },
        timestamp = os.time()
    }
    
    -- 添加到context中
    context.addCallInfo(ctx, callInfo)
    
    context.debug(ctx, "📞 记录call信息: %s (源: %s, 目标: %s, 参数: %d)", 
        callName, sourceSymbolId or "nil", targetSymbolId or "nil", #parameters)
end

-- 第1轮操作：遍历所有AST，记录call信息
local function recordAllCallInfos(ctx)
    local uris = context.getFiles(ctx)
    local totalFiles = #uris
    
    print(string.format("  📞 第1轮操作：遍历所有AST，记录call信息"))
    print(string.format("    发现 %d 个Lua文件", totalFiles))
    
    -- 初始化节点跟踪器
    if ctx.config.enableNodeTracking then
        tracker1 = nodeTracker.new("phase2_round1")
    end
    
    for i, uri in ipairs(uris) do
        -- 从context中获取模块信息，而不是重新读取文件
        local module = ctx.uriToModule[uri]
        if module and module.ast then
            local moduleId = utils.getModulePath(uri, ctx.rootUri)
            
            -- 遍历所有调用节点
            guide.eachSource(module.ast, function(source)
                -- 记录节点处理
                if tracker1 then
                    nodeTracker.recordNode(tracker1, source)
                end
                
                if source.type == 'call' then
                    recordCallInfo(ctx, uri, moduleId, source)
                end
            end)
        end
        
        -- 显示进度
        if i % 10 == 0 or i == totalFiles then
            print(string.format("    进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100))
        end
    end
    
    print(string.format("  ✅ call信息记录完成: 总计 %d 个调用", ctx.calls.callStatistics.totalCalls))
    print(string.format("    已解析: %d, 未解析: %d", 
        ctx.calls.callStatistics.resolvedCalls, ctx.calls.callStatistics.unresolvedCalls))
end

-- 添加类型到possibles数组，确保去重和别名处理
local function addTypeToPossibles(ctx, symbol, newType)
    if not symbol.possibles then
        symbol.possibles = {}
    end
    
    -- 如果新类型为空，直接返回
    if not newType or newType == "" then
        return false
    end
    
    -- 解析别名，获取最终类型
    local finalType = newType
    if ctx.symbols.aliases then
        for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
            if aliasName == newType then
                finalType = aliasInfo.targetName or aliasInfo.target or newType
                break
            end
        end
    end
    
    -- 检查是否已存在（包括原类型和最终类型）
    for _, existingType in pairs(symbol.possibles) do
        if existingType == newType or existingType == finalType then
            return false -- 已存在，不添加
        end
    end
    
    -- 添加最终类型
    table.insert(symbol.possibles, finalType)
    return true
end

-- 基于reference关系进行类型传播
local function propagateTypesThroughReferences(ctx)
    local changes = true
    local iterations = 0
    local maxIterations = 10
    
    context.debug(ctx, "🔄 开始基于reference关系的类型传播")
    
    while changes and iterations < maxIterations do
        changes = false
        iterations = iterations + 1
        
        context.debug(ctx, "  第%d轮类型传播", iterations)
        
        -- 遍历所有符号的引用关系
        for symbolId, symbol in pairs(ctx.symbols) do
            if symbol.refs and next(symbol.refs) then
                for refId, _ in pairs(symbol.refs) do
                    local refSymbol = ctx.symbols[refId]
                    if refSymbol then
                        -- 双向类型传播
                        -- 1. 从refSymbol传播到symbol
                        if refSymbol.possibles and next(refSymbol.possibles) then
                            for _, possibleType in pairs(refSymbol.possibles) do
                                if addTypeToPossibles(ctx, symbol, possibleType) then
                                    changes = true
                                end
                            end
                        elseif refSymbol.inferredType then
                            -- 兼容旧的inferredType字段
                            if addTypeToPossibles(ctx, symbol, refSymbol.inferredType) then
                                changes = true
                            end
                        end
                        
                        -- 2. 从symbol传播到refSymbol
                        if symbol.possibles and next(symbol.possibles) then
                            for _, possibleType in pairs(symbol.possibles) do
                                if addTypeToPossibles(ctx, refSymbol, possibleType) then
                                    changes = true
                                end
                            end
                        elseif symbol.inferredType then
                            -- 兼容旧的inferredType字段
                            if addTypeToPossibles(ctx, refSymbol, symbol.inferredType) then
                                changes = true
                            end
                        end
                    end
                end
            end
        end
    end
    
    context.debug(ctx, "✅ 类型传播完成，共%d轮迭代", iterations)
end

-- 基于call信息进行类型推断
local function inferTypesFromCalls(ctx)
    local inferredCount = 0
    
    context.debug(ctx, "🔄 开始基于call信息的类型推断")
    
    if not ctx.calls then
        context.debug(ctx, "❌ 没有找到call信息")
        return
    end
    
    for _, callInfo in pairs(ctx.calls) do
        if callInfo.method then
            -- 通过方法调用推断类型
            local sourceSymbol = ctx.symbols[callInfo.source_symbolid]
            if sourceSymbol then
                local inferredType = nil
                
                -- 查找拥有该方法的类
                for className, classSymbol in pairs(ctx.classes) do
                    if classSymbol.methods then
                        for methodName, _ in pairs(classSymbol.methods) do
                            if methodName == callInfo.method then
                                inferredType = className
            break
        end
    end
                    end
                    if inferredType then break end
                end
                
                if inferredType then
                    if addTypeToPossibles(ctx, sourceSymbol, inferredType) then
                        context.debug(ctx, "    通过方法推断类型: %s -> %s (方法: %s)", 
                            sourceSymbol.name or "unknown", inferredType, callInfo.method)
                        inferredCount = inferredCount + 1
                    end
                end
            end
        end
    end
    
    context.debug(ctx, "✅ 基于call信息的类型推断完成，推断了%d个类型", inferredCount)
end

-- 建立类型间关系
local function buildTypeRelations(ctx)
    local relationCount = 0
    
    context.debug(ctx, "🔄 开始建立类型间关系")
    
    if not ctx.relations then
        ctx.relations = {}
    end
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.possibles and next(symbol.possibles) then
            for _, possibleType in pairs(symbol.possibles) do
                -- 解析别名，获取最终类型
                local finalType = possibleType
                local aliasTarget = nil
                
                if ctx.symbols.aliases then
                    for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
                        if aliasName == possibleType then
                            finalType = aliasInfo.targetName or aliasInfo.target or possibleType
                            aliasTarget = finalType
                            break
                        end
                    end
                end
                
                -- 建立类型关系
                local relation = {
                    type = "type_relation",
                    from = symbol.name or symbolId,
                    to = finalType,
                    aliasTarget = aliasTarget
                }
                
                table.insert(ctx.relations, relation)
                relationCount = relationCount + 1
                
                context.debug(ctx, "    建立类型关系: %s -> %s (别名: %s)", 
                    relation.from, relation.to, aliasTarget or "nil")
            end
        end
    end
    
    context.debug(ctx, "✅ 类型间关系建立完成，共%d个关系", relationCount)
    return relationCount
end

-- 建立函数间调用关系
local function buildFunctionCallRelations(ctx)
    context.debug(ctx, "🔄 开始建立函数间调用关系")
    
    local functionRelationCount = 0
    
    -- 基于call信息建立函数调用关系
    for _, callInfo in ipairs(ctx.calls.callInfos) do
        if callInfo.sourceSymbolId and callInfo.targetSymbolId then
            local sourceSymbol = ctx.symbols[callInfo.sourceSymbolId]
            local targetSymbol = ctx.symbols[callInfo.targetSymbolId]
            
            if sourceSymbol and targetSymbol then
                -- 创建函数调用关系
                local relationId = context.addRelation(ctx, 'function_call', 
                    callInfo.sourceSymbolId, callInfo.targetSymbolId, {
                    relationship = 'function_invocation',
                    fromName = sourceSymbol.aliasTargetName or sourceSymbol.name,  -- 使用最终名称
                    toName = targetSymbol.aliasTargetName or targetSymbol.name,    -- 使用最终名称
                    callName = callInfo.callName,
                    parameterCount = #(callInfo.parameters or {}),
                    parameterTypes = {},
                    sourceLocation = {
                        uri = callInfo.location.uri,
                        module = callInfo.location.module,
                        line = callInfo.location.line,
                        column = callInfo.location.column
                    }
                })
                
                -- 记录参数类型信息
                local relation = ctx.relations[#ctx.relations]  -- 刚添加的关系
                if callInfo.parameters then
                    for i, param in ipairs(callInfo.parameters) do
                        if param.symbolId then
                            local paramSymbol = ctx.symbols[param.symbolId]
                            if paramSymbol then
                                relation.metadata.parameterTypes[i] = {
                                    type = param.type,
                                    inferredType = paramSymbol.inferredType,
                                    aliasTargetName = paramSymbol.aliasTargetName or paramSymbol.name
                                }
                            end
                        else
                            relation.metadata.parameterTypes[i] = {
                                type = param.type,
                                value = param.value
                            }
                        end
                    end
                end
                
                functionRelationCount = functionRelationCount + 1
                context.debug(ctx, "    建立函数关系: %s -> %s (调用: %s)", 
                    sourceSymbol.aliasTargetName or sourceSymbol.name, 
                    targetSymbol.aliasTargetName or targetSymbol.name, 
                    callInfo.callName)
            end
        end
    end
    
    context.debug(ctx, "✅ 函数间调用关系建立完成，共%d个关系", functionRelationCount)
    return functionRelationCount
end

-- 建立引用关系
local function buildReferenceRelations(ctx)
    context.debug(ctx, "🔄 开始建立引用关系")
    
    local referenceRelationCount = 0
    
    -- 基于reference关系建立关系
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.refs and next(symbol.refs) then
            for refId, _ in pairs(symbol.refs) do
                local refSymbol = ctx.symbols[refId]
                if refSymbol and symbolId ~= refId then
                    -- 创建引用关系
                    local relationId = context.addRelation(ctx, 'reference', symbolId, refId, {
                        relationship = 'symbol_reference',
                        fromName = symbol.aliasTargetName or symbol.name,  -- 使用最终名称
                        toName = refSymbol.aliasTargetName or refSymbol.name,  -- 使用最终名称
                        sourceLocation = {
                            line = symbol.position and symbol.position.line or 0,
                            column = symbol.position and symbol.position.column or 0
                        }
                    })
                    
                    referenceRelationCount = referenceRelationCount + 1
                    context.debug(ctx, "    建立引用关系: %s -> %s", 
                        symbol.aliasTargetName or symbol.name, 
                        refSymbol.aliasTargetName or refSymbol.name)
                end
            end
        end
    end
    
    context.debug(ctx, "✅ 引用关系建立完成，共%d个关系", referenceRelationCount)
    return referenceRelationCount
end

-- 第2轮操作：数据流分析
local function performDataFlowAnalysis(ctx)
    print(string.format("  🔄 第2轮操作：数据流分析"))
    
    -- 初始化节点跟踪器
    if ctx.config.enableNodeTracking then
        tracker2 = nodeTracker.new("phase2_round2")
    end
    
    -- 1. 基于reference和related关系进行类型传播
    propagateTypesThroughReferences(ctx)
    
    -- 2. 基于call信息进行类型推断
    inferTypesFromCalls(ctx)
    
    -- 3. 建立不同类型的关系
    local typeRelationCount = buildTypeRelations(ctx)
    local functionRelationCount = buildFunctionCallRelations(ctx)
    local referenceRelationCount = buildReferenceRelations(ctx)
    
    print(string.format("  ✅ 数据流分析完成:"))
    print(string.format("    类型关系: %d", typeRelationCount))
    print(string.format("    函数关系: %d", functionRelationCount))
    print(string.format("    引用关系: %d", referenceRelationCount))
    print(string.format("    总关系数: %d", ctx.statistics.totalRelations))
end

-- 第二阶段：类型推断和数据流分析
function phase2.analyze(ctx)
    print("🔄 开始第二阶段：类型推断和数据流分析")
    
    -- 第1轮操作：遍历AST记录call信息
    recordAllCallInfos(ctx)
    
    -- 第2轮操作：数据流分析
    performDataFlowAnalysis(ctx)
    
    -- 打印节点跟踪统计
    if ctx.config.enableNodeTracking then
        if tracker2 then
            tracker2:printStatistics()
        end
    end
    
    print("✅ 第二阶段完成")
end

return phase2 