-- analyze/phase1_symbols.lua
-- 第一阶段：符号定义识别
-- 重构版本：按照context.lua和symbol.lua的架构设计

local files = require 'files'
local guide = require 'parser.guide'
local vm = require 'vm'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'
local symbol = require 'cli.analyze.symbol'

-- 导入符号类型常量
local SYMBOL_TYPE = symbol.SYMBOL_TYPE
local FUNCTION_ANONYMOUS = symbol.FUNCTION_ANONYMOUS

local phase1 = {}

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
    
    print(string.format("  📄 分析文件: %s (%s)", fileName, modulePath))
    
    -- 创建模块符号
    local module = context.addModule(ctx, modulePath, fileName, uri, ast)
    
    -- 分析模块级别的符号定义
    guide.eachSource(ast, function(source)
        analyzeSymbolDefinition(ctx, uri, module, source)
    end)
    
    ctx.statistics.totalFiles = ctx.statistics.totalFiles + 1
end

-- 分析符号定义的主调度函数
function analyzeSymbolDefinition(ctx, uri, module, source)
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
    elseif sourceType == 'return' then
        analyzeReturnStatement(ctx, uri, module, source)
    end
end

-- 分析全局变量定义 (foo = value)
function analyzeGlobalVariableDefinition(ctx, uri, module, source)
    local varName = utils.getNodeName(source.node)
    if not varName then return end
    
    local position = utils.getNodePosition(source)
    
    -- 检查是否是require或类定义调用
    if source.value and source.value.type == 'call' then
        local callResult = analyzeCallExpression(ctx, uri, module, source.value)
        if callResult and callResult.isRequire then
            -- 这是一个require调用，创建引用
            local ref = context.addReference(ctx, callResult.moduleName, source, module)
            ref.localName = varName
            ref.position = position
            
            context.debug(ctx, "全局模块引用: %s = require('%s')", varName, callResult.moduleName)
            return
        elseif callResult and callResult.isClassDefinition then
            -- 这是一个类定义，创建类别名变量
            local className = callResult.className
            local class = ctx.classes[className]
            if class then
                -- 创建类的别名变量（作为普通容器）
                local aliasVar = context.addVariable(ctx, varName, source, module)
                table.insert(aliasVar.possibles, className)
                
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
        if source.value and source.value.type == 'call' then
            local callResult = analyzeCallExpression(ctx, uri, module, source.value)
            if callResult and callResult.isRequire then
                -- 这是一个require调用，创建引用
                local ref = context.addReference(ctx, callResult.moduleName, source, module)
                ref.localName = varName
                ref.position = position
                
                context.debug(ctx, "局部变量模块引用: %s = require('%s')", varName, callResult.moduleName)
                return
            elseif callResult and callResult.isClassDefinition then
                -- 这是一个类定义
                local className = callResult.className
                local class = ctx.classes[className]
                if class then
                    -- 更新变量的类型
                    table.insert(existingVar.possibles, className)
                    
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
        if value.type == 'call' then
            local callResult = analyzeCallExpression(ctx, uri, module, value)
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
    
    -- 分析函数体内的符号
    guide.eachSource(funcSource, function(source)
        if source ~= funcSource then  -- 避免递归处理自身
            analyzeSymbolDefinition(ctx, uri, method, source)
        end
    end)
end

-- 分析函数调用表达式
function analyzeCallExpression(ctx, uri, module, source)
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
                for i = 2, #args do
                    local arg = args[i]
                    if arg and arg.type == 'string' then
                        local parentName = utils.getStringValue(arg)
                        if parentName then
                            table.insert(class.parentClasses or {}, parentName)
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

-- 分析return语句
function analyzeReturnStatement(ctx, uri, module, source)
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
        end
        -- 其他函数调用结果在第二阶段处理
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
        analyzeSourceReferences(ctx, uri, module, source)
        
        -- 特别处理函数体：对于函数类型的节点，需要递归处理其函数体
        if source.type == 'function' then
            -- 函数体内的引用需要特殊处理，因为它们可能引用函数参数
            analyzeFunctionBodyReferences(ctx, uri, module, source)
        end
    end)
end

-- 分析函数体内的引用关系
function analyzeFunctionBodyReferences(ctx, uri, module, funcSource)
    context.debug(ctx, "分析函数体引用: %s", utils.getNodeName(funcSource) or "anonymous")
    
    -- 首先处理函数参数的引用
    if funcSource.args then
        for i, arg in ipairs(funcSource.args) do
            local paramName = utils.getNodeName(arg)
            if paramName then
                -- 查找参数对应的符号
                local paramSymbolId, paramSymbol = context.resolveName(ctx, paramName, context.findCurrentScope(ctx, funcSource))
                if paramSymbol then
                    -- 处理参数的引用
                    if arg.refs then
                        for _, ref in ipairs(arg.refs) do
                            analyzeParameterReference(ctx, uri, module, paramSymbol, ref)
                        end
                    end
                    
                    context.debug(ctx, "处理函数参数引用: %s", paramName)
                end
            end
        end
    end
    
    -- 然后递归处理函数体内的所有节点
    guide.eachSource(funcSource, function(source)
        -- 跳过函数节点本身，避免无限递归
        if source ~= funcSource then
            analyzeSourceReferences(ctx, uri, module, source)
            
            -- 如果是嵌套函数，递归处理
            if source.type == 'function' then
                analyzeFunctionBodyReferences(ctx, uri, module, source)
            end
        end
    end)
end

-- 分析函数参数的引用
function analyzeParameterReference(ctx, uri, module, paramSymbol, refNode)
    local refType = refNode.type
    
    -- 记录正向引用信息到参数符号的refs字段
    table.insert(paramSymbol.refs, {
        type = refType,
        node = refNode,
        position = utils.getNodePosition(refNode),
        uri = uri,
        isParameterReference = true
    })
    
    context.debug(ctx, "参数引用: %s -> %s", paramSymbol.name, refType)
    
    -- 根据引用类型进行处理
    if refType == 'getlocal' then
        -- 参数被引用
        local refName = utils.getNodeName(refNode)
        if refName and refName == paramSymbol.name then
            -- 在参数符号中记录被引用的信息
            table.insert(paramSymbol.references, {
                type = 'parameter_referenced',
                position = utils.getNodePosition(refNode),
                uri = uri
            })
            
            context.debug(ctx, "参数被引用: %s", paramSymbol.name)
        end
    elseif refType == 'setlocal' then
        -- 参数被重新赋值
        table.insert(paramSymbol.references, {
            type = 'parameter_reassigned',
            position = utils.getNodePosition(refNode),
            uri = uri
        })
        
        context.debug(ctx, "参数被重新赋值: %s", paramSymbol.name)
    end
end

-- 分析单个源节点的引用关系
function analyzeSourceReferences(ctx, uri, module, source)
    -- 处理当前节点的refs字段
    if source.refs then
        -- 获取当前节点对应的符号
        local currentSymbol = ctx.asts[source]
        if currentSymbol then
            -- 处理每个引用
            for _, ref in ipairs(source.refs) do
                analyzeReference(ctx, uri, module, currentSymbol, ref)
            end
        else
            -- 如果没有找到符号，说明我们的符号定义阶段有问题
            -- 应该直接报错，而不是静默处理
            error(string.format("引用分析阶段未找到符号: %s (类型: %s, 位置: %s:%d:%d)", 
                utils.getNodeName(source) or "unnamed", 
                source.type,
                utils.getFileName(uri),
                source.start and source.start.line or 0,
                source.start and source.start.character or 0))
        end
    end
    
    -- 第一阶段只处理符号间的引用关系，不进行类型推断
    -- 类型推断将在第二阶段(phase2_inference.lua)中处理
end

-- 分析单个引用
function analyzeReference(ctx, uri, module, sourceSymbol, refNode)
    local refType = refNode.type
    
    -- 记录正向引用信息到源符号的refs字段
    table.insert(sourceSymbol.refs, {
        type = refType,
        node = refNode,
        position = utils.getNodePosition(refNode),
        uri = uri
    })
    
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
                    table.insert(sourceSymbol.related, targetSymbol.id)
                    context.debug(ctx, "变量关联: %s -> %s (ID: %s)", sourceSymbol.name, refName, targetSymbol.id)
                end
                
                -- 在目标符号中记录反向引用
                table.insert(targetSymbol.references, {
                    type = 'referenced_by',
                    source_id = sourceSymbol.id,
                    position = utils.getNodePosition(refNode),
                    uri = uri
                })
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
                
                -- 记录字段引用
                table.insert(sourceSymbol.refs, {
                    type = 'field_reference',
                    object_id = objSymbol.id,
                    field_id = fieldSymbol and fieldSymbol.id or nil,
                    position = utils.getNodePosition(refNode),
                    uri = uri
                })
                
                -- 如果找到了字段符号，建立反向引用
                if fieldSymbol then
                    table.insert(fieldSymbol.references, {
                        type = 'field_accessed',
                        source_id = sourceSymbol.id,
                        position = utils.getNodePosition(refNode),
                        uri = uri
                    })
                end
                
                context.debug(ctx, "字段引用: %s -> %s.%s (字段ID: %s)", 
                    sourceSymbol.name, objName, fieldName, fieldSymbol and fieldSymbol.id or "未找到")
            end
        end
    elseif refType == 'call' then
        -- 函数调用引用
        local funcName = utils.getNodeName(refNode.node)
        if funcName then
            -- 查找函数符号
            local funcSymbolId, funcSymbol = context.resolveName(ctx, funcName, context.findCurrentScope(ctx, refNode))
            if funcSymbol then
                table.insert(sourceSymbol.refs, {
                    type = 'function_call',
                    function_id = funcSymbol.id,
                    position = utils.getNodePosition(refNode),
                    uri = uri
                })
                
                -- 在函数符号中记录反向引用
                table.insert(funcSymbol.references, {
                    type = 'called_by',
                    source_id = sourceSymbol.id,
                    position = utils.getNodePosition(refNode),
                    uri = uri
                })
                
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

-- 收集单个class的所有引用变量（递归处理refs）
function collectClassReferencingVariables(ctx, classSymbol, visited)
    visited = visited or {}
    
    -- 防止循环引用
    if visited[classSymbol.id] then
        return {}
    end
    visited[classSymbol.id] = true
    
    local referencingVariables = {}
    
    -- 查找所有引用了这个class的变量
    -- 通过遍历所有符号，找到那些在possibles中包含这个class的变量
    for id, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.VARIABLE and symbol.possibles then
            -- 检查这个变量是否引用了当前class
            for _, possible in ipairs(symbol.possibles) do
                if possible == classSymbol.name then
                    table.insert(referencingVariables, symbol)
                    context.debug(ctx, "找到引用class的变量: %s -> %s", symbol.name, classSymbol.name)
                    break
                end
            end
        end
    end
    
    -- 递归处理：如果找到的变量本身也有refs，继续查找引用这些变量的其他变量
    local originalVariables = {}
    for _, var in ipairs(referencingVariables) do
        table.insert(originalVariables, var)
    end
    
    for _, var in ipairs(originalVariables) do
        if var.refs and #var.refs > 0 then
            -- 查找所有引用了这个变量的其他变量
            for _, ref in ipairs(var.refs) do
                if ref.type == 'getlocal' or ref.type == 'getglobal' then
                    local refName = utils.getNodeName(ref.node)
                    if refName then
                        local refSymbolId, refSymbol = context.resolveName(ctx, refName, context.findCurrentScope(ctx, ref.node))
                        if refSymbol and refSymbol.type == SYMBOL_TYPE.VARIABLE then
                            -- 检查是否已经在列表中
                            local alreadyExists = false
                            for _, existingVar in ipairs(referencingVariables) do
                                if existingVar.id == refSymbol.id then
                                    alreadyExists = true
                                    break
                                end
                            end
                            
                            if not alreadyExists then
                                table.insert(referencingVariables, refSymbol)
                                context.debug(ctx, "找到间接引用class的变量: %s -> %s -> %s", 
                                    refSymbol.name, var.name, classSymbol.name)
                            end
                        end
                    end
                end
            end
        end
    end
    
    visited[classSymbol.id] = nil
    return referencingVariables
end

-- 处理通过引用关系找到的后继符号
function processReferenceBasedAliases(ctx)
    local processedCount = 0
    local movedMethods = 0
    local movedVariables = 0
    
    -- 遍历所有模块
    for moduleName, module in pairs(ctx.modules) do
        context.debug(ctx, "处理模块 %s 中的class符号", moduleName)
        
        -- 查找模块中的所有class类型符号
        if module.classes and #module.classes > 0 then
            for _, classId in ipairs(module.classes) do
                local classSymbol = ctx.symbols[classId]
                if classSymbol and classSymbol.type == SYMBOL_TYPE.CLASS then
                    context.debug(ctx, "处理class: %s (ID: %s)", classSymbol.name, classId)
                    
                    -- 收集所有引用这个class的变量（包括递归refs）
                    local referencingVariables = collectClassReferencingVariables(ctx, classSymbol)
                    
                    if #referencingVariables > 0 then
                        context.debug(ctx, "class %s 被 %d 个变量引用", classSymbol.name, #referencingVariables)
                        
                        -- 处理每个引用变量，检查是否有定义需要移动
                        for _, varSymbol in ipairs(referencingVariables) do
                            -- 检查变量是否有定义（methods或variables）
                            local hasDefinitions = (varSymbol.methods and #varSymbol.methods > 0) or
                                                 (varSymbol.variables and #varSymbol.variables > 0)
                            
                            if hasDefinitions then
                                -- 移动定义到class
                                if varSymbol.methods and #varSymbol.methods > 0 then
                                    for _, methodId in ipairs(varSymbol.methods) do
                                        local method = ctx.symbols[methodId]
                                        if method then
                                            table.insert(classSymbol.methods, methodId)
                                            method.parent = classSymbol
                                            movedMethods = movedMethods + 1
                                            
                                            context.debug(ctx, "移动方法: %s.%s -> %s.%s", 
                                                varSymbol.name, method.name, classSymbol.name, method.name)
                                        end
                                    end
                                    varSymbol.methods = {}
                                end
                                
                                if varSymbol.variables and #varSymbol.variables > 0 then
                                    for _, varId in ipairs(varSymbol.variables) do
                                        local var = ctx.symbols[varId]
                                        if var then
                                            table.insert(classSymbol.variables, varId)
                                            var.parent = classSymbol
                                            movedVariables = movedVariables + 1
                                            
                                            context.debug(ctx, "移动变量: %s.%s -> %s.%s", 
                                                varSymbol.name, var.name, classSymbol.name, var.name)
                                        end
                                    end
                                    varSymbol.variables = {}
                                end
                                
                                -- 标记变量为别名
                                varSymbol.isAlias = true
                                varSymbol.aliasTarget = classSymbol.id
                                varSymbol.aliasTargetName = classSymbol.name
                                
                                processedCount = processedCount + 1
                                context.debug(ctx, "标记别名: %s -> %s", 
                                    varSymbol.name, classSymbol.name)
                            end
                        end
                    end
                end
            end
        end
    end
    
    context.debug(ctx, "处理了 %d 个class别名，移动了 %d 个方法和 %d 个变量", 
        processedCount, movedMethods, movedVariables)
    
    return processedCount, movedMethods, movedVariables
end

-- 主分析函数 - 三遍处理
function phase1.analyze(ctx)
    -- 第一次调用时获取并缓存文件列表
    local uris = context.getFiles(ctx)
    local totalFiles = #uris
    
    print(string.format("  发现 %d 个Lua文件", totalFiles))
    
    -- 第一遍：建立基本符号定义（同时缓存AST和模块对象）
    print("  🔍 第一遍：建立符号定义...")
    for i, uri in ipairs(uris) do
        analyzeFileSymbols(ctx, uri)
        
        -- 显示进度
        if i % 10 == 0 or i == totalFiles then
            print(string.format("    进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100))
        end
    end
    
    context.debug(ctx, "第一遍完成，已缓存 %d 个模块对象", utils.tableSize(ctx.uriToModule))
    
    -- 第二遍：建立引用关系（使用缓存的模块对象）
    print("  🔗 第二遍：建立引用关系...")
    context.debug(ctx, "使用缓存的文件列表，共 %d 个文件", #ctx.fileList)
    
    -- 直接使用缓存的文件列表，不需要重新获取
    for i, uri in ipairs(ctx.fileList) do
        analyzeFileReferences(ctx, uri)
        
        -- 显示进度
        if i % 10 == 0 or i == totalFiles then
            print(string.format("    进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100))
        end
    end
    
    -- 调试输出：显示引用关系统计
    local totalRefs = 0
    local totalReferences = 0
    local totalRelated = 0
    for id, symbol in pairs(ctx.symbols) do
        if symbol.refs and #symbol.refs > 0 then
            totalRefs = totalRefs + #symbol.refs
            context.debug(ctx, "📤 符号 %s (%s) 有 %d 个正向引用", symbol.name, symbol.type, #symbol.refs)
        end
        if symbol.references and #symbol.references > 0 then
            totalReferences = totalReferences + #symbol.references
            context.debug(ctx, "📥 符号 %s (%s) 有 %d 个反向引用", symbol.name, symbol.type, #symbol.references)
        end
        if symbol.related and #symbol.related > 0 then
            totalRelated = totalRelated + #symbol.related
            context.debug(ctx, "🔗 符号 %s (%s) 关联了 %d 个其他符号", symbol.name, symbol.type, #symbol.related)
        end
    end
    
    context.debug(ctx, "📊 引用统计：正向引用 %d 个，反向引用 %d 个，关联关系 %d 个", 
        totalRefs, totalReferences, totalRelated)
    print(string.format("    引用统计：正向引用 %d 个，反向引用 %d 个，关联关系 %d 个", 
        totalRefs, totalReferences, totalRelated))
    
    -- 强制输出一些具体的引用信息用于调试
    if totalRelated > 0 then
        print("    具体的关联关系:")
        for id, symbol in pairs(ctx.symbols) do
            if symbol.related and #symbol.related > 0 then
                print(string.format("      %s -> %s", symbol.name, table.concat(symbol.related, ", ")))
            end
        end
    end
    
    -- 第三遍：整理类型别名，移动定义到真正的类型上
    print("  🔄 第三遍：整理类型别名...")
    consolidateTypeAliases(ctx)
    
    -- 统计信息
    local moduleCount = utils.tableSize(ctx.modules)
    local classCount = utils.tableSize(ctx.classes)
    local symbolCount = utils.tableSize(ctx.symbols)
    
    print(string.format("  ✅ 符号识别完成:"))
    print(string.format("     模块: %d, 类: %d, 符号: %d", 
        moduleCount, classCount, symbolCount))
end

return phase1 
