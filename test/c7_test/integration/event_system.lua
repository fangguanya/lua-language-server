-- test/c7_test/integration/event_system.lua
-- 事件系统模块

local EventSystem = DefineClass("EventSystem", {
    listeners = {},
    eventHistory = {},
    eventCount = 0
})

-- 事件监听器类
local EventListener = DefineClass("EventListener", {
    id = nil,
    eventType = nil,
    callback = nil,
    isActive = true
})

function EventListener:__init(id, eventType, callback)
    self.id = id
    self.eventType = eventType
    self.callback = callback
    self.isActive = true
    print(string.format("👂 创建事件监听器: %s (事件: %s)", id, eventType))
end

function EventListener:Execute(eventData)
    if self.isActive and self.callback then
        print(string.format("🔔 监听器 %s 处理事件: %s", self.id, self.eventType))
        return self.callback(eventData)
    end
    return nil
end

function EventListener:Deactivate()
    self.isActive = false
    print(string.format("🔇 监听器 %s 已停用", self.id))
end

-- EventSystem 方法实现
function EventSystem:__init()
    self.listeners = {}
    self.eventHistory = {}
    self.eventCount = 0
    print("📡 事件系统初始化完成")
end

function EventSystem:Subscribe(eventType, callback)
    if not self.listeners[eventType] then
        self.listeners[eventType] = {}
    end
    
    local listenerId = "listener_" .. (self.eventCount + 1)
    local listener = EventListener.new(listenerId, eventType, callback)
    
    table.insert(self.listeners[eventType], listener)
    self.eventCount = self.eventCount + 1
    
    print(string.format("📝 订阅事件: %s (监听器: %s)", eventType, listenerId))
    return listenerId
end

function EventSystem:Unsubscribe(eventType, listenerId)
    if self.listeners[eventType] then
        for i, listener in ipairs(self.listeners[eventType]) do
            if listener.id == listenerId then
                listener:Deactivate()
                table.remove(self.listeners[eventType], i)
                print(string.format("❌ 取消订阅: %s (监听器: %s)", eventType, listenerId))
                return true
            end
        end
    end
    return false
end

function EventSystem:Emit(eventType, eventData)
    print(string.format("📢 发送事件: %s", eventType))
    
    -- 记录事件历史
    local eventRecord = {
        type = eventType,
        data = eventData,
        timestamp = os.time(),
        listenersNotified = 0
    }
    
    -- 通知所有监听器
    if self.listeners[eventType] then
        for _, listener in ipairs(self.listeners[eventType]) do
            if listener.isActive then
                local success, result = pcall(listener.Execute, listener, eventData)
                if success then
                    eventRecord.listenersNotified = eventRecord.listenersNotified + 1
                else
                    print(string.format("⚠️ 监听器 %s 处理事件失败: %s", listener.id, tostring(result)))
                end
            end
        end
    end
    
    table.insert(self.eventHistory, eventRecord)
    
    print(string.format("✅ 事件 %s 处理完成，通知了 %d 个监听器", eventType, eventRecord.listenersNotified))
    return eventRecord.listenersNotified
end

function EventSystem:GetEventHistory()
    return {
        totalEvents = #self.eventHistory,
        events = self.eventHistory,
        activeListeners = self:CountActiveListeners()
    }
end

function EventSystem:CountActiveListeners()
    local count = 0
    for eventType, listeners in pairs(self.listeners) do
        for _, listener in ipairs(listeners) do
            if listener.isActive then
                count = count + 1
            end
        end
    end
    return count
end

function EventSystem:GetListenerStats()
    local stats = {
        totalListeners = 0,
        activeListeners = 0,
        eventTypes = {}
    }
    
    for eventType, listeners in pairs(self.listeners) do
        stats.eventTypes[eventType] = {
            total = #listeners,
            active = 0
        }
        
        for _, listener in ipairs(listeners) do
            stats.totalListeners = stats.totalListeners + 1
            if listener.isActive then
                stats.activeListeners = stats.activeListeners + 1
                stats.eventTypes[eventType].active = stats.eventTypes[eventType].active + 1
            end
        end
    end
    
    return stats
end

function EventSystem:ClearHistory()
    local clearedCount = #self.eventHistory
    self.eventHistory = {}
    print(string.format("🧹 清理事件历史，删除了 %d 条记录", clearedCount))
    return clearedCount
end

function EventSystem:BroadcastSystemEvent(message)
    local systemEvent = {
        source = "EventSystem",
        message = message,
        timestamp = os.time()
    }
    
    self:Emit("system_broadcast", systemEvent)
    return systemEvent
end

-- 高级事件处理方法
function EventSystem:CreateEventChain(events)
    print("🔗 创建事件链...")
    
    local chainId = "chain_" .. os.time()
    local results = {}
    
    for i, eventInfo in ipairs(events) do
        local eventType = eventInfo.type
        local eventData = eventInfo.data or {}
        
        -- 添加链信息
        eventData.chainId = chainId
        eventData.chainStep = i
        eventData.totalSteps = #events
        
        local notifiedCount = self:Emit(eventType, eventData)
        table.insert(results, {
            step = i,
            eventType = eventType,
            notifiedCount = notifiedCount
        })
        
        -- 可选的延迟（在实际应用中可能需要）
        -- 这里只是模拟
    end
    
    print(string.format("⛓️ 事件链 %s 执行完成，共 %d 个步骤", chainId, #events))
    return {
        chainId = chainId,
        results = results,
        totalSteps = #events
    }
end

return EventSystem 