<div align="center">

<img src="./android/app/src/main/res/ic_launcher.png" alt="logo" width="128" height="128" />

<h1>南哪课表 APP</h1>

**为 NJUer 打造的 Android / iOS / 鸿蒙 课程表，使用 Flutter 编写**

</div>

## 下载/Download

[南哪课表官网](https://nju.app)

[安卓下载地址](https://mirror.nju.edu.cn/download/%E5%8D%97%E5%93%AA%E8%AF%BE%E8%A1%A8)

[iOS 下载地址](https://apps.apple.com/cn/app/%E5%8D%97%E5%93%AA%E8%AF%BE%E8%A1%A8/id1511705694)

[南哪课表 FAQ](https://idealclover.top/archives/606/)

<!--more-->

## 项目目标

**让课表在后台自动保持最新，有变更主动告知用户，全程不需要用户操作。**

用户手动点「导入」只应该发生一次。此后学校调课、换教室、加课、退课，都由 App 自己发现并处理——用户要么直接看到已经更新好的课表，要么收到一条"周三高数换教室了"的通知。

本分支已收敛为**南京大学专属**：登录与抓取配置本地硬编码（[lib/Resources/NjuConfig.dart](lib/Resources/NjuConfig.dart)），不再运行时拉取多学校列表，旧的多学校 HTML 解析路径已删除。

## 整体框架

从"系统唤醒"到"用户看到结果"分四层。四层各自独立，可以分别验证：

```
┌─ ① 调度层 ────────────────────────────────────┐
│  决定"什么时候查一次"                          │
│  · 前台：打开 App / 切回前台时按节流判断       │
│  · 后台：WorkManager（Android）/ BGTask（iOS） │
└───────────────────┬───────────────────────────┘
                    ↓
┌─ ② 登录层 ────────────────────────────────────┐
│  拿到一个已登录的 WebView 会话                 │
│  · 存储的账号密码 → 自动登录链路               │
│  · 需要人工介入时中止，不阻塞                  │
└───────────────────┬───────────────────────────┘
                    ↓
┌─ ③ 同步服务层 ────────────────────────────────┐
│  抓取 → 判学期 → 比对 → 覆盖 → 产出报告        │
│  纯逻辑，不依赖 BuildContext，前后台共用       │
└───────────────────┬───────────────────────────┘
                    ↓
┌─ ④ 呈现层 ────────────────────────────────────┐
│  · 前台：变更预览页                            │
│  · 后台：本地通知，点开跳转详情                │
└───────────────────────────────────────────────┘
```

各层现状：

| 层 | 状态 | 位置 |
| --- | --- | --- |
| ① 调度 | 仅手动触发，节流与后台调度未做 | — |
| ② 登录 | 已完成 | [ImportView.dart](lib/Pages/Import/ImportView.dart) |
| ③ 同步服务 | 逻辑已完成，但**长在 Widget 里**，待抽出 | 散落于 `ImportView` / `CheckUpdateView` |
| ④ 呈现 | 前台已完成，通知未做 | 两个页面的变更预览 |

## 核心：比对与数据覆盖

### 比对引擎

[lib/Utils/CourseDiff.dart](lib/Utils/CourseDiff.dart) 是纯函数：先按**课程标识**（课程编号，缺失时退回 课程名 + 教师）分组判定"是不是同一门课"，再在组内按星期配对时间段，输出新增 / 消失 / 字段变更。

同一个课程标识（`Course.groupKey`）同时用于**颜色绑定**——两处必须一致，否则更新一轮之后颜色就对不上了。

### 覆盖规则

更新时什么该改、什么该留、什么该删：

**同学期更新**（学期代码一致）

| 数据 | 处置 |
| --- | --- |
| 系统课程 · 字段变了 | 原地更新，保留行 id 与颜色 |
| 系统课程 · 新增 | 插入，颜色查映射，没有则分配并记录 |
| 系统课程 · 这次没抓到 | 标记并从课表隐藏，累计两轮才彻底删除 |
| 手动添加 / 讲座 | 不参与比对，原样保留 |
| 抓取结果为 0 门 | 判定为抓取失败，整轮跳过，不做任何改动 |

**换学期**（学期代码不一致）：新建一张表并自动切过去，旧表保留为历史；手动数据与颜色映射都不带过去。

### 三个支撑机制

1. **学期身份** —— 抓取器输出 `semesterCode`（本科 `DM` / 研究生 `XNXQDM`）存入课表 `data` 存档，判定规则见 [SemesterCode.dart](lib/Utils/SemesterCode.dart)。抓不到代码时按"同学期"处理：漏判的代价是用户重导一次，误判的代价是手动数据被当成上学期的清掉。
2. **数据来源** —— `importType`（0 手动 / 1 系统导入 / 2 讲座）。过滤放在 `diffCourseLists` **内部**而非交给调用方，确保任何入口都不会漏。
3. **课程身份与配色** —— 颜色映射存进课表 `data` 存档的 `course_colors`，取色优先级为 **单独指定 → 课表级映射 → 色板**。这让颜色跟着课程走而非跟着数据库行走：课程被删掉又加回来，颜色不变。

### 消失课程的两轮宽限期

"这次没抓到"分不清是退课还是抓漏，所以把"眼不见"和"真删除"拆开（[MissingCourseSweeper.dart](lib/Utils/MissingCourseSweeper.dart)）：

| 观察 | 处置 | 课表上 |
| --- | --- | --- |
| 第一次没抓到 | 计数 +1，数据保留 | 立即隐藏 |
| 第二次仍没抓到 | 彻底删除 | 已隐藏 |
| 标记后又抓到 | 清除标记 | 恢复显示，颜色一并回来 |

状态存在 `Course.data` 列——该列建表时就有、v2 升级也补过，但从未被读写，因此省掉一次数据库迁移。

## 后台可行性：已验证

立项时判断"OS 级后台任务不可行"，理由是①后台 isolate 造不出 WebView，②滑块轨迹回放依赖 `requestAnimationFrame` 而 rAF 需要 WebView 参与渲染。

**两条理由均已被实验推翻。**

| 实验 | 方法 | 结果 |
| --- | --- | --- |
| rAF 是否依赖渲染 | 同一段计数脚本在「可见 / 被遮住 / 不挂进界面」三种状态下各跑 3 秒 | 不挂进界面反而跑满 60fps（181 帧），可见时因模拟器渲染开销只有 8fps |
| 后台能否用 WebView | WorkManager 唤醒后逐步探测：绑定初始化 → 插件注册 → 创建 WebView → 加载页面 → 读 rAF 计数 | 全部通过，后台 rAF 约 52fps（156 帧） |

**仍未验证**：真机（国产 ROM 清后台策略远比原生激进）、完整登录链路在无界面环境是否走得通、iOS `BGAppRefreshTask` 调度频率、鸿蒙需自写原生。

## 路线图

| # | 任务 | 状态 |
| --- | --- | --- |
| 1 | 抽出 `CourseSyncService`，两个入口改为调用它 | ✅ 已完成 |
| 2 | 前台节流检查（到期在课表顶部提醒） | ✅ 已完成 |
| 3 | 验证完整登录链路在后台可行 | 待推进 |
| 4 | 接 WorkManager + 本地通知 + 失败保护 | 待第 3 步结论 |
| 5 | 真机验证各厂商 ROM 表现 | 待 4 |

前两步不依赖后台方案是否成立，已经落地；从第 3 步起都要先回答"完整登录链路在无界面环境能不能跑通"。

**第 2 步做成了「提醒」而不是「静默自动执行」**：抓取必须先登录，而登录会话保不住（早期的「快捷导入」就是栽在这上面才删掉的），每次打开 App 都自动跑一遍完整登录既慢又可能弹验证码，代价大于收益。判断规则（[UpdateCheckPolicy.dart](lib/Utils/UpdateCheckPolicy.dart)）和间隔设置都是现成的，等会话策略明确后只需换触发方式。

### 已知问题

**手动删掉的系统课程会在下次更新时被加回来。** 比如申请了免修不免考的课，用户长按删除后，下一轮比对会发现"学校数据里有、本地没有"，判定为新增重新插入。修法是记一个「已弃用」课程标识列表、比对时跳过，尚未实施。

### 必须实现的保护措施

**账号锁定防护**（优先级最高）：用户在学校改了密码后本地凭据失效，后台若持续重试可能触发统一认证的账号锁定，而用户毫不知情。必须做到**连续失败即自动停用后台检查并通知用户**，绝不无限重试。

**数据库并发**：前后台 isolate 各自打开 sqflite，需要 WAL 模式或"前台正在同步则跳过本轮"的标记。

### 更远期

日历增量同步（修复导出到系统日历时因缺少事件 UID 导致的重复事件问题）、ICS 订阅链接。

> **不做服务器代抓**。让服务器定期抓取需要以可还原的形式保存学生统一认证密码，而该账号同时是邮箱、图书馆、成绩系统的入口。一旦泄露是全部用户一起泄露，这个责任不适合由学生社团项目承担。

## 其他已实现功能

* Android / iOS / 鸿蒙 多平台
* 统一认证登录，本科生 & 研究生均支持，可记住账号密码
* 同一时段多门课程并排显示，三门及以上折叠为 `+N` 角标
* 本学期已结课的课程自动不再显示，非本周课程灰显
* 8 套课程配色方案，支持逐门课自定义颜色，灰显色亦可自定义
* 多课表管理与切换、分享与备份、自定义背景图片

## 课程数据格式

抓取的实现在 [lib/Utils/NjuEhallJsonImporter.dart](lib/Utils/NjuEhallJsonImporter.dart)：在已登录的 WebView 内直接请求 eHall 的内部 JSON 接口，再把本科 / 研究生两套字段适配成下面这一份统一格式。写库经由 [lib/Utils/CourseImportCodec.dart](lib/Utils/CourseImportCodec.dart) 转换。

> 上游项目通过运行时拉取 `api/schoolList.json` + 每校一份远程 JS 脚本来支持多所学校。本分支不再走这条路径，仓库里的 `api/` 目录仅作存档保留，不参与编译，改动它不会影响 App 行为。

统一格式如下：

```
{
    "name": "当前学期名称",
    "courses": [
        {
            "name": "课程名称",
            "classroom": "课程地点",
            "class_number": "课程编号",
            "teacher": "教师名称",
            "test_time": "考试时间",
            "test_location": "考试地点",
            "link":"课程详情链接，没有传null",
            "weeks": [1,2,3], // 课程第几周上，是一个数组
            "week_time": 1, // 课程周几上
            "start_time": 1, // 课程开始节数，从1开始,
            "time_count": 2, // 课程持续节数，即结束节数-开始结束，注意如果是3-4节则为1，不需要额外进行加一操作
            "import_type": 1, // 固定填1，作为自动导入方式
            "info": "课程详情，没有传null",
            "data": null
        }
    ]
}

```

## 部署相关

因为增加了鸿蒙支持，需要使用鸿蒙 Flutter 版本。

1. 根据 [flutter_flutter oh-3.27.0](https://gitcode.com/openharmony-tpc/flutter_flutter/tree/oh-3.27.0-release) 配置鸿蒙依赖
2. 加载项目环境变量：`source tool/setup_ohos_env.sh` （配好环境之后就只需要每次开发打开终端执行一次）
3. 安装并使用指定版本：`fvm install oh-3.27.0-release && fvm use 3.27.5-ohos-1.0.3` （这里很奇怪，下载的版本号和cache版本号不一样）
4. 运行 `fvm flutter doctor -v` 检查环境变量配置，Flutter 与 OpenHarmony 都应为 `ok`
5. 在 `external` 文件夹中 clone 依赖（若尚未 clone）
  * `cd external`
  * `git clone https://gitcode.com/openharmony-tpc/flutter_packages.git` 
  * `git clone https://gitcode.com/openharmony-sig/flutter_sqflite.git`
  * `git clone https://gitcode.com/nutpi/flutter_plus_plugins_package_info_plus.git`
  * `git clone https://gitcode.com/openharmony-sig/fluttertpc_mobile_scanner.git`
  * `git clone https://gitcode.com/openharmony-sig/fluttertpc_device_calendar`
6. 如果在中国大陆网络下载失败，执行：
  * `export USE_CN_FLUTTER_MIRROR=1`
  * `source tool/setup_ohos_env.sh`

### 快速切换构建环境

为了在 Android/iOS 与 OHOS 间减少手动操作，可在当前终端直接切换：

* 切到 OHOS 构建环境：`source tool/switch_flutter_env.sh ohos`
* 切回官方 Flutter（Android/iOS 常用）：`source tool/switch_flutter_env.sh official`

切换后建议运行 `flutter doctor -v` 或 `fvm flutter doctor -v` 做一次确认，并执行 `flutter clean` 以清除之前环境的构建缓存。