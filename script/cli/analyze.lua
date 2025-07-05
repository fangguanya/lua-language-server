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
function export.runCLI()
    lang(LOCALE)
    
    -- 检查分析目标
    if not ANALYZE and not ANALYZE_FILES and not ANALYZE_FOLDERS then
        print('错误: 必须指定分析目标')
        print('使用 --analyze=目录 或设置 ANALYZE_FILES/ANALYZE_FOLDERS 环境变量')
        return 1
    end
    
    -- 确定根路径
    local rootPath
    local rootUri
    
    if ANALYZE then
        rootPath = fs.canonical(fs.path(ANALYZE)):string()
        rootUri = furi.encode(rootPath)
    elseif ANALYZE_FOLDERS then
        -- 使用第一个文件夹作为根路径
        local firstFolder = ANALYZE_FOLDERS:match("([^,]+)")
        if firstFolder then
            rootPath = fs.canonical(fs.path(firstFolder:match("^%s*(.-)%s*$"))):string()
            rootUri = furi.encode(rootPath)
        end
    else
        -- 使用当前目录作为根路径
        rootPath = fs.current_path():string()
        rootUri = furi.encode(rootPath)
    end
    
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
        await.disable()
        client:registerFakers()
        
        client:initialize {
            rootUri = rootUri,
        }
        
        print('正在初始化工作空间...')
        
        provider.updateConfig(rootUri)
        ws.awaitReady(rootUri)
        
        print('工作空间初始化完成')
        
        -- 使用新的模块化分析器
        local analyzer = require 'cli.analyze.init'
        local config = require 'cli.analyze.config'
        
        -- 创建分析选项
        local options = config.create({
            debug = ANALYZE_DEBUG == "true" or ANALYZE_DEBUG == "1"
        })
        
        -- 如果指定了文件，添加到选项中
        if ANALYZE_FILES then
            options.files = {}
            for file in string.gmatch(ANALYZE_FILES, "[^,]+") do
                table.insert(options.files, file:match("^%s*(.-)%s*$")) -- trim
            end
        end
        
        -- 运行分析
        local ctx = analyzer.analyze(rootUri, options)
        
        -- 输出结果（使用旧的输出格式作为兼容）
        local jsonFile = ANALYZE_OUTPUT or (rootPath .. '/lua_analysis_output.json')
        local mdFile = ANALYZE_REPORT or (rootPath .. '/lua_analysis_report.md')
        
        -- 简单的JSON输出
        local jsonOutput = require('json-beautify').beautify({
            metadata = {
                generatedAt = os.date('%Y-%m-%d %H:%M:%S'),
                analyzer = 'lua-language-server-modular',
                version = '2.0.0'
            },
            symbols = ctx.symbols,
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