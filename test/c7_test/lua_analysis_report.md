# Lua代码分析报告

基于lua-language-server的深度代码分析

生成时间: 2025-07-05 20:16:53

## 统计信息

- 分析文件数: 4
- 总节点数: 34
- 总关系数: 67
- 类别名映射: 10 个
- 变量类型推断: 6 个
- 类继承关系: 6 个

## 变量类型映射

以下变量的类型已被正确推断:

- `round` → `integer`
- `math` → `mathlib`
- `require` → `function`
- `string` → `stringlib`
- `print` → `function`
- `table` → `tablelib`

## 模块别名映射

以下模块别名已被正确识别和解析:

- `Item` → `Item`
- `Weapon` → `Weapon`
- `WeaponClass` → `Weapon`
- `GM` → `GameManager`
- `Enemy` → `Enemy`
- `BaseEntity` → `BaseEntity`
- `GameManager` → `GameManager`
- `GameObject` → `GameObject`
- `Player` → `Player`
- `PlayerClass` → `Player`

## 类继承关系

以下类的继承关系已被识别:

- `Item` 继承自 `BaseEntity`
- `GameManager` 继承自 `BaseEntity`
- `Weapon` 继承自 `Item`
- `GameObject` 继承自 `BaseEntity`
- `Player` 继承自 `[GameObject, BaseEntity]`
- `Enemy` 继承自 `GameObject`

## 方法调用图

按类型分组的方法调用统计:

### player1 类型

- `move()` 被调用 1 次
  - enhanced_test.lua:24 (对象: player1)

### self 类型

- `SimulateBattle()` 被调用 1 次
  - game_manager.lua:36 (对象: self)
- `LevelUp()` 被调用 1 次
  - weapon.lua:11 (对象: self)
- `GetInfo()` 被调用 1 次
  - player.lua:23 (对象: self)
- `__init()` 被调用 1 次
  - weapon.lua:29 (对象: self)

### sword 类型

- `GetInfo()` 被调用 1 次
  - game_manager.lua:33 (对象: sword)

### enemy1 类型

- `attack()` 被调用 1 次
  - enhanced_test.lua:25 (对象: enemy1)

### PlayerAlias 类型

- `new()` 被调用 1 次
  - enhanced_test.lua:31 (对象: PlayerAlias)

### weapon2 类型

- `Use()` 被调用 1 次
  - game_manager.lua:52 (对象: weapon2)
- `IsBroken()` 被调用 1 次
  - game_manager.lua:51 (对象: weapon2)

### obj2 类型

- `TakeDamage()` 被调用 1 次
  - game_manager.lua:48 (对象: obj2)
- `GetInfo()` 被调用 1 次
  - game_manager.lua:32 (对象: obj2)
- `AddItem()` 被调用 1 次
  - game_manager.lua:28 (对象: obj2)

### weapon 类型

- `Upgrade()` 被调用 1 次
  - game_manager.lua:76 (对象: weapon)
- `Repair()` 被调用 1 次
  - game_manager.lua:75 (对象: weapon)
- `GetInfo()` 被调用 1 次
  - game_manager.lua:82 (对象: weapon)
- `new()` 被调用 2 次
  - game_manager.lua:23 (对象: weapon)
  - game_manager.lua:24 (对象: weapon)

### target 类型

- `TakeDamage()` 被调用 1 次
  - player.lua:46 (对象: target)

### player2 类型

- `jump()` 被调用 1 次
  - enhanced_test.lua:32 (对象: player2)

### axe 类型

- `GetInfo()` 被调用 1 次
  - game_manager.lua:34 (对象: axe)

### Weapon 类型

- `new()` 被调用 1 次
  - enhanced_test.lua:20 (对象: Weapon)

### Player 类型

- `new()` 被调用 1 次
  - enhanced_test.lua:18 (对象: Player)

### weapon1 类型

- `Use()` 被调用 1 次
  - game_manager.lua:47 (对象: weapon1)
- `upgrade()` 被调用 1 次
  - enhanced_test.lua:26 (对象: weapon1)
- `IsBroken()` 被调用 1 次
  - game_manager.lua:46 (对象: weapon1)

### manager 类型

- `initialize()` 被调用 1 次
  - enhanced_test.lua:27 (对象: manager)

### GameManager 类型

- `new()` 被调用 1 次
  - enhanced_test.lua:21 (对象: GameManager)

### obj1 类型

- `TakeDamage()` 被调用 1 次
  - game_manager.lua:53 (对象: obj1)
- `GetInfo()` 被调用 1 次
  - game_manager.lua:31 (对象: obj1)
- `AddItem()` 被调用 1 次
  - game_manager.lua:27 (对象: obj1)

### player 类型

- `GetInfo()` 被调用 1 次
  - game_manager.lua:80 (对象: player)
- `LevelUp()` 被调用 1 次
  - game_manager.lua:71 (对象: player)
- `new()` 被调用 2 次
  - game_manager.lua:19 (对象: player)
  - game_manager.lua:20 (对象: player)

### Enemy 类型

- `new()` 被调用 1 次
  - enhanced_test.lua:19 (对象: Enemy)
