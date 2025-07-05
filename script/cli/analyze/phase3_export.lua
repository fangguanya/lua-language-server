-- analyze/phase3_export.lua
-- 第三阶段：实体关系导出

local files = require 'files'
local guide = require 'parser.guide'
local context = require 'cli.analyze.context'
local utils = require 'cli.analyze.utils'
local furi = require 'file-uri'

local phase3 = {}

-- 导出文件夹节点
local function exportFolderNodes(ctx)
    local folders = {}
    
    -- 从模块路径中提取文件夹
    for _, module in pairs(ctx.symbols.modules) do
        local modulePath = module.name
        local parts = {}
        
        -- 分割模块路径
        for part in modulePath:gmatch('[^%.]+') do
            table.insert(parts, part)
        end
        
        -- 构建文件夹层次结构
        local currentPath = ""
        for i, part in ipairs(parts) do
            if i < #parts then -- 不包括最后一个文件名
                currentPath = currentPath == "" and part or (currentPath .. "." .. part)
                if not folders[currentPath] then
                    folders[currentPath] = {
                        path = currentPath,
                        level = i,
                        modules = {}
                    }
                end
                table.insert(folders[currentPath].modules, module.id)
            end
        end
    end
    
    -- 导出文件夹实体
    for path, folder in pairs(folders) do
        local entityId = context.addEntity(ctx, 'folder', {
            name = path,
            path = path,
            level = folder.level,
            modules = folder.modules,
            category = 'folder',
            sourceLocation = {
                file = nil,
                line = nil,
                column = nil
            }
        })
    end
end

-- 导出模块节点
local function exportModuleNodes(ctx)
    for moduleId, module in pairs(ctx.symbols.modules) do
        local filePath = furi.decode(module.uri)
        
        local entityId = context.addEntity(ctx, 'module', {
            name = module.name,
            filePath = filePath,
            uri = module.uri,
            classes = module.classes or {},
            functions = module.functions or {},
            variables = module.variables or {},
            category = 'module',
            sourceLocation = {
                file = filePath,
                line = 1,
                column = 1
            }
        })
    end
end

-- 导出类节点
local function exportClassNodes(ctx)
    for classId, class in pairs(ctx.symbols.classes) do
        local filePath = furi.decode(class.uri)
        
        local entityId = context.addEntity(ctx, 'class', {
            name = class.name,
            defineType = class.defineType,
            parentClasses = class.parentClasses or {},
            members = class.members or {},
            methods = class.methods or {},
            module = class.module,
            category = 'class',
            sourceLocation = {
                file = filePath,
                line = class.position.line,
                column = class.position.column
            }
        })
    end
end

-- 获取函数完整源代码和偏移信息
local function getFunctionSourceCode(uri, funcSymbol)
    local state = files.getState(uri)
    if not state or not state.ast then
        return nil, nil, nil
    end
    
    local text = files.getText(uri)
    if not text then
        return nil, nil, nil
    end
    
    -- 查找函数节点 - 使用名称和位置匹配
    local functionNode = nil
    guide.eachSource(state.ast, function(source)
        if source.type == 'function' then
            -- 获取函数的起始位置
            local start, finish = guide.getRange(source)
            if start and finish then
                -- 转换为行列位置 - 使用正确的API
                local startRow, startCol = guide.rowColOf(start)
                
                -- 检查是否匹配位置（行号从1开始）
                if startRow == funcSymbol.position.line then
                    functionNode = source
                    return false -- 停止遍历
                end
            end
        end
    end)
    
    if not functionNode then
        -- 如果没找到，尝试更宽松的匹配
        guide.eachSource(state.ast, function(source)
            if source.type == 'function' then
                local start, finish = guide.getRange(source)
                if start and finish then
                    local startRow, startCol = guide.rowColOf(start)
                    -- 允许行号相差1的情况
                    if math.abs(startRow - funcSymbol.position.line) <= 1 then
                        functionNode = source
                        return false
                    end
                end
            end
        end)
    end
    
    if not functionNode then
        return nil, nil, nil
    end
    
    -- 获取函数的起始和结束位置
    local startPos, finishPos = guide.getRange(functionNode)
    
    if startPos and finishPos then
        -- 转换为字节偏移
        local startOffset = guide.positionToOffset(state, startPos)
        local finishOffset = guide.positionToOffset(state, finishPos)
        
        -- 确保位置有效
        if startOffset and finishOffset and startOffset > 0 and finishOffset > startOffset and finishOffset <= #text then
            local sourceCode = text:sub(startOffset, finishOffset)
            return sourceCode, startOffset - 1, finishOffset - 1 -- 转换为0基索引
        end
    end
    
    return nil, nil, nil
end

-- 导出函数节点
local function exportFunctionNodes(ctx)
    for funcId, func in pairs(ctx.symbols.functions) do
        local filePath = furi.decode(func.uri)
        
        -- 获取函数完整源代码和偏移信息
        local sourceCode, startPos, finishPos = getFunctionSourceCode(func.uri, func)
        
        local entityId = context.addEntity(ctx, 'function', {
            name = func.name,
            isMethod = func.isMethod or false,
            className = func.className,
            params = func.params or {},
            scope = func.scope,
            isAnonymous = func.isAnonymous or false,
            module = func.module,
            sourceCode = sourceCode or "",
            sourceStartOffset = startPos,
            sourceEndOffset = finishPos,
            category = 'function',
            sourceLocation = {
                file = filePath,
                line = func.position.line,
                column = func.position.column
            }
        })
    end
end

-- 导出变量节点
local function exportVariableNodes(ctx)
    for varId, variable in pairs(ctx.symbols.variables) do
        local filePath = furi.decode(variable.uri)
        
        -- 获取变量类型
        local variableType = "unknown"
        local typeInfo = ctx.types.inferred[varId]
        if typeInfo then
            variableType = typeInfo.type
        end
        
        local entityId = context.addEntity(ctx, 'variable', {
            name = variable.name,
            assignmentType = variable.assignmentType,
            scope = variable.scope,
            inferredType = variable.inferredType,
            variableType = variableType,
            confidence = variable.confidence,
            functionId = variable.functionId,
            parameterIndex = variable.parameterIndex,
            module = variable.module,
            category = 'variable',
            sourceLocation = {
                file = filePath,
                line = variable.position.line,
                column = variable.position.column
            }
        })
    end
end

-- 导出继承关系
local function exportInheritanceRelations(ctx)
    for classId, class in pairs(ctx.symbols.classes) do
        if class.parentClasses and #class.parentClasses > 0 then
            for _, parentClass in ipairs(class.parentClasses) do
                -- 查找父类实体
                local parentEntityId = nil
                for _, entity in ipairs(ctx.entities) do
                    if entity.type == 'class' and entity.name == parentClass then
                        parentEntityId = entity.id
                        break
                    end
                end
                
                if parentEntityId then
                    -- 查找子类实体
                    local childEntityId = nil
                    for _, entity in ipairs(ctx.entities) do
                        if entity.type == 'class' and entity.name == class.name then
                            childEntityId = entity.id
                            break
                        end
                    end
                    
                    if childEntityId then
                        context.addRelation(ctx, 'inherits', childEntityId, parentEntityId, {
                            relationship = 'inheritance',
                            sourceLocation = {
                                file = furi.decode(class.uri),
                                line = class.position.line,
                                column = class.position.column
                            }
                        })
                    end
                end
            end
        end
    end
end

-- 导出包含关系
local function exportContainmentRelations(ctx)
    -- 模块包含类
    for moduleId, module in pairs(ctx.symbols.modules) do
        if module.classes and #module.classes > 0 then
            for _, classId in ipairs(module.classes) do
                local moduleEntityId = nil
                local classEntityId = nil
                
                -- 查找模块实体
                for _, entity in ipairs(ctx.entities) do
                    if entity.type == 'module' and entity.name == module.name then
                        moduleEntityId = entity.id
                        break
                    end
                end
                
                -- 查找类实体
                local classSymbol = ctx.symbols.classes[classId]
                if classSymbol then
                    for _, entity in ipairs(ctx.entities) do
                        if entity.type == 'class' and entity.name == classSymbol.name then
                            classEntityId = entity.id
                            break
                        end
                    end
                end
                
                if moduleEntityId and classEntityId then
                    context.addRelation(ctx, 'contains', moduleEntityId, classEntityId, {
                        relationship = 'containment',
                        sourceLocation = {
                            file = furi.decode(module.uri),
                            line = 1,
                            column = 1
                        }
                    })
                end
            end
        end
        
        -- 模块包含函数
        if module.functions and #module.functions > 0 then
            for _, funcId in ipairs(module.functions) do
                local moduleEntityId = nil
                local funcEntityId = nil
                
                -- 查找模块实体
                for _, entity in ipairs(ctx.entities) do
                    if entity.type == 'module' and entity.name == module.name then
                        moduleEntityId = entity.id
                        break
                    end
                end
                
                -- 查找函数实体
                local funcSymbol = ctx.symbols.functions[funcId]
                if funcSymbol then
                    for _, entity in ipairs(ctx.entities) do
                        if entity.type == 'function' and entity.name == funcSymbol.name then
                            funcEntityId = entity.id
                            break
                        end
                    end
                end
                
                if moduleEntityId and funcEntityId then
                    context.addRelation(ctx, 'contains', moduleEntityId, funcEntityId, {
                        relationship = 'containment',
                        sourceLocation = {
                            file = furi.decode(module.uri),
                            line = 1,
                            column = 1
                        }
                    })
                end
            end
        end
    end
end

-- 导出文件夹包含关系
local function exportFolderContainmentRelations(ctx)
    for _, entity in ipairs(ctx.entities) do
        if entity.type == 'folder' then
            for _, moduleId in ipairs(entity.modules) do
                local moduleSymbol = ctx.symbols.modules[moduleId]
                if moduleSymbol then
                    -- 查找模块实体
                    local moduleEntityId = nil
                    for _, moduleEntity in ipairs(ctx.entities) do
                        if moduleEntity.type == 'module' and moduleEntity.name == moduleSymbol.name then
                            moduleEntityId = moduleEntity.id
                            break
                        end
                    end
                    
                    if moduleEntityId then
                        context.addRelation(ctx, 'contains', entity.id, moduleEntityId, {
                            relationship = 'folder_containment',
                            sourceLocation = {
                                file = nil,
                                line = nil,
                                column = nil
                            }
                        })
                    end
                end
            end
        end
    end
end

-- 后处理别名关系
local function postProcessAliasRelations(ctx)
    -- 处理别名关系，将方法名和静态函数名中的别名替换为真实类名
    for aliasName, aliasInfo in pairs(ctx.symbols.aliases) do
        if aliasInfo.type == "class_definition" then
            local targetClassName = aliasInfo.targetClass
            
            -- 遍历所有函数实体，替换方法名和静态函数名中的别名
            for _, entity in ipairs(ctx.entities) do
                if entity.type == 'function' then
                    if entity.isMethod then
                        -- 处理方法名 (aliasName:methodName -> targetClassName:methodName)
                        local aliasPrefix = aliasName .. ":"
                        if entity.name:sub(1, #aliasPrefix) == aliasPrefix then
                            local methodName = entity.name:sub(#aliasPrefix + 1)
                            entity.name = targetClassName .. ":" .. methodName
                            entity.className = targetClassName
                        end
                    else
                        -- 处理静态函数名 (aliasName.functionName -> targetClassName.functionName)
                        local aliasPrefix = aliasName .. "."
                        if entity.name:sub(1, #aliasPrefix) == aliasPrefix then
                            local functionName = entity.name:sub(#aliasPrefix + 1)
                            entity.name = targetClassName .. "." .. functionName
                            entity.className = targetClassName
                        end
                    end
                end
            end
        end
    end
end

-- 主分析函数
function phase3.analyze(ctx)
    print("  导出实体节点...")
    
    -- 导出各类节点
    exportFolderNodes(ctx)
    exportModuleNodes(ctx)
    exportClassNodes(ctx)
    exportFunctionNodes(ctx)
    exportVariableNodes(ctx)
    
    print("  导出关系...")
    
    -- 导出各类关系
    exportInheritanceRelations(ctx)
    exportContainmentRelations(ctx)
    exportFolderContainmentRelations(ctx)
    
    -- 后处理别名关系
    postProcessAliasRelations(ctx)
    
    -- 统计信息
    local entityCount = #ctx.entities
    local relationCount = #ctx.relations
    
    print(string.format("  ✅ 实体关系导出完成:"))
    print(string.format("     实体: %d, 关系: %d", entityCount, relationCount))
end

return phase3 