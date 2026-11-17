/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import Logger from '../Logger';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { MediaTools } from './MediaTools';
import { AVSessionController } from './AVSessionController';
import { AVPlayerEventCallbacks } from './MediaControllerCallbacks';
import SongItemBuilder from '../../../viewmodel/SongItemBuilder';
import { MediaResourceManager } from '../MediaResourceManager';
import { getCurrentVersion, isVersionMatch } from '../VersionUtil';
import { APP_STORAGE_KEYS } from '../../constants/AppStorageKeys';

const TAG = 'AVPlayerController';

export class AVPlayerController {
  public avPlayer?: media.AVPlayer;
  private avSessionController: AVSessionController | undefined = undefined;
  private eventCallbacks: AVPlayerEventCallbacks | undefined = undefined;
  private waitPlay: boolean = false;
  private urlRetryCount: number = 0;
  private static readonly MAX_URL_RETRY: number = 2;
  static avPlayerController: AVPlayerController | undefined;
  private preparedResolve?: () => void;
  private preparedReject?: (error: Error) => void;
  private preparedPromise?: Promise<void>;
  private initPromise?: Promise<void>;
  private initGeneration: number = 0;
  private playerOperationPromise: Promise<void> = Promise.resolve();
  private preparingPlayer?: media.AVPlayer;
  private playRequestGeneration: number = 0;
  private preparedTimeout?: number;
  private activeSourceVersion: number = -1;
  // Separate from the event version: source setup can fail after the version
  // is assigned but before AVPlayer accepts the URL.
  private activeSourceConfigured: boolean = false;
  // Each source transition gets a generation so duplicate/late native error
  // events cannot start parallel CDN recovery for the same failed source.
  private sourceGeneration: number = 0;
  private handledErrorSourceGeneration: number = -1;
  private completedHandledVersion: number = -1;
  private isCurrentLocal: boolean = false;
  private localFile: fileIo.File | null = null;
  private desiredMutedState: boolean | undefined = undefined;
  private desiredVolume: number | undefined = undefined;
  private desiredSpeed: number | undefined = undefined;

  public setEventCallbacks(callbacks: AVPlayerEventCallbacks | undefined): void {
    this.eventCallbacks = callbacks;
  }

  private waitForPrepared(expectedVersion: number = getCurrentVersion()): Promise<void> {
    if (!isVersionMatch(expectedVersion)) {
      return Promise.reject(new Error('Waiting for preparation was cancelled'));
    }
    const player = this.avPlayer;
    if (!player) {
      return Promise.reject(new Error('AVPlayer is unavailable while waiting for preparation'));
    }
    if (this.activeSourceVersion !== expectedVersion) {
      return Promise.reject(new Error('Waiting for preparation of a stale media source'));
    }

    // Read native state directly because stateChange callbacks may arrive late.
    const nativeState = player.state;
    if (nativeState === 'prepared' || nativeState === 'playing' ||
      nativeState === 'paused' || nativeState === 'completed') {
      return Promise.resolve();
    }
    if (nativeState === 'error' || nativeState === 'released') {
      return Promise.reject(new Error(`AVPlayer cannot prepare from state: ${nativeState}`));
    }
    if (!this.preparedPromise) {
      this.preparedPromise = new Promise<void>((resolve, reject) => {
        this.preparedResolve = resolve;
        this.preparedReject = reject;
        this.preparedTimeout = setTimeout(() => {
          if (this.preparedReject) {
            this.preparedReject(new Error('AVPlayer preparation timed out'));
            this.cleanupPreparedPromise();
          }
        }, 20000);
      });
    }

    // Close the check/subscribe race: native state can advance after the first
    // read above but before the waiter is installed. Re-read synchronously now
    // that preparedResolve/preparedReject exist, so a state event delivered in
    // that narrow window cannot be lost and leave the caller waiting 20 seconds.
    const pendingPromise = this.preparedPromise;
    const latestState = player.state;
    if (this.avPlayer !== player || !isVersionMatch(expectedVersion) ||
      this.activeSourceVersion !== expectedVersion) {
      const error = new Error('Waiting for preparation was cancelled by a source change');
      const reject = this.preparedReject;
      this.cleanupPreparedPromise();
      reject?.(error);
      return pendingPromise;
    }
    if (latestState === 'prepared' || latestState === 'playing' ||
      latestState === 'paused' || latestState === 'completed') {
      const resolve = this.preparedResolve;
      this.cleanupPreparedPromise();
      resolve?.();
      return pendingPromise;
    }
    if (latestState === 'error' || latestState === 'released') {
      const error = new Error(`AVPlayer cannot prepare from state: ${latestState}`);
      const reject = this.preparedReject;
      this.cleanupPreparedPromise();
      reject?.(error);
      return pendingPromise;
    }
    return pendingPromise;
  }

  private cleanupPreparedPromise(): void {
    if (this.preparedTimeout !== undefined) {
      clearTimeout(this.preparedTimeout);
      this.preparedTimeout = undefined;
    }
    this.preparedResolve = undefined;
    this.preparedReject = undefined;
    this.preparedPromise = undefined;
  }

  public hasActiveSourceForVersion(expectedVersion: number): boolean {
    return this.avPlayer !== undefined && this.activeSourceVersion === expectedVersion &&
      this.activeSourceConfigured;
  }

  private isLocalSource(url: string): boolean {
    // 本地绝对路径以 '/' 开头
    return url.startsWith('/');
  }

  private closeLocalFile(): void {
    if (!this.localFile) {
      return;
    }
    try {
      fileIo.closeSync(this.localFile);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Failed to close local media file: ${message}`);
    } finally {
      this.localFile = null;
    }
  }

  private enqueuePlayerOperation<T>(operation: () => Promise<T>): Promise<T> {
    const operationTask = this.playerOperationPromise.then(operation);
    this.playerOperationPromise = operationTask.then(
      () => undefined,
      () => undefined
    );
    return operationTask;
  }

  private setPlayerUrl(url: string, expectedVersion: number = getCurrentVersion()): Promise<boolean> {
    // All asynchronous AVPlayer mutations share one queue. This prevents reset,
    // prepare, play, stop, and release from racing each other.
    return this.enqueuePlayerOperation(() => this.applyPlayerUrl(url, expectedVersion));
  }

  private async applyPlayerUrl(url: string, expectedVersion: number): Promise<boolean> {
    if (!isVersionMatch(expectedVersion)) {
      return false;
    }
    const player = this.avPlayer;
    if (!player) {
      throw new Error('AVPlayer has not been initialized');
    }
    if (!url || url.trim().length === 0) {
      throw new Error('Media URL is empty');
    }

    // Reject an outstanding waiter before starting a new source transition.
    if (this.preparedReject) {
      this.preparedReject(new Error('Media source changed before preparation completed'));
      this.cleanupPreparedPromise();
    }
    const isNewSelection = this.activeSourceVersion !== expectedVersion;
    // Invalidate callbacks from the old source before reset() yields. This is
    // necessary even for a same-song source replacement (for example, CDN
    // fallback), where the song version itself has not changed.
    this.sourceGeneration++;
    this.handledErrorSourceGeneration = -1;
    this.activeSourceVersion = -1;
    this.activeSourceConfigured = false;
    if (isNewSelection) {
      this.urlRetryCount = 0;
      this.completedHandledVersion = -1;
    }

    // Reset the player before closing a file descriptor used by the old source.
    await player.reset();
    this.closeLocalFile();
    this.isCurrentLocal = false;

    if (!isVersionMatch(expectedVersion) || this.avPlayer !== player) {
      return false;
    }

    // Keep the selected track out of cache eviction while AVPlayer may still
    // be reading its local file or while the new source is being prepared.
    const activeBvid = AppStorage.get<string>(APP_STORAGE_KEYS.CURRENT_BVID);
    MediaResourceManager.getInstance().setActiveSong(activeBvid);

    // Mark the new source version before assigning it. AVPlayer may emit the
    // initialized/prepared events while setMediaSource is still resolving.
    this.activeSourceVersion = expectedVersion;

    if (this.isLocalSource(url)) {
      const localFile = fileIo.openSync(url, fileIo.OpenMode.READ_ONLY);
      this.localFile = localFile;
      player.url = `fd://${localFile.fd}`;
      this.isCurrentLocal = true;
    } else {
      const headers: Record<string, string> = {
        'Referer': 'https://www.bilibili.com/',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
      };
      const mediaSource: media.MediaSource = media.createMediaSourceWithUrl(url, headers);
      const playStrategy: media.PlaybackStrategy = {
        preferredBufferDuration: 1
      };
      await player.setMediaSource(mediaSource, playStrategy);
    }

    if (!isVersionMatch(expectedVersion) || this.avPlayer !== player) {
      return false;
    }
    this.activeSourceConfigured = true;
    return true;
  }

  // [Start loadSongAsset]
  public async loadSongAsset(src: string, expectedVersion: number = getCurrentVersion()): Promise<boolean> {
    if (!src || src.trim().length === 0) {
      Logger.error(TAG, 'loadSongAsset failed: source URL is empty');
      return false;
    }
    if (!this.avPlayer) {
      Logger.error(TAG, 'loadSongAsset failed: AVPlayer is unavailable');
      return false;
    }

    try {
      let sourceConfigured = false;
      try {
        sourceConfigured = await this.setPlayerUrl(src, expectedVersion);
      } catch (sourceError) {
        const sourceMessage = sourceError instanceof Error ? sourceError.message : String(sourceError);
        if (!this.isLocalSource(src) || !isVersionMatch(expectedVersion)) {
          throw new Error(sourceMessage);
        }

        const bvid = AppStorage.get<string>(APP_STORAGE_KEYS.CURRENT_BVID);
        const cid = AppStorage.get<number>(APP_STORAGE_KEYS.CURRENT_CID);
        if (!bvid || cid === undefined || !Number.isInteger(cid) || cid <= 0) {
          throw new Error(sourceMessage);
        }

        const message = sourceMessage;
        Logger.warn(TAG, `Cached media could not be opened; trying remote source: ${message}`);
        MediaResourceManager.getInstance().removeSongFile(bvid);

        const remoteUrl = await new SongItemBuilder().getBiliPlayUrl(bvid, cid, 0, expectedVersion);
        if (!isVersionMatch(expectedVersion)) {
          return false;
        }
        sourceConfigured = await this.setPlayerUrl(remoteUrl, expectedVersion);
        if (!sourceConfigured) {
          return false;
        }
        MediaResourceManager.getInstance().downloadSong(bvid, remoteUrl);
      }

      if (!sourceConfigured || !isVersionMatch(expectedVersion)) {
        return false;
      }

      await this.waitForPrepared(expectedVersion);
      return isVersionMatch(expectedVersion);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!isVersionMatch(expectedVersion) ||
        message === 'Media source changed before preparation completed' ||
        message.startsWith('Waiting for preparation was cancelled')) {
        Logger.debug(TAG, `Ignoring cancelled media load: ${message}`);
        return false;
      }
      Logger.error(TAG, `loadSongAsset failed: ${message}`);
      AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_LOADING, false);
      AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, `歌曲加载失败: ${message}`);
      return false;
    }
  }
  // [End loadSongAsset]

  public static getInstance(): AVPlayerController {
    if (!AVPlayerController.avPlayerController) {
      AVPlayerController.avPlayerController = new AVPlayerController();
    }
    return AVPlayerController.avPlayerController;
  }

  private static readonly SPEED_MAP: Map<number, media.PlaybackSpeed> = new Map([
    [0.25, media.PlaybackSpeed.SPEED_FORWARD_0_25_X],
    [0.5, media.PlaybackSpeed.SPEED_FORWARD_0_50_X],
    [0.75, media.PlaybackSpeed.SPEED_FORWARD_0_75_X],
    [1, media.PlaybackSpeed.SPEED_FORWARD_1_00_X],
    [1.25, media.PlaybackSpeed.SPEED_FORWARD_1_25_X],
    [1.5, media.PlaybackSpeed.SPEED_FORWARD_1_50_X],
    [1.75, media.PlaybackSpeed.SPEED_FORWARD_1_75_X],
    [2, media.PlaybackSpeed.SPEED_FORWARD_2_00_X],
  ]);

  public static normalizePlaybackSpeed(speed: number): number {
    return Number.isFinite(speed) && AVPlayerController.SPEED_MAP.has(speed) ? speed : 1;
  }

  // [Start initAVPlayer]
  // Initialize the player
  public async initAVPlayer(): Promise<void> {
    if (this.avPlayer) {
      Logger.info(TAG, 'AVPlayer already created');
      return;
    }
    if (this.initPromise) {
      return this.initPromise;
    }

    const generation = this.initGeneration;
    const pendingInit = this.enqueuePlayerOperation(() => this.createAVPlayer(generation));
    this.initPromise = pendingInit;
    try {
      await pendingInit;
    } finally {
      if (this.initPromise === pendingInit) {
        this.initPromise = undefined;
      }
    }
  }

  private async createAVPlayer(generation: number): Promise<void> {
    const player = await media.createAVPlayer();
    if (generation !== this.initGeneration) {
      await player.release();
      return;
    }

    this.avPlayer = player;
    Logger.info(TAG, `createAVPlayer success, curState is ${player.state}`);
    this.setAVPlayerCallbacks();
    Logger.info(TAG, `setAVPlayerCallbacks success, curState is ${player.state}`);
  }
  // [End initAVPlayer]

  private async preparePlayer(player: media.AVPlayer): Promise<void> {
    await this.enqueuePlayerOperation(async () => {
      if (this.avPlayer !== player || this.activeSourceVersion !== getCurrentVersion()) {
        return;
      }
      await this.preparePlayerInCurrentOperation(player);
    });
  }

  /**
   * Prepare the player while already holding the player-operation queue.
   * The per-player guard prevents an `initialized` event emitted by prepare()
   * from scheduling a second prepare operation behind the current one.
   */
  private async preparePlayerInCurrentOperation(player: media.AVPlayer): Promise<void> {
    if (this.avPlayer !== player || this.preparingPlayer === player) {
      return;
    }

    const state = player.state;
    if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
      return;
    }
    if (state !== 'initialized' && state !== 'stopped') {
      Logger.debug(TAG, `prepare skipped in AVPlayer state: ${state}`);
      return;
    }

    this.preparingPlayer = player;
    try {
      await player.prepare();
      if (this.avPlayer === player) {
        Logger.info(TAG, `prepare success, current state is ${player.state}`);
      }
    } finally {
      if (this.preparingPlayer === player) {
        this.preparingPlayer = undefined;
      }
    }
  }

  private enqueuePlayerAction(
    actionName: string,
    action: (player: media.AVPlayer) => void | Promise<void>
  ): Promise<void> {
    const player = this.avPlayer;
    if (!player) {
      Logger.warn(TAG, `${actionName} skipped: AVPlayer is unavailable`);
      return Promise.resolve();
    }

    return this.enqueuePlayerOperation(async () => {
      if (this.avPlayer === player) {
        await action(player);
      }
    }).catch((error: BusinessError) => {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `${actionName} failed: ${message}`);
    });
  }

  private switchSpeed(speed: number): media.PlaybackSpeed {
    const avPlayerSpeed = AVPlayerController.SPEED_MAP.get(speed) ??
      media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    Logger.info(TAG, `avPlayerSpeed is ${avPlayerSpeed}`);
    return avPlayerSpeed;
  }

  // [Start setSpeed]
  public setSpeed(speed: number): void {
    if (!Number.isFinite(speed)) {
      Logger.warn(TAG, `Invalid playback speed: ${speed}`);
      return;
    }

    const normalizedSpeed = AVPlayerController.normalizePlaybackSpeed(speed);
    if (normalizedSpeed !== speed) {
      Logger.warn(TAG, `Unsupported playback speed ${speed}; falling back to 1x`);
    }
    this.desiredSpeed = normalizedSpeed;

    void this.enqueuePlayerAction('setSpeed', (player: media.AVPlayer) => {
      if (!this.canSetPlaybackParameter(player.state)) {
        Logger.debug(TAG, `Defer speed update in state: ${player.state}`);
        return;
      }
      player.setSpeed(this.switchSpeed(normalizedSpeed));
      Logger.info(TAG, `set speed to ${normalizedSpeed}`);
    });
  }
  // [End setSpeed]

  // [Start setVolume]
  public setVolume(volume: number): void {
    if (!Number.isFinite(volume)) {
      Logger.warn(TAG, `Invalid volume value: ${volume}`);
      return;
    }
    const normalizedVolume = Math.max(0, Math.min(100, volume));
    this.desiredVolume = normalizedVolume;

    void this.enqueuePlayerAction('setVolume', (player: media.AVPlayer) => {
      if (!this.canSetPlaybackParameter(player.state)) {
        Logger.debug(TAG, `Defer volume update in state: ${player.state}`);
        return;
      }
      player.setVolume(normalizedVolume / 100);
      Logger.info(TAG, `set volume to ${normalizedVolume}`);
    });
  }
  // [End setVolume]

  // [Start play]
  public async play(): Promise<void> {
    const player = this.avPlayer;
    const expectedVersion = getCurrentVersion();
    const playRequestGeneration = ++this.playRequestGeneration;
    if (!player) {
      Logger.warn(TAG, 'avPlayer is unavailable');
      return;
    }

    await this.enqueuePlayerOperation(async () => {
      if (this.avPlayer !== player || !isVersionMatch(expectedVersion) ||
        playRequestGeneration !== this.playRequestGeneration) {
        return;
      }
      if (this.activeSourceVersion !== expectedVersion) {
        // Preserve an intentional play request made while the current source
        // is still being configured; discard it automatically on a new version.
        this.waitPlay = true;
        return;
      }
      if (player.state === 'playing') {
        this.waitPlay = false;
        Logger.info(TAG, 'AVPlayer is already playing');
        return;
      }
      let playerState = player.state;
      if (playerState === 'stopped') {
        // AVPlayer must be prepared again after stop(); play() is not a valid
        // state transition from stopped. Preserve the requested play intent
        // while prepare() is pending so an error can trigger the right recovery.
        this.waitPlay = true;
        await this.preparePlayerInCurrentOperation(player);
        if (this.avPlayer !== player || !isVersionMatch(expectedVersion) ||
          playRequestGeneration !== this.playRequestGeneration) {
          return;
        }
        playerState = player.state;
      }
      if (playerState !== 'prepared' && playerState !== 'paused' &&
        playerState !== 'completed') {
        this.waitPlay = true;
        Logger.info(TAG, `AVPlayer is not prepared for playback: ${playerState}`);
        return;
      }
      // Apply the latest user-selected audio settings before playback starts.
      // Volume and speed controls remain interactive while loading, but their
      // native AVPlayer setters are only legal in prepared/playing/paused/completed.
      await this.applyDesiredSettingsInCurrentOperation(player);
      if (this.avPlayer !== player || !isVersionMatch(expectedVersion) ||
        playRequestGeneration !== this.playRequestGeneration) {
        return;
      }

      // Record the play intent before awaiting the native promise so an error
      // event raised during play() can still recover with the right intent.
      this.waitPlay = true;
      // Keep the intent pending when the native promise rejects: AVPlayer may
      // deliver its error event asynchronously, and the fallback handler needs
      // this intent to decide whether playback should resume.
      await player.play();
      if (this.avPlayer !== player || !isVersionMatch(expectedVersion) ||
        playRequestGeneration !== this.playRequestGeneration) {
        return;
      }
      this.waitPlay = false;
      Logger.info(TAG, 'play success');
      this.updateIsPlay(true);
      Logger.info(TAG, `current state is ${player.state}`);
    });
  }
  // [End play]

  // [Start pause]
  public async pause(): Promise<void> {
    // Cancel queued or deferred play intents immediately, including a play
    // request that is waiting for the current source to become prepared.
    this.playRequestGeneration++;
    this.waitPlay = false;
    const player = this.avPlayer;
    if (!player) {
      Logger.warn(TAG, 'pause skipped: AVPlayer is unavailable');
      return;
    }
    await this.enqueuePlayerOperation(async () => {
      if (this.avPlayer !== player) {
        return;
      }
      const playerState = player.state;
      if (playerState !== 'playing') {
        // pause() is only valid while playing; keep this operation idempotent.
        this.updateIsPlay(false);
        return;
      }
      await player.pause();
      if (this.avPlayer === player) {
        this.updateIsPlay(false);
      }
    });
  }
  // [End pause]

  // [Start seek]
  public async seek(ms: number, expectedVersion: number = getCurrentVersion()): Promise<boolean> {
    if (!Number.isFinite(ms) || ms < 0) {
      Logger.warn(TAG, `Invalid seek position: ${ms}`);
      return false;
    }

    const player = this.avPlayer;
    if (!player) {
      Logger.warn(TAG, 'seek skipped: AVPlayer is unavailable');
      return false;
    }

    try {
      return await this.enqueuePlayerOperation(async () => {
        if (this.avPlayer !== player || !isVersionMatch(expectedVersion) ||
          this.activeSourceVersion !== expectedVersion) {
          return false;
        }

        const state = player.state;
        const canSeek = state === 'prepared' || state === 'playing' ||
          state === 'paused' || state === 'completed';
        if (!canSeek) {
          Logger.debug(TAG, `seek skipped in AVPlayer state: ${state}`);
          return false;
        }

        const duration = player.duration;
        const targetMs = Number.isFinite(duration) && duration > 0
          ? Math.min(ms, duration)
          : ms;
        await player.seek(targetMs);
        return this.avPlayer === player && isVersionMatch(expectedVersion) &&
          this.activeSourceVersion === expectedVersion;
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `seek failed: ${message}`);
      return false;
    }
  }
  // [End seek]

  // [Start stop]
  public async stop(): Promise<void> {
    // Stop is an explicit playback intent and must invalidate any deferred play.
    this.playRequestGeneration++;
    this.waitPlay = false;
    const player = this.avPlayer;
    if (!player) {
      Logger.warn(TAG, 'AVPlayer is unavailable; stop skipped');
      return;
    }

    await this.enqueuePlayerOperation(async () => {
      if (this.avPlayer !== player) {
        return;
      }
      const playerState = player.state;
      const canStop = playerState === 'prepared' || playerState === 'playing' ||
        playerState === 'paused' || playerState === 'completed';
      if (!canStop) {
        this.updateIsPlay(false);
        Logger.debug(TAG, `AVPlayer stop skipped in state: ${playerState}`);
        return;
      }
      await player.stop();
      if (this.avPlayer === player) {
        this.updateIsPlay(false);
        Logger.info(TAG, 'AVPlayer stopped successfully');
      }
    });
  }
  // [End stop]

  private canSetPlaybackParameter(state: media.AVPlayerState): boolean {
    return state === 'prepared' || state === 'playing' ||
      state === 'paused' || state === 'completed';
  }

  /**
   * Apply the most recent volume, speed and mute preferences while the caller
   * already owns the AVPlayer operation queue.
   */
  private async applyDesiredSettingsInCurrentOperation(player: media.AVPlayer): Promise<void> {
    if (this.avPlayer !== player || !this.canSetPlaybackParameter(player.state)) {
      return;
    }

    const speed = this.desiredSpeed;
    if (speed !== undefined) {
      try {
        player.setSpeed(this.switchSpeed(speed));
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `Failed to apply playback speed ${speed}: ${message}`);
      }
    }

    const volume = this.desiredVolume;
    if (volume !== undefined) {
      try {
        player.setVolume(volume / 100);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `Failed to apply media volume ${volume}: ${message}`);
      }
    }

    const muted = this.desiredMutedState;
    if (muted !== undefined) {
      try {
        await player.setMediaMuted(media.MediaType.MEDIA_TYPE_AUD, muted);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.warn(TAG, `Failed to apply media mute state ${muted}: ${message}`);
      }
    }
  }

  private applyDesiredPlayerSettings(player: media.AVPlayer): void {
    void this.enqueuePlayerOperation(async () => {
      await this.applyDesiredSettingsInCurrentOperation(player);
    }).catch((error: BusinessError) => {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Failed to apply pending player settings: ${message}`);
    });
  }

  // [Start setSilentMode]
  public setSilentMode(isSilentMode: boolean): Promise<void> {
    // Keep the requested state even when the player is not ready yet. The
    // prepared callback reapplies it after every source reset/switch.
    this.desiredMutedState = isSilentMode;
    return this.enqueuePlayerAction('setSilentMode', async (player: media.AVPlayer) => {
      if (!this.canSetPlaybackParameter(player.state)) {
        Logger.debug(TAG, `Defer media mute update in state: ${player.state}`);
        return;
      }
      await player.setMediaMuted(media.MediaType.MEDIA_TYPE_AUD, isSilentMode);
      Logger.info(TAG, `set media muted to ${isSilentMode}`);
    });
  }
  // [End setSilentMode]

  private safelyRemovePlayerListener(
    eventName: string,
    removeListener: () => void
  ): void {
    try {
      removeListener();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Failed to detach AVPlayer ${eventName} listener: ${message}`);
    }
  }

  private safelyRunReleaseCleanup(actionName: string, cleanup: () => void): void {
    try {
      cleanup();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `AVPlayer release cleanup failed (${actionName}): ${message}`);
    }
  }

  // [Start release]
  public release(): Promise<void> {
    this.initGeneration++;
    this.initPromise = undefined;

    if (this.preparedReject) {
      this.preparedReject(new Error('Player released'));
      this.cleanupPreparedPromise();
    }

    const player = this.avPlayer;
    this.avPlayer = undefined;
    this.waitPlay = false;
    this.playRequestGeneration++;
    this.isCurrentLocal = false;
    this.preparingPlayer = undefined;
    // Speed is a page-level control value (not persisted in PreferencesUtil).
    // A new player starts at 1x and the SpeedControl component also resets to
    // 1x when the page is recreated, so do not carry a stale in-memory value
    // across player releases. Volume remains managed by persisted preferences.
    this.desiredSpeed = undefined;
    this.activeSourceVersion = -1;
    this.activeSourceConfigured = false;
    this.sourceGeneration++;
    this.handledErrorSourceGeneration = -1;
    this.completedHandledVersion = -1;

    if (player) {
      // Stop receiving callbacks immediately. Detach each listener separately:
      // a single native off() failure must never prevent player.release() and
      // file-descriptor cleanup from running.
      this.safelyRemovePlayerListener('error', () => player.off('error'));
      this.safelyRemovePlayerListener('stateChange', () => player.off('stateChange'));
      this.safelyRemovePlayerListener('durationUpdate', () => player.off('durationUpdate'));
      this.safelyRemovePlayerListener('timeUpdate', () => player.off('timeUpdate'));
      this.safelyRemovePlayerListener('audioInterrupt', () => player.off('audioInterrupt'));
      this.safelyRemovePlayerListener('volumeChange', () => player.off('volumeChange'));
      this.safelyRemovePlayerListener(
        'audioOutputDeviceChangeWithInfo',
        () => player.off('audioOutputDeviceChangeWithInfo')
      );
    }

    const releaseTask = this.playerOperationPromise.then(async () => {
      try {
        if (player) {
          await player.release();
          Logger.info(TAG, 'AVPlayer released');
        } else {
          Logger.info(TAG, 'AVPlayer release skipped: player is unavailable');
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        Logger.error(TAG, `AVPlayer release failed: ${message}`);
      } finally {
        // Keep the file descriptor and cache pin alive until AVPlayer has
        // finished releasing the source that may still be reading from it.
        // Run each cleanup independently: a cache bookkeeping failure must
        // never prevent the local descriptor from being closed (or vice versa).
        this.safelyRunReleaseCleanup('local file', () => this.closeLocalFile());
        this.safelyRunReleaseCleanup('active cache pin', () => {
          MediaResourceManager.getInstance().setActiveSong(undefined);
        });
        this.safelyRunReleaseCleanup('cache eviction', () => {
          MediaResourceManager.getInstance().cleanupCacheByLimit();
        });
      }
    });
    this.playerOperationPromise = releaseTask.then(() => undefined, () => undefined);
    return releaseTask;
  }
  // [End release]

  // [Start setAVPlayerCallbacks]
  // Set callbacks
  private setAVPlayerCallbacks() {
    this.setAvSessionCallback();
    this.errorCallback();
    this.stateChangeCallback();
    this.audioInterruptCallback();
    this.durationUpdateCallback();
    this.timeUpdateCallback();
    this.outputDeviceChange();
    this.volumeChangeCallback();
  }
  // [End setAVPlayerCallbacks]

  // Update duration
  private durationUpdateCallback(): void {
    const player = this.avPlayer;
    const generation = this.initGeneration;
    if (!player) {
      Logger.warn(TAG, 'durationUpdate callback skipped: AVPlayer is unavailable');
      return;
    }
    player.on('durationUpdate', (duration: number) => {
      if (this.avPlayer === player && generation === this.initGeneration &&
        this.activeSourceVersion === getCurrentVersion()) {
        Logger.info(TAG, `duration updated: ${duration}`);
      }
    });
  }

  private timeUpdateCallback(): void {
    const player = this.avPlayer;
    const generation = this.initGeneration;
    if (!player) {
      return;
    }
    player.on('timeUpdate', (time: number) => {
      if (this.avPlayer === player && generation === this.initGeneration &&
        this.activeSourceVersion === getCurrentVersion()) {
        this.eventCallbacks?.onProgress(time);
      }
    });
  }

  private setAudioRendererInfo(player: media.AVPlayer): void {
    if (this.avPlayer !== player) {
      return;
    }
    player.audioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0,
      volumeMode: audio.AudioVolumeMode.SYSTEM_GLOBAL
    }
  }

  private setAvSessionCallback() {
    this.avSessionController = AVSessionController.getInstance();
  }

  // [Start errorCallback]
  private errorCallback(): void {
    const player = this.avPlayer;
    const generation = this.initGeneration;
    if (!player) {
      return;
    }
    player.on('error', async (error: BusinessError) => {
      if (this.avPlayer !== player || generation !== this.initGeneration) {
        return;
      }
      // Ignore a late error event from the previous source if the player has
      // already moved into a valid state for the newly selected source.
      if (player.state !== 'error') {
        Logger.debug(TAG, `Ignoring stale AVPlayer error event in state ${player.state}`);
        return;
      }
      Logger.error(TAG, `AVPlayer error: code ${error.code}, message ${error.message}`);
      const currentVersion = getCurrentVersion();
      if (this.activeSourceVersion !== currentVersion) {
        Logger.debug(TAG, 'Ignoring stale AVPlayer error from a previous song selection');
        return;
      }
      const failedSourceGeneration = this.sourceGeneration;
      if (this.handledErrorSourceGeneration === failedSourceGeneration) {
        Logger.debug(TAG, `Ignoring duplicate AVPlayer error for source generation ${failedSourceGeneration}`);
        return;
      }
      this.handledErrorSourceGeneration = failedSourceGeneration;

      const bvid = AppStorage.get<string>(APP_STORAGE_KEYS.CURRENT_BVID);
      const cid = AppStorage.get<number>(APP_STORAGE_KEYS.CURRENT_CID);
      // Preserve the user's playback intent while the fallback URL is fetched.
      // pause()/play() update this generation synchronously, even when their
      // native operations are still waiting in the player queue.
      const playbackIntentGeneration = this.playRequestGeneration;
      const shouldResumePlayback = this.waitPlay ||
        AppStorage.get<boolean>(APP_STORAGE_KEYS.IS_PLAY) === true ||
        // Loading alone does not imply auto-play: the user may have paused
        // while this track was loading. Consult the captured switch intent.
        this.eventCallbacks?.shouldAutoPlayForLoad(currentVersion) === true;
      const failedLocalSource = this.isCurrentLocal;
      // A failed local cache is not a failed CDN attempt. Start its recovery
      // from the primary URL; subsequent remote failures consume retry slots.
      const retryCount = failedLocalSource ? 0 : this.urlRetryCount + 1;
      this.urlRetryCount = retryCount;
      if (failedLocalSource && bvid) {
        // A corrupt audio cache should not evict the valid cover image.
        MediaResourceManager.getInstance().removeSongFile(bvid);
        this.isCurrentLocal = false;
      }

      if (bvid && cid !== undefined && retryCount <= AVPlayerController.MAX_URL_RETRY) {
        // Surface an in-progress automatic source recovery to the UI and avoid
        // treating the temporary native `error` state as a terminal failure.
        // A play tap during this period updates waitPlay; the recovery then
        // resumes according to the latest user intent.
        AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_LOADING, true);
        try {
          const songItemBuilder = new SongItemBuilder();
          // Retry 1 selects the first backup URL; retry 2 selects the next one.
          // The builder refreshes the signed URL on every attempt.
          const candidateIndex = failedLocalSource ? 0 : retryCount;
          const url = await songItemBuilder.getBiliPlayUrl(bvid, cid, candidateIndex, currentVersion);
          if (!isVersionMatch(currentVersion) || this.avPlayer !== player ||
            generation !== this.initGeneration || this.sourceGeneration !== failedSourceGeneration) {
            return;
          }

          this.waitPlay = this.playRequestGeneration === playbackIntentGeneration
            ? shouldResumePlayback
            : this.waitPlay;
          const sourceConfigured = await this.setPlayerUrl(url, currentVersion);
          if (!sourceConfigured || !isVersionMatch(currentVersion) || this.avPlayer !== player ||
            generation !== this.initGeneration) {
            return;
          }

          // A retry is successful only after the replacement source is prepared.
          await this.waitForPrepared(currentVersion);
          if (isVersionMatch(currentVersion) && this.avPlayer === player &&
            generation === this.initGeneration && retryCount === this.urlRetryCount) {
            AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, '');
            AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_LOADING, false);
          }
        } catch (retryError) {
          const message = retryError instanceof Error ? retryError.message : String(retryError);
          Logger.error(TAG, `URL retry failed: ${message}`);
          if (isVersionMatch(currentVersion) && this.avPlayer === player &&
            generation === this.initGeneration && retryCount === this.urlRetryCount) {
            // Do not overwrite a newer explicit play/pause request that arrived
            // while the fallback URL or replacement source was being prepared.
            if (this.playRequestGeneration === playbackIntentGeneration) {
              this.waitPlay = false;
            }
            AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, '播放失败，请检查网络后重试');
            AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_LOADING, false);
          }
        }
      } else {
        if (this.playRequestGeneration === playbackIntentGeneration) {
          this.waitPlay = false;
        }
        AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, '播放失败，请检查网络后重试');
        AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_LOADING, false);
      }
    });
  }
  // [End errorCallback]

  // [Start stateChangeCallback]
  // Watch state
  private stateChangeCallback(): void {
    const player = this.avPlayer;
    const generation = this.initGeneration;
    if (!player) {
      Logger.error(TAG, 'stateChangeCallback skipped: AVPlayer is unavailable');
      return;
    }
    player.on('stateChange', async (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      if (this.avPlayer !== player || generation !== this.initGeneration ||
        this.activeSourceVersion !== getCurrentVersion()) {
        return;
      }
      switch (state) {
        case 'idle':
          Logger.info(TAG, `state idle called , reason is ${reason}`);
          break;
        case 'initialized':
          Logger.info(TAG, `state initialized called , reason is ${reason}`);
          this.setAudioRendererInfo(player);
          // If prepare() itself emitted this event, its current queue operation
          // already owns preparation; do not enqueue a duplicate prepare.
          if (this.preparingPlayer === player) {
            break;
          }
          try {
            await this.preparePlayer(player);
          } catch (error) {
            if (this.avPlayer !== player || generation !== this.initGeneration) {
              return;
            }
            const message = error instanceof Error ? error.message : String(error);
            Logger.error(TAG, `AVPlayer prepare failed: ${message}`);
            if (this.preparedReject) {
              this.preparedReject(new Error(message));
              this.cleanupPreparedPromise();
            }
          }
          break;
        case 'prepared':
          // State events are asynchronous. If a previous source's prepared
          // event arrives after reset(), do not resolve the new source waiter
          // unless the native player has in fact reached a playable state.
          if (player.state !== 'prepared' && player.state !== 'playing' &&
            player.state !== 'paused' && player.state !== 'completed') {
            Logger.debug(TAG, `Ignoring stale prepared event in state ${player.state}`);
            break;
          }
          Logger.info(TAG, `state prepared called , reason is ${reason}`);
          const duration = player.duration ?? 0;
          AppStorage.setOrCreate(APP_STORAGE_KEYS.TOTAL_TIME, MediaTools.msToCountdownTime(duration));
          AppStorage.setOrCreate(APP_STORAGE_KEYS.TOTAL_MS_TIME, duration);
          AppStorage.setOrCreate(APP_STORAGE_KEYS.PROGRESS_MAX, duration);
          this.avSessionController?.setAVMetadata();
          this.applyDesiredPlayerSettings(player);
          if (this.waitPlay) {
            this.eventCallbacks?.onPlay();
          }
          if (this.preparedResolve) {
            this.preparedResolve();
            this.cleanupPreparedPromise();
          }
          break;
        // [StartExclude stateChangeCallback]
        case 'playing':
          Logger.info(TAG, `state playing called , reason is ${reason}`);
          this.urlRetryCount = 0;
          break;
        case 'paused':
          Logger.info(TAG, `state paused called , reason is ${reason}`);
          break;
        case 'completed':
          if (player.state === 'completed' &&
            this.completedHandledVersion !== this.activeSourceVersion) {
            this.completedHandledVersion = this.activeSourceVersion;
            this.eventCallbacks?.onPlayNext();
          } else {
            Logger.debug(TAG, `Ignoring duplicate or stale completed event in state ${player.state}`);
          }
          break;
        case 'stopped':
          Logger.info(TAG, `state stopped called , reason is ${reason}`);
          break;
        case 'released':
          Logger.info(TAG, `state released called , reason is ${reason}`);
          break;
        case 'error':
          Logger.info(TAG, `state error called , reason is ${reason}`);
          if (this.preparedReject) {
            this.preparedReject(new Error(`AVPlayer entered error state, reason: ${reason}`));
            this.cleanupPreparedPromise();
          }
          break;
        default:
          Logger.info(TAG, `state unknown called , reason is ${reason}`);
          break;
        // [EndExclude stateChangeCallback]
      }
    });
    Logger.info(TAG, `set stateChangeCallback success`);
  }
  // [End stateChangeCallback]

  private audioInterruptCallback(): void {
    const player = this.avPlayer;
    const generation = this.initGeneration;
    if (!player) {
      return;
    }
    player.on('audioInterrupt', (interruptEvent: audio.InterruptEvent) => {
      if (this.avPlayer !== player || generation !== this.initGeneration) {
        return;
      }
      if (interruptEvent.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
        switch (interruptEvent.hintType) {
          case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
            this.eventCallbacks?.onPause();
            break;
          case audio.InterruptHint.INTERRUPT_HINT_STOP:
            this.eventCallbacks?.onPause();
            break;
          case audio.InterruptHint.INTERRUPT_HINT_DUCK:
            break;
          case audio.InterruptHint.INTERRUPT_HINT_UNDUCK:
            break;
          default:
            break;
        }
      } else if (interruptEvent.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
        switch (interruptEvent.hintType) {
          case audio.InterruptHint.INTERRUPT_HINT_RESUME:
            this.eventCallbacks?.onPlay();
            break;
          default:
            break;
        }
      }
    });
  }

  private volumeChangeCallback(): void {
    const player = this.avPlayer;
    const generation = this.initGeneration;
    if (!player) {
      return;
    }
    player.on('volumeChange', (volume: number) => {
      if (this.avPlayer === player && generation === this.initGeneration) {
        Logger.info(TAG, `current volume is ${volume}`);
      }
    });
  }

  private outputDeviceChange(): void {
    const player = this.avPlayer;
    const generation = this.initGeneration;
    if (!player) {
      return;
    }
    player.on('audioOutputDeviceChangeWithInfo', (deviceChangeInfo: audio.AudioStreamDeviceChangeInfo) => {
      if (this.avPlayer !== player || generation !== this.initGeneration || !deviceChangeInfo) {
        return;
      }
      const devices = deviceChangeInfo.devices;
      const currentDevice = Array.isArray(devices) && devices.length > 0 ? devices[0] : undefined;
      if (currentDevice) {
        // Device identifiers and addresses are intentionally omitted from logs.
        Logger.info(TAG, 'Audio output device information changed');
      }
      const changeReason = deviceChangeInfo.changeReason;
      Logger.info(TAG, `Device change reason: ${changeReason}`);
      if (changeReason === audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {
        this.eventCallbacks?.onPause();
      }
    });
  }

  // Update play state
  private updateIsPlay(isPlay: boolean) {
    AppStorage.setOrCreate<boolean>(APP_STORAGE_KEYS.IS_PLAY, isPlay);
    if (!this.avSessionController) {
      return;
    }
    const currentMs = AppStorage.get<number>(APP_STORAGE_KEYS.PROGRESS) ?? 0;
    this.avSessionController.setPlayState(isPlay, currentMs);
  }
}
