-- analyze/phase1_symbols.lua
-- 第一阶段：符号定义识别

local files = require 'files'
local guide = require 'parser.guide'
local vm = require 'vm'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'

local phase1 = {}

-- 分析单个文件的符号定义
local function analyzeFileSymbols(ctx, uri)
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
    local fileName = utils.getFileName(uri)
    local modulePath = utils.getModulePath(uri, ctx.rootUri)
    
    print(string.format("  📄 分析文件: %s (%s)", fileName, modulePath))
    
    -- 创建模块符号
    local moduleId = context.addSymbol(ctx, 'module', {
        name = modulePath,
        fileName = fileName,
        uri = uri,
        exports = {},
        classes = {},
        functions = {},
        variables = {}
    })
    
    -- 分析模块级别的符号定义
    guide.eachSource(ast, function(source)
        analyzeSymbolDefinition(ctx, uri, moduleId, source)
    end)
    
    ctx.statistics.totalFiles = ctx.statistics.totalFiles + 1
end

-- 分析符号定义
function analyzeSymbolDefinition(ctx, uri, moduleId, source)
    local sourceType = source.type
    
    if sourceType == 'setlocal' or sourceType == 'setglobal' then
        analyzeVariableDefinition(ctx, uri, moduleId, source)
    elseif sourceType == 'call' then
        analyzeCallDefinition(ctx, uri, moduleId, source)
    elseif sourceType == 'function' then
        analyzeFunctionDefinition(ctx, uri, moduleId, source)
    elseif sourceType == 'return' then
        analyzeReturnStatement(ctx, uri, moduleId, source)
    elseif sourceType == 'local' then
        -- 处理local节点（包含变量定义）
        analyzeLocalStatement(ctx, uri, moduleId, source)
    end
end

-- 分析变量定义
function analyzeVariableDefinition(ctx, uri, moduleId, source)
    local varName = utils.getNodeName(source.node)
    if not varName then return end
    
    local position = utils.getNodePosition(source)
    local scope = utils.getScopeInfo(source)
    
    -- 检查是否是require语句
    if source.value and source.value.type == 'call' then
        local callNode = source.value.node
        if callNode and callNode.type == 'getglobal' then
            local funcName = utils.getNodeName(callNode)
            
            if utils.isRequireFunction(funcName, ctx.config.requireFunctions) then
                analyzeRequireStatement(ctx, uri, moduleId, source, varName, position)
                return
            end
        end
    end
    
    -- 普通变量定义
    local varId = context.addSymbol(ctx, 'variable', {
        name = varName,
        module = moduleId,
        uri = uri,
        scope = scope,
        position = position,
        isGlobal = source.type == 'setglobal',
        valueType = source.value and source.value.type or 'unknown'
    })
    
    -- 将变量添加到模块中
    local moduleSymbol = ctx.symbols.modules[moduleId]
    if moduleSymbol then
        table.insert(moduleSymbol.variables, varId)
    end
    
    context.debug(ctx, "变量定义: %s (ID: %s)", varName, varId)
end

-- 分析require语句
function analyzeRequireStatement(ctx, uri, moduleId, source, varName, position)
    local args = source.value.args
    if not args or not args[1] or args[1].type ~= 'string' then
        return
    end
    
    local modulePath = utils.getStringValue(args[1])
    if not modulePath then return end
    
    local moduleType = modulePath:match("([^./]+)$") or modulePath
    
    -- 创建模块导入符号
    local importId = context.addSymbol(ctx, 'variable', {
        name = varName,
        module = moduleId,
        uri = uri,
        position = position,
        isImport = true,
        importPath = modulePath,
        importedModule = moduleType
    })
    
    -- 注册别名映射（稍后在找到实际类定义时会更新）
    ctx.symbols.aliases[varName] = {
        type = 'module_import',
        targetModule = moduleType,
        symbolId = importId
    }
    
    print(string.format("    ✅ require识别: %s = require('%s') → 模块 %s", varName, modulePath, moduleType))
    
    -- 将导入添加到模块中
    local moduleSymbol = ctx.symbols.modules[moduleId]
    if moduleSymbol then
        table.insert(moduleSymbol.variables, importId)
    end
end

-- 分析调用定义（主要是类定义）
function analyzeCallDefinition(ctx, uri, moduleId, source)
    local callNode = source.node
    if not callNode or callNode.type ~= 'getglobal' then
        return
    end
    
    local funcName = utils.getNodeName(callNode)
    if not utils.isClassFunction(funcName, ctx.config.classFunctions) then
        return
    end
    
    local args = source.args
    if not args or not args[1] or args[1].type ~= 'string' then
        return
    end
    
    local className = utils.getStringValue(args[1])
    if not className then return end
    
    local position = utils.getNodePosition(source)
    
    -- 解析继承关系
    local parentClasses = {}
    for i = 2, #args do
        local arg = args[i]
        if arg and arg.type == 'string' then
            local parentName = utils.getStringValue(arg)
            if parentName then
                table.insert(parentClasses, parentName)
            end
        elseif arg and (arg.type == 'getlocal' or arg.type == 'getglobal') then
            local parentVarName = utils.getNodeName(arg)
            if parentVarName then
                -- 通过别名查找真实类名
                local alias = ctx.symbols.aliases[parentVarName]
                if alias and alias.targetClass then
                    table.insert(parentClasses, alias.targetClass)
                else
                    table.insert(parentClasses, parentVarName)
                end
            end
        end
    end
    
    -- 创建类定义符号
    local classId = context.addSymbol(ctx, 'class', {
        name = className,
        module = moduleId,
        uri = uri,
        position = position,
        defineType = funcName,
        parentClasses = parentClasses,
        members = {},
        methods = {}
    })
    
    -- 查找关联的变量（通过parent关系）
    local parent = source.parent
    
    -- 寻找变量名的多种方式
    local varName = nil
    
    -- 方式1：直接parent是setlocal/setglobal/local
    if parent and (parent.type == 'setlocal' or parent.type == 'setglobal') then
        varName = utils.getNodeName(parent.node)
    elseif parent and parent.type == 'local' then
        varName = parent[1] -- local节点的变量名在[1]中
    end
    
    -- 方式2：parent是select，需要向上寻找
    if not varName and parent then
        local grandparent = parent.parent
        if grandparent and (grandparent.type == 'setlocal' or grandparent.type == 'setglobal') then
            varName = utils.getNodeName(grandparent.node)
        elseif grandparent and grandparent.type == 'local' then
            varName = grandparent[1] -- local节点的变量名在[1]中
        end
    end
    
    -- 方式3：通过call节点的parent寻找
    if not varName then
        local currentNode = source
        while currentNode and currentNode.parent do
            currentNode = currentNode.parent
            if currentNode.type == 'setlocal' or currentNode.type == 'setglobal' then
                varName = utils.getNodeName(currentNode.node)
                break
            elseif currentNode.type == 'local' then
                varName = currentNode[1] -- local节点的变量名在[1]中
                break
            end
        end
    end
    
    if varName then
        -- 注册别名映射
        ctx.symbols.aliases[varName] = {
            type = 'class_definition',
            targetClass = className,
            symbolId = classId
        }
        
        context.debug(ctx, "类定义: %s (变量: %s)", className, varName)
    else
        print(string.format("    ⚠️  未找到关联变量，parent类型: %s", parent and parent.type or "nil"))
    end
    
    -- 将类添加到模块中
    local moduleSymbol = ctx.symbols.modules[moduleId]
    if moduleSymbol then
        table.insert(moduleSymbol.classes, classId)
    end
    
    context.debug(ctx, "类定义: %s (ID: %s)", className, classId)
end

-- 分析函数定义
function analyzeFunctionDefinition(ctx, uri, moduleId, source)
    local funcName = "anonymous"
    local isMethod = false
    local className = nil
    
    -- 获取函数名和类型
    local parent = source.parent
    if parent then
        if parent.type == 'setmethod' then
            isMethod = true
            local node = parent.node
            local method = parent.method
            if node and method then
                local objName = utils.getNodeName(node)
                local methodName = utils.getNodeName(method)
                if objName and methodName then
                    funcName = objName .. ':' .. methodName
                    className = objName
                end
            end
        elseif parent.type == 'setfield' then
            local node = parent.node
            local field = parent.field
            if node and field then
                local objName = utils.getNodeName(node)
                local fieldName = utils.getNodeName(field)
                if objName and fieldName then
                    funcName = objName .. '.' .. fieldName
                    className = objName
                end
            end
        elseif parent.type == 'setlocal' or parent.type == 'setglobal' then
            local varName = utils.getNodeName(parent.node)
            if varName then
                funcName = varName
            end
        end
    end
    
    local position = utils.getNodePosition(source)
    local scope = utils.getScopeInfo(source)
    
    -- 分析参数
    local params = {}
    if source.args then
        for i, arg in ipairs(source.args) do
            local paramName = utils.getNodeName(arg)
            if paramName then
                table.insert(params, {
                    name = paramName,
                    index = i,
                    position = utils.getNodePosition(arg)
                })
            end
        end
    end
    
    -- 创建函数符号
    local funcId = context.addSymbol(ctx, 'function', {
        name = funcName,
        module = moduleId,
        uri = uri,
        position = position,
        scope = scope,
        isMethod = isMethod,
        className = className,
        params = params,
        isAnonymous = funcName == "anonymous"
    })
    
    -- 将函数添加到模块中
    local moduleSymbol = ctx.symbols.modules[moduleId]
    if moduleSymbol then
        table.insert(moduleSymbol.functions, funcId)
    end
    
    -- 如果是类方法或静态函数，添加到类中
    if className then
        local alias = ctx.symbols.aliases[className]
        if alias and alias.type == 'class_definition' then
            local classSymbol = ctx.symbols.classes[alias.symbolId]
            if classSymbol then
                table.insert(classSymbol.methods, funcId)
                context.debug(ctx, "方法关联: %s -> %s (%s)", 
                    funcName, classSymbol.name, isMethod and "方法" or "静态函数")
            end
        end
    end
    
    context.debug(ctx, "函数定义: %s (ID: %s)", funcName, funcId)
end

-- 分析return语句
function analyzeReturnStatement(ctx, uri, moduleId, source)
    local returns = source.returns
    if not returns or #returns == 0 then
        return
    end
    
    -- 分析第一个返回值
    local firstReturn = returns[1]
    if not firstReturn then return end
    
    local position = utils.getNodePosition(source)
    
    -- 记录模块返回信息
    local moduleSymbol = ctx.symbols.modules[moduleId]
    if moduleSymbol then
        moduleSymbol.returnStatement = {
            position = position,
            returnType = firstReturn.type,
            returnNode = firstReturn
        }
        
        -- 如果返回的是变量，记录变量名
        if firstReturn.type == 'getlocal' or firstReturn.type == 'getglobal' then
            local varName = utils.getNodeName(firstReturn)
            if varName then
                moduleSymbol.returnVariable = varName
                context.debug(ctx, "模块返回: %s", varName)
            end
        end
    end
end

-- 分析local语句
function analyzeLocalStatement(ctx, uri, moduleId, source)
    if not source.keys or not source.values then return end
    
    -- 处理每个变量定义
    for i, key in ipairs(source.keys) do
        local varName = utils.getNodeName(key)
        if varName then
            local position = utils.getNodePosition(key)
            local scope = utils.getScopeInfo(source)
            local value = source.values[i]
            
            -- 检查是否是require语句
            if value and value.type == 'call' then
                local callNode = value.node
                if callNode and callNode.type == 'getglobal' then
                    local funcName = utils.getNodeName(callNode)
                    
                    if utils.isRequireFunction(funcName, ctx.config.requireFunctions) then
                        analyzeRequireStatement(ctx, uri, moduleId, {
                            node = key,
                            value = value,
                            type = 'setlocal'
                        }, varName, position)
                        goto continue
                    end
                end
            end
            
            -- 普通变量定义
            local varId = context.addSymbol(ctx, 'variable', {
                name = varName,
                module = moduleId,
                uri = uri,
                scope = scope,
                position = position,
                isGlobal = false,
                valueType = value and value.type or 'unknown'
            })
            
            -- 将变量添加到模块中
            local moduleSymbol = ctx.symbols.modules[moduleId]
            if moduleSymbol then
                table.insert(moduleSymbol.variables, varId)
            end
            
            context.debug(ctx, "局部变量定义: %s (ID: %s)", varName, varId)
            
            ::continue::
        end
    end
end

-- 主分析函数
function phase1.analyze(ctx)
    local uris = context.getFiles(ctx)
    local totalFiles = #uris
    
    print(string.format("  发现 %d 个Lua文件", totalFiles))
    
    for i, uri in ipairs(uris) do
        analyzeFileSymbols(ctx, uri)
        
        -- 显示进度
        if i % 10 == 0 or i == totalFiles then
            print(string.format("  进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100))
        end
    end
    
    -- 后处理：重新关联类方法和静态函数
    context.debug(ctx, "后处理：重新关联类方法和静态函数")
    local methodsLinked = 0
    for funcId, func in pairs(ctx.symbols.functions) do
        -- 处理类方法（isMethod=true）和静态函数（className存在但isMethod=false）
        if func.className then
            local alias = ctx.symbols.aliases[func.className]
            if alias and alias.type == 'class_definition' then
                local classSymbol = ctx.symbols.classes[alias.symbolId]
                if classSymbol then
                    -- 检查是否已经关联
                    local alreadyLinked = false
                    for _, methodId in ipairs(classSymbol.methods) do
                        if methodId == funcId then
                            alreadyLinked = true
                            break
                        end
                    end
                    
                    if not alreadyLinked then
                        table.insert(classSymbol.methods, funcId)
                        methodsLinked = methodsLinked + 1
                        context.debug(ctx, "重新关联: %s -> %s (%s)", 
                            func.name, classSymbol.name, func.isMethod and "方法" or "静态函数")
                    end
                end
            end
        end
    end
    context.debug(ctx, "重新关联了 %d 个方法和静态函数", methodsLinked)
    
    -- 统计信息
    local moduleCount = utils.tableSize(ctx.symbols.modules)
    local classCount = utils.tableSize(ctx.symbols.classes)
    local functionCount = utils.tableSize(ctx.symbols.functions)
    local variableCount = utils.tableSize(ctx.symbols.variables)
    local aliasCount = utils.tableSize(ctx.symbols.aliases)
    
    print(string.format("  ✅ 符号识别完成:"))
    print(string.format("     模块: %d, 类: %d, 函数: %d, 变量: %d, 别名: %d", 
        moduleCount, classCount, functionCount, variableCount, aliasCount))
end

return phase1 