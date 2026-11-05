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
import { MediaControlCenter } from './MediaControlCenter';
import SongItemBuilder from '../../../viewmodel/SongItemBuilder';
import { MediaResourceManager } from '../MediaResourceManager';
import { getCurrentVersion, isVersionMatch } from '../VersionUtil';
import { APP_STORAGE_KEYS } from '../../constants/AppStorageKeys';

const TAG = 'AVPlayerController';

export class AVPlayerController {
  public avPlayer?: media.AVPlayer;
  private avSessionController: AVSessionController | undefined = undefined;
  private currentState: media.AVPlayerState = 'idle';
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
  private completedHandledVersion: number = -1;
  private isCurrentLocal: boolean = false;
  private localFile: fileIo.File | null = null;
  private desiredMutedState: boolean | undefined = undefined;
  private desiredVolume: number | undefined = undefined;
  private desiredSpeed: number | undefined = undefined;

  public waitForPrepared(expectedVersion: number = getCurrentVersion()): Promise<void> {
    if (!isVersionMatch(expectedVersion)) {
      return Promise.reject(new Error('Waiting for preparation was cancelled'));
    }
    if (this.currentState === 'prepared') {
      return Promise.resolve();
    }
    if (this.currentState === 'error' || this.currentState === 'released') {
      return Promise.reject(new Error(`AVPlayer cannot prepare from state: ${this.currentState}`));
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
    return this.preparedPromise;
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

  public setPlayerUrl(url: string, expectedVersion: number = getCurrentVersion()): Promise<boolean> {
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
    if (isNewSelection) {
      this.urlRetryCount = 0;
      this.completedHandledVersion = -1;
    }

    // Reset the player before closing a file descriptor used by the old source.
    await player.reset();
    this.currentState = player.state;
    this.closeLocalFile();
    this.isCurrentLocal = false;

    if (!isVersionMatch(expectedVersion) || this.avPlayer !== player) {
      return false;
    }

    // Mark the new source version before assigning it. AVPlayer may emit the
    // initialized/prepared events while setMediaSource is still resolving.
    this.activeSourceVersion = expectedVersion;

    if (this.isLocalSource(url)) {
      const localFile = fileIo.openSync(url, fileIo.OpenMode.READ_ONLY);
      this.localFile = localFile;
      const fileDescriptor: media.AVFileDescriptor = {
        fd: localFile.fd,
        offset: 0,
        length: 0
      };
      player.fdSrc = fileDescriptor;
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
        // A cached file can disappear or become unreadable between hasSong()
        // and openSync(). That failure occurs before AVPlayer emits an error
        // event, so the normal error callback cannot recover it.
        if (!this.isLocalSource(src) || !isVersionMatch(expectedVersion)) {
          throw new Error(sourceError.message);
        }

        const bvid = AppStorage.get<string>(APP_STORAGE_KEYS.CURRENT_BVID);
        const cid = AppStorage.get<number>(APP_STORAGE_KEYS.CURRENT_CID);
        if (!bvid || cid === undefined || !Number.isInteger(cid) || cid <= 0) {
          throw new Error(sourceError.message);
        }

        const message = sourceError instanceof Error ? sourceError.message : String(sourceError);
        Logger.warn(TAG, `Cached media could not be opened; trying remote source: ${message}`);
        MediaResourceManager.getInstance().removeSongFile(bvid);

        const remoteUrl = await new SongItemBuilder().getBiliPlayUrl(bvid, cid);
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
      Logger.error(TAG, `loadSongAsset failed: ${message}`);
      if (isVersionMatch(expectedVersion)) {
        AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_LOADING, false);
        AppStorage.setOrCreate(APP_STORAGE_KEYS.ERROR_MESSAGE, `歌曲加载失败: ${message}`);
      }
      return false;
    }
  }
  // [End loadSongAsset]

  public static getInstance(): AVPlayerController {
    if (!AVPlayerController.avPlayerController) {
      Logger.info(TAG, 'no AVPlayerController')
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
    this.currentState = player.state;
    Logger.info(TAG, `createAVPlayer success, curState is ${player.state}`);
    this.setAVPlayerCallbacks();
    Logger.info(TAG, `setAVPlayerCallbacks success, curState is ${player.state}`);
  }
  // [End initAVPlayer]

  // [Start prepare]
  // Prepare the player
  public async prepare(): Promise<void> {
    const player = this.avPlayer;
    if (!player) {
      Logger.warn(TAG, 'avPlayer is unavailable');
      return;
    }
    await this.preparePlayer(player);
  }

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
      this.currentState = state;
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
        this.currentState = player.state;
        Logger.info(TAG, `prepare success, current state is ${player.state}`);
      }
    } finally {
      if (this.preparingPlayer === player) {
        this.preparingPlayer = undefined;
      }
    }
  }
  // [End prepare]

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
    let avPlayerSpeed: media.PlaybackSpeed | undefined;
    avPlayerSpeed = AVPlayerController.SPEED_MAP.get(speed);
    if (!avPlayerSpeed) {
      avPlayerSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    Logger.info(TAG, `avPlayerSpeed is ${avPlayerSpeed}`)
    return avPlayerSpeed
  }

  // [Start setSpeed]
  public setSpeed(speed: number): void {
    if (!Number.isFinite(speed)) {
      Logger.warn(TAG, `Invalid playback speed: ${speed}`);
      return;
    }

    const normalizedSpeed = AVPlayerController.SPEED_MAP.has(speed) ? speed : 1;
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
        this.currentState = 'playing';
        this.waitPlay = false;
        Logger.info(TAG, 'AVPlayer is already playing');
        return;
      }
      let playerState = player.state;
      this.currentState = playerState;
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
        this.currentState = playerState;
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
      this.currentState = playerState;
      if (playerState !== 'playing') {
        // pause() is only valid while playing; keep this operation idempotent.
        this.updateIsPlay(false);
        return;
      }
      await player.pause();
      if (this.avPlayer === player) {
        this.currentState = 'paused';
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
      this.currentState = playerState;
      const canStop = playerState === 'prepared' || playerState === 'playing' ||
        playerState === 'paused' || playerState === 'completed';
      if (!canStop) {
        this.updateIsPlay(false);
        Logger.debug(TAG, `AVPlayer stop skipped in state: ${playerState}`);
        return;
      }
      await player.stop();
      if (this.avPlayer === player) {
        this.currentState = 'stopped';
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
    this.currentState = 'released';
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
    this.completedHandledVersion = -1;

    if (player) {
      // Stop receiving callbacks immediately. The pending source transition is
      // still allowed to settle before the native player is actually released.
      player.off('error');
      player.off('stateChange');
      player.off('durationUpdate');
      player.off('timeUpdate');
      player.off('audioInterrupt');
      player.off('volumeChange');
      player.off('audioOutputDeviceChangeWithInfo');
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
        // Keep the file descriptor alive until AVPlayer has finished releasing
        // the source that may still be reading from it.
        this.closeLocalFile();
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
        MediaControlCenter.getInstance().updateProgress(time);
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
        MediaControlCenter.getInstance().shouldAutoPlayForLoad(currentVersion);
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
        try {
          const songItemBuilder = new SongItemBuilder();
          // Retry 1 selects the first backup URL; retry 2 selects the next one.
          // The builder refreshes the signed URL on every attempt.
          const candidateIndex = failedLocalSource ? 0 : retryCount;
          const url = await songItemBuilder.getBiliPlayUrl(bvid, cid, candidateIndex);
          if (!isVersionMatch(currentVersion) || this.avPlayer !== player ||
            generation !== this.initGeneration) {
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
      this.currentState = state;
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
            MediaControlCenter.getInstance().play();
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
          // A completed event from an old source can arrive after reset(). Do
          // not advance the new song unless the native player is still completed.
          if (player.state === 'completed' &&
            this.completedHandledVersion !== this.activeSourceVersion) {
            // A completion notification may be delivered more than once. Handle
            // it once per source version so one track cannot skip two songs.
            this.completedHandledVersion = this.activeSourceVersion;
            void MediaControlCenter.getInstance().playNext();
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
            MediaControlCenter.getInstance().pause();
            break;
          case audio.InterruptHint.INTERRUPT_HINT_STOP:
            MediaControlCenter.getInstance().pause();
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
            MediaControlCenter.getInstance().play();
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
      if (this.avPlayer !== player || generation !== this.initGeneration) {
        return;
      }
      const currentDevice = deviceChangeInfo.devices[0];
      if (currentDevice) {
        Logger.info(TAG, `DeviceInfo id: ${currentDevice.id}`);
        Logger.info(TAG, `DeviceInfo name: ${currentDevice.name}`);
        Logger.info(TAG, `DeviceInfo address: ${currentDevice.address}`);
      }
      Logger.info(TAG, `Device change reason: ${deviceChangeInfo.changeReason}`);
      if (deviceChangeInfo.changeReason === audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {
        Logger.info(TAG, `Device change reason: ${deviceChangeInfo.changeReason}`);
        MediaControlCenter.getInstance().pause();
      }
    })
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
