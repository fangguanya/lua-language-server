-- analyze/phase1_symbols.lua
-- 第一阶段：符号定义识别
-- 重构版本：按照context.lua和symbol.lua的架构设计

local files = require 'files'
local guide = require 'parser.guide'
local vm = require 'vm'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'
local symbol = require 'cli.analyze.symbol'
local nodeTracker = require 'cli.analyze.node_tracker'

-- 导入符号类型常量
local SYMBOL_TYPE = symbol.SYMBOL_TYPE
local FUNCTION_ANONYMOUS = symbol.FUNCTION_ANONYMOUS

local phase1 = {}

-- 节点跟踪器
local trackerSymbols = nil

-- 辅助函数：计算hash table的长度
local function countHashTable(t)
    if not t then return 0 end
    local count = 0
    for _, _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- 分析单个文件的符号定义
local function analyzeFileSymbols(ctx, uri)
    local fileName = utils.getFileName(uri)
    local modulePath = utils.getModulePath(uri, ctx.rootUri)
    local text = files.getText(uri)
    if not text then
        context.debug(ctx, "无法读取文件: %s", uri)
        return
    end
    
    local state = files.getState(uri)
    if not state or not state.ast then
        context.debug(ctx, "无法获取AST: %s", uri)
        return
    end
    
    local ast = state.ast
    
    context.info("  📄 分析文件: %s (%s)", fileName, modulePath)
    
    -- 创建模块符号
    local module = context.addModule(ctx, modulePath, fileName, uri, ast)
    
    -- 分析模块级别的符号定义
    guide.eachSource(ast, function(source)
        -- 每次处理新的源节点时，增加调用帧索引
        ctx.currentFrameIndex = ctx.currentFrameIndex + 1
        analyzeSymbolDefinition(ctx, uri, module, source)
    end)
    
    ctx.statistics.totalFiles = ctx.statistics.totalFiles + 1
end

-- 分析符号定义的主调度函数
function analyzeSymbolDefinition(ctx, uri, module, source)
    -- 节点去重检查：如果节点已经被处理过，直接返回
    if not context.checkAndMarkNode(ctx, source) then
        return
    end
    
    local sourceType = source.type
    
    -- 根据AST节点类型分发处理
    if sourceType == 'setglobal' then
        analyzeGlobalVariableDefinition(ctx, uri, module, source)
    elseif sourceType == 'setlocal' then
        analyzeLocalVariableDefinition(ctx, uri, module, source)  -- 这是对已声明局部变量的赋值
    elseif sourceType == 'setfield' then
        analyzeFieldDefinition(ctx, uri, module, source)
    elseif sourceType == 'setindex' then
        analyzeIndexDefinition(ctx, uri, module, source)
    elseif sourceType == 'setmethod' then
        analyzeMethodDefinition(ctx, uri, module, source)
    elseif sourceType == 'local' then
        analyzeLocalStatement(ctx, uri, module, source)  -- 这是局部变量声明语句
    elseif sourceType == 'function' then
        analyzeFunctionDefinition(ctx, uri, module, source)
    elseif sourceType == 'call' then
        analyzeCallExpression(ctx, uri, module, source)
    elseif sourceType == 'select' then
        analyzeSelectExpression(ctx, uri, module, source)
    elseif sourceType == 'return' then
        analyzeReturnStatement(ctx, uri, module, source)
    end
end

-- 分析全局变量定义 (foo = value)
function analyzeGlobalVariableDefinition(ctx, uri, module, source)
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    local varName = utils.getNodeName(source.node)
    if not varName then return end
    
    local position = utils.getNodePosition(source)
    
    -- 检查是否是require或类定义调用
    if source.value and (source.value.type == 'call' or source.value.type == 'select') then
        local result = nil
        if source.value.type == 'call' then
            result = analyzeCallExpression(ctx, uri, module, source.value)
        elseif source.value.type == 'select' then
            result = analyzeSelectExpression(ctx, uri, module, source.value)
        end
        
        if result and result.isRequire then
            -- 这是一个require调用，创建引用
            local ref = context.addReference(ctx, result.moduleName, source, module)
            ref.localName = varName
            ref.position = position
            
            context.debug(ctx, "全局模块引用: %s = require('%s')", varName, result.moduleName)
            return
        elseif result and result.isClassDefinition then
            -- 这是一个类定义，创建类别名变量
            local className = result.className
            local class = ctx.classes[className]
            if class then
                -- 创建类的别名变量（作为普通容器）
                local aliasVar = context.addVariable(ctx, varName, source, module)
                table.insert(aliasVar.possibles, className)
                class.refs[aliasVar.id] = true
                
                context.debug(ctx, "全局类别名: %s -> %s", varName, className)
                return
            end
        end
    end
    
    -- 普通全局变量
    local var = context.addVariable(ctx, varName, source, module)
    var.isGlobal = true
    var.position = position
    
    -- 分析赋值的值
    if source.value then
        analyzeValueAssignment(ctx, uri, module, var, source.value)
    end
    
    context.debug(ctx, "全局变量: %s", varName)
end

-- 分析局部变量赋值 (setlocal: var = value，对已声明的局部变量赋值)
function analyzeLocalVariableDefinition(ctx, uri, module, source)
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    local varName = utils.getNodeName(source.node)
    if not varName then return end
    
    local position = utils.getNodePosition(source)
    local currentScope = context.findCurrentScope(ctx, source)
    
    -- 查找已存在的局部变量
    local existingVar = context.resolveName(ctx, varName, currentScope)
    if existingVar and existingVar.type == SYMBOL_TYPE.VARIABLE and existingVar.isLocal then
        -- 更新已存在的局部变量
        context.debug(ctx, "更新局部变量: %s", varName)
        
        -- 检查是否是require语句
        if source.value and (source.value.type == 'call' or source.value.type == 'select') then
            local result = nil
            if source.value.type == 'call' then
                result = analyzeCallExpression(ctx, uri, module, source.value)
            elseif source.value.type == 'select' then
                result = analyzeSelectExpression(ctx, uri, module, source.value)
            end
            
            if result and result.isRequire then
                -- 这是一个require调用，创建引用
                local ref = context.addReference(ctx, result.moduleName, source, module)
                ref.localName = varName
                ref.position = position
                
                context.debug(ctx, "局部变量模块引用: %s = require('%s')", varName, result.moduleName)
                return
            elseif result and result.isClassDefinition then
                -- 这是一个类定义
                local className = result.className
                local class = ctx.classes[className]
                if class then
                    -- 更新变量的类型
                    table.insert(existingVar.possibles, className)
                    class.refs[existingVar.id] = true
                    
                    context.debug(ctx, "局部变量类别名: %s -> %s", varName, className)
                    return
                end
            end
        end
        
        -- 分析赋值的值
        if source.value then
            analyzeValueAssignment(ctx, uri, module, existingVar, source.value)
        end
    else
        -- 如果找不到已声明的局部变量，可能是错误的AST或者变量声明在其他地方
        context.debug(ctx, "警告: 找不到已声明的局部变量: %s", varName)
        
        -- 作为备用，创建一个新的局部变量
        local var = context.addVariable(ctx, varName, source, currentScope)
        var.isLocal = true
        var.position = position
        
        -- 分析赋值的值
        if source.value then
            analyzeValueAssignment(ctx, uri, module, var, source.value)
        end
        
        context.debug(ctx, "创建新局部变量: %s", varName)
    end
end

-- 分析字段定义 (obj.field = value)
function analyzeFieldDefinition(ctx, uri, module, source)
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    local objName = utils.getNodeName(source.node)
    local fieldName = utils.getNodeName(source.field)
    
    if not objName or not fieldName then return end
    
    local position = utils.getNodePosition(source)
    local currentScope = context.findCurrentScope(ctx, source)
    
    -- 检查是否是self.xxx的情况
    if objName == 'self' then
        -- 需要找到当前方法所属的类或对象
        local currentMethod = context.findCurrentMethod(ctx, source)
        if currentMethod and currentMethod.parent then
            local targetScope = currentMethod.parent
            local var = context.addVariable(ctx, fieldName, source, targetScope)
            var.isField = true
            var.position = position
            
            -- 分析赋值的值
            if source.value then
                analyzeValueAssignment(ctx, uri, module, var, source.value)
            end
            
            context.debug(ctx, "self成员字段: %s.%s", targetScope.name, fieldName)
            return
        end
    end
    
    -- 查找目标对象
    local targetSymbolId, targetSymbol = context.resolveName(ctx, objName, currentScope)
    if targetSymbol then
        -- 任何容器都可以添加字段
        if targetSymbol.container then
            local var = context.addVariable(ctx, fieldName, source, targetSymbol)
            var.isField = true
            var.position = position
            
            -- 分析赋值的值
            if source.value then
                analyzeValueAssignment(ctx, uri, module, var, source.value)
            end
            
            context.debug(ctx, "对象字段: %s.%s", objName, fieldName)
        end
    end
end

-- 分析索引定义 (obj[key] = value)
function analyzeIndexDefinition(ctx, uri, module, source)
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    local objName = utils.getNodeName(source.node)
    local indexKey = nil
    
    if source.index and source.index.type == 'string' then
        indexKey = utils.getStringValue(source.index)
    elseif source.index and source.index.type == 'integer' then
        indexKey = tostring(source.index[1])
    end
    
    if not objName or not indexKey then return end
    
    local position = utils.getNodePosition(source)
    local currentScope = context.findCurrentScope(ctx, source)
    
    -- 查找目标对象
    local targetSymbolId, targetSymbol = context.resolveName(ctx, objName, currentScope)
    if targetSymbol then
        -- 任何容器都可以添加索引
        if targetSymbol.container then
            local var = context.addVariable(ctx, indexKey, source, targetSymbol)
            var.isIndex = true
            var.position = position
            
            -- 分析赋值的值
            if source.value then
                analyzeValueAssignment(ctx, uri, module, var, source.value)
            end
            
            context.debug(ctx, "对象索引: %s[%s]", objName, indexKey)
        end
    end
end

-- 分析方法定义 (obj:method(...))
function analyzeMethodDefinition(ctx, uri, module, source)
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    local objName = utils.getNodeName(source.node)
    local methodName = utils.getNodeName(source.method)
    
    if not objName or not methodName then return end
    
    local position = utils.getNodePosition(source)
    local currentScope = context.findCurrentScope(ctx, source)
    
    -- 查找目标对象
    local targetSymbolId, targetSymbol = context.resolveName(ctx, objName, currentScope)
    if targetSymbol then
        -- 任何容器都可以添加方法
        if targetSymbol.container then
            local method = context.addMethod(ctx, methodName, source, targetSymbol)
            method.isMethod = true
            method.position = position
            
            -- 分析函数体
            if source.value and source.value.type == 'function' then
                analyzeFunctionBody(ctx, uri, module, method, source.value)
            end
            
            context.debug(ctx, "对象方法: %s:%s", objName, methodName)
        end
    end
end

-- 分析local语句声明 (local: local var = value，局部变量声明)
function analyzeLocalStatement(ctx, uri, module, source)
    -- 节点去重检查：如果节点已经被处理过，直接返回
    if not context.checkAndMarkNode(ctx, source) then
        return
    end
    
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    -- 根据实际的AST结构重新实现
    -- 从截图可以看出，local语句的结构是：
    -- source[1] = 变量名字符串（如"Player"）
    -- source.value = 赋值的值（如DefineClass调用）
    
    context.debug(ctx, "处理local声明语句: %s", source.type)
    
    -- 获取变量名
    local varName = source[1]
    if not varName or type(varName) ~= "string" then
        context.debug(ctx, "local语句没有有效的变量名")
        return
    end
    
    local position = utils.getNodePosition(source)
    local currentScope = context.findCurrentScope(ctx, source)
    
    context.debug(ctx, "处理local变量: %s", varName)
    
    -- 检查是否有赋值值
    local value = source.value
    if value then
        context.debug(ctx, "local变量 %s 有赋值，类型: %s", varName, value.type)
        
        -- 检查是否是require语句
        if value and (value.type == 'call' or value.type == 'select') then
            if value.type == 'call' then
                callResult = analyzeCallExpression(ctx, uri, module, value)
            elseif value.type == 'select' then
                callResult = analyzeSelectExpression(ctx, uri, module, value)
            end
            if callResult and callResult.isRequire then
                -- 这是一个require调用，创建引用
                local ref = context.addReference(ctx, callResult.moduleName, source, module)
                ref.localName = varName
                ref.position = position
                
                context.debug(ctx, "模块引用: %s = require('%s')", varName, callResult.moduleName)
                return
            elseif callResult and callResult.isClassDefinition then
                -- 这是一个类定义
                local className = callResult.className
                local class = ctx.classes[className]
                if class then
                    -- 创建类的别名变量
                    local aliasVar = context.addVariable(ctx, varName, source, currentScope)
                    table.insert(aliasVar.possibles, className)
                    class.refs[aliasVar.id] = true
                    
                    context.debug(ctx, "局部类别名: %s -> %s", varName, className)
                    return
                end
            end
        end
        
        -- 普通局部变量
        local var = context.addVariable(ctx, varName, source, currentScope)
        var.isLocal = true
        var.position = position
        
        -- 分析赋值的值
        analyzeValueAssignment(ctx, uri, module, var, value)
        
        context.debug(ctx, "局部变量（有赋值）: %s", varName)
    else
        -- 没有赋值的局部变量声明
        local var = context.addVariable(ctx, varName, source, currentScope)
        var.isLocal = true
        var.position = position
        
        context.debug(ctx, "局部变量（无赋值）: %s", varName)
    end
end

-- 分析函数定义
function analyzeFunctionDefinition(ctx, uri, module, source)
    -- 节点去重检查：如果节点已经被处理过，直接返回
    if not context.checkAndMarkNode(ctx, source) then
        return
    end
    
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    local parent = source.parent
    local currentScope = context.findCurrentScope(ctx, source)
    
    -- 检查函数定义的上下文
    if parent then
        if parent.type == 'setglobal' then
            -- 全局函数 function foo(...)
            local funcName = utils.getNodeName(parent.node)
            if funcName then
                local method = context.addMethod(ctx, funcName, source, module)
                method.isGlobal = true
                method.position = utils.getNodePosition(source)
                
                analyzeFunctionBody(ctx, uri, module, method, source)
                context.debug(ctx, "全局函数: %s", funcName)
            end
        elseif parent.type == 'setlocal' then
            -- 局部函数 local function foo(...)
            local funcName = utils.getNodeName(parent.node)
            if funcName then
                local method = context.addMethod(ctx, funcName, source, currentScope)
                method.isLocal = true
                method.position = utils.getNodePosition(source)
                
                analyzeFunctionBody(ctx, uri, module, method, source)
                context.debug(ctx, "局部函数: %s", funcName)
            end
        elseif parent.type == 'setfield' then
            -- 对象方法 obj.func = function(...)
            local objName = utils.getNodeName(parent.node)
            local methodName = utils.getNodeName(parent.field)
            
            if objName and methodName then
                local targetSymbolId, targetSymbol = context.resolveName(ctx, objName, currentScope)
                if targetSymbol then
                    local targetScope = targetSymbol
                    
                    -- 如果是类别名，找到真正的类
                    if targetSymbol.type == SYMBOL_TYPE.VARIABLE and targetSymbol.isClassAlias then
                        local className = targetSymbol.targetClass
                        targetScope = ctx.classes[className]
                    end
                    
                    if targetScope and targetScope.container then
                        local method = context.addMethod(ctx, methodName, source, targetScope)
                        method.isMethod = false
                        method.position = utils.getNodePosition(source)
                        
                        analyzeFunctionBody(ctx, uri, module, method, source)
                        context.debug(ctx, "对象方法: %s.%s", objName, methodName)
                    end
                end
            end
        elseif parent.type == 'setmethod' then
            -- 这种情况在analyzeMethodDefinition中处理
            return
        elseif parent.type == 'local' then
            -- local func = function(...) 的情况
            local funcName = parent[1]
            if funcName then
                local method = context.addMethod(ctx, funcName, source, currentScope)
                method.isLocal = true
                method.position = utils.getNodePosition(source)
                
                analyzeFunctionBody(ctx, uri, module, method, source)
                context.debug(ctx, "局部函数变量: %s", funcName)
            end
        else
            -- 匿名函数
            local method = context.addMethod(ctx, FUNCTION_ANONYMOUS, source, currentScope)
            method.isAnonymous = true
            method.position = utils.getNodePosition(source)
            
            analyzeFunctionBody(ctx, uri, module, method, source)
            context.debug(ctx, "匿名函数")
        end
    else
        -- 匿名函数
        local method = context.addMethod(ctx, FUNCTION_ANONYMOUS, source, currentScope)
        method.isAnonymous = true
        method.position = utils.getNodePosition(source)
        
        analyzeFunctionBody(ctx, uri, module, method, source)
        context.debug(ctx, "匿名函数")
    end
end

-- 分析函数体
function analyzeFunctionBody(ctx, uri, module, method, funcSource)
    -- 分析函数参数
    if funcSource.args then
        for i, arg in ipairs(funcSource.args) do
            local paramName = utils.getNodeName(arg)
            if paramName then
                local param = context.addVariable(ctx, paramName, arg, method)
                param.isParameter = true
                param.parameterIndex = i
                param.position = utils.getNodePosition(arg)
                
                -- 如果是self参数，标记为self
                if paramName == "self" then
                    param.isSelf = true
                end
                
                table.insert(method.parameters, param.id)
                context.debug(ctx, "函数参数: %s[%d] = %s", method.name, i, paramName)
            end
        end
    end
    
    -- 注意：不再手动添加self参数，因为setmethod类型的函数AST中已经包含了self参数
    -- 这避免了重复添加self参数的问题
    
    -- 注意：函数体内的符号由主循环的guide.eachSource处理，这里不再重复处理
    -- 避免重复处理同一个AST节点
end

-- 解析父类参数 - 在第一阶段就完成解析，转换为SYMBOL_ID或字符串名称
function parseParentClass(ctx, arg, module)
    if not arg then return nil end
    
    local argType = arg.type
    
    if argType == 'string' then
        -- 字符串形式的父类名
        local parentName = utils.getStringValue(arg)
        if parentName then
            -- 尝试在当前符号表中查找对应的类或变量
            local symbolId, _ = context.findSymbolByName(ctx, parentName, module)
            if symbolId then
                return {
                    type = 'resolved_symbol',
                    name = parentName,
                    resolved = true,
                    source = arg,
                    symbolId = symbolId,
                    description = string.format("已解析字符串父类: %s -> %s", parentName, symbolId)
                }
            else
                -- 保留字符串名称
                return {
                    type = 'string',
                    name = parentName,
                    resolved = true,
                    source = arg,
                    symbolId = parentName, -- 使用字符串名称作为标识
                    description = string.format("字符串父类: %s", parentName)
                }
            end
        end
    elseif argType == 'getlocal' or argType == 'getglobal' then
        -- 变量引用的父类
        local varName = utils.getNodeName(arg)
        if varName then
            -- 查找变量的symbol_id
            local varSymbolId, _ = context.findVariableSymbol(ctx, varName, module)
            if varSymbolId then
                return {
                    type = 'resolved_symbol',
                    name = varName,
                    resolved = true,
                    source = arg,
                    symbolId = varSymbolId,
                    description = string.format("已解析变量父类: %s -> %s", varName, varSymbolId)
                }
            else
                -- 如果找不到symbol_id，使用字符串名称
                return {
                    type = 'string',
                    name = varName,
                    resolved = true,
                    source = arg,
                    symbolId = varName, -- 使用字符串名称作为标识
                    description = string.format("变量父类(未找到符号): %s", varName)
                }
            end
        end
    elseif argType == 'call' then
        -- 函数调用返回的父类
        local callName = utils.getCallName(arg)
        if callName then
            -- 尝试查找函数的symbol_id
            local funcSymbolId, _ = context.findSymbolByName(ctx, callName, module)
            if funcSymbolId then
                return {
                    type = 'resolved_symbol',
                    name = callName,
                    resolved = true,
                    source = arg,
                    symbolId = funcSymbolId,
                    description = string.format("已解析函数调用父类: %s() -> %s", callName, funcSymbolId)
                }
            else
                -- 使用函数名作为字符串标识
                return {
                    type = 'string',
                    name = callName,
                    resolved = true,
                    source = arg,
                    symbolId = callName, -- 使用函数名作为标识
                    description = string.format("函数调用父类: %s()", callName)
                }
            end
        end
    elseif argType == 'binary' then
        -- 二元表达式父类 (如 A or B, A and B)
        local operator = arg.op and arg.op.type
        if operator then
            local leftName = utils.getNodeName(arg[1]) or "?"
            local rightName = utils.getNodeName(arg[2]) or "?"
            local exprName = string.format("%s_%s_%s", leftName, operator, rightName)
            return {
                type = 'string',
                name = exprName,
                resolved = true,
                source = arg,
                symbolId = exprName, -- 使用表达式作为标识
                description = string.format("表达式父类: (%s %s %s)", leftName, operator, rightName)
            }
        end
    elseif argType == 'table' then
        -- 表形式的组件列表（如 {ComponentA, ComponentB}）
        local components = {}
        for i, component in ipairs(arg) do
            local componentInfo = nil
            
            if component.type == 'getlocal' or component.type == 'getglobal' then
                local componentName = utils.getNodeName(component)
                if componentName then
                    -- 查找组件的symbol_id
                    local componentSymbolId, _ = context.findVariableSymbol(ctx, componentName, module)
                    if componentSymbolId then
                        componentInfo = {
                            type = 'resolved_symbol',
                            name = componentName,
                            resolved = true,
                            source = component,
                            symbolId = componentSymbolId,
                            description = string.format("已解析组件: %s -> %s", componentName, componentSymbolId)
                        }
                    else
                        -- 使用字符串名称
                        componentInfo = {
                            type = 'string',
                            name = componentName,
                            resolved = true,
                            source = component,
                            symbolId = componentName, -- 使用字符串名称作为标识
                            description = string.format("组件(未找到符号): %s", componentName)
                        }
                    end
                end
            elseif component.type == 'string' then
                -- 字符串形式的组件名
                local componentName = utils.getStringValue(component)
                if componentName then
                    -- 尝试查找对应的符号
                    local symbolId, _ = context.findSymbolByName(ctx, componentName, module)
                    if symbolId then
                        componentInfo = {
                            type = 'resolved_symbol',
                            name = componentName,
                            resolved = true,
                            source = component,
                            symbolId = symbolId,
                            description = string.format("已解析组件字符串: %s -> %s", componentName, symbolId)
                        }
                    else
                        componentInfo = {
                            type = 'string',
                            name = componentName,
                            resolved = true,
                            source = component,
                            symbolId = componentName, -- 使用字符串名称作为标识
                            description = string.format("组件字符串: %s", componentName)
                        }
                    end
                end
            elseif component.type == 'call' then
                -- 函数调用返回的组件
                local callName = utils.getCallName(component)
                if callName then
                    -- 尝试查找函数的symbol_id
                    local funcSymbolId, _ = context.findSymbolByName(ctx, callName, module)
                    if funcSymbolId then
                        componentInfo = {
                            type = 'resolved_symbol',
                            name = callName,
                            resolved = true,
                            source = component,
                            symbolId = funcSymbolId,
                            description = string.format("已解析组件函数: %s() -> %s", callName, funcSymbolId)
                        }
                    else
                        componentInfo = {
                            type = 'string',
                            name = callName,
                            resolved = true,
                            source = component,
                            symbolId = callName, -- 使用函数名作为标识
                            description = string.format("组件函数调用: %s()", callName)
                        }
                    end
                end
            end
            
            if componentInfo then
                table.insert(components, componentInfo)
                context.debug(ctx, "组件信息: %s (%s) -> %s", 
                    componentInfo.name or "unknown", 
                    componentInfo.type, 
                    componentInfo.symbolId or "nil")
            end
        end
        
        if #components > 0 then
            return {
                type = 'component_list',
                components = components,
                resolved = true,
                source = arg,
                symbolId = nil, -- 组件列表不需要单独的symbolId
                description = string.format("组件列表: [%s]", 
                    table.concat(
                        (function()
                            local names = {}
                            for _, comp in ipairs(components) do
                                table.insert(names, comp.name or "unknown")
                            end
                            return names
                        end)(), 
                        ", "
                    )
                )
            }
        end
    elseif argType == 'nil' then
        -- nil父类，忽略
        return nil
    end
    
    -- 未知类型，使用类型名作为字符串标识
    return {
        type = 'string',
        name = argType,
        resolved = true,
        source = arg,
        symbolId = argType, -- 使用类型名作为标识
        description = string.format("未知类型: <%s>", argType)
    }
end

-- 分析函数调用表达式
function analyzeCallExpression(ctx, uri, module, source)
    -- 节点去重检查：如果节点已经被处理过，直接返回
    if not context.checkAndMarkNode(ctx, source) then
        return nil
    end
    
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    local callNode = source.node
    if not callNode then return nil end
    
    local funcName = utils.getNodeName(callNode)
    if not funcName then return nil end
    
    -- 检查是否是require函数
    if utils.isRequireFunction(funcName, ctx.config.requireFunctions) then
        local args = source.args
        if args and args[1] and args[1].type == 'string' then
            local modulePath = utils.getStringValue(args[1])
            if modulePath then
                return {
                    isRequire = true,
                    moduleName = modulePath,
                    functionName = funcName
                }
            end
        end
    end
    
    -- 检查是否是类定义函数
    if utils.isClassFunction(funcName, ctx.config.classFunctions) then
        local args = source.args
        if args and args[1] and args[1].type == 'string' then
            local className = utils.getStringValue(args[1])
            if className then
                -- 创建类定义
                local class = context.addClass(ctx, className, source, module)
                class.defineFunction = funcName
                class.position = utils.getNodePosition(source)
                
                -- 处理继承关系
                class.parentClasses = class.parentClasses or {}
                for i = 2, #args do
                    local arg = args[i]
                    if arg then
                        local parentInfo = parseParentClass(ctx, arg, module)
                        if parentInfo then
                            table.insert(class.parentClasses, parentInfo)
                            context.debug(ctx, "父类关系: %s -> %s (%s)", 
                                className, parentInfo.name or parentInfo.description, parentInfo.type)
                        end
                    end
                end
                
                context.debug(ctx, "类定义: %s", className)
                return {
                    isClassDefinition = true,
                    className = className,
                    functionName = funcName
                }
            end
        end
    end
    
    return nil
end

-- 分析select表达式（处理DefineClass和kg_require等函数调用）
function analyzeSelectExpression(ctx, uri, module, source)
    -- 节点去重检查：如果节点已经被处理过，直接返回
    if not context.checkAndMarkNode(ctx, source) then
        return nil
    end
    
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    -- select节点通常包含一个调用表达式
    -- 例如：local PlayerClass = DefineClass("Player") 中的 DefineClass("Player") 部分
    
    -- 查找select节点中的call子节点
    local callNode = nil
    if source.vararg and source.vararg.type == 'call' then
        callNode = source.vararg
    elseif source.node and source.node.type == 'call' then
        callNode = source.node
    end
    
    if callNode then
        -- 使用现有的analyzeCallExpression函数处理调用
        -- 注意：这里不需要再次检查callNode的去重，因为analyzeCallExpression内部会处理
        local result = analyzeCallExpression(ctx, uri, module, callNode)
        
        context.debug(ctx, "select表达式中的调用: %s", 
            utils.getNodeName(callNode.node) or "unnamed")
        
        return result
    end
    
    context.debug(ctx, "select表达式未找到调用节点")
    return nil
end

-- 分析return语句
function analyzeReturnStatement(ctx, uri, module, source)
    -- 节点去重检查：如果节点已经被处理过，直接返回
    if not context.checkAndMarkNode(ctx, source) then
        return
    end
    
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    local currentScope = context.findCurrentScope(ctx, source)
    
    -- 如果在模块级别，记录模块的返回值
    if currentScope.type == SYMBOL_TYPE.MODULE then
        local returns = source.returns
        if returns and #returns > 0 then
            local firstReturn = returns[1]
            if firstReturn then
                currentScope.returns = firstReturn
                
                -- 如果返回的是变量，记录变量名
                if firstReturn.type == 'getlocal' or firstReturn.type == 'getglobal' then
                    local varName = utils.getNodeName(firstReturn)
                    if varName then
                        currentScope.returnVariable = varName
                        context.debug(ctx, "模块返回: %s", varName)
                    end
                end
            end
        end
    end
end

-- 分析值赋值
function analyzeValueAssignment(ctx, uri, module, variable, valueSource)
    if not valueSource then return end
    
    local valueType = valueSource.type
    
    -- 只记录可以立即确定的基础类型
    if valueType == 'string' then
        table.insert(variable.possibles, 'string')
    elseif valueType == 'number' or valueType == 'integer' then
        table.insert(variable.possibles, 'number')
    elseif valueType == 'boolean' then
        table.insert(variable.possibles, 'boolean')
    elseif valueType == 'table' then
        table.insert(variable.possibles, 'table')
    elseif valueType == 'function' then
        table.insert(variable.possibles, 'function')
    elseif valueType == 'nil' then
        table.insert(variable.possibles, 'nil')
    elseif valueType == 'call' then
        -- 函数调用结果 - 只处理可以立即确定类型的情况
        local callResult = analyzeCallExpression(ctx, uri, module, valueSource)
        if callResult and callResult.isClassDefinition then
            -- 类定义调用，可以立即确定类型
            table.insert(variable.possibles, callResult.className)
            local class = ctx.classes[callResult.className]
            if class then
                class.refs[variable.id] = true
            end
        end
        -- 其他函数调用结果在第二阶段处理
    elseif valueType == 'select' then
        -- select表达式结果 - 处理DefineClass和kg_require等
        local selectResult = analyzeSelectExpression(ctx, uri, module, valueSource)
        if selectResult and selectResult.isClassDefinition then
            -- 类定义调用，可以立即确定类型
            table.insert(variable.possibles, selectResult.className)
            local class = ctx.classes[callResult.className]
            if class then
                class.refs[variable.id] = true
            end
        end
        -- 其他select结果在第二阶段处理
    end
    
    -- 变量引用（getlocal, getglobal）在第二轮扫描refs时处理
    -- 不在这里处理，避免字符串依赖
end

-- 分析单个文件的引用关系（第二遍处理）
local function analyzeFileReferences(ctx, uri)
    local fileName = utils.getFileName(uri)
    
    -- 直接从缓存中获取模块对象，避免重复获取AST
    local module = context.getModuleByUri(ctx, uri)
    if not module or not module.ast then
        context.debug(ctx, "未找到缓存的模块: %s", fileName)
        return
    end
    
    local ast = module.ast
    context.debug(ctx, "📄 处理引用: %s", fileName)
    
    -- 使用guide.eachSource遍历当前节点及其所有子节点
    guide.eachSource(ast, function(source)
        -- 每次处理新的源节点时，增加调用帧索引
        ctx.currentFrameIndex = ctx.currentFrameIndex + 1
        analyzeSourceReferences(ctx, uri, module, source)
    end)
end

-- 注意：analyzeFunctionBodyReferences函数已被移除，避免重复处理
-- 函数体内的引用关系由主循环的guide.eachSource处理

-- 分析函数参数的引用
function analyzeParameterReference(ctx, uri, module, paramSymbol, refNode)
    local refType = refNode.type
    
    context.debug(ctx, "参数引用: %s -> %s", paramSymbol.name, refType)
    
    -- 根据引用类型进行处理
    if refType == 'getlocal' then
        -- 参数被引用 - 查找引用此参数的符号
        local refName = utils.getNodeName(refNode)
        if refName and refName == paramSymbol.name then
            -- 查找引用此参数的符号
            local refSymbol = ctx.asts[refNode]
            if refSymbol then
                -- 在参数符号的refs中记录被引用的符号ID
                paramSymbol.refs[refSymbol.id] = true
                
                -- 在引用符号的related中记录参数符号ID
                if refSymbol.related then
                    refSymbol.related[paramSymbol.id] = true
                end
                
                context.debug(ctx, "参数被引用: %s -> %s (ID: %s)", paramSymbol.name, refSymbol.name or "unnamed", refSymbol.id)
            end
        end
    elseif refType == 'setlocal' then
        -- 参数被重新赋值 - 查找赋值的符号
        local refSymbol = ctx.asts[refNode]
        if refSymbol then
            -- 在参数符号的refs中记录赋值符号ID
            paramSymbol.refs[refSymbol.id] = true
            
            context.debug(ctx, "参数被重新赋值: %s -> %s (ID: %s)", paramSymbol.name, refSymbol.name or "unnamed", refSymbol.id)
        end
    end
end

-- 分析单个源节点的引用关系
function analyzeSourceReferences(ctx, uri, module, source)
    -- 节点去重检查：如果节点已经被处理过，直接返回
    if not context.checkAndMarkNode(ctx, source) then
        return
    end
    
    -- 跟踪节点处理（如果启用）
    if trackerSymbols then
        nodeTracker.recordNode(trackerSymbols, source)
    end
    
    -- 调试：检查节点是否有ref字段（注意：是ref不是refs）
    if source.ref then
        context.debug(ctx, "节点 %s (类型: %s) 有 %d 个引用", 
            utils.getNodeName(source) or "unnamed", source.type, #source.ref)
            
        -- 获取当前节点对应的符号
        local currentSymbol = ctx.asts[source]
        if currentSymbol then
            context.debug(ctx, "找到对应符号: %s (ID: %s)", currentSymbol.name, currentSymbol.id)
            -- 处理每个引用
            for _, ref in ipairs(source.ref) do
                analyzeReference(ctx, uri, module, currentSymbol, ref)
            end
        else
            -- 如果没有找到符号，这可能是正常的（很多AST节点没有对应的符号）
            -- 但是我们仍然需要处理这些引用关系
            context.debug(ctx, "处理无符号节点的引用: %s (类型: %s)", 
                utils.getNodeName(source) or "unnamed", source.type)
            
            -- 对于没有符号的节点，我们需要分析其引用关系
            for _, ref in ipairs(source.ref) do
                analyzeNodeReference(ctx, uri, module, source, ref)
            end
        end
    else
        -- 调试：记录没有ref字段的节点
        context.debug(ctx, "节点 %s (类型: %s) 没有ref字段", 
            utils.getNodeName(source) or "unnamed", source.type)
    end
    
    -- 第一阶段只处理符号间的引用关系，不进行类型推断
    -- 类型推断将在第二阶段(phase2_inference.lua)中处理
end

-- 分析没有符号的节点的引用关系
function analyzeNodeReference(ctx, uri, module, sourceNode, refNode)
    local refType = refNode.type
    
    -- 根据引用类型进行处理
    if refType == 'getlocal' or refType == 'getglobal' then
        -- 变量引用 - 查找被引用的符号
        local refName = utils.getNodeName(refNode)
        if refName then
            -- 查找被引用的符号
            local targetSymbolId, targetSymbol = context.resolveName(ctx, refName, context.findCurrentScope(ctx, refNode))
            if targetSymbol then
                -- 查找源节点对应的符号（可能在父节点中）
                local sourceSymbol = context.findSymbolForNode(ctx, sourceNode)
                if sourceSymbol then
                    -- 如果源符号是变量，建立related关系
                    if sourceSymbol.type == SYMBOL_TYPE.VARIABLE then
                        sourceSymbol.related[targetSymbol.id] = true
                        context.debug(ctx, "节点变量关联: %s -> %s (ID: %s)", 
                            sourceSymbol.name, refName, targetSymbol.id)
                    end
                    
                    -- 在目标符号中记录反向引用（refs字段）
                    targetSymbol.refs[sourceSymbol.id] = true
                    
                    context.debug(ctx, "建立节点引用关系: %s (ID: %s) -> %s (ID: %s)", 
                        sourceSymbol.name, sourceSymbol.id, targetSymbol.name, targetSymbol.id)
                end
            else
                context.debug(ctx, "未找到节点引用目标: %s", refName)
            end
        end
    end
end

-- 分析单个引用
function analyzeReference(ctx, uri, module, sourceSymbol, refNode)
    local refType = refNode.type
    
    -- 根据引用类型进行处理
    if refType == 'getlocal' or refType == 'getglobal' then
        -- 变量引用 - 建立related关系
        local refName = utils.getNodeName(refNode)
        if refName then
            -- 查找被引用的符号
            local targetSymbolId, targetSymbol = context.resolveName(ctx, refName, context.findCurrentScope(ctx, refNode))
            if targetSymbol then
                -- 如果源符号是变量，建立related关系
                if sourceSymbol.type == SYMBOL_TYPE.VARIABLE then
                    sourceSymbol.related[targetSymbol.id] = true
                    context.debug(ctx, "变量关联: %s -> %s (ID: %s)", sourceSymbol.name, refName, targetSymbol.id)
                end
                
                -- 在目标符号中记录反向引用（refs字段）
                targetSymbol.refs[sourceSymbol.id] = true
                
                context.debug(ctx, "建立引用关系: %s (ID: %s) -> %s (ID: %s)", 
                    sourceSymbol.name, sourceSymbol.id, targetSymbol.name, targetSymbol.id)
            else
                context.debug(ctx, "未找到引用目标: %s", refName)
            end
        end
    elseif refType == 'getfield' then
        -- 字段引用
        local objName = utils.getNodeName(refNode.node)
        local fieldName = utils.getNodeName(refNode.field)
        if objName and fieldName then
            -- 查找对象符号
            local objSymbolId, objSymbol = context.resolveName(ctx, objName, context.findCurrentScope(ctx, refNode))
            if objSymbol then
                -- 使用context.resolveName在对象作用域内查找字段符号
                local fieldSymbolId, fieldSymbol = context.resolveName(ctx, fieldName, objSymbol)
                
                -- 如果找到了字段符号，建立引用关系
                if fieldSymbol then
                    -- 在源符号的related中记录字段符号ID
                    if sourceSymbol.related then
                        sourceSymbol.related[fieldSymbol.id] = true
                    end
                    
                    -- 在字段符号的refs中记录源符号ID
                    fieldSymbol.refs[sourceSymbol.id] = true
                
                context.debug(ctx, "字段引用: %s -> %s.%s (字段ID: %s)", 
                        sourceSymbol.name, objName, fieldName, fieldSymbol.id)
                end
            end
        end
    elseif refType == 'call' then
        -- 函数调用引用
        local funcName = utils.getNodeName(refNode.node)
        if funcName then
            -- 查找函数符号
            local funcSymbolId, funcSymbol = context.resolveName(ctx, funcName, context.findCurrentScope(ctx, refNode))
            if funcSymbol then
                -- 在源符号的related中记录函数符号ID
                if sourceSymbol.related then
                    sourceSymbol.related[funcSymbol.id] = true
                end
                
                -- 在函数符号的refs中记录源符号ID
                funcSymbol.refs[sourceSymbol.id] = true
                
                context.debug(ctx, "函数调用: %s -> %s() (函数ID: %s)", 
                    sourceSymbol.name, funcName, funcSymbol.id)
            end
        end
    end
end


-- 第三遍：整理类型别名，移动定义到真正的类型上
function consolidateTypeAliases(ctx)
    -- 只处理通过引用关系找到的类型别名
    local aliasCount, movedMethods, movedVariables = processReferenceBasedAliases(ctx)
    
    print(string.format("    整理了 %d 个类型别名，移动了 %d 个方法和 %d 个变量", 
        aliasCount, movedMethods, movedVariables))
end

-- 递归收集CLASS类型符号的所有后继符号
local function collectClassSuccessors(ctx, classSymbol, visited)
    visited = visited or {}
    
    -- 防止循环引用
    if visited[classSymbol.id] then
        return {}
    end
    visited[classSymbol.id] = true
    
    local successors = {}
    
    -- 如果class有refs，递归查找所有后继
    if classSymbol.refs and next(classSymbol.refs) then
        for refSymbolId, _ in pairs(classSymbol.refs) do
            local refSymbol = ctx.symbols[refSymbolId]
            if refSymbol then
                -- 添加当前后继符号
                table.insert(successors, refSymbol)
                context.debug(ctx, "找到class %s 的后继符号: %s (类型: %s)", 
                    classSymbol.name, refSymbol.name, refSymbol.type)
                
                -- 如果后继符号也是CLASS类型，递归查找其后继
                if refSymbol.type == SYMBOL_TYPE.CLASS then
                    local nestedSuccessors = collectClassSuccessors(ctx, refSymbol, visited)
                    for _, nestedSymbol in ipairs(nestedSuccessors) do
                        table.insert(successors, nestedSymbol)
                    end
                end
            end
        end
    end
    
    visited[classSymbol.id] = nil
    return successors
end

-- 处理通过CLASS类型refs关系找到的后继符号并进行合并
function processReferenceBasedAliases(ctx)
    local processedCount = 0
    local movedMethods = 0
    local movedVariables = 0
    local mergedClasses = 0
    
    -- 遍历所有CLASS类型符号
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.CLASS then
            context.debug(ctx, "处理CLASS符号: %s (ID: %s)", symbol.name, symbolId)
            
            -- 收集所有后继符号（递归）
            local successors = collectClassSuccessors(ctx, symbol)
            
            if #successors > 0 then
                context.debug(ctx, "CLASS %s 有 %d 个后继符号", symbol.name, #successors)
                
                -- 处理每个后继符号，将其定义合并到原始CLASS中
                for _, successor in ipairs(successors) do
                    local hasMerged = false
                    
                    -- 合并方法定义
                    if successor.methods and #successor.methods > 0 then
                        for _, methodId in ipairs(successor.methods) do
                                        local method = ctx.symbols[methodId]
                                        if method then
                                table.insert(symbol.methods, methodId)
                                method.parent = symbol
                                            movedMethods = movedMethods + 1
                                hasMerged = true
                                            
                                context.debug(ctx, "合并方法: %s.%s -> %s.%s", 
                                    successor.name, method.name, symbol.name, method.name)
                                        end
                                    end
                        successor.methods = {}
                                end
                                
                    -- 合并变量定义
                    if successor.variables and #successor.variables > 0 then
                        for _, varId in ipairs(successor.variables) do
                                        local var = ctx.symbols[varId]
                                        if var then
                                table.insert(symbol.variables, varId)
                                var.parent = symbol
                                            movedVariables = movedVariables + 1
                                hasMerged = true
                                            
                                context.debug(ctx, "合并变量: %s.%s -> %s.%s", 
                                    successor.name, var.name, symbol.name, var.name)
                                        end
                                    end
                        successor.variables = {}
                    end
                    
                    -- 如果后继符号是变量类型，标记为别名
                    if successor.type == SYMBOL_TYPE.VARIABLE and hasMerged then
                        successor.isAlias = true
                        successor.aliasTarget = symbol.id
                        successor.aliasTargetName = symbol.name
                        
                                context.debug(ctx, "标记别名: %s -> %s", 
                            successor.name, symbol.name)
                    end
                    
                    -- 如果后继符号是CLASS类型且有定义被合并，标记为已合并
                    if successor.type == SYMBOL_TYPE.CLASS and hasMerged then
                        mergedClasses = mergedClasses + 1
                        context.debug(ctx, "合并CLASS: %s -> %s", 
                            successor.name, symbol.name)
                    end
                    
                    if hasMerged then
                        processedCount = processedCount + 1
                    end
                end
            end
        end
    end
    
    context.debug(ctx, "处理了 %d 个符号，移动了 %d 个方法和 %d 个变量，合并了 %d 个CLASS", 
        processedCount, movedMethods, movedVariables, mergedClasses)
    
    return processedCount, movedMethods, movedVariables
end

-- 简化父类关系，只保存SYMBOL_ID或name字符串
local function resolveParentClassRelations(ctx)
    local processedCount = 0
    local mixinCount = 0
    
    -- 遍历所有类，简化其父类关系数据结构
    for className, classSymbol in pairs(ctx.classes) do
        if classSymbol.parentClasses and #classSymbol.parentClasses > 0 then
            context.debug(ctx, "简化类 %s 的父类关系", className)
            
            local simplifiedParents = {}
            local mixins = {}
            local seenParents = {}  -- 用于去重
            local seenMixins = {}   -- 用于去重
            
            for i, parentInfo in ipairs(classSymbol.parentClasses) do
                if parentInfo.type == 'component_list' then
                    -- 组件列表：提取每个组件的symbolId或name
                    for _, componentInfo in ipairs(parentInfo.components) do
                        local componentId = componentInfo.symbolId or componentInfo.name
                        if componentId and not seenMixins[componentId] then
                            seenMixins[componentId] = true
                            table.insert(mixins, componentId)
                            context.debug(ctx, "  添加混入组件: %s -> %s", className, componentId)
                            mixinCount = mixinCount + 1
                        end
                    end
                else
                    -- 单个父类：只保存symbolId或name
                    local parentId = parentInfo.symbolId or parentInfo.name
                    if parentId and not seenParents[parentId] then
                        seenParents[parentId] = true
                        table.insert(simplifiedParents, parentId)
                        context.debug(ctx, "  添加父类: %s -> %s", className, parentId)
                    end
                end
                processedCount = processedCount + 1
            end
            
            -- 更新类的父类信息，只保存简化的数据
            classSymbol.parentClasses = simplifiedParents
            if #mixins > 0 then
                classSymbol.mixins = mixins
            end
        end
    end
    
    context.debug(ctx, "父类关系简化完成：处理 %d 个父类，%d 个混入组件", processedCount, mixinCount)
    print(string.format("    父类关系简化：处理 %d 个父类，%d 个混入组件", processedCount, mixinCount))
    
    -- 输出简化后的父类关系
    if processedCount > 0 then
        print("    简化后的父类关系:")
        for className, classSymbol in pairs(ctx.classes) do
            if classSymbol.parentClasses and #classSymbol.parentClasses > 0 then
                print(string.format("      %s -> %s", className, table.concat(classSymbol.parentClasses, ", ")))
            end
            
            -- 输出混入组件
            if classSymbol.mixins and #classSymbol.mixins > 0 then
                print(string.format("      %s 混入: %s", className, table.concat(classSymbol.mixins, ", ")))
            end
        end
    end
    
    return processedCount, mixinCount
end

-- 主分析函数 - 三遍处理
function phase1.analyze(ctx)
    -- 重置节点去重状态
    context.resetProcessedNodes(ctx, "Phase1")
    
    -- 初始化节点处理跟踪器（可通过配置控制）
    if ctx.config and ctx.config.enableNodeTracking then
        trackerSymbols = nodeTracker.new("phase1_symbols")
    end
    
    -- 第一次调用时获取并缓存文件列表
    local uris = context.getFiles(ctx)
    local totalFiles = #uris
    
    context.info("  发现 %d 个Lua文件", totalFiles)
    
    -- 第一遍：建立基本符号定义（同时缓存AST和模块对象）
    context.info("  🔍 第一遍：建立符号定义...")
    for i, uri in ipairs(uris) do
        analyzeFileSymbols(ctx, uri)
        
        -- 显示进度
        if i % 10 == 0 or i == totalFiles then
            context.info("    进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100)
        end
    end
    
    context.debug(ctx, "第一遍完成，已缓存 %d 个模块对象", utils.tableSize(ctx.uriToModule))
    
    -- 第二遍：建立引用关系（使用缓存的模块对象）
    context.resetProcessedNodes(ctx, "Phase1-Round2")
    context.info("  🔗 第二遍：建立引用关系...")
    context.debug(ctx, "使用缓存的文件列表，共 %d 个文件", #ctx.fileList)
    
    -- 直接使用缓存的文件列表，不需要重新获取
    for i, uri in ipairs(ctx.fileList) do
        analyzeFileReferences(ctx, uri)
        
        -- 显示进度
        if i % 10 == 0 or i == totalFiles then
            context.info("    进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100)
        end
    end
    
    -- 调试输出：显示引用关系统计
    local totalRefs = 0
    local totalRelated = 0
    for id, symbol in pairs(ctx.symbols) do
        if symbol.refs and next(symbol.refs) then
            local refCount = countHashTable(symbol.refs)
            totalRefs = totalRefs + refCount
            context.debug(ctx, "📤 符号 %s (%s) 有 %d 个引用", symbol.name, symbol.type, refCount)
        end
        if symbol.related and next(symbol.related) then
            local relatedCount = countHashTable(symbol.related)
            totalRelated = totalRelated + relatedCount
            context.debug(ctx, "🔗 符号 %s (%s) 关联了 %d 个其他符号", symbol.name, symbol.type, relatedCount)
        end
    end
    
    context.debug(ctx, "📊 引用统计：引用关系 %d 个，关联关系 %d 个", totalRefs, totalRelated)
    context.info("    引用统计：引用关系 %d 个，关联关系 %d 个", totalRefs, totalRelated)
    
    -- 强制输出一些具体的引用信息用于调试
    if totalRelated > 0 then
        context.info("    具体的关联关系:")
        for id, symbol in pairs(ctx.symbols) do
                    if symbol.related and next(symbol.related) then
            local relatedList = {}
            for relatedId, _ in pairs(symbol.related) do
                table.insert(relatedList, relatedId)
            end
            context.info("      %s -> %s", symbol.name, table.concat(relatedList, ", "))
            end
        end
    end
    
    -- 第三遍：简化父类关系
    context.resetProcessedNodes(ctx, "Phase1-Round3")
    context.info("  🔄 第三遍：简化父类关系...")
    resolveParentClassRelations(ctx)
    
    -- 第四遍：整理类型别名，移动定义到真正的类型上
    context.resetProcessedNodes(ctx, "Phase1-Round4")
    context.info("  🔄 第四遍：整理类型别名...")
    consolidateTypeAliases(ctx)
    
    -- 统计信息
    local moduleCount = utils.tableSize(ctx.modules)
    local classCount = utils.tableSize(ctx.classes)
    local symbolCount = utils.tableSize(ctx.symbols)
    
    context.info("  ✅ 符号识别完成:")
    context.info("     模块: %d, 类: %d, 符号: %d", moduleCount, classCount, symbolCount)
    
    -- 输出节点去重统计信息
    local dedupStats = context.getDeduplicationStats(ctx)
    print(string.format("🔒 节点去重统计: 总处理节点数 %d", dedupStats.totalProcessedNodes))
    context.debug(ctx, "🔒 节点去重统计: 总处理节点数 %d", dedupStats.totalProcessedNodes)
    
    -- 输出节点处理跟踪统计
    if ctx.config.enableNodeTracking and trackerSymbols then
        nodeTracker.printStatistics(trackerSymbols)
    end
end

return phase1 
