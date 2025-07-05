-- analyze/phase2_inference.lua
-- 第二阶段：类型推断

local files = require 'files'
local guide = require 'parser.guide'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'

local phase2 = {}

-- 分析局部变量赋值
local function analyzeLocalAssignment(ctx, uri, moduleId, source)
    -- local节点结构: source[1], source[2], ... 是变量名
    -- source.value 是值的数组
    if not source.value or not source[1] then return end
    
    -- 处理每个局部变量
    for i, varNode in ipairs(source) do
        local varName = utils.getNodeName(varNode)
        if not varName then goto continue end
        
        -- 只对enemy1变量进行详细调试
        if varName == "enemy1" then
            print(string.format("🔍 分析局部变量赋值: %s", varName))
        end
        
        local position = utils.getNodePosition(varNode)
        local inferredType = nil
        local confidence = 0
        
        -- 获取对应的值
        local value = source.value[i]
        if not value then goto continue end
        
        if varName == "enemy1" then
            print(string.format("  值类型: %s", value.type))
        end
        
        -- 分析赋值值类型
        if value.type == 'call' then
            -- 函数调用赋值
            local callName = utils.getCallName(value)
            if varName == "enemy1" then
                print(string.format("  调用名称: %s", callName or "nil"))
            end
            if callName then
                -- 检查是否是构造函数调用
                if callName:find(':new') then
                    local className = callName:match('([^:]+):new')
                    if varName == "enemy1" then
                        print(string.format("  构造函数调用，类名: %s", className or "nil"))
                    end
                    if className then
                        -- 查找类别名
                        local alias = ctx.symbols.aliases[className]
                        if varName == "enemy1" then
                            print(string.format("  查找别名: %s = %s", className, alias and alias.type or "nil"))
                        end
                        if alias and alias.type == 'class_definition' then
                            inferredType = alias.targetClass
                            confidence = 0.9
                            if varName == "enemy1" then
                                print(string.format("  ✅ 通过别名推断: %s -> %s", className, inferredType))
                            end
                        else
                            inferredType = className
                            confidence = 0.7
                            if varName == "enemy1" then
                                print(string.format("  ✅ 直接推断: %s", inferredType))
                            end
                        end
                    end
                elseif callName == 'require' or callName == 'kg_require' then
                    -- require调用
                    local modulePath = utils.getRequireModulePath(value)
                    if modulePath then
                        inferredType = 'module:' .. modulePath
                        confidence = 0.8
                        if varName == "enemy1" then
                            print(string.format("  ✅ 模块推断: %s", inferredType))
                        end
                    end
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
        
        -- 记录推断结果
        if inferredType then
            local varId = context.addSymbol(ctx, 'variable', {
                name = varName,
                module = moduleId,
                uri = uri,
                position = position,
                scope = utils.getScopeInfo(source),
                assignmentType = 'local',
                inferredType = inferredType,
                confidence = confidence
            })
            
            -- 添加到类型推断结果
            ctx.types.inferred[varId] = {
                type = inferredType,
                confidence = confidence,
                source = 'local_assignment'
            }
            
            context.debug(ctx, "局部变量类型推断: %s -> %s (%.1f)", varName, inferredType, confidence)
        else
            -- 添加到待推断列表
            table.insert(ctx.types.pending, {
                name = varName,
                module = moduleId,
                uri = uri,
                position = position,
                source = source
            })
        end
        
        ::continue::
    end
end

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

-- 分析文件中的类型推断
local function analyzeFileTypes(ctx, uri)
    local state = files.getState(uri)
    if not state or not state.ast then
        return
    end
    
    local moduleId = utils.getModulePath(uri, ctx.rootUri)
    context.debug(ctx, "分析文件类型推断: %s", moduleId)
    
    -- 遍历AST节点
    guide.eachSource(state.ast, function(source)
        if source.type == 'local' then
            analyzeLocalAssignment(ctx, uri, moduleId, source)
        elseif source.type == 'function' then
            analyzeFunctionParameters(ctx, uri, moduleId, source)
        elseif source.type == 'call' then
            analyzeFunctionCall(ctx, uri, moduleId, source)
        end
    end)
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