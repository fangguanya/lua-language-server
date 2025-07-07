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
local symbol = require 'cli.analyze.symbol'

local SYMBOL_TYPE = symbol.SYMBOL_TYPE

local phase2 = {}

-- 节点跟踪器
local tracker1 = nil
local tracker2 = nil

-- 获取符号的所有可能类型名称（严格基于数据流分析）
local function getAllPossibleTypeNames(ctx, symbolId)
    if not symbolId then
        return {}
    end
    
    local symbol = ctx.symbols[symbolId]
    if not symbol then
        return {}
    end
    
    local possibleTypes = {}
    
    -- 如果是方法，查找其所属的类或模块
    if symbol.type == SYMBOL_TYPE.METHOD then
        -- 查找父符号
        local parent = symbol.parent
        while parent do
            local parentSymbol = ctx.symbols[parent]
            if parentSymbol then
                if parentSymbol.type == SYMBOL_TYPE.CLASS then
                    table.insert(possibleTypes, parentSymbol.aliasTargetName or parentSymbol.name)
                elseif parentSymbol.type == SYMBOL_TYPE.MODULE then
                    table.insert(possibleTypes, parentSymbol.aliasTargetName or parentSymbol.name)
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
    
    return possibleTypes
end

-- 记录call信息
local function recordCallInfo(ctx, uri, moduleId, source, providedCallName)
    local callName = providedCallName or utils.getCallName(source)
    if not callName then
        -- 特殊处理getmethod类型的调用
        if source and source.type == 'call' and source.node and source.node.type == 'getmethod' then
            local objNode = source.node.node
            local methodNode = source.node.method
            local obj = utils.getNodeName(objNode)
            local method = utils.getNodeName(methodNode)
            
            if method then
                -- 如果obj为nil，尝试其他方式获取对象名
                if not obj and objNode then
                    if objNode.type == 'getlocal' then
                        obj = objNode[1]  -- 直接获取变量名
                    elseif objNode.type == 'getglobal' then
                        obj = objNode[1]  -- 直接获取全局变量名
                    elseif objNode.type == 'getfield' then
                        -- 可能是复杂的字段访问
                        local baseObj = utils.getNodeName(objNode.node)
                        local field = utils.getNodeName(objNode.field)
                        if baseObj and field then
                            obj = baseObj .. '.' .. field
                        end
                    end
                end
                
                if obj and method then
                    callName = obj .. ':' .. method
                end
            end
        end
        
        if not callName then
            return
        end
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
    
    -- 如果直接查找失败，说明符号不存在，记录为未解析调用
    -- 第一阶段已经建立了完整的符号表，如果找不到就是真的不存在
    
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
    
    -- 检查并建立模块间引用关系
    local sourceModule = nil
    local targetModule = nil
    
    -- 获取源符号所属的模块
    if sourceSymbolId then
        local sourceSymbol = ctx.symbols[sourceSymbolId]
        if sourceSymbol and sourceSymbol.module then
            sourceModule = sourceSymbol.module
        end
    end
    
    -- 获取目标符号所属的模块
    if targetSymbolId then
        local targetSymbol = ctx.symbols[targetSymbolId]
        if targetSymbol and targetSymbol.module then
            targetModule = targetSymbol.module
        end
    end
    
    -- 如果源模块和目标模块不同，建立模块间引用关系
    if sourceModule and targetModule and sourceModule ~= targetModule then
        context.addRelation(ctx, 'module_reference', sourceModule, targetModule)
        context.debug(ctx, "🔗 模块间引用: %s -> %s (通过调用 %s)", sourceModule, targetModule, callName)
    end
    
    -- 添加类型级别的调用信息（处理所有可能的类型组合）
    local sourcePossibleTypes = getAllPossibleTypeNames(ctx, sourceSymbolId)
    local targetPossibleTypes = getAllPossibleTypeNames(ctx, targetSymbolId)
    
    callInfo.typeCallInfos = {}
    
    -- 为每个可能的类型组合创建调用关系
    if #sourcePossibleTypes > 0 and #targetPossibleTypes > 0 then
        for _, sourceType in ipairs(sourcePossibleTypes) do
            for _, targetType in ipairs(targetPossibleTypes) do
                local typeCallInfo = {
                    sourceType = sourceType,
                    targetType = targetType,
                    callPattern = sourceType .. " -> " .. targetType .. " (" .. callName .. ")"
                }
                table.insert(callInfo.typeCallInfos, typeCallInfo)
                context.debug(ctx, "🎯 类型调用关系: %s", typeCallInfo.callPattern)
            end
        end
    elseif #sourcePossibleTypes > 0 then
        -- 只有源类型，目标未知
        for _, sourceType in ipairs(sourcePossibleTypes) do
            local typeCallInfo = {
                sourceType = sourceType,
                targetType = "unknown",
                callPattern = sourceType .. " -> unknown (" .. callName .. ")"
            }
            table.insert(callInfo.typeCallInfos, typeCallInfo)
            context.debug(ctx, "🎯 类型调用关系: %s", typeCallInfo.callPattern)
        end
    elseif #targetPossibleTypes > 0 then
        -- 只有目标类型，源未知
        for _, targetType in ipairs(targetPossibleTypes) do
            local typeCallInfo = {
                sourceType = "unknown",
                targetType = targetType,
                callPattern = "unknown -> " .. targetType .. " (" .. callName .. ")"
            }
            table.insert(callInfo.typeCallInfos, typeCallInfo)
            context.debug(ctx, "🎯 类型调用关系: %s", typeCallInfo.callPattern)
        end
    end
    
    -- 添加到context中
    context.addCallInfo(ctx, callInfo)
    
    context.debug(ctx, "📞 记录call信息: %s (源: %s, 目标: %s, 参数: %d)", 
        callName, sourceSymbolId or "nil", targetSymbolId or "nil", #parameters)
end

-- 第1轮操作：遍历所有AST，记录call信息
local function recordAllCallInfos(ctx)
    -- 重置节点去重状态
    context.resetProcessedNodes(ctx, "Phase2-Round1")
    
    local uris = context.getFiles(ctx)
    local totalFiles = #uris
    

    
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
                -- 每次处理新的源节点时，增加调用帧索引
                ctx.currentFrameIndex = ctx.currentFrameIndex + 1
                
                -- 记录节点处理
                if tracker1 then
                    nodeTracker.recordNode(tracker1, source)
                end
                
                -- 处理getmethod节点 - 这些可能是方法调用的一部分
                if source.type == 'getmethod' then
                    -- 检查这个getmethod是否是call的一部分
                    local parent = source.parent
                    if parent and parent.type == 'call' and parent.node == source then
                        -- 这是一个方法调用！直接处理
                        local objNode = source.node
                        local methodNode = source.method
                        local obj = utils.getNodeName(objNode)
                        local method = utils.getNodeName(methodNode)
                        

                        
                        if obj and method then
                            local callName = obj .. ':' .. method
                            recordCallInfo(ctx, uri, moduleId, parent, callName)
                        end
                    end
                end
                
                if source.type == 'call' then
                    recordCallInfo(ctx, uri, moduleId, source)
                end
            end)
        end
        

    end
    

end

-- 添加类型到possibles哈希表，确保去重和别名处理
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
    if symbol.possibles[newType] or symbol.possibles[finalType] then
        return false -- 已存在，不添加
    end
    
    -- 添加最终类型到哈希表
    symbol.possibles[finalType] = true
    return true
end

-- 基于reference关系进行类型传播
local function propagateTypesThroughReferences(ctx)
    local changes = true
    local iterations = 0
    local maxIterations = 2
    
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
                            for possibleType, _ in pairs(refSymbol.possibles) do
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
                            for possibleType, _ in pairs(symbol.possibles) do
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

-- 查找赋值目标变量（用于构造函数调用的类型推断）
local function findAssignmentTargets(ctx, callInfo)
    local targets = {}
    
    -- 这是一个简化的实现，实际需要通过AST分析来找到赋值语句
    -- 对于构造函数调用，我们需要找到形如 `local obj = player:new()` 的语句
    
    if callInfo.location and callInfo.location.uri then
        local uri = callInfo.location.uri
        local module = ctx.uriToModule[uri]
        
        if module and module.ast then
            -- 遍历AST查找赋值语句
            guide.eachSource(module.ast, function(source)
                -- 处理local变量赋值：local obj = player:new()
                if source.type == 'local' and source.value then
                    -- 检查是否是我们要找的调用
                    for i, value in ipairs(source.value) do
                        if value.type == 'call' then
                            local valueCallName = utils.getCallName(value)
                            if valueCallName == callInfo.callName then
                                -- 找到了匹配的赋值语句
                                local varName = source[i]
                                if varName then
                                    -- 查找对应的变量符号
                                    local currentScope = context.findCurrentScope(ctx, source)
                                    local varSymbolId, varSymbol = context.resolveName(ctx, varName, currentScope)
                                    if varSymbol then
                                        table.insert(targets, varSymbol)
                                        context.debug(ctx, "    找到local赋值目标: %s", varName)
                                    end
                                end
                            end
                        end
                    end
                end
                
                -- 处理成员赋值：self.x = player.new() 或 obj.field = player.new()
                if source.type == 'setfield' and source.value and source.value.type == 'call' then
                    local valueCallName = utils.getCallName(source.value)
                    if valueCallName == callInfo.callName then
                        -- 找到了匹配的成员赋值
                        local objName = utils.getNodeName(source.node)
                        local fieldName = utils.getNodeName(source.field)
                        
                        if objName and fieldName then
                            context.debug(ctx, "    找到成员赋值: %s.%s = %s", objName, fieldName, valueCallName)
                            
                            -- 查找对象符号
                            local currentScope = context.findCurrentScope(ctx, source)
                            local objSymbolId, objSymbol = context.resolveName(ctx, objName, currentScope)
                            
                            if objSymbol then
                                -- 查找或创建成员变量符号
                                local memberSymbolId, memberSymbol = context.resolveName(ctx, fieldName, objSymbol)
                                if not memberSymbol then
                                    -- 创建新的成员变量
                                    memberSymbol = context.addVariable(ctx, fieldName, source.field, objSymbol)
                                    memberSymbol.isMember = true
                                    context.debug(ctx, "    创建成员变量: %s.%s", objName, fieldName)
                                end
                                
                                if memberSymbol then
                                    table.insert(targets, memberSymbol)
                                    context.debug(ctx, "    找到成员赋值目标: %s.%s", objName, fieldName)
                                end
                            end
                        end
                    end
                end
                
                -- 处理全局变量赋值：globalVar = player.new()
                if source.type == 'setglobal' and source.value and source.value.type == 'call' then
                    local valueCallName = utils.getCallName(source.value)
                    if valueCallName == callInfo.callName then
                        local varName = utils.getNodeName(source.node)
                        if varName then
                            context.debug(ctx, "    找到全局赋值: %s = %s", varName, valueCallName)
                            
                            -- 查找全局变量符号
                            local varSymbolId, varSymbol = context.findVariableSymbol(ctx, varName, nil)
                            if varSymbol then
                                table.insert(targets, varSymbol)
                                context.debug(ctx, "    找到全局赋值目标: %s", varName)
                            end
                        end
                    end
                end
            end)
        end
    end
    
    return targets
end

-- 基于call信息进行类型推断
local function inferTypesFromCalls(ctx)
    local inferredCount = 0
    
    context.debug(ctx, "🔄 开始基于call信息的类型推断")
    
    if not ctx.calls or not ctx.calls.callInfos then
        context.debug(ctx, "❌ 没有找到call信息")
        return
    end
    
    -- 遍历所有调用信息
    for _, callInfo in ipairs(ctx.calls.callInfos) do
        local callName = callInfo.callName
        
        -- 检查是否为构造函数调用
        if callName and (callName:find(':new') or callName:find('%.new')) then
            context.debug(ctx, "🔍 分析构造函数调用: %s", callName)
            
            -- 提取类名
            local className = nil
            if callName:find(':new') then
                className = callName:match('([^:]+):new')
            elseif callName:find('%.new') then
                className = callName:match('([^.]+)%.new')
            end
            
            if className then
                context.debug(ctx, "  提取类名: %s", className)
                
                -- 查找类符号
                local classSymbol = nil
                for _, symbol in pairs(ctx.symbols) do
                    if symbol.type == SYMBOL_TYPE.CLASS and symbol.name == className then
                        classSymbol = symbol
                        break
                    end
                end
                
                if classSymbol then
                    context.debug(ctx, "  找到类符号: %s", classSymbol.name)
                    
                    -- 查找当前作用域中可能被赋值的local变量
                    -- 这需要通过AST分析来找到赋值语句
                    local targetVariables = findAssignmentTargets(ctx, callInfo)
                    
                    for _, varSymbol in ipairs(targetVariables) do
                        if varSymbol.isLocal or varSymbol.isMember then
                            -- 为local变量或成员变量推断类型
                            if addTypeToPossibles(ctx, varSymbol, classSymbol.name) then
                                context.debug(ctx, "  ✅ 推断类型: %s -> %s (构造函数: %s)", 
                                    varSymbol.name, classSymbol.name, callName)
                                inferredCount = inferredCount + 1
                            end
                        end
                    end
                else
                    context.debug(ctx, "  ❌ 未找到类符号: %s", className)
                end
            end
        end
        
        -- 处理函数调用的参数类型推断
        if callInfo.parameters and #callInfo.parameters > 0 and callInfo.targetSymbolId then
            local targetSymbol = ctx.symbols[callInfo.targetSymbolId]
            if targetSymbol and targetSymbol.type == SYMBOL_TYPE.METHOD then
                context.debug(ctx, "🔍 分析函数调用参数类型推断: %s", callName)
                
                -- 查找函数的参数定义
                if targetSymbol.parameters then
                    for i, param in ipairs(callInfo.parameters) do
                        if param.type == 'variable_reference' and param.symbolId then
                            local argSymbol = ctx.symbols[param.symbolId]
                            local paramSymbol = targetSymbol.parameters[i]
                            
                            if argSymbol and paramSymbol and argSymbol.possibles and next(argSymbol.possibles) then
                                -- 将参数的类型信息传播到函数参数
                                for typeName, _ in pairs(argSymbol.possibles) do
                                    if addTypeToPossibles(ctx, paramSymbol, typeName) then
                                        context.debug(ctx, "  ✅ 参数类型推断: %s[%d] -> %s (来自 %s)", 
                                            targetSymbol.name, i, typeName, argSymbol.name)
                                        inferredCount = inferredCount + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        
        -- 处理普通方法调用的类型推断
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
                    local relationId = context.addRelation(ctx, 'reference', symbolId, refId)
                    
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

-- 建立类型间调用关系汇总
local function buildTypeCallSummary(ctx)
    context.debug(ctx, "🔄 开始建立类型间调用关系汇总")
    
    local typeCallSummary = {}
    local callCount = 0
    
    -- 遍历所有调用信息，提取类型级别的调用关系
    for _, callInfo in ipairs(ctx.calls.callInfos) do
        if callInfo.typeCallInfo then
            local sourceType = callInfo.typeCallInfo.sourceType
            local targetType = callInfo.typeCallInfo.targetType
            local sourceMethod = callInfo.typeCallInfo.sourceMethod
            local targetMethod = callInfo.typeCallInfo.targetMethod
            
            -- 创建类型调用关系的键
            local relationKey = sourceType .. " -> " .. targetType
            
            if not typeCallSummary[relationKey] then
                typeCallSummary[relationKey] = {
                    sourceType = sourceType,
                    targetType = targetType,
                    calls = {}
                }
            end
            
            -- 添加具体的方法调用
            local methodCall = {
                sourceMethod = sourceMethod,
                targetMethod = targetMethod,
                callName = callInfo.callName,
                location = callInfo.location
            }
            
            table.insert(typeCallSummary[relationKey].calls, methodCall)
            callCount = callCount + 1
        end
    end
    
    -- 输出类型调用关系汇总
    context.debug(ctx, "📊 类型间调用关系汇总:")
    for relationKey, relation in pairs(typeCallSummary) do
        context.debug(ctx, "  %s (%d个调用)", relationKey, #relation.calls)
        for _, call in ipairs(relation.calls) do
            context.debug(ctx, "    %s.%s -> %s.%s (%s)", 
                relation.sourceType, call.sourceMethod or "unknown",
                relation.targetType, call.targetMethod or call.callName,
                call.callName)
        end
    end
    
    -- 保存到context中
    ctx.typeCallSummary = typeCallSummary
    
    context.debug(ctx, "✅ 类型间调用关系汇总完成，共%d个调用关系", callCount)
    return callCount
end

-- 分析成员访问（getfield和getindex）
local function analyzeMemberAccess(ctx)
    context.debug(ctx, "🔄 开始分析成员访问")
    
    local accessCount = 0
    
    -- 获取所有文件的URI列表
    local fileUris = context.getFiles(ctx)
    
    -- 遍历所有文件的AST
    for _, uri in ipairs(fileUris) do
        local state = files.getState(uri)
        if state and state.ast then
            -- 查找getfield和getindex节点
            guide.eachSourceType(state.ast, 'getfield', function(source)
                local objName = utils.getNodeName(source.node)
                local fieldName = utils.getNodeName(source.field)
                
                if objName and fieldName then
                    local currentScope = context.findCurrentScope(ctx, source)
                    local position = utils.getNodePosition(source)
                    
                    -- 查找对象符号
                    local objSymbolId, objSymbol = context.resolveName(ctx, objName, currentScope)
                    local memberSymbolId = nil
                    
                    -- 查找成员符号
                    if objSymbol then
                        memberSymbolId, _ = context.resolveName(ctx, fieldName, objSymbol)
                    end
                    
                    -- 记录成员访问
                    context.addMemberAccess(ctx, 'field', objSymbolId, fieldName, memberSymbolId, {
                        uri = uri,
                        line = position.line,
                        column = position.column
                    })
                    
                    accessCount = accessCount + 1
                end
            end)
            
            guide.eachSourceType(state.ast, 'getindex', function(source)
                local objName = utils.getNodeName(source.node)
                local indexKey = nil
                
                if source.index and source.index.type == 'string' then
                    indexKey = utils.getStringValue(source.index)
                elseif source.index and source.index.type == 'integer' then
                    indexKey = tostring(source.index[1])
                end
                
                if objName and indexKey then
                    local currentScope = context.findCurrentScope(ctx, source)
                    local position = utils.getNodePosition(source)
                    
                    -- 查找对象符号
                    local objSymbolId, objSymbol = context.resolveName(ctx, objName, currentScope)
                    local memberSymbolId = nil
                    
                    -- 查找成员符号
                    if objSymbol then
                        memberSymbolId, _ = context.resolveName(ctx, indexKey, objSymbol)
                    end
                    
                    -- 记录成员访问
                    context.addMemberAccess(ctx, 'index', objSymbolId, indexKey, memberSymbolId, {
                        uri = uri,
                        line = position.line,
                        column = position.column
                    })
                    
                    accessCount = accessCount + 1
                end
            end)
        end
    end
    
    context.debug(ctx, "✅ 成员访问分析完成，共记录 %d 个访问", accessCount)
    return accessCount
end

-- 第2轮操作：数据流分析
local function performDataFlowAnalysis(ctx)
    -- 重置节点去重状态
    context.resetProcessedNodes(ctx, "Phase2-Round2")
    

    
    -- 初始化节点跟踪器
    if ctx.config.enableNodeTracking then
        tracker2 = nodeTracker.new("phase2_round2")
    end
    
    -- 1. 基于reference和related关系进行类型传播
    --propagateTypesThroughReferences(ctx)
    
    -- 2. 基于call信息进行类型推断
    inferTypesFromCalls(ctx)
    
    -- 3. 建立不同类型的关系
    local referenceRelationCount = buildReferenceRelations(ctx)
    
    -- 4. 建立类型间调用关系汇总
    local typeCallSummaryCount = buildTypeCallSummary(ctx)
    
    -- 5. 分析成员访问
    local memberAccessCount = analyzeMemberAccess(ctx)
    

end

-- 第二阶段：类型推断和数据流分析
function phase2.analyze(ctx)

    
    -- 第1轮操作：遍历AST记录call信息
    recordAllCallInfos(ctx)
    
    -- 第2轮操作：数据流分析
    performDataFlowAnalysis(ctx)
    
    -- 打印节点跟踪统计
    if ctx.config.enableNodeTracking then
        if tracker2 then
            nodeTracker.printStatistics(tracker2)
        end
    end
    

end

return phase2 