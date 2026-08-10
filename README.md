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

## 功能/Features

本分支已收敛为**南京大学专属**：登录与抓取配置改为本地硬编码（[lib/Resources/NjuConfig.dart](lib/Resources/NjuConfig.dart)），不再于运行时拉取多学校列表，旧的多学校 HTML 解析路径已删除。

1. Android / iOS / 鸿蒙 多平台支持
2. 南京大学统一认证登录，本科生 & 研究生均支持，可记住账号密码
3. 一键导入教务系统课表，自动获取当前周
4. 课表更新检测：重新抓取并与本地逐条比对，展示新增 / 变更 / 消失
5. 同一时段的多门课程并排显示，三门及以上折叠为 `+N` 角标
6. 本学期已结课的课程自动不再显示，非本周课程灰显
7. 多套课程配色方案，支持逐门课自定义颜色，灰显色亦可自定义
8. 多个课表管理与切换、分享与备份、自由添加背景图片

## 路线图 / Roadmap：课表更新检测

### 已完成：手动触发的更新检测

比对引擎 [lib/Utils/CourseDiff.dart](lib/Utils/CourseDiff.dart) 是纯函数：先按「课程编号，缺失时退回 课程名 + 教师」把记录分组判定"是不是同一门课"，再在组内按星期配对时间段，输出新增 / 消失 / 字段变更。

目前有**两个入口**都会触发比对，实施任何更新逻辑时都要同时覆盖：

* 导入页的「更新当前课程表」——带完整自动登录链路，不依赖既有会话
* 课表管理里每张表的「检查更新」——复用已有登录状态

### 进行中：数据覆盖逻辑

更新时什么该改、什么该留、什么该删。目标行为：

| 场景 | 系统抓来的课 | 手动添加的数据 | 课程颜色 |
| --- | --- | --- | --- |
| 同学期内再次更新 | 按差异更新 | 保留不动 | 保持不变 |
| 换学期 | 全量替换 | 清除 | 重新分配 |

要执行这张表，需要三种身份识别：

1. **学期身份**：抓取器目前只返回 `{name, courses}`，学期代码（本科 `DM` / 研究生 `XNXQDM`）被揉进显示名丢掉了。需要单独输出 `semesterCode` 并存入课表的 `data` 存档，更新时比对。
2. **数据来源**：`importType` 字段已存在（0 手动 / 1 系统导入 / 2 讲座）但比对时没用上，导致手动添加的课被误报为"消失"。在比对输入侧过滤即可。
3. **课程身份**：颜色目前绑在「课程名 + 哪张表」上，所以重新导入生成新表必然打乱配色。改为绑到比对引擎那个稳定的分组键，映射存进课表 `data` 存档。

**消失课程采用两轮宽限期**：第一次没抓到就从课表上隐藏但保留数据，连续两次没抓到才彻底删除，中途重新出现则恢复（颜色一并回来）。另有熔断：抓取结果为 0 门时判定为抓取失败，整轮跳过不做任何改动。

**换学期**新建一张表并自动切过去，旧表保留为历史——手动数据"清除"因此并非不可逆销毁。

实施顺序：学期代码贯通 → 来源过滤 → 颜色映射 → 消失处理。前三步是纯增量，第四步是唯一会删数据的，最后单独验证。

### 计划中：前台节流自动检查

**不采用 OS 级后台任务**（Android WorkManager / iOS BGTaskScheduler 等）。原因：抓取链路依赖一个真实渲染并执行 JS 的 WebView 而非纯 HTTP 请求，iOS 上无界面后台执行历史上并不稳定，且 Android / iOS / 鸿蒙三端行为差异较大，投入产出比低。

改为在 App 启动或切前台时判断"距上次检查是否超过用户设置的间隔"，达到阈值才静默触发检查。间隔默认**每天一次**，可调整为"每次打开 / 每天 / 每 3 天 / 每周 / 手动"——课表变化频率本身很低，没必要做成实时监控。若过程中需要重新登录或遇到验证码，不做自动处理，只提示用户手动打开 App 检查。

### 更远期

真正的 OS 后台任务、日历增量同步（修复导出到系统日历时因缺少事件 UID 导致的重复事件问题）、ICS 订阅链接等。这些需要额外的服务器组件或更高的工程投入，暂不作为近期目标。

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