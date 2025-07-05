# Lua代码分析报告

基于lua-language-server的深度代码分析

生成时间: 2025-07-05 18:00:44

## 统计信息

- 分析文件数: 3
- 总节点数: 14
- 总关系数: 40
- 类别名映射: 0 个

## 方法调用图

### obj1

- `TakeDamage()` 被调用 1 次
  - game_manager.lua:53 (对象: obj1)
- `GetInfo()` 被调用 1 次
  - game_manager.lua:31 (对象: obj1)
- `AddItem()` 被调用 1 次
  - game_manager.lua:27 (对象: obj1)

### obj2

- `TakeDamage()` 被调用 1 次
  - game_manager.lua:48 (对象: obj2)
- `GetInfo()` 被调用 1 次
  - game_manager.lua:32 (对象: obj2)
- `AddItem()` 被调用 1 次
  - game_manager.lua:28 (对象: obj2)

### self

- `SimulateBattle()` 被调用 1 次
  - game_manager.lua:36 (对象: self)
- `LevelUp()` 被调用 1 次
  - weapon.lua:11 (对象: self)
- `GetInfo()` 被调用 1 次
  - player.lua:23 (对象: self)
- `__init()` 被调用 1 次
  - weapon.lua:29 (对象: self)

### sword

- `GetInfo()` 被调用 1 次
  - game_manager.lua:33 (对象: sword)

### weapon1

- `Use()` 被调用 1 次
  - game_manager.lua:47 (对象: weapon1)
- `IsBroken()` 被调用 1 次
  - game_manager.lua:46 (对象: weapon1)

### target

- `TakeDamage()` 被调用 1 次
  - player.lua:46 (对象: target)

### weapon

- `Upgrade()` 被调用 1 次
  - game_manager.lua:76 (对象: weapon)
- `Repair()` 被调用 1 次
  - game_manager.lua:75 (对象: weapon)
- `GetInfo()` 被调用 1 次
  - game_manager.lua:82 (对象: weapon)
- `new()` 被调用 2 次
  - game_manager.lua:23 (对象: weapon)
  - game_manager.lua:24 (对象: weapon)

### axe

- `GetInfo()` 被调用 1 次
  - game_manager.lua:34 (对象: axe)

### player

- `GetInfo()` 被调用 1 次
  - game_manager.lua:80 (对象: player)
- `LevelUp()` 被调用 1 次
  - game_manager.lua:71 (对象: player)
- `new()` 被调用 2 次
  - game_manager.lua:19 (对象: player)
  - game_manager.lua:20 (对象: player)

### weapon2

- `Use()` 被调用 1 次
  - game_manager.lua:52 (对象: weapon2)
- `IsBroken()` 被调用 1 次
  - game_manager.lua:51 (对象: weapon2)
