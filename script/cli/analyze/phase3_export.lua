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

-- 导入符号类型常量
local SYMBOL_TYPE = symbol.SYMBOL_TYPE

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
        
        context.addEntity(ctx, 'module', module.id, module.name)
        
        moduleCount = moduleCount + 1
    end
    
    context.debug(ctx, "导出了 %d 个模块实体", moduleCount)
    return moduleCount
end

-- 导出类实体
local function exportClassEntities(ctx)
    local classCount = 0
    
    for className, class in pairs(ctx.classes) do
        
        context.addEntity(ctx, 'class', class.id, class.name)
        
        classCount = classCount + 1
    end
    
    context.debug(ctx, "导出了 %d 个类实体", classCount)
    return classCount
end

-- 导出函数实体
local function exportFunctionEntities(ctx)
    local functionCount = 0
    
    for symbolId, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.METHOD then
            
            context.addEntity(ctx, 'function', symbol.id, symbol.name)
            
            functionCount = functionCount + 1
        end
    end
    
    context.debug(ctx, "导出了 %d 个函数实体", functionCount)
    return functionCount
end

-- 导出变量实体
local function exportVariableEntities(ctx)
    local variableCount = 0
    
    for id, symbol in pairs(ctx.symbols) do
        if symbol.type == SYMBOL_TYPE.VARIABLE then
            -- 排除local变量
            if symbol.isLocal then
                context.debug(ctx, "跳过local变量: %s", symbol.name)
                goto continue
            end
            
            context.addEntity(ctx, 'variable', symbol.id, symbol.name)
            variableCount = variableCount + 1
        end
        
        ::continue::
    end
    
    context.debug(ctx, "导出变量实体: %d", variableCount)
    return variableCount
end

-- 查找实体ID通过symbolId
local function findEntityIdBySymbolId(ctx, symbolId)
    for _, entity in ipairs(ctx.entities) do
        if entity.symbolId == symbolId then
            return entity.id
        end
    end
    return nil
end

-- 导出包含关系
local function exportContainmentRelations(ctx)
    local relationCount = 0
    
    -- 模块包含类
    for moduleName, module in pairs(ctx.modules) do
        if module.classes and #module.classes > 0 then
            local moduleEntityId = findEntityIdBySymbolId(ctx, module.id)
            
            if moduleEntityId then
                for _, classId in ipairs(module.classes) do
                    local classEntityId = findEntityIdBySymbolId(ctx, classId)
                    
                    if classEntityId then
                        context.addRelation(ctx, 'contains', moduleEntityId, classEntityId)
                        relationCount = relationCount + 1
                    end
                end
            end
        end
        
        -- 模块包含函数
        if module.methods and #module.methods > 0 then
            local moduleEntityId = findEntityIdBySymbolId(ctx, module.id)
            
            if moduleEntityId then
                for _, methodId in ipairs(module.methods) do
                    -- 检查是否是local函数，如果是则跳过
                    local methodSymbol = ctx.symbols[methodId]
                    if methodSymbol and methodSymbol.isLocal then
                        context.debug(ctx, "跳过local函数关系: %s", methodSymbol.name)
                        goto continue_method
                    end
                    
                    local functionEntityId = findEntityIdBySymbolId(ctx, methodId)
                    
                    if functionEntityId then
                        context.addRelation(ctx, 'contains', moduleEntityId, functionEntityId)
                        relationCount = relationCount + 1
                    end
                    
                    ::continue_method::
                end
            end
        end
    end
    
    -- 类包含函数
    for className, class in pairs(ctx.classes) do
        if class.methods and #class.methods > 0 then
            local classEntityId = findEntityIdBySymbolId(ctx, class.id)
            
            if classEntityId then
                for _, methodId in ipairs(class.methods) do
                    -- 检查是否是local函数，如果是则跳过
                    local methodSymbol = ctx.symbols[methodId]
                    if methodSymbol and methodSymbol.isLocal then
                        context.debug(ctx, "跳过local函数关系: %s", methodSymbol.name)
                        goto continue_class_method
                    end
                    
                    local functionEntityId = findEntityIdBySymbolId(ctx, methodId)
                    
                    if functionEntityId then
                        context.addRelation(ctx, 'contains', classEntityId, functionEntityId)
                        relationCount = relationCount + 1
                    end
                    
                    ::continue_class_method::
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
        -- 排除local符号的引用关系
        if symbol.isLocal then
            context.debug(ctx, "跳过local符号的引用关系: %s", symbol.name)
            goto continue
        end
        
        if symbol.refs and next(symbol.refs) then
            local sourceEntityId = findEntityIdBySymbolId(ctx, symbolId)
            
            if sourceEntityId then
                for refId, _ in pairs(symbol.refs) do
                    -- 检查被引用的符号是否是local
                    local refSymbol = ctx.symbols[refId]
                    if refSymbol and refSymbol.isLocal then
                        context.debug(ctx, "跳过对local符号的引用: %s -> %s", symbol.name, refSymbol.name)
                        goto continue_ref
                    end
                    
                    local targetEntityId = findEntityIdBySymbolId(ctx, refId)
                    
                    if targetEntityId then
                        context.addRelation(ctx, 'references', sourceEntityId, targetEntityId)
                        relationCount = relationCount + 1
                    end
                    
                    ::continue_ref::
                end
            end
        end
        
        ::continue::
    end
    
    context.debug(ctx, "导出了 %d 个引用关系", relationCount)
    return relationCount
end

-- 导出别名关系
local function exportAliasRelations(ctx)
    local relationCount = 0
    
    if ctx.symbols.aliases then
        for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
            -- 检查别名是否是local
            local aliasSymbol = ctx.symbols[aliasInfo.symbolId]
            if aliasSymbol and aliasSymbol.isLocal then
                context.debug(ctx, "跳过local别名关系: %s", aliasName)
                goto continue
            end
            
            -- 检查目标是否是local
            local targetSymbol = ctx.symbols[aliasInfo.targetId]
            if targetSymbol and targetSymbol.isLocal then
                context.debug(ctx, "跳过指向local符号的别名关系: %s -> %s", aliasName, targetSymbol.name)
                goto continue
            end
            
            local aliasEntityId = findEntityIdBySymbolId(ctx, aliasInfo.symbolId)
            local targetEntityId = findEntityIdBySymbolId(ctx, aliasInfo.targetId)
            
            if aliasEntityId and targetEntityId then
                context.addRelation(ctx, 'alias_of', aliasEntityId, targetEntityId)
                relationCount = relationCount + 1
            end
            
            ::continue::
        end
    end
    
    context.debug(ctx, "导出了 %d 个别名关系", relationCount)
    return relationCount
end

-- 导出继承关系
local function exportInheritanceRelations(ctx)
    local relationCount = 0
    
    context.debug(ctx, "开始导出继承关系...")
    
    for className, class in pairs(ctx.classes) do
        if class.parentClasses and #class.parentClasses > 0 then
            local childEntityId = findEntityIdBySymbolId(ctx, class.id)
            
            if childEntityId then
                -- 现在parentClasses是一个简化的数组，直接包含父类ID或名称
                for _, parentId in ipairs(class.parentClasses) do
                    local parentEntityId = nil
                    local parentName = parentId
                    
                    -- 如果parentId是符号ID，直接查找
                    if ctx.symbols[parentId] then
                        parentEntityId = findEntityIdBySymbolId(ctx, parentId)
                        if parentEntityId then
                            -- 从entity中获取name
                            for _, entity in ipairs(ctx.entities) do
                                if entity.id == parentEntityId then
                                    parentName = entity.name
                                    break
                                end
                            end
                        end
                    else
                        -- 如果是名称，根据名称查找
                        for _, entity in ipairs(ctx.entities) do
                            if entity.type == 'class' and entity.name == parentId then
                                parentEntityId = entity.id
                                parentName = entity.name
                                break
                            end
                        end
                    end
                    
                    if parentEntityId then
                        context.addRelation(ctx, 'inherits', childEntityId, parentEntityId)
                        relationCount = relationCount + 1
                        context.debug(ctx, "继承关系: %s -> %s", className, parentName)
                    else
                        context.debug(ctx, "未找到父类实体: %s -> %s", className, parentId)
                    end
                end
            end
        end
    end
    
    context.debug(ctx, "导出了 %d 个继承关系", relationCount)
    return relationCount
end

-- 主分析函数
function phase3.analyze(ctx)
    print("🔍 第三阶段：实体关系导出")
    
    -- 重置节点去重状态
    context.resetProcessedNodes(ctx, "Phase3")
    
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
    local inheritanceCount = exportInheritanceRelations(ctx)
    
    -- 统计信息
    local totalEntities = #ctx.entities
    local totalRelations = #ctx.relations
    
    print(string.format("  ✅ 实体关系导出完成:"))
    print(string.format("    实体: %d (模块: %d, 类: %d, 函数: %d, 变量: %d)", 
        totalEntities, moduleCount, classCount, functionCount, variableCount))
    print(string.format("    关系: %d (包含: %d, 引用: %d, 别名: %d, 继承: %d)", 
        totalRelations, containmentCount, referenceCount, aliasCount, inheritanceCount))
    
    -- 打印节点跟踪统计
    if ctx.config.enableNodeTracking and tracker3 then
        nodeTracker.printStatistics(tracker3)
    end
end

return phase3 
