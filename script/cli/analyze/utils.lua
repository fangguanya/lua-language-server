---
--- Created by fanggang
--- DateTime: 2025/7/6 17:27
---
-- analyze/utils.lua
-- 工具函数模块

local furi = require 'file-uri'
local guide = require 'parser.guide'

local utils = {}

-- 获取文件名（不含扩展名）
function utils.getFileName(uri)
    return furi.decode(uri):match("([^/\\]+)%.lua$") or furi.decode(uri)
end

-- 获取模块路径
function utils.getModulePath(uri, rootUri)
    local filePath = furi.decode(uri)
    local rootPath = furi.decode(rootUri)
    
    -- 移除根路径前缀
    local relativePath = filePath:gsub("^" .. rootPath:gsub("([^%w])", "%%%1"), "")
    
    -- 移除开头的路径分隔符
    relativePath = relativePath:gsub("^[/\\]", "")
    
    -- 移除.lua扩展名
    relativePath = relativePath:gsub("%.lua$", "")
    
    -- 将路径分隔符替换为点号
    local modulePath = relativePath:gsub("[/\\]", ".")
    
    return modulePath
end

-- 获取AST节点的位置信息
function utils.getNodePosition(source)
    if not source or not source.start then
        return {line = 0, column = 0}
    end
    
    local line, col = guide.rowColOf(source.start)
    return {
        line = line + 1,  -- 转换为1-based
        column = col + 1,
        position = source.start
    }
end

-- 安全获取AST节点的名称
function utils.getNodeName(node)
    if not node then return nil end
    
    if type(node) == "string" then
        return node
    end
    
    if node[1] then
        return node[1]
    end
    
    return nil
end

-- 检查是否是支持的require函数
function utils.isRequireFunction(funcName, requireFunctions)
    if not funcName or not requireFunctions then return false end
    
    for _, reqFunc in ipairs(requireFunctions) do
        if funcName == reqFunc then
            return true
        end
    end
    
    return false
end

-- 检查是否是支持的类定义函数
function utils.isClassFunction(funcName, classFunctions)
    if not funcName or not classFunctions then return false end
    
    for _, classFunc in ipairs(classFunctions) do
        if funcName == classFunc then
            return true
        end
    end
    
    return false
end

-- 提取字符串字面量的值
function utils.getStringValue(node)
    if not node or node.type ~= 'string' then
        return nil
    end
    return node[1]
end

-- 获取作用域信息
function utils.getScopeInfo(source)
    -- 这里可以根据需要实现更复杂的作用域分析
    local scope = {
        type = "unknown",
        level = 0
    }
    
    -- 简单的作用域判断
    local parent = source.parent
    while parent do
        if parent.type == 'function' then
            scope.type = "function"
            scope.level = scope.level + 1
        elseif parent.type == 'main' then
            scope.type = "module"
            break
        end
        parent = parent.parent
    end
    
    return scope
end

-- 深拷贝表
function utils.deepCopy(obj)
    if type(obj) ~= "table" then
        return obj
    end
    
    local result = {}
    for k, v in pairs(obj) do
        result[k] = utils.deepCopy(v)
    end
    
    return result
end

-- 合并表
function utils.merge(t1, t2)
    local result = utils.deepCopy(t1)
    
    if t2 then
        for k, v in pairs(t2) do
            result[k] = v
        end
    end
    
    return result
end

-- 检查表是否为空
function utils.isEmpty(t)
    return not t or next(t) == nil
end

-- 获取表的大小
function utils.tableSize(t)
    if not t then return 0 end
    
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    
    return count
end

-- 数组去重
function utils.unique(arr)
    local seen = {}
    local result = {}
    
    for _, item in ipairs(arr) do
        if not seen[item] then
            seen[item] = true
            table.insert(result, item)
        end
    end
    
    return result
end

-- 格式化时间
function utils.formatTime(seconds)
    if seconds < 1 then
        return string.format("%.0fms", seconds * 1000)
    else
        return string.format("%.2fs", seconds)
    end
end

-- 获取函数调用名称
function utils.getCallName(source)
    if not source or source.type ~= 'call' then
        return nil
    end
    
    local node = source.node
    if not node then return nil end
    
    if node.type == 'getlocal' or node.type == 'getglobal' then
        return utils.getNodeName(node)
    elseif node.type == 'getfield' then
        local obj = utils.getNodeName(node.node)
        local field = utils.getNodeName(node.field)
        if obj and field then
            return obj .. '.' .. field
        end
    elseif node.type == 'getmethod' then
        local obj = utils.getNodeName(node.node)
        local method = utils.getNodeName(node.method)
        if obj and method then
            return obj .. ':' .. method
        end
    end
    
    return nil
end

-- 获取require模块路径
function utils.getFormularModulePath(p)
    return string.gsub(p, "[/\\]", ".")
end
function utils.getRequireModulePath(source)
    if not source or source.type ~= 'call' then
        return nil
    end
    
    if source.args and source.args[1] and source.args[1].type == 'string' then
        return utils.getFormularModulePath(source.args[1][1])
    end
    
    return nil
end

-- 获取函数名称
function utils.getFunctionName(source)
    if not source or source.type ~= 'function' then
        return nil
    end
    
    local parent = source.parent
    if not parent then return nil end
    
    if parent.type == 'setlocal' or parent.type == 'setglobal' then
        return utils.getNodeName(parent.node)
    elseif parent.type == 'setfield' then
        local obj = utils.getNodeName(parent.node)
        local field = utils.getNodeName(parent.field)
        if obj and field then
            return obj .. '.' .. field
        end
    elseif parent.type == 'setmethod' then
        local obj = utils.getNodeName(parent.node)
        local method = utils.getNodeName(parent.method)
        if obj and method then
            return obj .. ':' .. method
        end
    end
    
    return nil
end

-- 检查数组是否包含某个值
function utils.containsValue(array, value)
    for _, v in ipairs(array) do
        if v == value then
            return true
        end
    end
    return false
end

return utils 
