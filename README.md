# Aurym Music

> *名字里的金，是昕昀的日光。*

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-Next-black)](https://developer.huawei.com/consumer/cn/harmonyos/)
[![ArkTS](https://img.shields.io/badge/lang-ArkTS-blue)](https://developer.huawei.com/consumer/cn/arkts/)
[![Bilibili](https://img.shields.io/badge/data-Bilibili%20API-00A1D6?logo=bilibili)](https://www.bilibili.com)
[![status](https://img.shields.io/badge/status-stable-brightgreen)]()

Aurym Music 是一个轻量级的 B 站收藏夹音乐播放器，运行在 HarmonyOS 上。它只做一件事：把你收藏夹里的音乐内容筛选出来，放进一个干净的播放列表。没有社交，没有推荐算法，没有直播——只有音乐。

## 功能

- [x] 获取指定 UP 主的收藏夹列表
- [x] 干净的播放列表，极简播放
- [x] 后台播放
- [x] 响应蓝牙设备播放指令
- [x] 播控中心控制及冷启动
- [x] 记忆上次播放模式
- [x] 收藏夹缓存

## 为什么做这个

B 站收藏夹里塞满了各种内容，但那些音乐视频值得一个更好的播放器。Aurym Music 帮你把它们单独拎出来，还给听歌这件事一个不被打扰的空间。这是 Aurym 的第一个 App，也是一个关于"光"的实验——我们希望技术是温暖的，像日光一样。

## 技术栈

- HarmonyOS
- ArkTS
- Bilibili API

## 快速开始

```bash
# 克隆项目
git clone https://github.com/fbotp/AurymMusic.git

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
│  │  │  └──StyleConstants.ets                            // 样式常量
│  │  └──utils                                            // 工具函数
│  │     ├──mediautils                                    // 媒体方法
│  │     │  ├──AVPlayerController.ets                     // AVPlayerController播放类
│  │     │  ├──AVSessionController.ets                    // 播控中心控制类
│  │     │  ├──MediaControlCenter.ets                     // 媒体控制中心类
│  │     │  └──MediaTools.ets                             // 媒体工具处理类
│  │     ├──BackgroundUtil.ets                            // 后台任务类
│  │     ├──BiliWbiUtil.ets                               // BiliWbi加密工具类
│  │     ├──BreakpointSystem.ets                          // 断点系统类
│  │     ├──Logger.ets                                    // 日志类
│  │     ├──PreferencesUtil.ets                           // 首选项工具类
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

## 声明

Aurym Music 是一个独立开发者的个人应用，与哔哩哔哩官方无关。本应用使用的 Bilibili API 仅为学习研究目的，请勿将其用于商业用途。
