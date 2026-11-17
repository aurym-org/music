/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SongItem } from '../../../viewmodel/SongData';
import Logger from '../Logger';
import { MusicPlayMode } from '../../constants/PlayerConstants';
import { PreferencesUtil } from '../PreferencesUtil';
import { AVSessionCommandCallbacks } from './MediaControllerCallbacks';
import { APP_STORAGE_KEYS } from '../../constants/AppStorageKeys';

const TAG = 'AVSessionController';

export class AVSessionController {
  private context: common.UIAbilityContext | undefined = undefined;
  private avSession: avSession.AVSession | undefined = undefined;
  private songList: SongItem[] = [];
  private musicIndex: number = 0;
  private commandCallbacks: AVSessionCommandCallbacks | undefined = undefined;
  private initPromise?: Promise<void>;
  private destroyPromise?: Promise<void>;
  private sessionGeneration: number = 0;
  private metadataUpdateGeneration: number = 0;
  private metadataUpdatePromise: Promise<void> = Promise.resolve();
  private static avSessionController: AVSessionController;

  constructor() {
    const list: SongItem[] | undefined = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST);
    if (list) {
      this.songList = list;
    }
  }

  public setCommandCallbacks(callbacks: AVSessionCommandCallbacks | undefined): void {
    this.commandCallbacks = callbacks;
  }

  public static getInstance(): AVSessionController {
    if (!AVSessionController.avSessionController) {
      AVSessionController.avSessionController = new AVSessionController();
    }
    return AVSessionController.avSessionController;
  }

  // [Start initAVSession]
  public async initAVSession(): Promise<void> {
    // Capture the lifecycle token before waiting. If teardown happens while this
    // request is waiting for a previous destroy operation, the request must not
    // resume later and create a session for a page that has already disappeared.
    const generation = this.sessionGeneration;
    const pendingDestroy = this.destroyPromise;
    if (pendingDestroy) {
      await pendingDestroy;
      if (generation !== this.sessionGeneration) {
        Logger.debug(TAG, 'Ignoring AVSession initialization cancelled during teardown');
        return;
      }
    }

    if (this.avSession) {
      Logger.info(TAG, 'AVSession already initialized');
      return;
    }
    if (this.initPromise) {
      return this.initPromise;
    }

    const pendingInit = this.createAVSession(generation);
    this.initPromise = pendingInit;
    try {
      await pendingInit;
    } finally {
      if (this.initPromise === pendingInit) {
        this.initPromise = undefined;
      }
    }
  }

  private async safelyDestroySession(session: avSession.AVSession, reason: string): Promise<void> {
    try {
      await session.destroy();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `AVSession destroy failed (${reason}): ${message}`);
    }
  }

  private async createAVSession(generation: number): Promise<void> {
    const context: common.UIAbilityContext | undefined = AppStorage.get(APP_STORAGE_KEYS.CONTEXT);
    if (!context) {
      Logger.warn(TAG, 'Session creation skipped: context is unavailable');
      return;
    }

    const session = await avSession.createAVSession(context, 'PLAY_AUDIO', 'audio');
    if (generation !== this.sessionGeneration) {
      await this.safelyDestroySession(session, 'stale initialization');
      return;
    }

    this.context = context;
    this.avSession = session;
    this.songList = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST) ?? [];
    this.musicIndex = AppStorage.get(APP_STORAGE_KEYS.SELECT_INDEX) ?? 0;

    try {
      await session.activate();
      if (generation !== this.sessionGeneration) {
        if (this.avSession === session) {
          this.avSession = undefined;
        }
        // unregisterSessionListener owns destruction after invalidating this generation.
        return;
      }
    } catch (error) {
      const isCurrentSession = this.avSession === session && generation === this.sessionGeneration;
      if (isCurrentSession) {
        this.avSession = undefined;
        await this.safelyDestroySession(session, 'activation failure');
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(message);
      }
      // The teardown path already took ownership of destroying this session.
      return;
    }

    Logger.info(TAG, `AVSession created successfully: ${session.sessionId}`);
    this.setLaunchAbility(session, generation);
    this.setListenerForMesFromController();
    await this.configureMediaCenterControls(session, generation);
    if (session !== this.avSession || generation !== this.sessionGeneration) {
      return;
    }
    const currentSong = this.songList[this.musicIndex];
    if (currentSong) {
      this.getAndUpdateFavoriteState(currentSong.bvid);
    }
  }
  // [End initAVSession]

  // [Start setLaunchAbility]
  // Set LaunchAbility.
  private setLaunchAbility(session: avSession.AVSession, generation: number): void {
    if (!this.context) {
      return;
    }
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      operationType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    wantAgent.getWantAgent(wantAgentInfo).then((agent) => {
      if (this.avSession === session && generation === this.sessionGeneration) {
        session.setLaunchAbility(agent);
      }
    })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `getWantAgent failed: code: ${err.code}, message: ${err.message}`);
      });
  }
  // [End setLaunchAbility]

  /** Configure the API 26 media-center controls used by this audio player. */
  private async configureMediaCenterControls(
    session: avSession.AVSession,
    generation: number
  ): Promise<void> {
    try {
      await session.setSupportedLoopModes([
        avSession.LoopMode.LOOP_MODE_SINGLE,
        avSession.LoopMode.LOOP_MODE_SEQUENCE,
        avSession.LoopMode.LOOP_MODE_SHUFFLE
      ]);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Failed to set supported loop modes: ${message}`);
    }
    if (session !== this.avSession || generation !== this.sessionGeneration) {
      return;
    }

    try {
      await session.setMediaCenterControlType([
        'playNext',
        'playPrevious',
        'toggleFavorite',
        'setLoopMode'
      ]);
      Logger.info(TAG, 'API 26 media-center controls configured');
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `Failed to configure API 26 media-center control types: ${message}`);
    }
  }

  private getDuration(): number | undefined {
    const duration = AppStorage.get<number>(APP_STORAGE_KEYS.TOTAL_MS_TIME);
    if (duration === undefined || !Number.isFinite(duration) || duration <= 0) {
      return undefined;
    }
    return duration;
  }

  // [Start setAVMetadata]
  // Set metadata
  public setAVMetadata(): void {
    // Invalidate older queued writes immediately, including when the current
    // song/index is temporarily invalid during a playlist transition.
    const updateGeneration = ++this.metadataUpdateGeneration;
    const session = this.avSession;
    const sessionGeneration = this.sessionGeneration;
    this.songList = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST) ?? this.songList;
    this.musicIndex = AppStorage.get(APP_STORAGE_KEYS.SELECT_INDEX) ?? 0;
    Logger.info(TAG, 'Current music index: ' + this.musicIndex);

    const currentSong = this.songList[this.musicIndex];
    if (!currentSong || !session || !this.context) {
      Logger.warn(TAG, `Metadata update skipped: song/session/context unavailable (index=${this.musicIndex})`);
      return;
    }

    try {
      const mediaImage = AppStorage.get<PixelMap>(APP_STORAGE_KEYS.CURRENT_PIXEL_MAP);
      const duration = this.getDuration();
      Logger.info(TAG, `Metadata image available: ${mediaImage !== undefined}`);
      const metadata: avSession.AVMetadata = {
        assetId: currentSong.bvid,
        title: currentSong.title,
        artist: currentSong.singer,
        avQueueName: 'Aurym Music',
        avQueueId: 'AurymMusic'
      };
      // AVSession's native metadata parser rejects a present-but-undefined
      // duration. During an early track switch the duration is not known yet;
      // omit it and let the prepared callback publish the complete metadata.
      if (duration !== undefined) {
        metadata.duration = duration;
      }
      if (mediaImage) {
        metadata.mediaImage = mediaImage;
        metadata.avQueueImage = mediaImage;
      }

      // Serialize writes and discard queued metadata that has already become
      // stale. If an older native write is in-flight, the newest write follows
      // it and therefore wins at the lock screen.
      const updateTask = this.metadataUpdatePromise.then(async () => {
        if (updateGeneration !== this.metadataUpdateGeneration ||
          session !== this.avSession || sessionGeneration !== this.sessionGeneration) {
          return;
        }
        await session.setAVMetadata(metadata);
        if (updateGeneration === this.metadataUpdateGeneration &&
          session === this.avSession && sessionGeneration === this.sessionGeneration) {
          Logger.info(TAG, 'SetAVMetadata successfully');
        }
      });
      this.metadataUpdatePromise = updateTask.catch((error: BusinessError) => {
        const message = error instanceof Error ? error.message : String(error);
        Logger.error(TAG, `SetAVMetadata failed: ${message}`);
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `SetAVMetadata failed: ${message}`);
    }
  }
  // [End setAVMetadata]

  // [Start setListenerForMesFromController]
  // Set listening events
  private safelyAddSessionListener(
    eventName: string,
    addListener: () => void
  ): void {
    try {
      addListener();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Failed to register AVSession ${eventName} listener: ${message}`);
    }
  }

  private safelyRemoveSessionListener(
    eventName: string,
    removeListener: () => void
  ): void {
    try {
      removeListener();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.warn(TAG, `Failed to detach AVSession ${eventName} listener: ${message}`);
    }
  }

  public setListenerForMesFromController(): void {
    const session = this.avSession;
    if (!session) {
      return;
    }
    // A single unsupported/failing listener must not leave every other lock-
    // screen action unregistered or make AVSession init appear to have failed.
    this.safelyAddSessionListener('play', () => session.on('play', this.onPlay));
    this.safelyAddSessionListener('pause', () => session.on('pause', this.onPause));
    this.safelyAddSessionListener('playNext', () => session.on('playNext', this.onPlayNext));
    this.safelyAddSessionListener('playPrevious', () => session.on('playPrevious', this.onPlayPrevious));
    this.safelyAddSessionListener('seek', () => session.on('seek', this.onSeek));
    // API 26 Media Controller reports the selected loop mode through
    // setTargetLoopMode when the supported mode range is configured.
    this.safelyAddSessionListener('setTargetLoopMode', () =>
      session.on('setTargetLoopMode', this.onSetTargetLoopMode));
    this.safelyAddSessionListener('toggleFavorite', () => session.on('toggleFavorite', this.onToggleFavorite));
  }

  // [End setListenerForMesFromController]

  // Set playback listening
  private onPlay: () => void = () => {
    Logger.info(TAG, 'on play, dispatch command');
    this.commandCallbacks?.play();
  }
  // Set pause listening
  private onPause: () => void = () => {
    Logger.info(TAG, 'on pause, dispatch command');
    this.commandCallbacks?.pause();
  }
  // Set play next song listening.
  private onPlayNext: () => void = () => {
    Logger.info(TAG, 'on playNext, dispatch command');
    this.commandCallbacks?.playNext();
  }
  // Set play previous song listening.
  private onPlayPrevious: () => void = () => {
    Logger.info(TAG, 'on playPrevious, dispatch command');
    this.commandCallbacks?.playPrevious();
  }
  // Set seek listening.
  private onSeek: (curMs: number) => void = (curMs: number) => {
    Logger.info(TAG, 'on seek, dispatch command');
    this.commandCallbacks?.seek(curMs);
  }
  // Set target loop mode listening (API 26 Media Controller).
  private onSetTargetLoopMode: (loopMode: avSession.LoopMode) => void = (loopMode: avSession.LoopMode) => {
    Logger.info(TAG, `on setTargetLoopMode: ${loopMode}, dispatch command`);
    switch (loopMode) {
      case avSession.LoopMode.LOOP_MODE_SINGLE:
        this.commandCallbacks?.setPlayMode(MusicPlayMode.SINGLE_CYCLE);
        break;
      case avSession.LoopMode.LOOP_MODE_SEQUENCE:
        this.commandCallbacks?.setPlayMode(MusicPlayMode.ORDER);
        break;
      case avSession.LoopMode.LOOP_MODE_SHUFFLE:
        this.commandCallbacks?.setPlayMode(MusicPlayMode.RANDOM);
        break;
      default:
        break;
    }
  }
  // Set favorite state listening.
  private onToggleFavorite: (assetId: string) => void = (assetId: string) => {
    if (!assetId) {
      Logger.warn(TAG, 'Ignore favorite toggle with an empty assetId');
      return;
    }

    // AVSession may deliver a delayed event for the previously active track.
    // Read that track's own persisted state instead of blindly toggling the
    // current track's UI state.
    const currentSongList: SongItem[] = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST) ?? this.songList;
    const currentIndex = AppStorage.get<number>(APP_STORAGE_KEYS.SELECT_INDEX) ?? 0;
    const isCurrentAsset = currentSongList[currentIndex]?.bvid === assetId;
    const currentFavoriteState = isCurrentAsset
      ? AppStorage.get<boolean>(APP_STORAGE_KEYS.IS_FAVORITE) === true
      : PreferencesUtil.getInstance().getValue(assetId) === true;

    Logger.info(TAG, `on toggleFavorite assetId=${assetId}, nextState=${!currentFavoriteState}`);
    this.updateFavoriteState(assetId, !currentFavoriteState);
  }

  // Set play mode listening.
  public setPlayModeToAVSession(currentPlayMode: MusicPlayMode) {
    if (!this.avSession) {
      Logger.warn(TAG, 'Cannot update loop mode before AVSession initialization');
      return;
    }
    let sessionLoopMode: avSession.LoopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
    switch (currentPlayMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        sessionLoopMode = avSession.LoopMode.LOOP_MODE_SINGLE;
        break;
      case MusicPlayMode.ORDER:
        sessionLoopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
        break;
      case MusicPlayMode.RANDOM:
        sessionLoopMode = avSession.LoopMode.LOOP_MODE_SHUFFLE;
        break;
      default:
        break;
    }
    this.setLoopModeState(sessionLoopMode);
  }

  /** Send a partial playback-state update without blocking the caller. */
  private publishPlaybackState(state: avSession.AVPlaybackState, action: string): void {
    const session = this.avSession;
    if (!session) {
      return;
    }
    session.setAVPlaybackState(state, (error: BusinessError) => {
      if (error) {
        Logger.error(TAG, `${action} failed: code: ${error.code}, message: ${error.message}`);
      }
    });
  }

  private setFavoriteState(isFavorite: boolean): void {
    this.publishPlaybackState({ isFavorite }, 'Favorite state update');
  }

  public setProgressState(ms: number): void {
    this.publishPlaybackState({
      position: {
        elapsedTime: ms,
        updateTime: Date.now()
      }
    }, 'Progress state update');
  }

  public setPlayState(isPlay: boolean, currentMs: number): void {
    this.publishPlaybackState({
      state: isPlay
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      position: {
        elapsedTime: currentMs,
        updateTime: Date.now()
      }
    }, 'Play state update');
  }

  public updateFavoriteState(assetId: string, isFavorite: boolean): void {
    if (!assetId) {
      return;
    }
    this.songList = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST) ?? this.songList;
    const currentIndex = AppStorage.get<number>(APP_STORAGE_KEYS.SELECT_INDEX) ?? 0;
    const currentSong = this.songList[currentIndex];
    if (currentSong?.bvid === assetId) {
      // Update the visible/session state first. Preference persistence is
      // synchronous in-memory work and must not delay the control-center reply.
      AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_FAVORITE, isFavorite);
      this.setFavoriteState(isFavorite);
    }
    // preferencesPut updates the in-memory cache synchronously; PreferencesUtil
    // already coalesces disk flushes. Avoid an extra timer so a teardown cannot
    // discard a queued favorite update.
    const preferences = PreferencesUtil.getInstance();
    if (preferences.getValue(assetId) !== isFavorite) {
      preferences.preferencesPut(assetId, isFavorite);
    }
  }

  public getAndUpdateFavoriteState(assetId: string): void {
    if (!assetId) {
      return;
    }

    // Session activation is asynchronous. The song may have changed while
    // createAVSession()/activate() was pending, so never let an old asset
    // overwrite the current track's favorite UI state.
    this.songList = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST) ?? this.songList;
    this.musicIndex = AppStorage.get<number>(APP_STORAGE_KEYS.SELECT_INDEX) ?? 0;
    const currentSong = this.songList[this.musicIndex];
    if (currentSong?.bvid !== assetId) {
      Logger.debug(TAG, `Ignoring stale favorite-state sync for ${assetId}`);
      return;
    }

    const storedValue = PreferencesUtil.getInstance().getValue(assetId);
    const isFavorite = storedValue === true;
    Logger.info(TAG, `isFavorite: ${isFavorite}, assetId: ${assetId}`);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_FAVORITE, isFavorite);
    this.setFavoriteState(isFavorite);
  }

  public setLoopModeState(sessionLoopMode: avSession.LoopMode): void {
    this.publishPlaybackState({ loopMode: sessionLoopMode }, 'Loop mode update');
  }

  public async unregisterSessionListener(): Promise<void> {
    this.sessionGeneration++;
    const previousDestroy = this.destroyPromise;
    const pendingInit = this.initPromise;
    this.initPromise = undefined;

    const session = this.avSession;
    const pendingMetadata = this.metadataUpdatePromise;
    this.metadataUpdateGeneration++;
    // Detach session and ability references immediately. A new initialization
    // must wait until the exact session instance has completed teardown.
    this.avSession = undefined;
    this.context = undefined;
    this.commandCallbacks = undefined;
    this.songList = [];
    this.musicIndex = 0;

    if (session) {
      this.safelyRemoveSessionListener('play', () => session.off('play'));
      this.safelyRemoveSessionListener('pause', () => session.off('pause'));
      this.safelyRemoveSessionListener('playNext', () => session.off('playNext'));
      this.safelyRemoveSessionListener('playPrevious', () => session.off('playPrevious'));
      this.safelyRemoveSessionListener('setTargetLoopMode', () => session.off('setTargetLoopMode'));
      this.safelyRemoveSessionListener('seek', () => session.off('seek'));
      this.safelyRemoveSessionListener('toggleFavorite', () => session.off('toggleFavorite'));
    }

    if (!previousDestroy && !pendingInit && !session) {
      return;
    }

    const cleanupTask = (async (): Promise<void> => {
      if (previousDestroy) {
        await previousDestroy;
      }
      if (pendingInit) {
        await pendingInit.catch((error: BusinessError) => {
          const message = error instanceof Error ? error.message : String(error);
          Logger.warn(TAG, `Pending AVSession initialization ended during release: ${message}`);
        });
      }
      // Do not destroy the session while a previously started metadata update
      // is still using it. The generation guard prevents queued stale writes.
      await pendingMetadata;
      // Wait for activate() to settle before destroying its session. This avoids
      // concurrently activating and destroying the same native AVSession.
      if (session) {
        await this.safelyDestroySession(session, 'controller teardown');
      }
    })();

    this.destroyPromise = cleanupTask;
    try {
      await cleanupTask;
    } finally {
      if (this.destroyPromise === cleanupTask) {
        this.destroyPromise = undefined;
      }
    }
  }
}
