---
--- Created by fanggang
--- DateTime: 2025/7/6 17:27
---

-- 下面为典型的几个封装抽象
SYMBOL_TYPE = {
    MODULE=1,
    CLASS=2,
    METHOD=3,       -- MODULE+CLASS+METHOD为scope类型，包含内部嵌套再定义
    VARIABLE=4,     -- 注意：去掉了alias，同时这里将var全都假定为可以任意赋值（不仅是类型成员变量、还是全局变量） 
    REFERENCE=6,    -- 一个module对另外一个module的引用
}
FUNCTION_ANONYMOUS = "anonymous"

-- 简单拷贝一下API函数
local function applyMethods(obj, parent)
    for k, v in pairs(parent) do
        if type(v) == 'function' then
            obj[k] = v
        end
    end
end

-- 所有symbol的基础对象
local base = {}
function base.new(sym_id, name, type, ast)
    local b = {}
    b.id = sym_id
    b.name = name
    b.type = type
    b.refs = {}        -- 正向引用：此符号对其他符号的引用（只存储SYMBOL_ID）- 使用hash table去重
    b.container = false
    b.parent = nil  -- 对于module，这个变量固定为nil
    b.ast = ast     -- 缓存的模块ast句柄，省去每次重新构建
    applyMethods(b, base)
    return b
end

-- 所有作用域的基础对象
local scope = {}
function scope.new(sym_id, name, type, ast)
    local s = base.new(sym_id, name, type, ast)
    s.container = true
    s.classes = {}
    s.methods = {}
    s.variables = {}
    applyMethods(s, scope)
    return s
end
function scope:addClass(cls)
    table.insert(self.classes, cls.id)
end
function scope:addMethod(mtd)
    table.insert(self.methods, mtd.id)
end
function scope:addVariable(var)
    table.insert(self.variables, var.id)
end

-- module：一个文件作用域，可以包含classes、methodss、variables、references
local module = {}
function module.new(sym_id, name, ast)
    local mdl = scope.new(sym_id, name, SYMBOL_TYPE.MODULE, ast)
    mdl.returns = nil  -- 该模块的导出'返回类型'列表，这里记录的是一个'symbol_id'
    applyMethods(mdl, module)
    return mdl
end

-- class：一个类型定义，包含属性和函数成员
local class = {}
function class.new(sym_id, name, ast)
    local cls = scope.new(sym_id, name, SYMBOL_TYPE.CLASS, ast)
    cls.aliases = {}  -- 指向此类的别名列表
    applyMethods(cls, class)
    return cls
end
-- function：全局和类型函数定义（对于闭包函数记录为non-name的函数
local method = {}
function method.new(sym_id, name, ast)
    local md = scope.new(sym_id, name, SYMBOL_TYPE.METHOD, ast)
    if name == nil or name == "" then
        md.name = FUNCTION_ANONYMOUS
    end
    md.parameters = {}  -- 函数的参数，配合类型推断（VARIABLE）
    applyMethods(md, method)
    return md
end
function method:IsAnonymous()
    return self.name == FUNCTION_ANONYMOUS
end
-- variable,全局和类型所属的属性定义
local variable = {}
function variable.new(sym_id, name, ast)
    local var = scope.new(sym_id, name, SYMBOL_TYPE.VARIABLE, ast)
    var.possibles = {}  -- 确定的类型列表（如：'string', 'number', 'boolean', 'table', 'function'）
    var.related = {}    -- 关联的其他符号ID列表（如：A=B，那么A的related = {B的symbol_id}）- 使用hash table去重
    
    -- 别名相关字段
    var.isAlias = false       -- 是否为别名
    var.aliasTarget = nil     -- 别名指向的目标符号ID
    var.aliasTargetName = nil -- 别名指向的目标符号名称
    
    applyMethods(var, variable)
    return var
end
-- reference：模块间的依赖关系
local reference = {}
function reference.new(sym_id, name, ast)
    local re = base.new(sym_id, name, SYMBOL_TYPE.REFERENCE, ast)
    re.target = nil     -- 依赖索引的目标模块（记录的是symbol_id）
    applyMethods(re, reference)
    return re
end

return {
    module = module,
    class = class,
    method = method,
    variable = variable,
    reference = reference,
    applyMethods = applyMethods,
    SYMBOL_TYPE = SYMBOL_TYPE,
    FUNCTION_ANONYMOUS = FUNCTION_ANONYMOUS
}
