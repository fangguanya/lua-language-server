local lclient   = require 'lclient'()
local furi      = require 'file-uri'
local util      = require 'utility'
local lang      = require 'language'
local fs        = require 'bee.filesystem'
local provider  = require 'provider'
local await     = require 'await'
require 'plugin'

local export = {}
function export.runCLI()
    lang(LOCALE)
    
    -- 检查分析目标
    local dir = _G['ANALYZE']
    if not dir then
        print('错误: 必须指定分析目标')
        print('使用 --analyze=目录')
        return 1
    end
    
    -- 确定根路径
    local rootPath = fs.canonical(fs.path(dir)):string()
    local rootUri = furi.encode(rootPath)
    
    if not rootUri then
        print(string.format('错误: 无法创建URI: %s', rootPath))
        return 1
    end
    rootUri = rootUri:gsub("/$", "")
    
    util.enableCloseFunction()
    
    local function errorhandler(err)
        print('错误: ' .. tostring(err))
        print(debug.traceback())
    end
    
    ---@async
    xpcall(lclient.start, errorhandler, lclient, function (client)
        await.disable()  -- 禁用await模式
        client:registerFakers()
        
        client:initialize {
            rootUri = rootUri,
        }
        
        print('正在初始化工作空间...')
        
        provider.updateConfig(rootUri)
        -- ws.awaitReady(rootUri)  -- 暂时跳过这个，可能导致挂起
        
        print('工作空间初始化完成')
        
        -- 使用新的模块化分析器
        print('正在加载分析器模块...')
        local analyzer = require 'cli.analyze.init'
        local context = require 'cli.analyze.context'
        print('分析器模块加载完成')
        
        -- 创建分析选项
        local dbg = _G['ANALYZE_DEBUG']
        local options = {
            debug = dbg == true or dbg == "true" or dbg == "1"
        }
        
        -- 运行分析
        print('开始运行分析...')
        local ctx = analyzer.analyze(rootUri, options)
        print('分析运行完成')
        
        -- 输出结果（使用旧的输出格式作为兼容）
        local jsonFile = _G['ANALYZE_OUTPUT'] or (rootPath .. '/lua_analysis_output.json')
        local mdFile = _G['ANALYZE_REPORT'] or (rootPath .. '/lua_analysis_report.md')
        
        -- 简单的JSON输出
        local jsonOutput = require('json-beautify').beautify({
            metadata = {
                generatedAt = os.date('%Y-%m-%d %H:%M:%S'),
                analyzer = 'lua-language-server-modular',
                version = '2.0.0'
            },
            symbols = context.getSerializableSymbols(ctx),
            entities = ctx.entities,
            relations = ctx.relations,
            statistics = ctx.statistics
        })
        
        util.saveFile(jsonFile, jsonOutput)
        print(string.format('✓ JSON输出已保存到: %s', jsonFile))
        
        -- 简单的Markdown输出
        local mdLines = {
            '# Lua代码分析报告 (模块化版本)',
            '',
            '生成时间: ' .. os.date('%Y-%m-%d %H:%M:%S'),
            '',
            '## 统计信息',
            '',
            string.format('- 分析文件数: %d', ctx.statistics.totalFiles),
            string.format('- 总符号数: %d', ctx.statistics.totalSymbols),
            string.format('- 总实体数: %d', ctx.statistics.totalEntities),
            string.format('- 总关系数: %d', ctx.statistics.totalRelations),
            string.format('- 处理时间: %.2f 秒', ctx.statistics.processingTime),
            ''
        }
        
        util.saveFile(mdFile, table.concat(mdLines, '\n'))
        print(string.format('✓ Markdown报告已保存到: %s', mdFile))
        
        print('')
        print('✅ 模块化分析任务完成！')
    end)
    
    return 0
end

return export 
