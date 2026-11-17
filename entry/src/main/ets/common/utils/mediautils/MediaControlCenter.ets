/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { getFavoriteDetail } from '../../../repository/FavoriteRepository';
import { SongItem } from '../../../viewmodel/SongData';
import SongItemBuilder from '../../../viewmodel/SongItemBuilder';
import { DEFAULT_VOLUME, MusicPlayMode, SILENT_ID, VOLUME_ID, PLAY_MODE_ID } from '../../constants/PlayerConstants';
import { ContentConstants } from '../../constants/ContentConstants';
import Logger from '../Logger';
import { AVSessionController } from './AVSessionController';
import { MediaTools } from './MediaTools';
import { AVPlayerController } from './AVPlayerController';
import { AVPlayerEventCallbacks, AVSessionCommandCallbacks } from './MediaControllerCallbacks';
import { BackgroundUtil } from '../BackgroundUtil';
import { common } from '@kit.AbilityKit';
import { PreferencesUtil } from '../PreferencesUtil';
import { MediaResourceManager } from '../MediaResourceManager';
import { audio } from '@kit.AudioKit';
import { getCurrentVersion, incrementVersion, isVersionMatch } from '../VersionUtil';
import { APP_STORAGE_KEYS } from '../../constants/AppStorageKeys';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'MediaControlCenter';

export class MediaControlCenter {
  private avSessionController: AVSessionController | undefined = undefined;
  private avPlayerController: AVPlayerController | undefined = undefined;
  private context: common.UIAbilityContext | undefined = AppStorage.get(APP_STORAGE_KEYS.CONTEXT);
  private songItemBuilder: SongItemBuilder = new SongItemBuilder();
  // Default to ordered playback until persisted preferences are loaded.
  private playMode: MusicPlayMode = MusicPlayMode.ORDER;
  private songList: SongItem[] = [];
  private musicIndex: number = 0;
  private audioSessionManager: audio.AudioSessionManager | undefined = undefined;
  private isInitialized = false;
  private initPromise: Promise<void> | undefined = undefined;
  private audioSessionOperationPromise: Promise<void> = Promise.resolve();
  private static mediaControlFunction: MediaControlCenter;
  private lastProgressUpdateTime: number = 0;
  private lastAVSessionProgressUpdateTime: number = 0;
  private currentPixelMap: PixelMap | undefined = undefined;
  // A user/system pause or stop during track loading must override the
  // automatic-play behavior of the in-flight track switch.
  private playbackIntentGeneration: number = 0;
  // Preserve the default auto-play intent for the active track switch so an
  // asynchronous AVPlayer error fallback can distinguish it from a user pause.
  private pendingAutoPlayVersion: number = -1;
  private pendingAutoPlayIntentGeneration: number = -1;
  // Speed is intentionally page-scoped rather than persisted. Keep a pending
  // value because the control can be changed before AVPlayer initialization.
  private desiredPlaybackSpeed: number = 1;
  private setLoading(loading: boolean) {
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_LOADING, loading);
  }

  // [Start loadSongAsset]
  private async loadSongAsset(expectedVersion: number): Promise<boolean> {
    const currentSong = this.songList[this.musicIndex];
    if (!currentSong) {
      Logger.error(TAG, `Cannot load song: invalid index ${this.musicIndex}`);
      return false;
    }
    if (!isVersionMatch(expectedVersion)) {
      return false;
    }

    // Protect both the previous active track and this candidate while its
    // cover/source are prepared. AVPlayerController narrows the pin to the
    // new active track once the old source has been reset.
    MediaResourceManager.getInstance().protectSongForTransition(currentSong.bvid);
    await this.songItemBuilder.build(currentSong, expectedVersion);
    if (!isVersionMatch(expectedVersion)) {
      return false;
    }
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return false;
    }

    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_BVID, currentSong.bvid);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_CID, currentSong.cid);

    // Detach the previous image synchronously before awaiting release. This
    // prevents an older song-load continuation from clearing a newer PixelMap.
    const previousPixelMap = this.currentPixelMap;
    this.currentPixelMap = undefined;
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_PIXEL_MAP, undefined);
    if (previousPixelMap) {
      try {
        await previousPixelMap.release();
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `Previous PixelMap release failed: ${message}`);
      }
    }
    if (!isVersionMatch(expectedVersion)) {
      return false;
    }

    this.getPixelMap(currentSong.label, expectedVersion).catch((error: BusinessError) => {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `封面加载失败，忽略: ${message}`);
    });

    if (!currentSong.src) {
      Logger.error(TAG, `Song source is empty: ${currentSong.bvid}`);
      return false;
    }
    return this.avPlayerController.loadSongAsset(currentSong.src, expectedVersion);
  }
  // [End loadSongAsset]

  public static getInstance(): MediaControlCenter {
    if (!MediaControlCenter.mediaControlFunction) {
      MediaControlCenter.mediaControlFunction = new MediaControlCenter();
    }
    return MediaControlCenter.mediaControlFunction;
  }

  private async initAVSession(): Promise<void> {
    this.avSessionController = AVSessionController.getInstance();
    const callbacks: AVSessionCommandCallbacks = {
      play: () => { void this.play(); },
      pause: () => { void this.pause(); },
      playNext: () => { void this.playNext(); },
      playPrevious: () => { void this.playPrevious(); },
      seek: (position: number) => { void this.seek(position); },
      setPlayMode: (mode: MusicPlayMode) => this.setPlayMode(mode)
    };
    this.avSessionController.setCommandCallbacks(callbacks);
    await this.avSessionController.initAVSession();
  }

  private async initAvplayer(): Promise<void> {
    this.avPlayerController = AVPlayerController.getInstance();
    const callbacks: AVPlayerEventCallbacks = {
      onProgress: (time: number) => this.updateProgress(time),
      shouldAutoPlayForLoad: (version: number) => this.shouldAutoPlayForLoad(version),
      onPlay: () => { void this.play(); },
      onPause: () => { void this.pause(); },
      onPlayNext: () => { void this.playNext(); }
    };
    this.avPlayerController.setEventCallbacks(callbacks);
    await this.avPlayerController.initAVPlayer();
  }

  private async initAudioManager(expectedVersion: number): Promise<void> {
    if (!isVersionMatch(expectedVersion)) {
      return;
    }

    const audioManager = audio.getAudioManager();
    const sessionManager = audioManager.getSessionManager();
    this.audioSessionManager = sessionManager;
    await this.activateAudioSession(
      audio.AudioConcurrencyMode.CONCURRENCY_PAUSE_OTHERS,
      expectedVersion
    );
  }

  private enqueueAudioSessionOperation(operation: () => Promise<void>): Promise<void> {
    const operationTask = this.audioSessionOperationPromise.then(operation);
    this.audioSessionOperationPromise = operationTask.then(
      () => undefined,
      () => undefined
    );
    return operationTask;
  }

  private async activateAudioSession(
    concurrencyMode: audio.AudioConcurrencyMode = audio.AudioConcurrencyMode.CONCURRENCY_PAUSE_OTHERS,
    expectedVersion?: number
  ): Promise<void> {
    const manager = this.audioSessionManager;
    if (!manager || (expectedVersion !== undefined && !isVersionMatch(expectedVersion))) {
      return;
    }
    const strategy: audio.AudioSessionStrategy = {
      concurrencyMode: concurrencyMode
    };
    await this.enqueueAudioSessionOperation(async () => {
      if (expectedVersion !== undefined && !isVersionMatch(expectedVersion)) {
        return;
      }
      await manager.activateAudioSession(strategy);
      Logger.info(TAG, 'activateAudioSession succeeded');
    });
  }

  public async init(): Promise<void> {
    if (this.isInitialized) {
      return;
    }
    if (this.initPromise) {
      return this.initPromise;
    }

    this.setLoading(true);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, '');
    const initVersion = incrementVersion();
    const pendingInit = this.doInit(initVersion);
    this.initPromise = pendingInit;
    try {
      await pendingInit;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!isVersionMatch(initVersion)) {
        Logger.warn(TAG, `Ignoring obsolete initialization failure: ${message}`);
        return;
      }
      this.setLoading(false);
      AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, `播放器初始化失败: ${message}`);
      throw error instanceof Error ? error : new Error(message);
    } finally {
      if (this.initPromise === pendingInit) {
        this.initPromise = undefined;
      }
    }
  }

  private async doInit(initVersion: number): Promise<void> {
    this.context = AppStorage.get(APP_STORAGE_KEYS.CONTEXT);
    this.songList = [];
    this.musicIndex = 0;
    AppStorage.setOrCreate(APP_STORAGE_KEYS.SONG_LIST, []);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.SELECT_INDEX, 0);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_FAVORITE, false);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_BVID, '');
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_CID, 0);
    if (!isVersionMatch(initVersion)) {
      return;
    }
    const favoriteSongs = await getFavoriteDetail(
      ContentConstants.FAV_ID,
      undefined,
      () => isVersionMatch(initVersion)
    );
    if (!isVersionMatch(initVersion)) {
      return;
    }
    this.songList = favoriteSongs;
    AppStorage.setOrCreate(APP_STORAGE_KEYS.SONG_LIST, favoriteSongs);
    if (this.songList.length === 0) {
      AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_FAVORITE, false);
      AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, '歌单为空，请检查网络连接后重试');
      this.setLoading(false);
      return;
    }

    this.musicIndex = 0;
    AppStorage.setOrCreate(APP_STORAGE_KEYS.SELECT_INDEX, this.musicIndex);
    // Favorite state belongs to the in-app player, not to the optional lock
    // screen session. Synchronize it even when AVSession creation is unavailable.
    this.avSessionController = AVSessionController.getInstance();
    const firstSong = this.songList[this.musicIndex];
    if (firstSong) {
      this.avSessionController.getAndUpdateFavoriteState(firstSong.bvid);
    }
    MediaResourceManager.getInstance().cleanupOrphanResources(this.songList);

    // AVPlayer is the required playback dependency. Lock-screen session and
    // audio-session activation are optional integrations and must not prevent playback.
    await this.initAvplayer();
    if (!isVersionMatch(initVersion)) {
      return;
    }
    // SpeedControl remains interactive while the favorite list and player are
    // initializing. Apply the latest pre-init selection as soon as AVPlayer exists.
    this.avPlayerController?.setSpeed(this.desiredPlaybackSpeed);

    await Promise.all([
      this.initAVSession().catch((error: BusinessError) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `AVSession initialization skipped: ${message}`);
      }),
      this.initAudioManager(initVersion).catch((error: BusinessError) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `Audio session initialization skipped: ${message}`);
      })
    ]);
    if (!isVersionMatch(initVersion)) {
      return;
    }

    const loaded = await this.loadSongAsset(initVersion);
    if (!isVersionMatch(initVersion)) {
      return;
    }
    if (!loaded) {
      this.setLoading(false);
      return;
    }

    await this.setSilentModeFromPrefer(initVersion);
    if (!isVersionMatch(initVersion)) {
      return;
    }
    this.setVolumeFromPrefer(initVersion);
    if (!isVersionMatch(initVersion)) {
      return;
    }
    this.setPlayModeFromPrefer(initVersion);
    if (!isVersionMatch(initVersion)) {
      return;
    }

    this.setLoading(false);
    this.isInitialized = true;
  }

  public release(): void {
    this.isInitialized = false;
    this.songList = [];
    this.musicIndex = 0;
    this.desiredPlaybackSpeed = 1;
    this.playbackIntentGeneration++;
    this.pendingAutoPlayVersion = -1;
    this.pendingAutoPlayIntentGeneration = -1;
    incrementVersion();
    this.initPromise = undefined;

    if (this.avSessionController) {
      this.avSessionController.setCommandCallbacks(undefined);
      this.avSessionController.unregisterSessionListener().catch((error: BusinessError) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `AVSession release failed: ${message}`);
      });
    }
    if (this.avPlayerController) {
      this.avPlayerController.setEventCallbacks(undefined);
      this.avPlayerController.release().catch((error: BusinessError) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.error(TAG, `AVPlayer release failed: ${message}`);
      });
    }

    const pixelMapToRelease = this.currentPixelMap;
    this.currentPixelMap = undefined;
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_PIXEL_MAP, undefined);
    if (pixelMapToRelease) {
      try {
        pixelMapToRelease.release().catch((error: BusinessError) => {
          const message = error instanceof Error ? error.message : String(error);
          Logger.warn(TAG, `PixelMap release failed: ${message}`);
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `PixelMap release failed: ${message}`);
      }
    }

    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_PLAY, false);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_FAVORITE, false);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.SONG_LIST, []);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.SELECT_INDEX, 0);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_BVID, '');
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_CID, 0);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_LOADING, false);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.PROGRESS, 0);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_TIME, '00:00');
    AppStorage.setOrCreate(APP_STORAGE_KEYS.TOTAL_TIME, '00:00');
    AppStorage.setOrCreate(APP_STORAGE_KEYS.TOTAL_MS_TIME, 0);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.PROGRESS_MAX, 0);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_PIXEL_MAP, undefined);
    const audioSessionManager = this.audioSessionManager;
    this.audioSessionManager = undefined;
    if (audioSessionManager) {
      this.enqueueAudioSessionOperation(async () => {
        if (audioSessionManager.isAudioSessionActivated()) {
          await audioSessionManager.deactivateAudioSession();
          Logger.info(TAG, 'Audio session deactivated');
        }
      }).catch((error: BusinessError) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `Audio session deactivation failed: ${message}`);
      });
    }

    const contextToStop = this.context;
    this.context = undefined;
    this.lastProgressUpdateTime = 0;
    this.lastAVSessionProgressUpdateTime = 0;
    if (contextToStop) {
      BackgroundUtil.stopContinuousTask(contextToStop);
    }
  }

  public async switchToIndex(newIndex: number): Promise<void> {
    if (!Number.isInteger(newIndex) || newIndex < 0 || newIndex >= this.songList.length) {
      Logger.warn(TAG, `Invalid song index: ${newIndex}`);
      return;
    }

    this.setLoading(true);
    const currentVersion = incrementVersion();
    const playbackIntentGeneration = this.playbackIntentGeneration;
    this.pendingAutoPlayVersion = currentVersion;
    this.pendingAutoPlayIntentGeneration = playbackIntentGeneration;
    AppStorage.setOrCreate(APP_STORAGE_KEYS.PROGRESS, 0);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_TIME, '00:00');
    AppStorage.setOrCreate(APP_STORAGE_KEYS.TOTAL_TIME, '00:00');
    AppStorage.setOrCreate(APP_STORAGE_KEYS.TOTAL_MS_TIME, 0);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.PROGRESS_MAX, 0);
    this.updateMusicIndex(newIndex);
    this.avSessionController?.setAVMetadata();

    try {
      // Stop the previous track without treating the internal transition as
      // an explicit user stop. User pause/stop actions still invalidate the
      // captured playback-intent generation below.
      await this.stopCurrentPlayback(playbackIntentGeneration);
      if (!isVersionMatch(currentVersion)) {
        return;
      }

      const loaded = await this.loadSongAsset(currentVersion);
      if (!loaded || !isVersionMatch(currentVersion)) {
        return;
      }
      if (this.playbackIntentGeneration === playbackIntentGeneration) {
        await this.play();
      } else {
        Logger.info(TAG, 'Automatic playback skipped because playback was paused or stopped during loading');
      }
      if (this.pendingAutoPlayVersion === currentVersion) {
        this.pendingAutoPlayVersion = -1;
        this.pendingAutoPlayIntentGeneration = -1;
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!isVersionMatch(currentVersion)) {
        Logger.debug(TAG, `Ignoring obsolete song-switch failure: ${message}`);
        return;
      }
      Logger.error(TAG, `switchToIndex failed: ${message}`);
      AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, `切换歌曲失败: ${message}`);
    } finally {
      // Keep a failed track's pending auto-play intent until its asynchronous
      // AVPlayer fallback handler captures it. A user pause/stop invalidates it
      // through playbackIntentGeneration; a new song replaces its version.
      // An obsolete switch must not clear the loading state of a newer switch.
      if (isVersionMatch(currentVersion)) {
        this.setLoading(false);
      }
    }
  }

  private async createCoverPixelMap(bvid: string): Promise<PixelMap> {
    const mediaMgr = MediaResourceManager.getInstance();
    const imageSource = image.createImageSource(mediaMgr.getCoverPath(bvid));
    if (!imageSource) {
      throw new Error('Failed to create image source');
    }

    try {
      return await imageSource.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
    } finally {
      try {
        await imageSource.release();
      } catch (releaseError) {
        const releaseMessage = releaseError instanceof Error
          ? releaseError.message
          : String(releaseError);
        Logger.warn(TAG, `ImageSource release failed: ${releaseMessage}`);
      }
    }
  }

  private async getPixelMap(url: string, currentVersion: number): Promise<void> {
    if (!isVersionMatch(currentVersion)) return;

    const song = this.songList[this.musicIndex];
    if (!song) {
      return;
    }
    const bvid = song.bvid;
    const mediaMgr = MediaResourceManager.getInstance();
    const hadCachedCover = mediaMgr.hasCover(bvid);

    if (!hadCachedCover) {
      await mediaMgr.downloadCover(bvid, url);
      if (!isVersionMatch(currentVersion)) {
        return;
      }
      Logger.info(TAG, `封面从网络加载并缓存: ${bvid}`);
    }

    try {
      let pixelMap: PixelMap;
      try {
        pixelMap = await this.createCoverPixelMap(bvid);
      } catch (cacheError) {
        const cacheErrorMessage = cacheError instanceof Error ? cacheError.message : String(cacheError);
        if (!hadCachedCover || !isVersionMatch(currentVersion)) {
          throw new Error(cacheErrorMessage);
        }

        Logger.warn(TAG, `Cached cover is unreadable; refreshing ${bvid}: ${cacheErrorMessage}`);
        mediaMgr.removeCover(bvid);
        await mediaMgr.downloadCover(bvid, url);
        if (!isVersionMatch(currentVersion)) {
          return;
        }
        pixelMap = await this.createCoverPixelMap(bvid);
      }

      if (!isVersionMatch(currentVersion)) {
        try {
          await pixelMap.release();
        } catch (releaseError) {
          const message = releaseError instanceof Error
            ? releaseError.message
            : String(releaseError);
          Logger.warn(TAG, `Stale PixelMap release failed: ${message}`);
        }
        return;
      }
      this.currentPixelMap = pixelMap;
      AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_PIXEL_MAP, pixelMap);
      this.avSessionController?.setAVMetadata();
      Logger.info(TAG, `封面从本地加载: ${bvid}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `封面加载失败: ${message}`);
      // An old image task must not delete the active song's cache.
      if (isVersionMatch(currentVersion)) {
        mediaMgr.removeCover(bvid);
      }
    }
  }

  /**
   * Whether the active track switch still owns its default auto-play intent.
   * A newer explicit play/pause/stop action invalidates the captured intent.
   */
  public shouldAutoPlayForLoad(expectedVersion: number): boolean {
    return isVersionMatch(expectedVersion) &&
      this.pendingAutoPlayVersion === expectedVersion &&
      this.pendingAutoPlayIntentGeneration === this.playbackIntentGeneration;
  }

  // [Start StartContinuousTask]
  public async play(): Promise<void> {
    const playbackIntentGeneration = ++this.playbackIntentGeneration;
    Logger.info(TAG, `musicIndex is ${this.musicIndex}`);
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }

    // If URL resolution failed before AVPlayer received a source, a normal
    // play() call cannot recover because there is nothing configured to play.
    // Once loading has ended, retry the current track just as we do after a
    // terminal native-player error.
    const isLoading = AppStorage.get<boolean>(APP_STORAGE_KEYS.IS_LOADING) ?? false;
    const currentVersion = getCurrentVersion();
    const hasCurrentSource = this.avPlayerController.hasActiveSourceForVersion(currentVersion);
    if (!isLoading && (this.avPlayerController.avPlayer?.state === 'error' || !hasCurrentSource)) {
      Logger.info(TAG, 'Retrying current track because its playback source is unavailable');
      await this.switchToIndex(this.musicIndex);
      return;
    }

    try {
      await this.avPlayerController.play();
      // A later pause/stop must prevent this older continuation from starting
      // a background task after playback has already been cancelled.
      if (playbackIntentGeneration !== this.playbackIntentGeneration) {
        return;
      }
      if (AppStorage.get<boolean>(APP_STORAGE_KEYS.IS_PLAY) === true && this.context) {
        BackgroundUtil.startContinuousTask(this.context);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `play failed: ${message}`);
    }
  }

  public async pause(): Promise<void> {
    // Invalidate any pending auto-play continuation before awaiting the native
    // player queue. This also covers lock-screen and audio-interruption pauses.
    const playbackIntentGeneration = ++this.playbackIntentGeneration;
    try {
      await this.avPlayerController?.pause();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `pause failed: ${message}`);
    }
    // A newer play request owns the background-task state now.
    if (playbackIntentGeneration === this.playbackIntentGeneration &&
      AppStorage.get<boolean>(APP_STORAGE_KEYS.IS_PLAY) !== true && this.context) {
      BackgroundUtil.stopContinuousTask(this.context);
    }
  }

  // [End StartContinuousTask]

  // Select a different track without an unbounded retry loop.
  private setRandom(): number {
    const songCount = this.songList.length;
    if (songCount <= 1) {
      return 0;
    }

    const random0To1 = Math.random();
    const currentIndexIsValid = Number.isInteger(this.musicIndex) &&
      this.musicIndex >= 0 && this.musicIndex < songCount;
    if (!currentIndexIsValid) {
      return Math.floor(random0To1 * songCount);
    }

    // Choose an offset in [1, songCount), which excludes the current track.
    const offset = 1 + Math.floor(random0To1 * (songCount - 1));
    const nextIndex = (this.musicIndex + offset) % songCount;
    Logger.debug(TAG, `Shuffle selected index ${nextIndex}`);
    return nextIndex;
  }

  // [Start playNext]
  public async playNext(): Promise<void> {
    if (this.songList.length === 0) {
      Logger.warn(TAG, 'Cannot play next: song list is empty');
      return;
    }
    let nextIndex = this.musicIndex;
    switch (this.playMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        break;
      case MusicPlayMode.ORDER:
        if (this.musicIndex === this.songList.length - 1) {
          nextIndex = 0;
        } else {
          nextIndex += 1;
        }
        break;
      case MusicPlayMode.RANDOM:
        nextIndex = this.setRandom();
        break;
      default:
        break;
    }
    await this.switchToIndex(nextIndex);
  }

  // [End playNext]

  public async playPrevious(): Promise<void> {
    if (this.songList.length === 0) {
      Logger.warn(TAG, 'Cannot play previous: song list is empty');
      return;
    }
    let preIndex = this.musicIndex;
    switch (this.playMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        break;
      case MusicPlayMode.ORDER:
        if (this.musicIndex === 0) {
          preIndex = this.songList.length - 1;
        } else {
          preIndex -= 1;
        }
        break;
      case MusicPlayMode.RANDOM:
        preIndex = this.setRandom();
        break;
      default:
        break;
    }
    await this.switchToIndex(preIndex);
  }

  public async stop(): Promise<void> {
    // An explicit stop is a user playback intent and cancels pending auto-play.
    const playbackIntentGeneration = ++this.playbackIntentGeneration;
    await this.stopCurrentPlayback(playbackIntentGeneration);
  }

  private async stopCurrentPlayback(playbackIntentGeneration?: number): Promise<void> {
    if (!this.avPlayerController) {
      return;
    }
    let stopRequestFailed = false;
    try {
      await this.avPlayerController.stop();
    } catch (error) {
      stopRequestFailed = true;
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `stop failed: ${message}`);
    }
    if (!stopRequestFailed) {
      Logger.info(TAG, 'stop request completed');
    }
    if (playbackIntentGeneration !== undefined &&
      playbackIntentGeneration !== this.playbackIntentGeneration) {
      return;
    }
    if (this.context) {
      BackgroundUtil.stopContinuousTask(this.context);
    }
  }

  // Set play mode
  public setPlayMode(playMode: MusicPlayMode | undefined): void {
    const isSupportedMode = playMode === MusicPlayMode.SINGLE_CYCLE ||
      playMode === MusicPlayMode.ORDER || playMode === MusicPlayMode.RANDOM;
    this.playMode = isSupportedMode ? playMode as MusicPlayMode : MusicPlayMode.ORDER;
    if (playMode !== undefined && !isSupportedMode) {
      Logger.warn(TAG, `Unsupported playback mode ${playMode}; falling back to ordered playback`);
    }
    // Publish the selected mode to the system immediately. Preference writes
    // stay after the AVSession request so they cannot delay dismissal of the
    // system's mode selector.
    AppStorage.setOrCreate(APP_STORAGE_KEYS.PLAY_MODE, this.playMode);
    this.avSessionController?.setPlayModeToAVSession(this.playMode);

    // preferencesPut updates the in-memory value immediately; disk writes are
    // already coalesced by PreferencesUtil, so another timer is unnecessary.
    const preferences = PreferencesUtil.getInstance();
    if (preferences.getValue(PLAY_MODE_ID) !== this.playMode) {
      preferences.preferencesPut(PLAY_MODE_ID, this.playMode);
    }
  }

  public getVolume(): number {
    const volume = PreferencesUtil.getInstance().getValue(VOLUME_ID) as number | undefined;
    if (volume === undefined || !Number.isFinite(volume) || volume <= 0) {
      return DEFAULT_VOLUME;
    }
    return Math.max(0, Math.min(100, volume));
  }

  public setVolume(volume: number): void {
    try {
      // AVPlayerController owns volume validation and normalization.
      this.avPlayerController?.setVolume(volume);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `set volume failed: ${message}`);
    }
  }

  public persistVolume(volume: number): void {
    if (!Number.isFinite(volume) || volume <= 0) {
      return;
    }
    const normalizedVolume = Math.min(100, volume);
    const preferences = PreferencesUtil.getInstance();
    if (preferences.getValue(VOLUME_ID) !== normalizedVolume) {
      preferences.preferencesPut(VOLUME_ID, normalizedVolume);
    }
  }

  public setSpeed(speed: number): void {
    if (!Number.isFinite(speed)) {
      Logger.warn(TAG, `Invalid playback speed: ${speed}`);
      return;
    }

    this.desiredPlaybackSpeed = AVPlayerController.normalizePlaybackSpeed(speed);
    if (this.desiredPlaybackSpeed !== speed) {
      Logger.warn(TAG, `Unsupported playback speed ${speed}; falling back to 1x`);
    }

    // Retain the requested value even when AVPlayer has not been created yet.
    // init() applies it immediately after initAvplayer() completes.
    this.avPlayerController?.setSpeed(this.desiredPlaybackSpeed);
  }

  // Set silent mode
  public async setSilentMode(isSilentMode: boolean = false, expectedVersion?: number): Promise<void> {
    if (expectedVersion !== undefined && !isVersionMatch(expectedVersion)) {
      return;
    }
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_SILENT_MODE, isSilentMode);
    PreferencesUtil.getInstance().preferencesPut(SILENT_ID, isSilentMode);

    // Queue the player mute immediately instead of waiting for audio-session
    // activation. Otherwise a slow session service can leave the player audible
    // after the UI has already switched to silent mode.
    const playerMuteTask = this.avPlayerController?.setSilentMode(isSilentMode) ?? Promise.resolve();

    try {
      const concurrencyMode = isSilentMode
        ? audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
        : audio.AudioConcurrencyMode.CONCURRENCY_PAUSE_OTHERS;
      await this.activateAudioSession(concurrencyMode, expectedVersion);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Audio session mode update skipped: ${message}`);
    }

    if (expectedVersion !== undefined && !isVersionMatch(expectedVersion)) {
      return;
    }

    try {
      await playerMuteTask;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `set silentMode failed: ${message}`);
    }
  }

  private async setSilentModeFromPrefer(expectedVersion: number): Promise<void> {
    const storedValue = PreferencesUtil.getInstance().getValue(SILENT_ID);
    const isSupportSilent = storedValue === true;
    await this.setSilentMode(isSupportSilent, expectedVersion);
  }

  private setVolumeFromPrefer(expectedVersion: number): void {
    if (!isVersionMatch(expectedVersion)) {
      return;
    }
    const storedVolume = PreferencesUtil.getInstance().getValue(VOLUME_ID);
    const volume = typeof storedVolume === 'number' && Number.isFinite(storedVolume) && storedVolume > 0
      ? Math.max(0, Math.min(100, storedVolume))
      : DEFAULT_VOLUME;
    Logger.info(TAG, `setVolumeFromPrefer volume is ${volume}`);
    this.setVolume(volume);
    this.persistVolume(volume);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_VOLUME, volume);
  }

  private setPlayModeFromPrefer(expectedVersion: number): void {
    if (!isVersionMatch(expectedVersion)) {
      return;
    }
    const storedMode = PreferencesUtil.getInstance().getValue(PLAY_MODE_ID);
    const playMode = storedMode === MusicPlayMode.SINGLE_CYCLE ||
      storedMode === MusicPlayMode.ORDER || storedMode === MusicPlayMode.RANDOM
      ? storedMode as MusicPlayMode
      : MusicPlayMode.ORDER;
    this.setPlayMode(playMode);
  }

  public async seek(ms: number): Promise<void> {
    if (!Number.isFinite(ms) || ms < 0) {
      Logger.warn(TAG, `Invalid seek position: ${ms}`);
      return;
    }
    if (AppStorage.get<boolean>(APP_STORAGE_KEYS.IS_LOADING) ?? false) {
      const currentMs = AppStorage.get<number>(APP_STORAGE_KEYS.PROGRESS) ?? 0;
      AppStorage.setOrCreate(
        APP_STORAGE_KEYS.CURRENT_TIME,
        MediaTools.msToCountdownTime(currentMs)
      );
      return;
    }
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }

    const duration = AppStorage.get<number>(APP_STORAGE_KEYS.TOTAL_MS_TIME);
    const targetMs = duration !== undefined && Number.isFinite(duration) && duration > 0
      ? Math.min(ms, duration)
      : ms;

    const expectedVersion = getCurrentVersion();
    const seekSucceeded = await this.avPlayerController.seek(targetMs, expectedVersion);
    if (seekSucceeded && isVersionMatch(expectedVersion)) {
      this.updateProgress(targetMs, true);
      return;
    }
    if (!isVersionMatch(expectedVersion)) {
      return;
    }

    // Restore the displayed time when the player rejected a seek (for example,
    // while the source is still initializing or has already been released).
    const currentMs = AppStorage.get<number>(APP_STORAGE_KEYS.PROGRESS) ?? 0;
    AppStorage.setOrCreate(
      APP_STORAGE_KEYS.CURRENT_TIME,
      MediaTools.msToCountdownTime(currentMs)
    );
  }

  public updateProgress(ms: number, forceUpdate: boolean = false): void {
    if (AppStorage.get<boolean>(APP_STORAGE_KEYS.IS_LOADING) ?? false) {
      return;
    }
    if (!Number.isFinite(ms) || ms < 0) {
      Logger.warn(TAG, `Invalid playback progress: ${ms}`);
      return;
    }

    const duration = AppStorage.get<number>(APP_STORAGE_KEYS.TOTAL_MS_TIME);
    const normalizedMs = duration !== undefined && Number.isFinite(duration) && duration > 0
      ? Math.min(ms, duration)
      : ms;
    const now = Date.now();
    if (!forceUpdate && now - this.lastProgressUpdateTime < 300) {
      return;
    }
    this.lastProgressUpdateTime = now;

    // UI playback progress is independent of the optional lock-screen session.
    // Keep the in-app controls responsive even when AVSession is unavailable.
    AppStorage.setOrCreate(APP_STORAGE_KEYS.PROGRESS, normalizedMs);
    const newTimeStr = MediaTools.msToCountdownTime(normalizedMs);
    const oldTimeStr = AppStorage.get<string>(APP_STORAGE_KEYS.CURRENT_TIME);
    if (newTimeStr !== oldTimeStr) {
      AppStorage.setOrCreate(APP_STORAGE_KEYS.CURRENT_TIME, newTimeStr);
    }

    // The in-app slider/time display keeps its 300ms cadence. AVSession only
    // needs periodic position snapshots; sending one every UI tick needlessly
    // queues system playback-state IPC behind favorite/loop-mode commands.
    if (forceUpdate || now - this.lastAVSessionProgressUpdateTime >= 1000) {
      this.lastAVSessionProgressUpdateTime = now;
      try {
        this.avSessionController?.setProgressState(normalizedMs);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `AVSession progress update skipped: ${message}`);
      }
    }
  }

  private updateMusicIndex(musicIndex: number): void {
    const song = this.songList[musicIndex];
    if (!song) {
      Logger.warn(TAG, `Cannot update music index: ${musicIndex}`);
      return;
    }

    this.musicIndex = musicIndex;
    AppStorage.setOrCreate(APP_STORAGE_KEYS.SELECT_INDEX, musicIndex);
    this.avSessionController?.getAndUpdateFavoriteState(song.bvid);
    Logger.info(TAG, `Current music index updated: ${musicIndex}`);
  }
}
