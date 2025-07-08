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

-- 性能优化：添加缓存机制
local symbolCache = {}
local typeCache = {}
local callNameCache = {}

-- 获取符号的所有可能类型名称（原始版本，供缓存版本使用）
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

-- 清理缓存（在新的分析开始时调用）
local function clearCaches()
    symbolCache = {}
    typeCache = {}
    callNameCache = {}
end

-- 缓存的符号查找
local function findFunctionSymbolCached(ctx, callName)
    if symbolCache[callName] then
        return symbolCache[callName].id, symbolCache[callName].symbol
    end
    
    local id, symbol = context.findFunctionSymbol(ctx, callName)
    symbolCache[callName] = { id = id, symbol = symbol }
    return id, symbol
end

-- 缓存的类型获取
local function getAllPossibleTypeNamesCached(ctx, symbolId)
    if not symbolId then return {} end
    
    if typeCache[symbolId] then
        return typeCache[symbolId]
    end
    
    local types = getAllPossibleTypeNames(ctx, symbolId)
    typeCache[symbolId] = types
    return types
end

-- 优化的调用名称获取
local function getCallNameOptimized(source, providedCallName)
    if providedCallName then
        return providedCallName
    end
    
    -- 缓存key基于source的位置和类型
    local cacheKey = string.format("%s_%d_%d", source.type, source.start or 0, source.finish or 0)
    if callNameCache[cacheKey] then
        return callNameCache[cacheKey]
    end
    
    local callName = utils.getCallName(source)
    
    -- 特殊处理getmethod类型的调用（优化版本）
    if not callName and source.type == 'call' and source.node and source.node.type == 'getmethod' then
        local objNode = source.node.node
        local methodNode = source.node.method
        
        -- 快速获取节点名称
        local obj, method
        if objNode.type == 'getlocal' then
            obj = objNode[1]
        elseif objNode.type == 'getglobal' then
            obj = objNode[1]
        elseif objNode.type == 'getfield' then
            local baseObj = objNode.node and objNode.node[1]
            local field = objNode.field and objNode.field[1]
            if baseObj and field then
                obj = baseObj .. '.' .. field
            end
        else
            obj = utils.getNodeName(objNode)
        end
        
        if methodNode.type == 'string' then
            method = methodNode[1]
        else
            method = utils.getNodeName(methodNode)
        end
        
        if obj and method then
            callName = obj .. ':' .. method
        end
    end
    
    callNameCache[cacheKey] = callName
    return callName
end

-- 简化的参数分析（只分析必要信息）
local function analyzeParametersOptimized(source, currentScope, ctx)
    if not source.args then
        return {}
    end
    
    local parameters = {}
    for i, arg in ipairs(source.args) do
        local param = {
            index = i,
            type = arg.type,
            value = nil
        }
        
        -- 只分析最常见的参数类型
        if arg.type == 'string' then
            param.value = arg[1]
        elseif arg.type == 'number' then
            param.value = arg[1]
        elseif arg.type == 'boolean' then
            param.value = arg[1]
        elseif arg.type == 'getlocal' or arg.type == 'getglobal' then
            param.value = arg[1]
        else
            param.value = arg.type
        end
        
        table.insert(parameters, param)
    end
    
    return parameters
end

-- 优化的类型组合生成（限制组合数量）
local function generateTypeCallInfosOptimized(sourcePossibleTypes, targetPossibleTypes, callName)
    local typeCallInfos = {}
    local maxCombinations = 10  -- 限制最大组合数
    local combinationCount = 0
    
    -- 如果类型太多，只取前几个
    local sourceTypes = {}
    local targetTypes = {}
    
    for i, sourceType in ipairs(sourcePossibleTypes) do
        if i <= 3 then  -- 最多3个源类型
            table.insert(sourceTypes, sourceType)
        end
    end
    
    for i, targetType in ipairs(targetPossibleTypes) do
        if i <= 3 then  -- 最多3个目标类型
            table.insert(targetTypes, targetType)
        end
    end
    
    -- 生成组合
    if #sourceTypes > 0 and #targetTypes > 0 then
        for _, sourceType in ipairs(sourceTypes) do
            for _, targetType in ipairs(targetTypes) do
                if combinationCount >= maxCombinations then
                    break
                end
                
                table.insert(typeCallInfos, {
                    sourceType = sourceType,
                    targetType = targetType,
                    callPattern = sourceType .. " -> " .. targetType .. " (" .. callName .. ")"
                })
                combinationCount = combinationCount + 1
            end
            if combinationCount >= maxCombinations then
                break
            end
        end
    elseif #sourceTypes > 0 then
        for _, sourceType in ipairs(sourceTypes) do
            table.insert(typeCallInfos, {
                sourceType = sourceType,
                targetType = "unknown",
                callPattern = sourceType .. " -> unknown (" .. callName .. ")"
            })
        end
    elseif #targetTypes > 0 then
        for _, targetType in ipairs(targetTypes) do
            table.insert(typeCallInfos, {
                sourceType = "unknown",
                targetType = targetType,
                callPattern = "unknown -> " .. targetType .. " (" .. callName .. ")"
            })
        end
    end
    
    return typeCallInfos
end

-- 优化的recordCallInfo函数
local function recordCallInfoOptimized(ctx, uri, moduleId, source, providedCallName)
    local callName = getCallNameOptimized(source, providedCallName)
    if not callName then
        return
    end
    
    local position = utils.getNodePosition(source)
    
    -- 快速查找当前作用域和方法
    local sourceSymbolId = nil
    local currentScope = context.findCurrentScope(ctx, source)
    local currentMethod = context.findCurrentMethod(ctx, source)
    
    if currentMethod then
        sourceSymbolId = currentMethod.id
    elseif currentScope then
        sourceSymbolId = currentScope.id
    end
    
    -- 使用缓存查找目标函数
    local targetSymbolId, targetSymbol = findFunctionSymbolCached(ctx, callName)
    
    -- 如果直接查找失败，尝试类别名查找（简化版本）
    if not targetSymbolId then
        local className, methodName = callName:match('([^.:]+)[.:](.+)')
        if className and methodName then
            local classCallName = className .. '.' .. methodName
            targetSymbolId, targetSymbol = findFunctionSymbolCached(ctx, classCallName)
        end
    end
    
    -- 简化的参数分析
    local parameters = analyzeParametersOptimized(source, currentScope, ctx)
    
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
    
    -- 快速处理模块间引用关系
    if sourceSymbolId and targetSymbolId then
        local sourceSymbol = ctx.symbols[sourceSymbolId]
        local targetSymbol = ctx.symbols[targetSymbolId]
        
        if sourceSymbol and targetSymbol and 
           sourceSymbol.module and targetSymbol.module and 
           sourceSymbol.module ~= targetSymbol.module then
            context.addRelation(ctx, 'module_reference', sourceSymbol.module, targetSymbol.module)
        end
    end
    
    -- 优化的类型级别调用信息
    local sourcePossibleTypes = getAllPossibleTypeNamesCached(ctx, sourceSymbolId)
    local targetPossibleTypes = getAllPossibleTypeNamesCached(ctx, targetSymbolId)
    
    callInfo.typeCallInfos = generateTypeCallInfosOptimized(sourcePossibleTypes, targetPossibleTypes, callName)
    
    -- 添加到context中
    context.addCallInfo(ctx, callInfo)
end

-- 优化的recordAllCallInfos函数
local function recordAllCallInfosOptimized(ctx)
    -- 清理缓存
    clearCaches()
    
    -- 重置节点去重状态
    context.resetProcessedNodes(ctx, "Phase2-Round1")
    
    local uris = context.getFiles(ctx)
    local totalFiles = #uris
    
    -- 初始化节点跟踪器
    if ctx.config.enableNodeTracking then
        tracker1 = nodeTracker.new("phase2_round1_optimized")
    end
    
    context.info("🚀 开始优化版本的调用信息记录: %d个文件", totalFiles)
    
    -- 批量收集所有调用节点
    local allCallNodes = {}
    local allMethodNodes = {}
    
    for i, uri in ipairs(uris) do
        local module = ctx.uriToModule[uri]
        if module and module.ast then
            local moduleId = utils.getModulePath(uri, ctx.rootUri)
            
            -- 预过滤：只收集call和getmethod节点
            guide.eachSource(module.ast, function(source)
                if source.type == 'call' then
                    table.insert(allCallNodes, {
                        source = source,
                        uri = uri,
                        moduleId = moduleId
                    })
                elseif source.type == 'getmethod' then
                    -- 检查是否是方法调用的一部分
                    local parent = source.parent
                    if parent and parent.type == 'call' and parent.node == source then
                        table.insert(allMethodNodes, {
                            source = parent,
                            methodSource = source,
                            uri = uri,
                            moduleId = moduleId
                        })
                    end
                end
            end)
        end
        
        -- 显示进度
        if i % 20 == 0 or i == totalFiles then
            context.info("📊 文件扫描进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100)
        end
    end
    
    context.info("📦 收集到 %d 个调用节点，%d 个方法调用节点", #allCallNodes, #allMethodNodes)
    
    -- 批量处理调用节点
    local totalNodes = #allCallNodes + #allMethodNodes
    local processedNodes = 0
    
    for _, nodeInfo in ipairs(allCallNodes) do
        recordCallInfoOptimized(ctx, nodeInfo.uri, nodeInfo.moduleId, nodeInfo.source)
        processedNodes = processedNodes + 1
        
        if processedNodes % 100 == 0 then
            context.info("🔄 处理进度: %d/%d (%.1f%%)", processedNodes, totalNodes, processedNodes/totalNodes*100)
        end
    end
    
    -- 处理方法调用节点
    for _, nodeInfo in ipairs(allMethodNodes) do
        local objNode = nodeInfo.methodSource.node
        local methodNode = nodeInfo.methodSource.method
        local obj = utils.getNodeName(objNode)
        local method = utils.getNodeName(methodNode)
        
        if obj and method then
            local callName = obj .. ':' .. method
            recordCallInfoOptimized(ctx, nodeInfo.uri, nodeInfo.moduleId, nodeInfo.source, callName)
        end
        
        processedNodes = processedNodes + 1
        
        if processedNodes % 100 == 0 then
            context.info("🔄 处理进度: %d/%d (%.1f%%)", processedNodes, totalNodes, processedNodes/totalNodes*100)
        end
    end
    
    context.info("✅ 优化版本调用信息记录完成，共处理 %d 个节点", processedNodes)
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
                        if value and value.type == 'call' then
                            local valueCallName = utils.getCallName(value)
                            if valueCallName == callInfo.callName then
                                -- 找到了匹配的赋值语句
                                local varName = nil
                                
                                -- 安全地获取变量名
                                if source[i] then
                                    if type(source[i]) == 'table' and source[i][1] then
                                        varName = source[i][1]  -- 获取变量名
                                    elseif type(source[i]) == 'string' then
                                        varName = source[i]
                                    end
                                end
                                
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
    local length = #ctx.calls.callInfos
    for i, callInfo in ipairs(ctx.calls.callInfos) do
        local callName = callInfo.callName
        
        -- 显示进度
        if i % 10 == 0 or i == length then
            context.info("【step2-2-1】    %s, 进度: %d/%d (%.1f%%)", callName, i, length, i/length*100)
        end
        
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
    local length = #ctx.calls.callInfos
    for i, callInfo in ipairs(ctx.calls.callInfos) do
        -- 显示进度
        if i % 10 == 0 or i == length then
            context.info("【step2-2-3】    进度: %d/%d (%.1f%%)", i, length, i/length*100)
        end
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
    local length = #fileUris
    for i, uri in ipairs(fileUris) do
        -- 显示进度
        if i % 10 == 0 or i == length then
            context.info("【step2-2-4】    %s, 进度: %d/%d (%.1f%%)", uri, i, length, i/length*100)
        end
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
    print("第二轮操作1，inferTypesFromCalls")
    inferTypesFromCalls(ctx)
    
    -- 3. 建立不同类型的关系
    print("第二轮操作2，buildReferenceRelations")
    local referenceRelationCount = buildReferenceRelations(ctx)
    
    -- 4. 建立类型间调用关系汇总
    print("第二轮操作3，buildTypeCallSummary")
    local typeCallSummaryCount = buildTypeCallSummary(ctx)
    
    -- 5. 分析成员访问
    print("第二轮操作4，analyzeMemberAccess")
    local memberAccessCount = analyzeMemberAccess(ctx)
    

end

-- 第二阶段：类型推断和数据流分析
function phase2.analyze(ctx)
    -- 获取缓存管理器（如果有的话）
    local cacheManager = ctx.cacheManager

    print("第一轮操作，recordAllCallInfos")
    -- 第1轮操作：遍历AST记录call信息
    recordAllCallInfosOptimized(ctx)
    
    -- 保存第一轮完成后的缓存
    if cacheManager and cacheManager.config.enabled then
        local progress = {
            step = "phase2_round1_complete",
            description = "第一轮：调用信息记录完成",
            callInfosRecorded = #ctx.calls.callInfos
        }
        local cache_manager = require 'cli.analyze.cache_manager'
        cache_manager.saveCache(cacheManager, ctx, "phase2_inference", progress)
    end
    
    print("第二轮操作，performDataFlowAnalysis")
    -- 第2轮操作：数据流分析
    performDataFlowAnalysis(ctx)
    
    -- 保存第二轮完成后的缓存
    if cacheManager and cacheManager.config.enabled then
        local progress = {
            step = "phase2_round2_complete",
            description = "第二轮：数据流分析完成",
            totalRelations = #ctx.relations
        }
        local cache_manager = require 'cli.analyze.cache_manager'
        cache_manager.saveCache(cacheManager, ctx, "phase2_inference", progress)
    end
    
    -- 打印节点跟踪统计
    if ctx.config.enableNodeTracking then
        if tracker2 then
            nodeTracker.printStatistics(tracker2)
        end
    end
end

return phase2 
