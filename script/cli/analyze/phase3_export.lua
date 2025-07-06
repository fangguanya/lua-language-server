---
--- Created by fanggang
--- DateTime: 2025/7/6 17:27
---
-- analyze/phase3_export.lua
-- 第三阶段：实体关系导出

local files = require 'files'
local guide = require 'parser.guide'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'
local furi = require 'file-uri'
local nodeTracker = require 'cli.analyze.node_tracker'
local symbol = require 'cli.analyze.symbol'

local phase3 = {}

-- 节点跟踪器
local tracker3 = nil

-- 导出模块实体
local function exportModuleEntities(ctx)
    local moduleCount = 0
    
    for moduleName, module in pairs(ctx.modules) do
        local filePath = nil
        if module.ast and ctx.uriToModule then
            -- 查找对应的URI
            for uri, mod in pairs(ctx.uriToModule) do
                if mod.id == module.id then
                    filePath = furi.decode(uri)
                    break
                end
            end
        end
        
        local entityId = context.addEntity(ctx, 'module', {
            name = module.name,
            symbolId = module.id,
            filePath = filePath,
            classes = module.classes or {},
            methods = module.methods or {},
            variables = module.variables or {},
            category = 'module',
            sourceLocation = {
                file = filePath,
                line = 1,
                column = 1
            }
        })
        
        moduleCount = moduleCount + 1
        context.debug(ctx, "导出模块实体: %s (ID: %s)", module.name, entityId)
    end
    
    context.debug(ctx, "导出了 %d 个模块实体", moduleCount)
    return moduleCount
end

-- 导出类实体
local function exportClassEntities(ctx)
    local classCount = 0
    
    for className, class in pairs(ctx.classes) do
        local filePath = nil
        if class.ast and ctx.uriToModule then
            -- 查找对应的URI
            for uri, mod in pairs(ctx.uriToModule) do
                if mod.id == class.parent.id then
                    filePath = furi.decode(uri)
                    break
                end
            end
        end
        
        local entityId = context.addEntity(ctx, 'class', {
            name = class.name,
            symbolId = class.id,
            parentId = class.parent and class.parent.id or nil,
            methods = class.methods or {},
            variables = class.variables or {},
            aliases = class.aliases or {},
            category = 'class',
            sourceLocation = {
                file = filePath,
                line = 1, -- 类的具体位置需要从AST中获取
                column = 1
            }
        })
        
        classCount = classCount + 1
        context.debug(ctx, "导出类实体: %s (ID: %s)", class.name, entityId)
    end
    
    context.debug(ctx, "导出了 %d 个类实体", classCount)
    return classCount
end

-- 导出函数实体
local function exportFunctionEntities(ctx)
    local functionCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.METHOD then
            local filePath = nil
            if symbol.parent and ctx.uriToModule then
                -- 查找对应的URI
                for uri, mod in pairs(ctx.uriToModule) do
                    if mod.id == symbol.parent.id then
                        filePath = furi.decode(uri)
                        break
                    end
                end
            end
            
            local entityId = context.addEntity(ctx, 'function', {
                name = symbol.name,
                symbolId = symbol.id,
                parentId = symbol.parent and symbol.parent.id or nil,
                parentName = symbol.parent and symbol.parent.name or nil,
                isAnonymous = symbol:IsAnonymous(),
                parameters = symbol.parameters or {},
                variables = symbol.variables or {},
                category = 'function',
                sourceLocation = {
                    file = filePath,
                    line = 1, -- 函数的具体位置需要从AST中获取
                    column = 1
                }
            })
            
            functionCount = functionCount + 1
            context.debug(ctx, "导出函数实体: %s (ID: %s)", symbol.name, entityId)
        end
    end
    
    context.debug(ctx, "导出了 %d 个函数实体", functionCount)
    return functionCount
end

-- 导出变量实体
local function exportVariableEntities(ctx)
    local variableCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.VARIABLE then
            local filePath = nil
            if symbol.parent and ctx.uriToModule then
                -- 查找对应的URI
                for uri, mod in pairs(ctx.uriToModule) do
                    if mod.id == symbol.parent.id then
                        filePath = furi.decode(uri)
                        break
                    end
                end
            end
            
            -- 获取变量的推断类型
            local inferredType = nil
            if ctx.types.inferred[symbolId] then
                inferredType = ctx.types.inferred[symbolId].type
            end
            
            local entityId = context.addEntity(ctx, 'variable', {
                name = symbol.name,
                symbolId = symbol.id,
                parentId = symbol.parent and symbol.parent.id or nil,
                parentName = symbol.parent and symbol.parent.name or nil,
                possibles = symbol.possibles or {},
                inferredType = inferredType,
                isAlias = symbol.isAlias or false,
                aliasTarget = symbol.aliasTarget,
                aliasTargetName = symbol.aliasTargetName,
                category = 'variable',
                sourceLocation = {
                    file = filePath,
                    line = 1, -- 变量的具体位置需要从AST中获取
                    column = 1
                }
            })
            
            variableCount = variableCount + 1
            context.debug(ctx, "导出变量实体: %s (ID: %s)", symbol.name, entityId)
        end
    end
    
    context.debug(ctx, "导出了 %d 个变量实体", variableCount)
    return variableCount
end

-- 导出包含关系
local function exportContainmentRelations(ctx)
    local relationCount = 0
    
    -- 模块包含类
    for moduleName, module in pairs(ctx.modules) do
        if module.classes and #module.classes > 0 then
            -- 查找模块实体
            local moduleEntityId = nil
            for _, entity in ipairs(ctx.entities) do
                if entity.type == 'module' and entity.symbolId == module.id then
                    moduleEntityId = entity.id
                    break
                end
            end
            
            if moduleEntityId then
                for _, classId in ipairs(module.classes) do
                    -- 查找类实体
                    local classEntityId = nil
                    for _, entity in ipairs(ctx.entities) do
                        if entity.type == 'class' and entity.symbolId == classId then
                            classEntityId = entity.id
                            break
                        end
                    end
                    
                    if classEntityId then
                        context.addRelation(ctx, 'contains', moduleEntityId, classEntityId, {
                            relationship = 'module_contains_class',
                            sourceLocation = {
                                file = nil,
                                line = 1,
                                column = 1
                            }
                        })
                        relationCount = relationCount + 1
                    end
                end
            end
        end
        
        -- 模块包含函数
        if module.methods and #module.methods > 0 then
            -- 查找模块实体
            local moduleEntityId = nil
            for _, entity in ipairs(ctx.entities) do
                if entity.type == 'module' and entity.symbolId == module.id then
                    moduleEntityId = entity.id
                    break
                end
            end
            
            if moduleEntityId then
                for _, methodId in ipairs(module.methods) do
                    -- 查找函数实体
                    local functionEntityId = nil
                    for _, entity in ipairs(ctx.entities) do
                        if entity.type == 'function' and entity.symbolId == methodId then
                            functionEntityId = entity.id
                            break
                        end
                    end
                    
                    if functionEntityId then
                        context.addRelation(ctx, 'contains', moduleEntityId, functionEntityId, {
                            relationship = 'module_contains_function',
                            sourceLocation = {
                                file = nil,
                                line = 1,
                                column = 1
                            }
                        })
                        relationCount = relationCount + 1
                    end
                end
            end
        end
    end
    
    -- 类包含函数
    for className, class in pairs(ctx.classes) do
        if class.methods and #class.methods > 0 then
            -- 查找类实体
            local classEntityId = nil
            for _, entity in ipairs(ctx.entities) do
                if entity.type == 'class' and entity.symbolId == class.id then
                    classEntityId = entity.id
                    break
                end
            end
            
            if classEntityId then
                for _, methodId in ipairs(class.methods) do
                    -- 查找函数实体
                    local functionEntityId = nil
                    for _, entity in ipairs(ctx.entities) do
                        if entity.type == 'function' and entity.symbolId == methodId then
                            functionEntityId = entity.id
                            break
                        end
                    end
                    
                    if functionEntityId then
                        context.addRelation(ctx, 'contains', classEntityId, functionEntityId, {
                            relationship = 'class_contains_method',
                            sourceLocation = {
                                file = nil,
                                line = 1,
                                column = 1
                            }
                        })
                        relationCount = relationCount + 1
                    end
                end
            end
        end
    end
    
    context.debug(ctx, "导出了 %d 个包含关系", relationCount)
    return relationCount
end

-- 导出引用关系
local function exportReferenceRelations(ctx)
    local relationCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.refs and next(symbol.refs) then
            -- 查找源实体
            local sourceEntityId = nil
            for _, entity in ipairs(ctx.entities) do
                if entity.symbolId == symbolId then
                    sourceEntityId = entity.id
                    break
                end
            end
            
            if sourceEntityId then
                for refId, _ in pairs(symbol.refs) do
                    -- 查找目标实体
                    local targetEntityId = nil
                    for _, entity in ipairs(ctx.entities) do
                        if entity.symbolId == refId then
                            targetEntityId = entity.id
                            break
                        end
                    end
                    
                    if targetEntityId then
                        context.addRelation(ctx, 'references', sourceEntityId, targetEntityId, {
                            relationship = 'symbol_reference',
                            sourceLocation = {
                                file = nil,
                                line = 1,
                                column = 1
                            }
                        })
                        relationCount = relationCount + 1
                    end
                end
            end
        end
    end
    
    context.debug(ctx, "导出了 %d 个引用关系", relationCount)
    return relationCount
end

-- 导出别名关系
local function exportAliasRelations(ctx)
    local relationCount = 0
    
    if ctx.symbols.aliases then
        for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
            -- 查找别名实体
            local aliasEntityId = nil
            for _, entity in ipairs(ctx.entities) do
                if entity.symbolId == aliasInfo.symbolId then
                    aliasEntityId = entity.id
                    break
                end
            end
            
            -- 查找目标实体
            local targetEntityId = nil
            for _, entity in ipairs(ctx.entities) do
                if entity.symbolId == aliasInfo.targetId then
                    targetEntityId = entity.id
                    break
                end
            end
            
            if aliasEntityId and targetEntityId then
                context.addRelation(ctx, 'alias_of', aliasEntityId, targetEntityId, {
                    relationship = 'type_alias',
                    aliasType = aliasInfo.type,
                    sourceLocation = {
                        file = nil,
                        line = 1,
                        column = 1
                    }
                })
                relationCount = relationCount + 1
            end
        end
    end
    
    context.debug(ctx, "导出了 %d 个别名关系", relationCount)
    return relationCount
end

-- 主分析函数
function phase3.analyze(ctx)
    print("🔍 第三阶段：实体关系导出")
    
    -- 初始化节点跟踪器
    if ctx.config.enableNodeTracking then
        tracker3 = nodeTracker.new("phase3_export")
    end
    
    print("  导出实体...")
    
    -- 导出各类实体
    local moduleCount = exportModuleEntities(ctx)
    local classCount = exportClassEntities(ctx)
    local functionCount = exportFunctionEntities(ctx)
    local variableCount = exportVariableEntities(ctx)
    
    print("  导出关系...")
    
    -- 导出各类关系
    local containmentCount = exportContainmentRelations(ctx)
    local referenceCount = exportReferenceRelations(ctx)
    local aliasCount = exportAliasRelations(ctx)
    
    -- 统计信息
    local totalEntities = #ctx.entities
    local totalRelations = #ctx.relations
    
    print(string.format("  ✅ 实体关系导出完成:"))
    print(string.format("    实体: %d (模块: %d, 类: %d, 函数: %d, 变量: %d)", 
        totalEntities, moduleCount, classCount, functionCount, variableCount))
    print(string.format("    关系: %d (包含: %d, 引用: %d, 别名: %d)", 
        totalRelations, containmentCount, referenceCount, aliasCount))
    
    -- 打印节点跟踪统计
    if ctx.config.enableNodeTracking and tracker3 then
        nodeTracker.printStatistics(tracker3)
    end
end

return phase3 