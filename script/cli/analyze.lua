local lclient   = require 'lclient'()
local furi      = require 'file-uri'
local ws        = require 'workspace'
local files     = require 'files'
local util      = require 'utility'
local jsonb     = require 'json-beautify'
local lang      = require 'language'
local config    = require 'config.config'
local fs        = require 'bee.filesystem'
local provider  = require 'provider'
local await     = require 'await'
local parser    = require 'parser'
local guide     = require 'parser.guide'
local vm        = require 'vm'
require 'plugin'

local export = {}

-- 分析结果存储
local analysisResults = {
    metadata = {
        generatedAt = '',
        analyzer = 'lua-language-server-based',
        version = '1.0.0'
    },
    nodes = {},
    relations = {},
    classAliases = {},
    callGraph = {},
    typeInferences = {},
    inheritanceGraph = {}, -- 新增：继承关系图
    statistics = {
        totalFiles = 0,
        totalNodes = 0,
        totalRelations = 0,
        processingTime = 0
    }
}

-- 节点和关系计数器
local nodeCounter = 0
local relationCounter = 0

-- 变量类型跟踪（全局）
local variableTypes = {}

-- 生成唯一ID
local function generateId(prefix)
    if prefix == 'node' then
        nodeCounter = nodeCounter + 1
        return 'node_' .. nodeCounter
    elseif prefix == 'relation' then
        relationCounter = relationCounter + 1
        return 'rel_' .. relationCounter
    end
end

-- 添加节点
local function addNode(nodeType, name, metadata)
    local node = {
        id = generateId('node'),
        type = nodeType,
        name = name,
        metadata = metadata or {}
    }
    table.insert(analysisResults.nodes, node)
    analysisResults.statistics.totalNodes = analysisResults.statistics.totalNodes + 1
    return node.id
end

-- 添加关系
local function addRelation(relType, fromId, toId, metadata)
    local relation = {
        id = generateId('relation'),
        type = relType,
        from = fromId,
        to = toId,
        metadata = metadata or {}
    }
    table.insert(analysisResults.relations, relation)
    analysisResults.statistics.totalRelations = analysisResults.statistics.totalRelations + 1
    return relation.id
end

-- 分析require语句和模块别名
local function analyzeRequireStatement(uri, source)
    if source.type ~= 'setlocal' and source.type ~= 'setglobal' then
        return
    end
    
    local value = source.value
    if not value or value.type ~= 'call' then
        return
    end
    
    local callNode = value.node
    if not callNode or callNode.type ~= 'getglobal' then
        return
    end
    
    local callNodeName = callNode[1]
    if not callNodeName or (callNodeName ~= 'require' and callNodeName ~= 'kg_require') then
        return
    end
    
    local args = value.args
    if not args or not args[1] or args[1].type ~= 'string' then
        return
    end
    
    local modulePath = args[1][1]
    if not modulePath then
        return
    end
    
    local varName = source.node and source.node[1]
    if not varName then
        return
    end
    
    -- 推断模块类型
    local moduleType = modulePath:match("([^./]+)$") or modulePath
    
    -- 注册模块别名和变量类型
    analysisResults.classAliases[varName] = moduleType
    variableTypes[varName] = moduleType
    
    print(string.format("✅ 识别require: %s = require('%s') → %s", varName, modulePath, moduleType))
    
    -- 添加节点和关系...
    local moduleId = addNode('module', moduleType, {
        uri = uri,
        modulePath = modulePath,
        line = guide.rowColOf(source.start) + 1,
        position = source.start
    })
    
    local varType = source.type == 'setglobal' and 'global' or 'variable'
    local varId = addNode(varType, varName, {
        uri = uri,
        moduleType = moduleType,
        line = guide.rowColOf(source.start) + 1,
        position = source.start
    })
    
    addRelation('imports', varId, moduleId, {
        uri = uri,
        modulePath = modulePath,
        line = guide.rowColOf(source.start) + 1
    })
end

-- 分析变量赋值和类型推断
local function analyzeVariableAssignment(uri, source)
    if source.type ~= 'setlocal' and source.type ~= 'setglobal' then
        return
    end
    
    local varName = source.node and source.node[1]
    if not varName then
        return
    end
    
    -- 使用vm.getInfer获取真实类型
    local typeView = vm.getInfer(source):view(uri)
    if typeView and typeView ~= 'unknown' and typeView ~= 'any' then
        variableTypes[varName] = typeView
        print(string.format("✅ 类型推断: %s → %s", varName, typeView))
        
        -- 如果是构造函数调用，尝试提取类名
        if source.value and source.value.type == 'call' then
            local callNode = source.value.node
            if callNode and callNode.type == 'getmethod' then
                local method = callNode.method
                if method and method[1] == 'new' then
                    local object = callNode.node
                    if object and object[1] then
                        local objName = object[1]
                        local realClassName = variableTypes[objName] or analysisResults.classAliases[objName] or objName
                        variableTypes[varName] = realClassName
                        print(string.format("✅ 构造函数推断: %s = %s:new() → %s类型", varName, objName, realClassName))
                    end
                end
            end
        end
    end
end

-- 分析所有变量和类型
local function analyzeAllVariables(uri, ast)
    local fileName = furi.decode(uri):match("([^/\\]+)%.lua$") or furi.decode(uri)
    local isGameManager = (fileName == "game_manager")
    
    if isGameManager then
        print("🔍 [GM] 开始详细分析game_manager文件")
    end
    
    -- 分析setlocal节点
    guide.eachSourceType(ast, 'setlocal', function(source)
        local varName = source.node and source.node[1]
        if not varName then
            return
        end
        
        if isGameManager then
            print(string.format("🔍 [GM] 发现setlocal: %s", varName))
            if source.value then
                print(string.format("    值类型: %s", source.value.type))
                if source.value.type == 'call' then
                    local callNode = source.value.node
                    if callNode then
                        print(string.format("    call节点类型: %s", callNode.type))
                        if callNode.type == 'getglobal' then
                            print(string.format("    全局函数名: %s", callNode[1] or "nil"))
                        elseif callNode.type == 'getmethod' then
                            local obj = callNode.node
                            local method = callNode.method
                            if obj and method then
                                print(string.format("    方法调用: %s:%s", obj[1] or "nil", method[1] or "nil"))
                            end
                        end
                    end
                else
                    print("    没有值")
                end
            end
        end
        
        -- 检查require语句（支持require和kg_require）
        if source.value and source.value.type == 'call' then
            local callNode = source.value.node
            if callNode and callNode.type == 'getglobal' and (callNode[1] == 'require' or callNode[1] == 'kg_require') then
                local args = source.value.args
                if args and args[1] and args[1].type == 'string' then
                    local modulePath = args[1][1]
                    if modulePath then
                        local moduleType = modulePath:match("([^./]+)$") or modulePath
                        analysisResults.classAliases[varName] = moduleType
                        variableTypes[varName] = moduleType
                        print(string.format("✅ require识别: %s = %s('%s') → %s", varName, callNode[1], modulePath, moduleType))
                    end
                end
            elseif callNode and callNode.type == 'getmethod' then
                -- 构造函数调用
                local method = callNode.method
                if method and method[1] == 'new' then
                    local object = callNode.node
                    if object and object[1] then
                        local objName = object[1]
                        local realClassName = variableTypes[objName] or analysisResults.classAliases[objName] or objName
                        variableTypes[varName] = realClassName
                        print(string.format("✅ 构造函数: %s = %s:new() → %s类型", varName, objName, realClassName))
                    end
                end
            end
        end
        
        -- 使用vm.getInfer获取类型
        if not variableTypes[varName] then
            local typeView = vm.getInfer(source):view(uri)
            if typeView and typeView ~= 'unknown' and typeView ~= 'any' then
                variableTypes[varName] = typeView
                if isGameManager then
                    print(string.format("✅ [GM] 类型推断: %s → %s", varName, typeView))
                end
            end
        end
    end)
    
    -- 分析setglobal节点
    guide.eachSourceType(ast, 'setglobal', function(source)
        local varName = source.node and source.node[1]
        if not varName then
            return
        end
        
        -- 类似setlocal的处理逻辑（支持require和kg_require）
        if source.value and source.value.type == 'call' then
            local callNode = source.value.node
            if callNode and callNode.type == 'getglobal' and (callNode[1] == 'require' or callNode[1] == 'kg_require') then
                local args = source.value.args
                if args and args[1] and args[1].type == 'string' then
                    local modulePath = args[1][1]
                    if modulePath then
                        local moduleType = modulePath:match("([^./]+)$") or modulePath
                        analysisResults.classAliases[varName] = moduleType
                        variableTypes[varName] = moduleType
                        print(string.format("✅ 全局require: %s = %s('%s') → %s", varName, callNode[1], modulePath, moduleType))
                    end
                end
            end
        end
    end)
    
    -- 分析local节点（局部变量定义）
    guide.eachSourceType(ast, 'local', function(source)
        local varName = source[1]
        if varName then
            local typeView = vm.getInfer(source):view(uri)
            if typeView and typeView ~= 'unknown' and typeView ~= 'any' then
                variableTypes[varName] = typeView
                if isGameManager then
                    print(string.format("✅ [GM] 局部变量定义: %s → %s", varName, typeView))
                end
            end
        end
    end)
    
    -- 分析变量引用，获取内置函数和库的类型
    guide.eachSourceType(ast, 'getglobal', function(source)
        local varName = source[1]
        if varName and not variableTypes[varName] then
            local typeView = vm.getInfer(source):view(uri)
            if typeView and typeView ~= 'unknown' and typeView ~= 'any' then
                variableTypes[varName] = typeView
                if not isGameManager then -- 只对非GM文件显示，减少输出
                    print(string.format("✅ 全局变量: %s → %s", varName, typeView))
                end
            end
        end
    end)
    
    if isGameManager then
        print("🔍 [GM] game_manager文件分析完成")
    end
end

-- 分析构造函数调用和变量类型推断
local function analyzeConstructorCall(uri, source)
    if source.type ~= 'setlocal' and source.type ~= 'setglobal' then
        return
    end
    
    local value = source.value
    if not value or value.type ~= 'call' then
        return
    end
    
    local callNode = value.node
    if not callNode or callNode.type ~= 'getmethod' then
        return
    end
    
    local object = callNode.node
    local method = callNode.method
    
    if not object or not method then
        return
    end
    
    -- 检查是否是构造函数调用 (obj:new())
    local methodName = nil
    if method.type == 'string' then
        methodName = method[1]
    else
        methodName = method[1]
    end
    
    if methodName == 'new' then
        -- 获取对象名
        local objName = nil
        if object.type == 'getlocal' or object.type == 'getglobal' then
            objName = object[1]
        end
        
        -- 获取变量名
        local varName = nil
        if source.node and source.node[1] then
            varName = source.node[1]
        end
        
        if objName and varName then
            -- 推断变量类型
            local realClassName = analysisResults.classAliases[objName] or variableTypes[objName] or objName
            
            -- 记录变量类型
            variableTypes[varName] = realClassName
            
            print(string.format("✅ 识别构造函数: %s = %s:new() → %s类型", varName, objName, realClassName))
            
            -- 添加实例节点
            local instanceId = addNode('instance', varName, {
                uri = uri,
                instanceType = realClassName,
                constructorCall = true,
                line = guide.rowColOf(source.start) + 1,
                position = source.start
            })
            
            -- 添加实例化关系
            addRelation('instantiates', instanceId, realClassName, {
                uri = uri,
                constructorObject = objName,
                line = guide.rowColOf(source.start) + 1
            })
        end
    end
end

-- 分析类定义调用（支持多种定义方式和继承关系）
local function analyzeDefineClass(uri, source)
    if source.type ~= 'call' then
        return
    end
    
    local node = source.node
    if not node or node.type ~= 'getglobal' then
        return
    end
    
    -- 支持的类定义函数列表
    local defineTypes = {
        "DefineClass", "CreateClass", "DefineEntity",
        "DefineBriefEntity", "DefineLocalEntity", "DefineComponent", "DefineSingletonClass"
    }
    
    local nodeName = node[1]
    if not nodeName then
        return
    end
    
    -- 检查是否是支持的类定义函数
    local isDefineType = false
    for _, defineType in ipairs(defineTypes) do
        if nodeName == defineType then
            isDefineType = true
            break
        end
    end
    
    if not isDefineType then
        return
    end
    
    -- 添加调试信息
    local fileName = furi.decode(uri):match("([^/\\]+)%.lua$") or furi.decode(uri)
    if fileName == "enhanced_test" then
        print(string.format("🔍 [DEBUG] 发现类定义调用: %s", nodeName))
        print(string.format("    parent类型: %s", source.parent and source.parent.type or "nil"))
    end
    
    local args = source.args
    if not args or not args[1] or args[1].type ~= 'string' then
        return
    end
    
    local className = args[1][1]
    if not className then
        return
    end
    
    -- 解析继承关系（第二个及后续参数）
    local parentClasses = {}
    for i = 2, #args do
        local arg = args[i]
        if arg and arg.type == 'string' and arg[1] then
            table.insert(parentClasses, arg[1])
        elseif arg and (arg.type == 'getlocal' or arg.type == 'getglobal') and arg[1] then
            -- 支持变量引用作为父类
            local parentVarName = arg[1]
            local realParentClass = analysisResults.classAliases[parentVarName] or variableTypes[parentVarName] or parentVarName
            table.insert(parentClasses, realParentClass)
        end
    end
    
    local parent = source.parent
    
    if parent and (parent.type == 'setlocal' or parent.type == 'setglobal') then
        local varName = nil
        if parent.node and parent.node[1] then
            varName = parent.node[1]
        end
        
        if not varName then
            return
        end
        
        -- 注册类别名
        analysisResults.classAliases[varName] = className
        
        -- 记录继承关系
        if #parentClasses > 0 then
            analysisResults.inheritanceGraph[className] = parentClasses
            print(string.format("✅ 类继承: %s 继承自 [%s] (定义方式: %s)", 
                className, table.concat(parentClasses, ", "), nodeName))
        else
            print(string.format("✅ 类定义: %s (定义方式: %s)", className, nodeName))
        end
        
        -- 添加类节点
        local classId = addNode('class', className, {
            uri = uri,
            defineType = nodeName,
            parentClasses = parentClasses,
            line = guide.rowColOf(source.start) + 1,
            position = source.start
        })
        
        -- 添加变量节点
        local varType = parent.type == 'setglobal' and 'global' or 'variable'
        local varId = addNode(varType, varName, {
            uri = uri,
            classType = className,
            line = guide.rowColOf(parent.start) + 1,
            position = parent.start
        })
        
        -- 添加定义关系
        addRelation('defines', varId, classId, {
            uri = uri,
            line = guide.rowColOf(parent.start) + 1
        })
        
        -- 添加继承关系
        for _, parentClass in ipairs(parentClasses) do
            addRelation('inherits', classId, parentClass, {
                uri = uri,
                childClass = className,
                parentClass = parentClass,
                line = guide.rowColOf(source.start) + 1
            })
        end
    end
end

-- 分析别名赋值
local function analyzeAliasAssignment(uri, source)
    if source.type ~= 'setlocal' and source.type ~= 'setglobal' then
        return
    end
    
    local value = source.value
    if not value or (value.type ~= 'getlocal' and value.type ~= 'getglobal') then
        return
    end
    
    -- 安全地获取变量名和源变量名
    local varName = nil
    if source.node and source.node[1] then
        varName = source.node[1]
    end
    
    local sourceVar = nil
    if value[1] then
        sourceVar = value[1]
    end
    
    if not varName or not sourceVar then
        return
    end
    
    local sourceClass = analysisResults.classAliases[sourceVar]
    
    if sourceClass then
        -- 注册别名
        analysisResults.classAliases[varName] = sourceClass
        
        -- 添加别名节点
        local aliasId = addNode('alias', varName, {
            uri = uri,
            targetClass = sourceClass,
            sourceVariable = sourceVar,
            line = guide.rowColOf(source.start) + 1,
            position = source.start
        })
        
        -- 添加别名关系
        addRelation('aliases', aliasId, sourceVar, {
            uri = uri,
            targetClass = sourceClass,
            line = guide.rowColOf(source.start) + 1
        })
    end
end

-- 分析方法定义
local function analyzeMethodDefinition(uri, source)
    if source.type ~= 'setmethod' then
        return
    end
    
    local node = source.node
    local method = source.method
    
    if not node or not method then
        return
    end
    
    -- 安全地获取类名和方法名
    local className = nil
    local methodName = nil
    
    -- 处理类名
    if node.type == 'getlocal' or node.type == 'getglobal' then
        className = node[1]
    else
        className = node[1] or tostring(node.type)
    end
    
    -- 处理方法名
    if method.type == 'string' then
        methodName = method[1]
    else
        methodName = method[1] or tostring(method.type)
    end
    
    -- 如果无法获取名称，使用默认值
    if not className then
        className = 'unknown_class'
    end
    if not methodName then
        methodName = 'unknown_method'
    end
    
    -- 解析真实类名
    local realClassName = analysisResults.classAliases[className] or className
    
    -- 添加方法节点
    local methodId = addNode('method', realClassName .. ':' .. methodName, {
        uri = uri,
        className = realClassName,
        methodName = methodName,
        line = guide.rowColOf(source.start) + 1,
        position = source.start
    })
    
    -- 添加定义关系
    addRelation('defines_method', realClassName, methodId, {
        uri = uri,
        line = guide.rowColOf(source.start) + 1
    })
end

-- 分析普通函数调用
local function analyzeFunctionCall(uri, source)
    if source.type ~= 'call' then
        return
    end
    
    local node = source.node
    if not node then
        return
    end
    
    -- 处理不同类型的函数调用
    local funcName = nil
    local objName = nil
    
    if node.type == 'getglobal' then
        funcName = node[1]
    elseif node.type == 'getlocal' then
        funcName = node[1]
    elseif node.type == 'getfield' then
        -- 处理 obj.func() 或 module.func() 的情况
        if node.node and node.field then
            local nodeName = nil
            if node.node.type == 'getlocal' or node.node.type == 'getglobal' then
                nodeName = node.node[1]
            end
            
            local fieldName = nil
            if node.field.type == 'string' then
                fieldName = node.field[1]
            end
            
            if nodeName and fieldName then
                objName = nodeName
                funcName = fieldName
                
                -- 检查是否是构造函数调用（如 player:new()）
                if fieldName == 'new' then
                    local realClassName = analysisResults.classAliases[nodeName] or nodeName
                    
                    -- 记录构造函数调用
                    if not analysisResults.callGraph[realClassName] then
                        analysisResults.callGraph[realClassName] = {}
                    end
                    if not analysisResults.callGraph[realClassName][funcName] then
                        analysisResults.callGraph[realClassName][funcName] = {}
                    end
                    table.insert(analysisResults.callGraph[realClassName][funcName], {
                        uri = uri,
                        line = guide.rowColOf(source.start) + 1,
                        position = source.start,
                        objectName = objName,
                        callType = 'constructor'
                    })
                    
                    -- 添加构造函数调用关系
                    addRelation('constructs', objName, realClassName, {
                        uri = uri,
                        objectName = objName,
                        objectType = realClassName,
                        functionName = funcName,
                        line = guide.rowColOf(source.start) + 1
                    })
                end
            end
        end
    end
end

-- 分析方法调用
local function analyzeMethodCall(uri, source)
    if source.type ~= 'call' then
        return
    end
    
    local node = source.node
    if not node or node.type ~= 'getmethod' then
        return
    end
    
    local object = node.node
    local method = node.method
    
    if not object or not method then
        return
    end
    
    -- 安全地获取对象名和方法名
    local objName = nil
    local methodName = nil
    
    -- 处理对象名
    if object.type == 'getlocal' or object.type == 'getglobal' then
        objName = object[1]
    elseif object.type == 'getfield' then
        -- 处理类似 obj.field 的情况
        if object.node and object.node[1] then
            objName = object.node[1]
        end
    else
        -- 对于其他类型，尝试获取第一个元素
        objName = object[1] or tostring(object.type)
    end
    
    -- 处理方法名
    if method.type == 'string' then
        methodName = method[1]
    else
        methodName = method[1] or tostring(method.type)
    end
    
    -- 如果无法获取名称，使用默认值
    if not objName then
        objName = 'unknown_object'
    end
    if not methodName then
        methodName = 'unknown_method'
    end
    
    -- 解析对象的真实类型（优先使用变量类型跟踪）
    local realClassName = variableTypes[objName] or analysisResults.classAliases[objName] or objName
    
    -- 记录调用图（使用真实类型作为键）
    if not analysisResults.callGraph[realClassName] then
        analysisResults.callGraph[realClassName] = {}
    end
    if not analysisResults.callGraph[realClassName][methodName] then
        analysisResults.callGraph[realClassName][methodName] = {}
    end
    table.insert(analysisResults.callGraph[realClassName][methodName], {
        uri = uri,
        line = guide.rowColOf(source.start) + 1,
        position = source.start,
        objectName = objName,
        objectType = realClassName
    })
    
    -- 添加调用关系
    addRelation('calls', objName, realClassName .. ':' .. methodName, {
        uri = uri,
        objectName = objName,
        objectType = realClassName,
        methodName = methodName,
        line = guide.rowColOf(source.start) + 1
    })
end

-- 最终的变量类型分析方案
local function analyzeVariableTypesAdvanced(uri, ast)
    local fileName = furi.decode(uri):match("([^/\\]+)%.lua$") or furi.decode(uri)
    
    print(string.format("🔍 深度分析文件: %s", fileName))
    
    -- 方法1: 遍历所有源码节点，寻找变量定义
    guide.eachSource(ast, function(source)
        -- 处理局部变量定义和赋值
        if source.type == 'setlocal' then
            local varName = source.node and source.node[1]
            if varName then
                print(string.format("  发现setlocal: %s", varName))
                
                -- 检查是否是require调用
                if source.value and source.value.type == 'call' then
                    local callNode = source.value.node
                    if callNode and callNode.type == 'getglobal' and callNode[1] == 'require' then
                        local args = source.value.args
                        if args and args[1] and args[1].type == 'string' then
                            local modulePath = args[1][1]
                            if modulePath then
                                local moduleType = modulePath:match("([^./]+)$") or modulePath
                                variableTypes[varName] = moduleType
                                analysisResults.classAliases[varName] = moduleType
                                print(string.format("    ✅ require: %s → %s", varName, moduleType))
                            end
                        end
                    elseif callNode and callNode.type == 'getmethod' then
                        local method = callNode.method
                        local object = callNode.node
                        if method and method[1] == 'new' and object and object[1] then
                            local objName = object[1]
                            local objType = variableTypes[objName] or analysisResults.classAliases[objName] or objName
                            variableTypes[varName] = objType
                            print(string.format("    ✅ 构造函数: %s = %s:new() → %s", varName, objName, objType))
                        end
                    end
                end
                
                -- 使用vm.getInfer获取类型
                if not variableTypes[varName] then
                    local typeView = vm.getInfer(source):view(uri)
                    if typeView and typeView ~= 'unknown' and typeView ~= 'any' then
                        variableTypes[varName] = typeView
                        print(string.format("    ✅ 类型推断: %s → %s", varName, typeView))
                    end
                end
            end
        end
        
        -- 处理局部变量声明
        if source.type == 'local' then
            local varName = source[1]
            if varName and not variableTypes[varName] then
                local typeView = vm.getInfer(source):view(uri)
                if typeView and typeView ~= 'unknown' and typeView ~= 'any' then
                    variableTypes[varName] = typeView
                    print(string.format("  ✅ 局部变量: %s → %s", varName, typeView))
                end
            end
        end
        
        -- 处理全局变量引用
        if source.type == 'getglobal' then
            local varName = source[1]
            if varName and not variableTypes[varName] then
                local typeView = vm.getInfer(source):view(uri)
                if typeView and typeView ~= 'unknown' and typeView ~= 'any' then
                    variableTypes[varName] = typeView
                    print(string.format("  ✅ 全局变量: %s → %s", varName, typeView))
                end
            end
        end
        
        -- 处理局部变量引用
        if source.type == 'getlocal' then
            local varName = source[1]
            if varName and not variableTypes[varName] then
                local typeView = vm.getInfer(source):view(uri)
                if typeView and typeView ~= 'unknown' and typeView ~= 'any' then
                    variableTypes[varName] = typeView
                    print(string.format("  ✅ 局部变量引用: %s → %s", varName, typeView))
                end
            end
        end
    end)
end

-- 分析单个文件
local function analyzeFile(uri)
    local text = files.getText(uri)
    if not text then
        return
    end
    
    local state = files.getState(uri)
    if not state or not state.ast then
        return
    end
    
    local ast = state.ast
    local fileName = furi.decode(uri):match("([^/\\]+)%.lua$") or furi.decode(uri)
    
    print(string.format("正在分析文件: %s", fileName))
    
    -- 使用新的高级变量类型分析
    analyzeVariableTypesAdvanced(uri, ast)
    
    -- 遍历AST节点进行其他分析
    guide.eachSource(ast, function(source)
        analyzeDefineClass(uri, source)
        analyzeAliasAssignment(uri, source)
        analyzeConstructorCall(uri, source)
        analyzeMethodDefinition(uri, source)
        analyzeFunctionCall(uri, source)
        analyzeMethodCall(uri, source)
    end)
    
    -- 显示发现的变量类型
    local typeCount = 0
    for varName, varType in pairs(variableTypes) do
        typeCount = typeCount + 1
    end
    if typeCount > 0 then
        print(string.format("  发现 %d 个变量类型", typeCount))
    else
        print("  未发现任何变量类型")
    end
    
    analysisResults.statistics.totalFiles = analysisResults.statistics.totalFiles + 1
end

-- 输出JSON结果
local function outputJSON()
    analysisResults.metadata.generatedAt = os.date('%Y-%m-%d %H:%M:%S')
    return jsonb.beautify(analysisResults)
end

-- 输出Markdown报告
local function outputMarkdown()
    local lines = {}
    
    table.insert(lines, '# Lua代码分析报告')
    table.insert(lines, '')
    table.insert(lines, '基于lua-language-server的深度代码分析')
    table.insert(lines, '')
    table.insert(lines, '生成时间: ' .. os.date('%Y-%m-%d %H:%M:%S'))
    table.insert(lines, '')
    
    -- 统计信息
    table.insert(lines, '## 统计信息')
    table.insert(lines, '')
    table.insert(lines, string.format('- 分析文件数: %d', analysisResults.statistics.totalFiles))
    table.insert(lines, string.format('- 总节点数: %d', analysisResults.statistics.totalNodes))
    table.insert(lines, string.format('- 总关系数: %d', analysisResults.statistics.totalRelations))
    
    local aliasCount = 0
    for _ in pairs(analysisResults.classAliases) do aliasCount = aliasCount + 1 end
    table.insert(lines, string.format('- 类别名映射: %d 个', aliasCount))
    
    local typeCount = 0
    for _ in pairs(variableTypes) do typeCount = typeCount + 1 end
    table.insert(lines, string.format('- 变量类型推断: %d 个', typeCount))
    
    local inheritanceCount = 0
    for _ in pairs(analysisResults.inheritanceGraph) do inheritanceCount = inheritanceCount + 1 end
    table.insert(lines, string.format('- 类继承关系: %d 个', inheritanceCount))
    table.insert(lines, '')
    
    -- 变量类型映射
    if next(variableTypes) then
        table.insert(lines, '## 变量类型映射')
        table.insert(lines, '')
        table.insert(lines, '以下变量的类型已被正确推断:')
        table.insert(lines, '')
        for varName, varType in pairs(variableTypes) do
            table.insert(lines, string.format('- `%s` → `%s`', varName, varType))
        end
        table.insert(lines, '')
    end
    
    -- 类别名映射
    if next(analysisResults.classAliases) then
        table.insert(lines, '## 模块别名映射')
        table.insert(lines, '')
        table.insert(lines, '以下模块别名已被正确识别和解析:')
        table.insert(lines, '')
        for alias, realClass in pairs(analysisResults.classAliases) do
            table.insert(lines, string.format('- `%s` → `%s`', alias, realClass))
        end
        table.insert(lines, '')
    end
    
    -- 类继承关系
    if next(analysisResults.inheritanceGraph) then
        table.insert(lines, '## 类继承关系')
        table.insert(lines, '')
        table.insert(lines, '以下类的继承关系已被识别:')
        table.insert(lines, '')
        for childClass, parentClasses in pairs(analysisResults.inheritanceGraph) do
            if #parentClasses == 1 then
                table.insert(lines, string.format('- `%s` 继承自 `%s`', childClass, parentClasses[1]))
            else
                table.insert(lines, string.format('- `%s` 继承自 `[%s]`', childClass, table.concat(parentClasses, ', ')))
            end
        end
        table.insert(lines, '')
    end
    
    -- 调用图
    if next(analysisResults.callGraph) then
        table.insert(lines, '## 方法调用图')
        table.insert(lines, '')
        table.insert(lines, '按类型分组的方法调用统计:')
        table.insert(lines, '')
        
        for className, methods in pairs(analysisResults.callGraph) do
            table.insert(lines, string.format('### %s 类型', className))
            table.insert(lines, '')
            for methodName, calls in pairs(methods) do
                table.insert(lines, string.format('- `%s()` 被调用 %d 次', methodName, #calls))
                for _, call in ipairs(calls) do
                    local relativePath = furi.decode(call.uri):gsub('^.*[/\\]', '')
                    local objectInfo = call.objectName
                    if call.objectType and call.objectType ~= call.objectName then
                        objectInfo = string.format('%s (%s类型)', call.objectName, call.objectType)
                    end
                    table.insert(lines, string.format('  - %s:%d (对象: %s)', 
                        relativePath, call.line, objectInfo))
                end
            end
            table.insert(lines, '')
        end
    end
    
    return table.concat(lines, '\n')
end

function export.runCLI()
    lang(LOCALE)
    
    local startTime = os.clock()
    
    if type(ANALYZE) ~= 'string' then
        print('错误: ANALYZE 参数必须是字符串类型，指定要分析的目录路径')
        return 1
    end
    
    local rootPath = fs.canonical(fs.path(ANALYZE)):string()
    local rootUri = furi.encode(rootPath)
    if not rootUri then
        print(string.format('错误: 无法创建URI: %s', rootPath))
        return 1
    end
    rootUri = rootUri:gsub("/$", "")
    
    print(string.format('=== Lua代码分析器 (基于lua-language-server) ==='))
    print(string.format('分析目录: %s', rootPath))
    print('')
    
    util.enableCloseFunction()
    
    local function errorhandler(err)
        print('错误: ' .. tostring(err))
        print(debug.traceback())
    end
    
    ---@async
    xpcall(lclient.start, errorhandler, lclient, function (client)
        await.disable()
        client:registerFakers()
        
        client:initialize {
            rootUri = rootUri,
        }
        
        print('正在初始化工作空间...')
        
        provider.updateConfig(rootUri)
        ws.awaitReady(rootUri)
        
        print('工作空间初始化完成，开始分析文件...')
        
        local uris = files.getChildFiles(rootUri)
        local max = #uris
        
        print(string.format('发现 %d 个Lua文件', max))
        
        for i, uri in ipairs(uris) do
            if not ws.isIgnored(uri) then
                files.open(uri)
                analyzeFile(uri)
                
                -- 显示进度
                if i % 10 == 0 or i == max then
                    print(string.format('进度: %d/%d (%.1f%%)', i, max, i/max*100))
                end
            end
        end
        
        print('分析完成，正在生成报告...')
    end)
    
    local endTime = os.clock()
    analysisResults.statistics.processingTime = endTime - startTime
    
    -- 输出结果
    local jsonOutput = outputJSON()
    local jsonFile = ANALYZE_OUTPUT or (rootPath .. '/lua_analysis_output.json')
    util.saveFile(jsonFile, jsonOutput)
    print(string.format('✓ JSON输出已保存到: %s', jsonFile))
    
    local mdOutput = outputMarkdown()
    local mdFile = ANALYZE_REPORT or (rootPath .. '/lua_analysis_report.md')
    util.saveFile(mdFile, mdOutput)
    print(string.format('✓ Markdown报告已保存到: %s', mdFile))
    
    -- 打印关键结果
    print('')
    print('=== 分析结果摘要 ===')
    
    if next(analysisResults.classAliases) then
        print('✅ 类别名映射:')
        for alias, realClass in pairs(analysisResults.classAliases) do
            print(string.format('   %s → %s', alias, realClass))
        end
    end
    
    if next(analysisResults.inheritanceGraph) then
        print('')
        print('🔗 类继承关系:')
        for childClass, parentClasses in pairs(analysisResults.inheritanceGraph) do
            if #parentClasses == 1 then
                print(string.format('   %s 继承自 %s', childClass, parentClasses[1]))
            else
                print(string.format('   %s 继承自 [%s]', childClass, table.concat(parentClasses, ', ')))
            end
        end
    end
    
    if next(analysisResults.callGraph) then
        print('')
        print('📞 方法调用统计:')
        for className, methods in pairs(analysisResults.callGraph) do
            print(string.format('   %s:', className))
            for methodName, calls in pairs(methods) do
                print(string.format('     %s() - %d 次调用', methodName, #calls))
            end
        end
    end
    
    print('')
    print(string.format('📊 统计信息:'))
    print(string.format('   文件数: %d', analysisResults.statistics.totalFiles))
    print(string.format('   节点数: %d', analysisResults.statistics.totalNodes))
    print(string.format('   关系数: %d', analysisResults.statistics.totalRelations))
    print(string.format('   处理时间: %.2f 秒', analysisResults.statistics.processingTime))
    
    print('')
    print('✅ 分析任务完成！')
    return 0
end

return export 