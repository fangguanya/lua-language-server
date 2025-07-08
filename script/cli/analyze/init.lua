---
--- Created by fanggang
--- DateTime: 2025/7/6 17:27
---
-- analyze/init.lua
-- 分析器核心模块初始化

local analyzer = {}

-- 导入各个阶段的分析器
analyzer.phase1 = require 'cli.analyze.phase1_symbols'      -- 符号定义识别
analyzer.phase2 = require 'cli.analyze.phase2_inference'    -- 类型推断
analyzer.phase3 = require 'cli.analyze.phase3_export'       -- 实体关系导出
analyzer.phase4 = require 'cli.analyze.phase4_calls'        -- 函数调用分析

-- 导入工具模块
analyzer.context = require 'cli.analyze.context'            -- 全局上下文管理
analyzer.utils = require 'cli.analyze.utils'                -- 工具函数
analyzer.cache_manager = require 'cli.analyze.cache_manager' -- 缓存管理器

-- 阶段枚举
local PHASES = analyzer.cache_manager.PHASES

-- 分析器主流程
function analyzer.analyze(rootUri, options)
    local startTime = os.clock()
    
    -- 初始化上下文
    local ctx = analyzer.context.new(rootUri, options)
    
    -- 初始化缓存管理器
    local cacheManager = analyzer.cache_manager.new(rootUri, options and options.cache)
    
    -- 将缓存管理器传递给上下文
    ctx.cacheManager = cacheManager
    
    print("=== 开始多阶段Lua代码分析 ===")
    print(string.format("根目录: %s", rootUri))
    
    -- 尝试从缓存恢复
    local resumeFromPhase = nil
    local cacheData = nil
    
    if cacheManager.config.enabled and not (options and options.forceReanalysis) then
        print("\n🔄 检查缓存...")
        cacheData = analyzer.cache_manager.loadCache(cacheManager)
        
        if cacheData then
            -- 获取文件列表用于缓存验证
            local currentFileList = analyzer.context.getFiles(ctx)
            local isValid, reason, changes = analyzer.cache_manager.validateCache(cacheManager, cacheData, currentFileList)
            
            if isValid then
                print("✅ 发现有效缓存，正在恢复状态...")
                
                -- 恢复上下文状态
                analyzer.cache_manager.deserializeContext(cacheManager, cacheData.context, ctx)
                
                -- 确定从哪个阶段开始
                resumeFromPhase = cacheData.currentPhase
                print(string.format("📍 从阶段 %s 继续执行", resumeFromPhase))
                
                -- 如果有步骤信息，显示详细的恢复信息
                if cacheData.progress and cacheData.progress.step then
                    print(string.format("📋 上次进度: %s", cacheData.progress.description or cacheData.progress.step))
                end
                
                -- 恢复统计信息
                if cacheData.context.statistics then
                    ctx.statistics = cacheData.context.statistics
                end
            else
                print(string.format("❌ 缓存无效: %s", reason))
                if changes then
                    print(string.format("   文件变更: 修改%d个，新增%d个，删除%d个", 
                        #changes.modified, #changes.added, #changes.deleted))
                    
                    -- 如果只是少量文件变更，可以考虑增量更新
                    local totalChanges = #changes.modified + #changes.added + #changes.deleted
                    if totalChanges <= 5 then
                        print("💡 检测到少量文件变更，建议使用增量更新")
                    end
                end
                
                -- 清除无效缓存
                analyzer.cache_manager.clearCache(cacheManager)
            end
        else
            print("ℹ️  未找到缓存文件")
        end
    end
    
    -- 执行分析阶段
    local phaseOrder = {
        PHASES.PHASE1_SYMBOLS,
        PHASES.PHASE2_INFERENCE,
        PHASES.PHASE3_EXPORT,
        PHASES.PHASE4_CALLS
    }
    
    local startPhaseIndex = 1
    if resumeFromPhase then
        for i, phase in ipairs(phaseOrder) do
            if phase == resumeFromPhase then
                startPhaseIndex = i
                break
            end
        end
    end
    
    -- 执行各个阶段
    for i = startPhaseIndex, #phaseOrder do
        local phase = phaseOrder[i]
        local phaseStartTime = os.clock()
        
        if phase == PHASES.PHASE1_SYMBOLS then
            print("\n🔍 第一阶段：符号定义识别")
            analyzer.phase1.analyze(ctx)
            
        elseif phase == PHASES.PHASE2_INFERENCE then
            print("\n🔍 第二阶段：类型推断和call信息记录")
            analyzer.phase2.analyze(ctx)
            
        elseif phase == PHASES.PHASE3_EXPORT then
            print("\n🔍 第三阶段：实体关系导出")
            analyzer.phase3.analyze(ctx)
            
        elseif phase == PHASES.PHASE4_CALLS then
            print("\n🔍 第四阶段：函数调用分析")
            analyzer.phase4.analyze(ctx)
        end
        
        local phaseEndTime = os.clock()
        local phaseTime = phaseEndTime - phaseStartTime
        print(string.format("   ⏱️  阶段耗时: %.2f秒", phaseTime))
        
        -- 保存缓存
        if cacheManager.config.enabled then
            local progress = {
                completedPhases = {},
                currentPhase = phase,
                phaseStartTime = phaseStartTime,
                phaseEndTime = phaseEndTime,
                phaseTime = phaseTime
            }
            
            -- 记录已完成的阶段
            for j = 1, i do
                table.insert(progress.completedPhases, phaseOrder[j])
            end
            
            local saveSuccess = analyzer.cache_manager.saveCache(cacheManager, ctx, phase, progress)
            if not saveSuccess then
                print("⚠️  缓存保存失败，但分析将继续")
            end
        end
    end
    
    local endTime = os.clock()
    ctx.statistics.processingTime = endTime - startTime
    
    print(string.format("\n✅ 分析完成，总耗时: %.2f秒", ctx.statistics.processingTime))
    
    -- 显示缓存信息
    if cacheManager.config.enabled then
        local cacheInfo = analyzer.cache_manager.getCacheInfo(cacheManager)
        if cacheInfo then
            print(string.format("💾 缓存信息: 大小 %.2fKB, 版本 %s", 
                cacheInfo.size / 1024, cacheInfo.version or "未知"))
        end
    end
    
    return ctx
end

-- 清除缓存的辅助函数
function analyzer.clearCache(rootUri, options)
    local cacheManager = analyzer.cache_manager.new(rootUri, options and options.cache)
    local success = analyzer.cache_manager.clearCache(cacheManager)
    
    if success then
        print("✅ 缓存已清除")
    else
        print("❌ 清除缓存失败")
    end
    
    return success
end

-- 获取缓存信息的辅助函数
function analyzer.getCacheInfo(rootUri, options)
    local cacheManager = analyzer.cache_manager.new(rootUri, options and options.cache)
    return analyzer.cache_manager.getCacheInfo(cacheManager)
end

-- 验证缓存的辅助函数
function analyzer.validateCache(rootUri, options)
    local cacheManager = analyzer.cache_manager.new(rootUri, options and options.cache)
    local cacheData = analyzer.cache_manager.loadCache(cacheManager)
    
    if not cacheData then
        return false, "未找到缓存"
    end
    
    -- 创建临时上下文来获取文件列表
    local ctx = analyzer.context.new(rootUri, options)
    local fileList = analyzer.context.getFiles(ctx)
    
    return analyzer.cache_manager.validateCache(cacheManager, cacheData, fileList)
end

return analyzer 
