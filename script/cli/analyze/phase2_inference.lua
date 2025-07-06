-- analyze/phase2_inference.lua
-- 第二阶段：类型推断

local files = require 'files'
local guide = require 'parser.guide'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'

local phase2 = {}

-- 分析函数参数类型
local function analyzeFunctionParameters(ctx, uri, moduleId, source)
    if not source.args then return end
    
    -- 获取函数名
    local funcName = utils.getFunctionName(source)
    if not funcName then return end
    
    -- 查找函数调用来推断参数类型
    local funcId = context.findSymbol(ctx, 'function', function(func)
        return func.name == funcName and func.module == moduleId
    end)
    
    if not funcId then return end
    
    -- 分析每个参数
    for i, arg in ipairs(source.args) do
        local paramName = utils.getNodeName(arg)
        if paramName then
            local paramId = context.addSymbol(ctx, 'variable', {
                name = paramName,
                module = moduleId,
                uri = uri,
                position = utils.getNodePosition(arg),
                scope = utils.getScopeInfo(source),
                assignmentType = 'parameter',
                functionId = funcId,
                parameterIndex = i
            })
            
            -- 添加到待推断列表（需要从调用点推断）
            table.insert(ctx.types.pending, {
                name = paramName,
                module = moduleId,
                uri = uri,
                position = utils.getNodePosition(arg),
                source = arg,
                type = 'parameter',
                functionId = funcId,
                parameterIndex = i
            })
        end
    end
end

-- 分析函数调用来推断参数类型
local function analyzeFunctionCall(ctx, uri, moduleId, source)
    local callName = utils.getCallName(source)
    if not callName then return end
    
    -- 查找对应的函数定义
    local funcId = context.findSymbol(ctx, 'function', function(func)
        return func.name == callName
    end)
    
    if not funcId then return end
    
    -- 分析调用参数
    if source.args then
        for i, arg in ipairs(source.args) do
            local argType = nil
            local confidence = 0
            
            if arg.type == 'getlocal' or arg.type == 'getglobal' then
                local varName = utils.getNodeName(arg)
                if varName then
                    -- 查找变量的推断类型
                    local varType = ctx.types.inferred[varName]
                    if varType then
                        argType = varType.type
                        confidence = varType.confidence
                    end
                end
            elseif arg.type == 'string' then
                argType = 'string'
                confidence = 1.0
            elseif arg.type == 'number' then
                argType = 'number'
                confidence = 1.0
            end
            
            if argType then
                -- 更新对应参数的类型推断
                for j, pending in ipairs(ctx.types.pending) do
                    if pending.type == 'parameter' and 
                       pending.functionId == funcId and 
                       pending.parameterIndex == i then
                        
                        ctx.types.inferred[pending.name] = {
                            type = argType,
                            confidence = confidence,
                            source = 'function_call'
                        }
                        
                        -- 从待推断列表中移除
                        table.remove(ctx.types.pending, j)
                        break
                    end
                end
            end
        end
    end
end

-- 从值推断类型
local function inferTypeFromValue(ctx, value)
    local inferredType = nil
    local confidence = 0
    
    if value.type == 'call' then
        local callName = utils.getCallName(value)
        
        -- 检查是否是构造函数调用 - 支持 AAA:new() 和 AAA.new() 两种格式
        if callName and (callName:find(':new') or callName:find('%.new')) then
            local className = nil
            if callName:find(':new') then
                className = callName:match('([^:]+):new')
            elseif callName:find('%.new') then
                className = callName:match('([^.]+)%.new')
            end
            
            if className then
                -- 查找类别名
                local alias = ctx.symbols.aliases[className]
                if alias and alias.type == 'class_definition' then
                    inferredType = alias.targetClass
                    confidence = 0.9
                else
                    inferredType = className
                    confidence = 0.7
                end
            end
        elseif utils.isRequireFunction(callName, ctx.config.requireFunctions) then
            -- require调用
            local modulePath = utils.getRequireModulePath(value)
            if modulePath then
                inferredType = 'module:' .. modulePath
                confidence = 0.8
            end
        end
    elseif value.type == 'string' then
        inferredType = 'string'
        confidence = 1.0
    elseif value.type == 'number' then
        inferredType = 'number'
        confidence = 1.0
    elseif value.type == 'boolean' then
        inferredType = 'boolean'
        confidence = 1.0
    elseif value.type == 'table' then
        inferredType = 'table'
        confidence = 0.8
    elseif value.type == 'getlocal' or value.type == 'getglobal' then
        -- 变量引用
        local refName = utils.getNodeName(value)
        if refName then
            -- 查找引用变量的类型
            local refType = ctx.types.inferred[refName]
            if refType then
                inferredType = refType.type
                confidence = refType.confidence * 0.8
            end
        end
    end
    
    return inferredType, confidence
end

-- 记录类型推断结果
local function recordTypeInference(ctx, uri, moduleId, varName, varNode, inferredType, confidence, source)
    local position = utils.getNodePosition(varNode)
    local varId = context.addSymbol(ctx, 'variable', {
        name = varName,
        module = moduleId,
        uri = uri,
        position = position,
        scope = utils.getScopeInfo(varNode),
        assignmentType = source,
        inferredType = inferredType,
        confidence = confidence
    })
    
    -- 添加到类型推断结果
    ctx.types.inferred[varId] = {
        type = inferredType,
        confidence = confidence,
        source = source
    }
    
    context.debug(ctx, "类型推断: %s -> %s (%.1f)", varName, inferredType, confidence)
end

-- 分析构造函数参数类型
local function analyzeConstructorArguments(ctx, uri, moduleId, callSource, className, targetType)
    if not callSource.args then
        return
    end
    
    print(string.format("  📋 分析构造函数参数: %s (参数个数: %d)", className, #callSource.args))
    
    for i, arg in ipairs(callSource.args) do
        local argType, confidence = inferTypeFromValue(ctx, arg)
        print(string.format("    参数[%d]: %s (置信度: %.1f)", i, argType, confidence))
        
        -- 记录参数类型推断结果
        local argId = context.addSymbol(ctx, 'variable', {
            name = string.format("%s_arg_%d", className, i),
            module = moduleId,
            uri = uri,
            position = utils.getNodePosition(arg),
            scope = 'constructor_argument',
            parameterIndex = i,
            parentConstructor = className,
            inferredType = argType,
            confidence = confidence
        })
        
        -- 添加到类型推断结果
        ctx.types.inferred[argId] = {
            type = argType,
            confidence = confidence,
            source = 'constructor_argument'
        }
    end
end

-- 分析构造函数调用，检查是否用于局部变量赋值
local function analyzeConstructorCall(ctx, uri, moduleId, callSource, callName)
    -- 向上查找父节点，直到找到local节点或到达根节点
    local current = callSource
    local depth = 0
    local maxDepth = 5  -- 限制查找深度
    
    while current and current.parent and depth < maxDepth do
        current = current.parent
        depth = depth + 1
        
        print(string.format("  父节点[%d]: %s", depth, current.type))
        
        -- 如果找到local节点，说明这是局部变量声明
        if current.type == 'local' then
            -- 查找变量名
            local varName = nil
            if current[1] then
                varName = current[1]
            end
            
            print(string.format("  ✅ 找到局部变量赋值: %s = %s", varName or "unknown", callName))
            
            if varName then
                -- 进行类型推断 - 支持 AAA:new() 和 AAA.new() 两种格式
                local className = nil
                if callName:find(':new') then
                    className = callName:match('([^:]+):new')
                elseif callName:find('%.new') then
                    className = callName:match('([^.]+)%.new')
                end
                
                if className then
                    local inferredType = nil
                    local confidence = 0
                    
                    -- 查找类别名
                    local alias = ctx.symbols.aliases[className]
                    if alias and alias.type == 'class_definition' then
                        inferredType = alias.targetClass
                        confidence = 0.9
                    else
                        inferredType = className
                        confidence = 0.7
                    end
                    
                    print(string.format("  🎯 类型推断: %s -> %s (%.1f)", varName, inferredType, confidence))
                    
                    -- 记录类型推断结果
                    recordTypeInference(ctx, uri, moduleId, varName, current, inferredType, confidence, 'constructor_call')
                    
                    -- 分析构造函数参数类型
                    analyzeConstructorArguments(ctx, uri, moduleId, callSource, className, inferredType)
                    
                    return  -- 找到后退出
                end
            end
        end
    end
    
    print(string.format("  ❌ 未找到对应的局部变量声明 (深度: %d)", depth))
end

-- 分析文件中的类型推断
local function analyzeFileTypes(ctx, uri)
    local state = files.getState(uri)
    if not state or not state.ast then
        return
    end
    
    local moduleId = utils.getModulePath(uri, ctx.rootUri)
    context.debug(ctx, "分析文件类型推断: %s", moduleId)
    
    -- 新策略：查找构造函数调用，然后检查其是否用于局部变量赋值
    guide.eachSource(state.ast, function(source)
        if source.type == 'call' then
            local callName = utils.getCallName(source)
            if callName and (callName:find(':new') or callName:find('%.new')) then
                print(string.format("🔍 找到构造函数调用: %s", callName))
                -- 检查这个调用是否是局部变量赋值的值
                analyzeConstructorCall(ctx, uri, moduleId, source, callName)
            end
        elseif source.type == 'function' then
            -- 处理函数参数
            analyzeFunctionParameters(ctx, uri, moduleId, source)
        end
    end)
end

-- 分析函数调用，通过调用时的参数类型推断函数定义的参数类型
local function analyzeFunctionCallForParameterInference(ctx, uri, moduleId, callSource)
    local callName = utils.getCallName(callSource)
    if not callName then
        return
    end
    
    -- 跳过构造函数调用
    if callName:find(':new') or callName:find('%.new') then
        return
    end
    
    context.debug(ctx, "🔍 分析函数调用: %s", callName)
    
    -- 查找对应的函数定义，考虑别名情况
    local funcSymbol = nil
    for funcId, func in pairs(ctx.symbols.functions) do
        if func.name == callName then
            funcSymbol = func
            context.debug(ctx, "✅ 直接匹配到函数: %s", func.name)
            break
        end
    end
    
    -- 如果直接匹配失败，尝试通过别名匹配
    if not funcSymbol then
        -- 解析调用名称，如 GM.SimulateBattle -> GameManager.SimulateBattle
        local className, methodName = callName:match('([^.]+)%.(.+)')
        if className and methodName then
            context.debug(ctx, "🔍 解析调用名称: %s.%s", className, methodName)
            -- 查找类别名
            local alias = ctx.symbols.aliases[className]
            if alias and alias.type == 'class_definition' then
                local realClassName = alias.targetClass
                local realFuncName = realClassName .. '.' .. methodName
                context.debug(ctx, "🔍 通过别名查找: %s -> %s", callName, realFuncName)
                
                -- 重新查找函数定义
                for funcId, func in pairs(ctx.symbols.functions) do
                    if func.name == realFuncName then
                        funcSymbol = func
                        context.debug(ctx, "✅ 通过别名匹配到函数: %s", func.name)
                        break
                    end
                end
            end
        end
    end
    
    if not funcSymbol then
        context.debug(ctx, "❌ 未找到函数定义: %s", callName)
        return
    end
    
    if not callSource.args then
        context.debug(ctx, "❌ 函数调用没有参数: %s", callName)
        return
    end
    
    context.debug(ctx, "📋 分析函数参数: %s (参数个数: %d)", funcSymbol.name, #callSource.args)
    
    -- 分析每个参数
    for i, arg in ipairs(callSource.args) do
        local argType, confidence = inferTypeFromValue(ctx, arg)
        context.debug(ctx, "  参数[%d]: %s (置信度: %.1f)", i, argType or "nil", confidence or 0.0)
        
        if argType and funcSymbol.params and funcSymbol.params[i] then
            local paramName = funcSymbol.params[i].name
            context.debug(ctx, "  匹配参数: %s -> %s", paramName, argType)
            
            -- 创建参数类型推断记录
            local paramId = string.format("%s_param_%d", funcSymbol.name, i)
            
            -- 记录参数类型推断结果
            local varId = context.addSymbol(ctx, 'variable', {
                name = paramName,
                module = moduleId,
                uri = uri,
                position = funcSymbol.params[i].position,
                scope = 'function_parameter',
                functionId = funcSymbol.id or funcSymbol.name,
                parameterIndex = i,
                inferredType = argType,
                confidence = confidence
            })
            
            -- 添加到类型推断结果
            ctx.types.inferred[varId] = {
                type = argType,
                confidence = confidence,
                source = 'function_call_inference'
            }
            
            context.debug(ctx, "✅ 函数参数类型推断: %s.%s -> %s (%.1f)", funcSymbol.name, paramName, argType, confidence)
        else
            if not argType then
                context.debug(ctx, "  ❌ 无法推断参数[%d]类型", i)
            elseif not funcSymbol.params then
                context.debug(ctx, "  ❌ 函数没有参数定义")
            elseif not funcSymbol.params[i] then
                context.debug(ctx, "  ❌ 函数参数[%d]不存在", i)
            end
        end
    end
end

-- 主分析函数
function phase2.analyze(ctx)
    local uris = context.getFiles(ctx)
    local totalFiles = #uris
    
    print(string.format("  发现 %d 个Lua文件", totalFiles))
    
    -- 第一遍：分析局部变量和函数参数
    for i, uri in ipairs(uris) do
        analyzeFileTypes(ctx, uri)
        
        -- 显示进度
        if i % 10 == 0 or i == totalFiles then
            print(string.format("  进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100))
        end
    end
    
    -- 第二遍：分析函数调用来推断参数类型
    for i, uri in ipairs(uris) do
        local state = files.getState(uri)
        if state and state.ast then
            local moduleId = utils.getModulePath(uri, ctx.rootUri)
            guide.eachSource(state.ast, function(source)
                if source.type == 'call' then
                    analyzeFunctionCall(ctx, uri, moduleId, source)
                    -- 新增：分析普通函数调用的参数类型推断
                    analyzeFunctionCallForParameterInference(ctx, uri, moduleId, source)
                end
            end)
        end
    end
    
    -- 统计信息
    local inferredCount = utils.tableSize(ctx.types.inferred)
    local pendingCount = #ctx.types.pending
    local totalCount = inferredCount + pendingCount
    
    ctx.types.statistics.total = totalCount
    ctx.types.statistics.inferred = inferredCount
    ctx.types.statistics.pending = pendingCount
    
    print(string.format("  ✅ 类型推断完成:"))
    print(string.format("     总计: %d, 已推断: %d, 待推断: %d (成功率: %.1f%%)", 
        totalCount, inferredCount, pendingCount, 
        totalCount > 0 and (inferredCount / totalCount * 100) or 0))
end

return phase2 