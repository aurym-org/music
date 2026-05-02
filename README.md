# Aurum

> 从 B 站收藏夹里淘金。

Aurum 是一个轻量级的 B 站收藏夹音乐播放器，运行在 HarmonyOS 上。它只做一件事：把你收藏夹里的音乐内容筛选出来，放进一个干净的播放列表。

名字取自拉丁语 "Aurum"（金）。收藏夹像矿砂，好的音乐是金粒。从信息洪流里把它们筛出来，存好，反复听。

## 功能

- 获取指定 UP 主的收藏夹列表
- 响应蓝牙设备播放指令
- 播控中心控制及冷启动
- 干净的播放列表，极简播放
- 记忆上次播放模式

## 为什么做这个

B 站收藏夹里塞满了各种内容，但那些音乐视频值得一个更好的播放器。Aurum 帮你把它们单独拎出来，还给听歌这件事一个不被打扰的空间。

## 技术栈

- HarmonyOS
- ArkTS
- Bilibili API

## 快速开始

```bash
# 克隆项目
git clone https://github.com/fbotp/Aurum.git

# 用 DevEco Studio 打开
# 构建并运行
```

## 工程目录
```
├──entry/src/main/ets/
│  ├──common
│  │  ├──constants                                        // 常量
│  │  │  ├──BreakpointConstants.ets                       // 断点常量
│  │  │  ├──ContentConstants.ets                          // 内容常量
│  │  │  ├──PlayerConstants.ets                           // 播放常量
│  │  │  └──StyleConstants.ets                            // 顶部区域组件
│  │  └──utils                                            // 工具函数
│  │     ├──mediautils                                    // 媒体方法
│  │     │  ├──AVPlayerController.ets                     // AVPlayerController播放类
│  │     │  ├──AVSessionController.ets                    // 播控中心控制类
│  │     │  ├──MediaControlCenter.ets                     // 媒体控制中心类
│  │     │  ├──MediaControlCenterCallbackAction.ets       // 媒体控制中心回调函数响应类
│  │     │  ├──MediaControlCenterHandle.ets               // 媒体控制中心句柄类
│  │     │  └──MediaTools.ets                             // 媒体工具处理类
│  │     ├──BackgroundUtil                                // 后台任务类
│  │     ├──BreakpointSystem                              // 断点系统类
│  │     ├──Logger                                        // 日志类
│  │     ├──PreferencesUtil                               // 首选项工具类
│  │     └──ResourceConversion.ets                        // 资源工具类
│  ├──entryability
│  │  ├──EntryAbility.ets                                 // Ability的生命周期回调内容
│  │  └──InsightIntentExecutorImpl.ets                    // 意图框架回调内容
│  ├──entrybackupability
│  │  └──EntryBackupAbility.ets                           // EntryBackupAbility的生命周期回调内容
│  ├──model
│  │  └──SongListData.ets                                 // 歌单列表数据
│  ├──pages
│  │  └──Index.ets                                        // 首页
│  ├──view
│  │  ├──ControlAreaComponent.ets                         // 控制区域组件
│  │  ├──MusicInfoComponent.ets                           // 音乐详情组件
│  │  └──PlayerInfoComponent.ets                          // 播放详情组件
│  └──viewmodel
│     ├──BiliFavDetail.ets                                // Bilibili收藏夹详情
│     ├──BiliPlayUrl.ets                                  // Bilibili视频播放地址
│     ├──SongData.ets                                     // 歌曲基础数据类型
│     ├──SongDataSource.ets                               // 歌曲列表数据源
│     └──SongItemBuilder.ets                              // 歌曲列表数据构造
└──entry/src/main/resources                               // 应用静态资源目录
```

## 路线图

- [x] 后台播放
- [x] 收藏夹缓存

## 协议

MIT License

---

*名字里的金，是昕昀的日光。*
