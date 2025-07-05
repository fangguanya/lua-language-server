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
analyzer.config = require 'cli.analyze.config'              -- 配置管理

-- 分析器主流程
function analyzer.analyze(rootUri, options)
    local startTime = os.clock()
    
    -- 初始化上下文
    local ctx = analyzer.context.new(rootUri, options)
    
    print("=== 开始多阶段Lua代码分析 ===")
    print(string.format("根目录: %s", rootUri))
    
    -- 第一阶段：符号定义识别
    print("\n🔍 第一阶段：符号定义识别")
    analyzer.phase1.analyze(ctx)
    
    -- 第二阶段：类型推断
    print("\n🔍 第二阶段：类型推断")
    analyzer.phase2.analyze(ctx)
    
    -- 第三阶段：实体关系导出
    print("\n🔍 第三阶段：实体关系导出")
    analyzer.phase3.analyze(ctx)
    
    -- 第四阶段：函数调用分析
    print("\n🔍 第四阶段：函数调用分析")
    analyzer.phase4.analyze(ctx)
    
    local endTime = os.clock()
    ctx.statistics.processingTime = endTime - startTime
    
    print(string.format("\n✅ 分析完成，耗时: %.2f秒", ctx.statistics.processingTime))
    
    return ctx
end

return analyzer 