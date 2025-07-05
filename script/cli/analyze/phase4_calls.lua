-- analyze/phase4_calls.lua
-- 第四阶段：函数调用关系分析

local files = require 'files'
local guide = require 'parser.guide'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'
local furi = require 'file-uri'

local phase4 = {}

-- 分析函数调用
local function analyzeFunctionCall(ctx, uri, moduleId, source)
    local callName = utils.getCallName(source)
    if not callName then return end
    
    local position = utils.getNodePosition(source)
    local filePath = furi.decode(uri)
    
    -- 查找调用者函数
    local callerFunction = nil
    local currentNode = source.parent
    while currentNode do
        if currentNode.type == 'function' then
            callerFunction = currentNode
            break
        end
        currentNode = currentNode.parent
    end
    
    local callerName = "global"
    if callerFunction then
        callerName = utils.getFunctionName(callerFunction) or "anonymous"
    end
    
    -- 查找被调用函数实体
    local calleeEntityId = nil
    for _, entity in ipairs(ctx.entities) do
        if entity.type == 'function' and entity.name == callName then
            calleeEntityId = entity.id
            break
        end
    end
    
    -- 查找调用者函数实体
    local callerEntityId = nil
    for _, entity in ipairs(ctx.entities) do
        if entity.type == 'function' and entity.name == callerName then
            callerEntityId = entity.id
            break
        end
    end
    
    -- 如果找不到调用者，创建一个全局调用上下文
    if not callerEntityId and callerName == "global" then
        callerEntityId = context.addEntity(ctx, 'function', {
            name = "global",
            isMethod = false,
            className = nil,
            params = {},
            scope = "global",
            isAnonymous = false,
            module = moduleId,
            sourceCode = nil,
            category = 'function',
            sourceLocation = {
                file = filePath,
                line = position.line,
                column = position.column
            }
        })
    end
    
    -- 创建调用关系
    if callerEntityId and calleeEntityId then
        context.addRelation(ctx, 'calls', callerEntityId, calleeEntityId, {
            relationship = 'function_call',
            callName = callName,
            sourceLocation = {
                file = filePath,
                line = position.line,
                column = position.column
            }
        })
        
        context.debug(ctx, "函数调用: %s -> %s", callerName, callName)
    else
        -- 记录外部调用
        context.addRelation(ctx, 'external_call', callerEntityId or "unknown", callName, {
            relationship = 'external_function_call',
            callName = callName,
            sourceLocation = {
                file = filePath,
                line = position.line,
                column = position.column
            }
        })
        
        context.debug(ctx, "外部调用: %s -> %s", callerName, callName)
    end
end

-- 分析类型实例化
local function analyzeTypeInstantiation(ctx, uri, moduleId, source)
    local callName = utils.getCallName(source)
    if not callName or not callName:find(':new') then return end
    
    local className = callName:match('([^:]+):new')
    if not className then return end
    
    local position = utils.getNodePosition(source)
    local filePath = furi.decode(uri)
    
    -- 查找类实体
    local classEntityId = nil
    for _, entity in ipairs(ctx.entities) do
        if entity.type == 'class' and entity.name == className then
            classEntityId = entity.id
            break
        end
    end
    
    if classEntityId then
        -- 查找实例化的上下文
        local contextFunction = nil
        local currentNode = source.parent
        while currentNode do
            if currentNode.type == 'function' then
                contextFunction = currentNode
                break
            end
            currentNode = currentNode.parent
        end
        
        local contextName = "global"
        if contextFunction then
            contextName = utils.getFunctionName(contextFunction) or "anonymous"
        end
        
        -- 查找上下文实体
        local contextEntityId = nil
        for _, entity in ipairs(ctx.entities) do
            if entity.type == 'function' and entity.name == contextName then
                contextEntityId = entity.id
                break
            end
        end
        
        if contextEntityId then
            context.addRelation(ctx, 'instantiates', contextEntityId, classEntityId, {
                relationship = 'type_instantiation',
                className = className,
                sourceLocation = {
                    file = filePath,
                    line = position.line,
                    column = position.column
                }
            })
            
            context.debug(ctx, "类型实例化: %s 在 %s", className, contextName)
        end
    end
end

-- 分析require依赖
local function analyzeRequireDependency(ctx, uri, moduleId, source)
    local callName = utils.getCallName(source)
    if not callName or (callName ~= 'require' and callName ~= 'kg_require') then return end
    
    local modulePath = utils.getRequireModulePath(source)
    if not modulePath then return end
    
    local position = utils.getNodePosition(source)
    local filePath = furi.decode(uri)
    
    -- 查找当前模块实体
    local currentModuleEntityId = nil
    for _, entity in ipairs(ctx.entities) do
        if entity.type == 'module' and entity.uri == uri then
            currentModuleEntityId = entity.id
            break
        end
    end
    
    -- 查找被依赖模块实体
    local dependentModuleEntityId = nil
    for _, entity in ipairs(ctx.entities) do
        if entity.type == 'module' and entity.name == modulePath then
            dependentModuleEntityId = entity.id
            break
        end
    end
    
    if currentModuleEntityId and dependentModuleEntityId then
        context.addRelation(ctx, 'depends_on', currentModuleEntityId, dependentModuleEntityId, {
            relationship = 'module_dependency',
            requireType = callName,
            modulePath = modulePath,
            sourceLocation = {
                file = filePath,
                line = position.line,
                column = position.column
            }
        })
        
        context.debug(ctx, "模块依赖: %s -> %s", moduleId, modulePath)
    end
end

-- 分析文件中的调用关系
local function analyzeFileCalls(ctx, uri)
    local state = files.getState(uri)
    if not state or not state.ast then
        return
    end
    
    local moduleId = utils.getModuleId(uri)
    context.debug(ctx, "分析文件调用关系: %s", moduleId)
    
    -- 遍历AST节点
    guide.eachSource(state.ast, function(source)
        if source.type == 'call' then
            analyzeFunctionCall(ctx, uri, moduleId, source)
            analyzeTypeInstantiation(ctx, uri, moduleId, source)
            analyzeRequireDependency(ctx, uri, moduleId, source)
        end
    end)
end

-- 主分析函数
function phase4.analyze(ctx)
    local uris = context.getFiles(ctx)
    local totalFiles = #uris
    
    print(string.format("  发现 %d 个Lua文件", totalFiles))
    
    for i, uri in ipairs(uris) do
        analyzeFileCalls(ctx, uri)
        
        -- 显示进度
        if i % 10 == 0 or i == totalFiles then
            print(string.format("  进度: %d/%d (%.1f%%)", i, totalFiles, i/totalFiles*100))
        end
    end
    
    -- 统计调用关系
    local functionCalls = 0
    local typeCalls = 0
    local moduleDeps = 0
    
    for _, relation in ipairs(ctx.relations) do
        if relation.type == 'calls' then
            functionCalls = functionCalls + 1
        elseif relation.type == 'instantiates' then
            typeCalls = typeCalls + 1
        elseif relation.type == 'depends_on' then
            moduleDeps = moduleDeps + 1
        end
    end
    
    print(string.format("  ✅ 函数调用分析完成:"))
    print(string.format("     函数调用: %d, 类型实例化: %d, 模块依赖: %d", 
        functionCalls, typeCalls, moduleDeps))
end

return phase4 