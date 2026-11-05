# CG 剧情窗口配置指南

本文说明如何给《Space》配置全屏 CG：一条 CG 只有**图片**和**文本**两部分，按现实秒计时播放，可以挂在四种游戏事件上自动触发。

---

## 1. 它由什么组成

| 文件 | 作用 |
|---|---|
| `scenes/ui/cg_window.tscn` | CG 窗口场景（`CanvasLayer`，`layer=45`，高于对话框的 40） |
| `scripts/ui/cg_window.gd` | 播放节奏与队列：淡入 → 停留 → 淡出，只负责显示 |
| `scripts/progression/cg_controller.gd` | 读配置、判定触发条件、记账（哪些 CG 已播过） |
| `data/cg.json` | 全局 CG 配置表：所有地图都会加载 |
| `data/cg/<地图名>.json` | 地图专属 CG：由地图根节点 `cg_data_path` 指定，只有那张地图会加载（见第 11 节） |
| `assets/cg/` | 建议的 CG 图片目录（不存在时自行创建） |
| `tests/cg_test.gd` | 窗口、四种条件、暂停与存档的回归 |
| `tests/fixtures/cg.json` | 测试夹具（四条各一种条件），不要拿它当产品配置 |

窗口节点结构刻意保持极简：`Root/Image`（图片）+ `Root/Bottom/.../Text`（文本）+ 一条进度线。没有头像、没有确认按钮——需要玩家读得更久就把 `duration` 调大。

---

## 2. 三步配好一条 CG

### 第一步：放图片

把图片放进项目的 `assets/cg/`（目录不存在就新建），例如：

```
assets/cg/opening.png
```

路径必须写成 `res://assets/cg/opening.png`。支持 `png / jpg / jpeg / webp / svg / bmp / tres`。

> 图片缺失不会让游戏报错：CG 仍会播放，只是黑底 + 文本，并在控制台给出 `CG 图片不存在` 警告。可以先用纯文本跑通剧情，再补图。

### 第二步：写 CG 配置

全局剧情（任何地图都可能触发，比如「完成某个任务」「到达某个地点」）写进 `data/cg.json`：

```json
{
  "version": 1,
  "cgs": [
    {
      "id": "opening_world",
      "image": "res://assets/cg/opening.png",
      "text": "离开行星轨道的那一刻，舷窗外只剩下无尽的星海。",
      "duration": 5.0,
      "trigger": { "type": "map_enter", "map": "default_map" }
    }
  ]
}
```

只想在某一张地图里出现的剧情（比如这座太空城的开场 CG），写进 `data/cg/<地图名>.json`，并让地图指向它——见第 11 节「把 CG 绑定到指定地图」。两种文件格式完全相同。

### 第三步：进游戏验证

- 新游戏会先走行星教程、城市教程，**不会**加载 `default_map`；要验证「进入世界地图」，先把两段教程跳过。
- 想快速验证某条 CG，把 `trigger` 临时改成 `{"type": "map_enter", "map": "*"}`，任何地图加载都会播放。
- 播放完一条后 `once` 默认是 `true`，同一次游戏内不会重播；改配置后要**开新游戏**或删掉存档再试。

---

## 3. 字段表

| 字段 | 必填 | 类型 | 说明 |
|---|---|---|---|
| `id` | 是 | 字符串 | 唯一标识，只允许字母、数字、`_`、`-`，≤ 64 字符；存档按它记「已播过」 |
| `image` | 是 | 字符串 | `res://` 图片路径 |
| `text` | 是 | 字符串 | 显示在底部文本区的正文，≤ 4000 字符 |
| `duration` | 是 | 数字 | 停留时长（现实秒），必须 > 0 且 ≤ 3600；淡入淡出时间另算 |
| `trigger` | 是 | 对象 | 播放条件，见下一节 |
| `once` | 否 | 布尔 | 默认 `true`。`false` 表示每次满足条件都播（受「进入瞬间」限制，不会每帧刷） |
| `skippable` | 否 | 布尔 | 默认 `true`。`false` 时点击/空格不能提前结束 |
| `enabled` | 否 | 布尔 | 默认 `true`。设 `false` 可临时停用而不用删配置 |

顶层必须是：

```json
{ "version": 1, "cgs": [] }
```

`cgs` 是数组，**同一次判定命中多条时按数组顺序排队播放**。

---

## 4. 四种播放条件

### 4.1 进入地图 `map_enter`

```json
{ "type": "map_enter", "map": "default_map" }
```

- `map` 写地图文件名（不含 `.json`）。也接受 `maps/default_map.json` 或 `res://maps/default_map.json`，判定时只取文件名。
- 写 `"*"` 表示任意地图，常用于调试。
- 判定时机：`main.gd` 每次成功应用地图后 `map_epoch += 1`，调度器发现序号变化就判定一次。**同一张地图重复加载也算一次新的进入**。
- 典型用途：进入世界地图的开场 CG、每张教程地图的说明 CG。

> 注意：教程阶段的地图是 `plante_teach`（行星）、`city_teach`（城市），不是 `default_map`。

### 4.2 进入行星 / 太空城 `enter_object`

```json
{ "type": "enter_object", "object": "city_1", "kind": "city" }
```

- `object` 是**地图 JSON 里的对象 id**（不是显示名）。`"*"` 表示任意对象。
- `kind` 可选：`"planet"`、`"city"`、`"any"`；不写等于 `any`。
- 判定时机：`PortController.enter_port()` 成功后发 `port_entered(object_id, source)` 信号。行星入轨确认、太空城泊船都会走这里。
- 典型用途：第一次抵达某颗行星、第一次进入某座太空城的 CG。

对象 id 可以从 `maps/*.json` 的 `objects[].id` 查，也可以用 `tools/quest_editor.py` 载入地图后看左栏。

### 4.3 完成某个任务 `quest_complete`

```json
{ "type": "quest_complete", "quest": "q_first_dock" }
```

- `quest` 是 `data/planets/*.json` 里 `quests[].id`，必须全局唯一。
- 判定时机：`QuestManager.quest_completed(quest_id)` 信号。
- 只对**本次运行中真正完成**的委托生效。读档时已完成的任务不会补发信号，因此也不会补播 CG。

### 4.4 到达某个地点 `reach_point`

```json
{ "type": "reach_point", "position": [0.0, -62000.0], "radius_m": 5000.0 }
```

- `position` 是**物理世界坐标（米）**，与地图 JSON 的 `objects[].position` 同一坐标系。
- `radius_m` 是圆形范围半径（米），必须 > 0。
- 判定时机：每 `poll_interval`（默认 0.1 秒）取一次当前受控飞船位置，用「上一采样点 → 当前位置」的线段与圆求交。**高速穿过小圆也不会漏判**。
- 只在「圈外 → 圈内」的那一次触发；停在圈里不会反复播。

取坐标的办法：在游戏里看飞船位置不方便，通常直接抄地图 JSON。例如想让玩家飞到某颗行星附近，就抄该行星的 `position`，把 `radius_m` 设为行星半径的 3~5 倍。

---

## 5. 播放节奏与交互

| 阶段 | 时长 | 说明 |
|---|---|---|
| 淡入 | `fade_seconds`，默认 0.35s | 从全黑显现 |
| 停留 | 配置里的 `duration` | 底部进度线走完 |
| 淡出 | `fade_seconds` | 回到全黑，然后播下一条 |

- 计时用 `Time.get_ticks_usec()` 的真实时间，**不受模拟倍率影响**。
- 播放期间 `simulation_paused` 会被置为 `true`，避免玩家看不见时撞上行星。结束后只解除自己设的那次暂停：如果玩家本来就暂停、或教程正在暂停，不会被强行恢复。
- 点击鼠标左键、空格、回车、ESC 可提前结束当前 CG（`skippable=false` 时无效）；淡入期间与停留前 0.35 秒内的点击会被忽略，防止误触。
- 播放期间吞掉输入，点击不会穿透到航行操作或暂停菜单。
- 队列播完才发出 `queue_finished`；`clear_queue()`（读档、重置、新游戏）会立即清空。

---

## 6. 放进 Godot 与导出

| 内容 | 位置 | 说明 |
|---|---|---|
| 配置 | `data/cg.json` | 全局配置，项目内固定路径，`CgController.config_path` 可在 Inspector 改 |
| 地图专属配置 | `data/cg/<地图名>.json` | 由地图根节点 `cg_data_path` 指向 |
| 图片 | `assets/cg/*` | 建议目录；也可以放任意 `res://` 路径 |
| 导出 | `export_presets.cfg` | `include_filter` 已含 `data/*.json,data/planets/*.json,data/cg/*.json,maps/*.json`，新增 CG 不需要再改导出配置；图片按资源正常导入即可 |

`data/cg.json` 与 `data/cg/*.json` 都是普通 JSON，不是 Godot 资源。修改后重启游戏生效（运行时不会热重载配置）。

---

## 7. 存档行为

- `CgController.make_state()` 把已播放的 `id` 写进存档的 `cg_state`。
- 读档时恢复这份记录，**看过的 CG 不会重播**；读档瞬间因地图加载误触发的 CG 会被撤销。
- 新游戏调用 `reset_for_new_game()` 清空记录，CG 会重新播。
- 普通「重置航行」**不会**清空记录，避免重复剧情。
- 旧存档没有 `cg_state` 字段时按「一条都没看过」处理，不会读档失败。

---

## 8. 校验与测试

配置写错不会让游戏崩溃，但会在控制台 `push_warning` 提示；写错的条目会被跳过。要一次看全部问题，运行：

```bash
/d/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe \
  --headless --path . --script res://tests/cg_test.gd
```

或直接跑全量回归：

```bash
bash tools/run_regression.sh cg
```

测试覆盖：窗口节点结构（只有图片/文本）、播放节奏、队列顺序、缺图降级、四类条件的判定、`once` 语义、暂停恢复、存档状态往返，以及地图绑定（`cg_data_path` 读取、非法路径拒绝、归属不一致忽略、id 加地图前缀）。

校验规则（`CgController.collect_errors()`）：

- `version` 必须为 1，`cgs` 必须是数组；
- `id` 唯一且只含 `[A-Za-z0-9_-]`；
- `image` 必须是 `res://` 下、扩展名合法的图片；
- `text` 必须是字符串且 ≤ 4000 字符；
- `duration` 必须 > 0；
- `trigger.type` 必须是四种之一，且各自必填字段齐全；
- 根节点 `map` 若存在必须是字符串；用在地图绑定时，它与当前地图名不一致会导致**整份文件被忽略**（只告警，不崩游戏）。

---

## 9. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 进了地图但没播 | `map` 写成了显示名或带目录的完整路径且文件名不符 | 用地图**文件名**（不含 `.json`） |
| 到了城市没播 | `object` 填了显示名 | 改填地图 JSON 的 `objects[].id` |
| 播完一次再也不播 | `once` 默认 `true` | 想反复播就设 `once: false` |
| 一进游戏就被 CG 挡住、什么也点不了 | 触发了长 `duration` 且 `skippable: false` | 先按 ESC 或改配置；调试期建议 `duration ≤ 5` |
| 只有黑底和文字 | 图片路径不存在或未导入 | 看控制台 `CG 图片不存在`；确认 `.import` 已生成 |
| 读档后 CG 又播了一次 | 该 CG 在存档写入前没播完/没有记录 | 正常现象；`once` 记录在**入队时**写入，不会重复 |
| 教程阶段看不到世界地图的 CG | 教程走的是 `plante_teach` / `city_teach` | 给教程地图单独配 `map_enter` |

---

## 10. 最小可运行示例

```json
{
  "version": 1,
  "cgs": [
    {
      "id": "teach_orbit_intro",
      "image": "res://assets/cg/teach_orbit.png",
      "text": "这里是你的第一次入轨训练。别急，先看清行星的引力范围。",
      "duration": 4.0,
      "trigger": { "type": "map_enter", "map": "plante_teach" }
    },
    {
      "id": "first_city",
      "image": "res://assets/cg/first_city.png",
      "text": "晨曦港。你第一次真正踏进人类在群星间的落脚点。",
      "duration": 5.0,
      "trigger": { "type": "enter_object", "object": "city_1", "kind": "city" }
    },
    {
      "id": "arrive_outer_ring",
      "image": "res://assets/cg/ring.png",
      "text": "远处那圈微光，是很久以前留下的航标。",
      "duration": 3.5,
      "trigger": { "type": "reach_point", "position": [120000.0, -46000.0], "radius_m": 8000.0 }
    }
  ]
}
```

---

## 11. 把 CG 绑定到指定地图

全局 `data/cg.json` 适合「任何地图都可能发生」的剧情。如果一段 CG 只属于某一座城、某一张教程图，把它绑到地图上更安全：地图被替换、被复制时，CG 不会跟着串到别的地图。

### 11.1 绑定方式：地图根节点写 `cg_data_path`

地图 JSON 的根节点多一个可选字段，指向这份地图专属的 CG 文件：

```json
{
  "version": 1,
  "cg_data_path": "res://data/cg/default_map.json",
  "objects": [ ... ],
  "ship": { "position": [0, 0], "velocity": [0, 0] }
}
```

约束（`map_loader.gd` 的 `valid_cg_path`，游戏启动时硬校验，不符合直接判定地图无效）：

- 必须以 `res://data/cg/` 开头、`.json` 结尾；
- 不能含 `..` 或反斜杠；
- 只能直接放在 `data/cg/` 下，不允许子目录；
- 全字段最长 256 字符。

地图里没写 `cg_data_path` 就只加载全局 `data/cg.json`，不会报错。

### 11.2 专属文件格式：与全局完全相同，多一个 `map`

```json
{
  "version": 1,
  "map": "default_map",
  "cgs": [
    {
      "id": "city_gate",
      "image": "res://assets/cg/city_gate.png",
      "text": "晨曦港的闸门在你面前缓缓打开。",
      "duration": 4.5,
      "trigger": { "type": "enter_object", "object": "city_1", "kind": "city" }
    }
  ]
}
```

`map` 是这份文件的归属地图名（地图文件名去掉 `.json`）。运行时如果它与当前地图不一致，整份文件会被忽略并给出警告——防止「A 城的 CG 文件」被误挂到 B 城上。`map` 留空则不做归属校验。

### 11.3 加载与记账规则

- 进入地图时，`CgController` 读取 `当前地图.cg_data_path` 指向的文件，与全局 `data/cg.json` **合并**；离开地图后地图专属部分卸载。
- 地图专属 CG 的 `id` 在内部会加上地图前缀：`default_map/city_gate`。所以不同地图可以有同名 `id`，互不顶掉；存档里记录的也是带前缀的 key。
- 切换地图会重置「到达地点」的上一次采样点与圈内状态，避免把跨地图的位移误判成一次进入圆形范围。
- `map_enter` 条件在专属文件里依然有效；`trigger.map` 应写本图地图名（或 `*`），否则永远不会命中。
- 专属文件里 `enter_object` 的 `object` 必须是**本图**的对象 id；`quest_complete` 的 `quest` 建议取本图事件 JSON 里出现过的委托 id。
- 播放记录仍写进存档 `cg_state`，读档后不会重播；换地图不会丢失记录。

### 11.4 用什么编辑

- 直接用 `tools/quest_editor.py`：打开地图 JSON → 切到「CG 剧情」页 → `创建 CG 配置`（默认生成 `data/cg/<地图名>.json`，并把路径写回地图根节点 `cg_data_path`）→ 逐条编辑 → `保存全部`。
- 手改也可以，但两个文件要一起改：地图里写 `cg_data_path`，CG 文件里写 `map`，两边地图名必须一致。
- 用 `tools/map_editor.py` 重新保存地图不会丢掉 `cg_data_path`（它保留未知根字段），可以放心来回改。

### 11.5 存档影响

地图指纹 `map_hash` 覆盖整份地图 JSON。**给地图新增/更换 `cg_data_path` 会让旧存档读档失败**（原档保留、自动保存关闭）。只改 CG 文件内容不影响存档。开发期建议绑定完再开新游戏验证。
