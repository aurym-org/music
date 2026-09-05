/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

/**
 * Constants for AppStorage keys.
 * Use these keys to get/set values in AppStorage to avoid typos and improve maintainability.
 */
export class APP_STORAGE_KEYS {
  // ---- 应用核心上下文 ----
  /** UIAbility 上下文 */
  static readonly CONTEXT: string = 'context';
  /** 窗口实例 */
  static readonly WINDOW: string = 'window';
  /** 窗口 Stage */
  static readonly WINDOW_STAGE: string = 'windowStage';
  /** UI 上下文（用于媒体查询等） */
  static readonly UI_CONTEXT: string = 'uiContext';
  /** 顶部安全区高度 */
  static readonly TOP_HEIGHT: string = 'topHeight';
  /** 底部安全区高度 */
  static readonly BOTTOM_HEIGHT: string = 'bottomHeight';
  /** 当前加载图片像素 */
  static readonly CURRENT_PIXEL_MAP: string = 'current_pixel_map';

  // ---- 播放器状态 ----
  /** 当前播放列表 */
  static readonly SONG_LIST: string = 'songList';
  /** 当前选中歌曲索引 */
  static readonly SELECT_INDEX: string = 'selectIndex';
  /** 是否正在播放 */
  static readonly IS_PLAY: string = 'isPlay';
  /** 当前播放进度（毫秒） */
  static readonly PROGRESS: string = 'progress';
  /** 当前播放时间字符串（如 "01:23"） */
  static readonly CURRENT_TIME: string = 'currentTime';
  /** 总时长字符串 */
  static readonly TOTAL_TIME: string = 'totalTime';
  /** 进度条最大值（总毫秒数） */
  static readonly PROGRESS_MAX: string = 'progressMax';
  /** 总时长（毫秒） */
  static readonly TOTAL_MS_TIME: string = 'totalMsTime';
  /** 是否正在加载（显示 Loading） */
  static readonly IS_LOADING: string = 'isLoading';
  /** 是否收藏当前歌曲 */
  static readonly IS_FAVORITE: string = 'isFavorite';
  /** 是否静音模式 */
  static readonly IS_SILENT_MODE: string = 'isSilentMode';
  /** 当前音量（0-100） */
  static readonly CURRENT_VOLUME: string = 'currentVolume';
  /** 当前歌曲的 bvid */
  static readonly CURRENT_BVID: string = 'currentBvid';
  /** 当前歌曲的 cid */
  static readonly CURRENT_CID: string = 'currentCid';
  /** 播放模式（MusicPlayMode 枚举值） */
  static readonly PLAY_MODE: string = 'playMode';
  /** 错误信息（用于 Toast 提示） */
  static readonly ERROR_MESSAGE: string = 'errorMessage';

  // ---- UI 辅助 ----
  /** 折叠屏是否完全展开 */
  static readonly IS_FOLD_FULL: string = 'isFoldFull';
  /** 页面显示时间（用于自动隐藏控件） */
  static readonly PAGE_SHOW_TIME: string = 'pageShowTime';

  // ---- 版本控制 ----
  /** 用于取消过期异步操作的版本号 */
  static readonly SWITCH_VERSION: string = 'switchVersion';
}
