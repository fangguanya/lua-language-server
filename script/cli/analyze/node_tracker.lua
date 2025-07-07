---
--- Created by fanggang
--- DateTime: 2025/7/6 17:27
---
-- analyze/node_tracker.lua
-- 节点重复处理跟踪模块

local guide = require 'parser.guide'
local nodeTracker = {}

-- 创建节点跟踪器
function nodeTracker.new(phaseName)
    return {
        phaseName = phaseName,
        processedNodes = {},      -- 已处理的节点 {nodeId -> count}
        selectNodes = {},         -- select节点统计 {nodeId -> count}
        duplicateNodes = {},      -- 重复处理的节点列表
        totalNodes = 0,           -- 总节点数
        duplicateCount = 0        -- 重复处理节点数
    }
end

-- 记录节点处理
function nodeTracker.recordNode(tracker, node)
    if not node then
        return
    end
    -- 使用节点的内存地址作为唯一标识
    local nodeId = tostring(node)
    
    -- 记录处理次数
    tracker.processedNodes[nodeId] = (tracker.processedNodes[nodeId] or 0) + 1
    
    -- 如果是第一次处理，增加总节点数
    if tracker.processedNodes[nodeId] == 1 then
        tracker.totalNodes = tracker.totalNodes + 1
    else
        -- 如果是重复处理，记录到重复列表
        if tracker.processedNodes[nodeId] == 2 then
            tracker.duplicateCount = tracker.duplicateCount + 1
            table.insert(tracker.duplicateNodes, {
                nodeId = nodeId,
                nodeType = node.type,
                count = tracker.processedNodes[nodeId]
            })
        else
            -- 更新重复次数
            for _, dupNode in ipairs(tracker.duplicateNodes) do
                if dupNode.nodeId == nodeId then
                    dupNode.count = tracker.processedNodes[nodeId]
                    break
                end
            end
        end
    end
    
    -- 特别统计select节点
    if node.type == 'select' then
        tracker.selectNodes[nodeId] = (tracker.selectNodes[nodeId] or 0) + 1
    end
end

-- 获取统计信息
function nodeTracker.getStatistics(tracker)
    local selectTotal = 0
    local selectDuplicate = 0
    
    for nodeId, count in pairs(tracker.selectNodes) do
        selectTotal = selectTotal + 1
        if count > 1 then
            selectDuplicate = selectDuplicate + 1
        end
    end
    
    return {
        phaseName = tracker.phaseName,
        totalNodes = tracker.totalNodes,
        duplicateNodes = tracker.duplicateCount,
        selectTotal = selectTotal,
        selectDuplicate = selectDuplicate,
        duplicateDetails = tracker.duplicateNodes
    }
end

-- 打印统计信息
function nodeTracker.printStatistics(tracker)
    local stats = nodeTracker.getStatistics(tracker)
    
    print(string.format("📊 %s 节点处理统计:", stats.phaseName))
    print(string.format("  节点数: %d, 重复: %d, select: %d, select重复: %d",
        stats.totalNodes, stats.duplicateNodes, stats.selectTotal, stats.selectDuplicate))
    
    -- 如果有重复节点，打印详细信息（限制数量）
    if #stats.duplicateDetails > 0 then
        print(string.format("  重复处理的节点详情 (显示前10个):"))
        for i = 1, math.min(10, #stats.duplicateDetails) do
            local dupNode = stats.duplicateDetails[i]
            print(string.format("    - 节点 %s (类型: %s) 被处理了 %d 次",
                dupNode.nodeId, dupNode.nodeType, dupNode.count))
        end
        
        if #stats.duplicateDetails > 10 then
            print(string.format("    ... 还有 %d 个重复节点", #stats.duplicateDetails - 10))
        end
    end
end

-- 合并多个跟踪器的统计信息
function nodeTracker.mergeStatistics(trackers)
    local merged = {
        totalNodes = 0,
        duplicateNodes = 0,
        selectTotal = 0,
        selectDuplicate = 0,
        phaseDetails = {}
    }
    
    for _, tracker in ipairs(trackers) do
        local stats = nodeTracker.getStatistics(tracker)
        merged.totalNodes = merged.totalNodes + stats.totalNodes
        merged.duplicateNodes = merged.duplicateNodes + stats.duplicateNodes
        merged.selectTotal = merged.selectTotal + stats.selectTotal
        merged.selectDuplicate = merged.selectDuplicate + stats.selectDuplicate
        
        table.insert(merged.phaseDetails, {
            phaseName = stats.phaseName,
            totalNodes = stats.totalNodes,
            duplicateNodes = stats.duplicateNodes,
            selectTotal = stats.selectTotal,
            selectDuplicate = stats.selectDuplicate
        })
    end
    
    return merged
end

return nodeTracker 
