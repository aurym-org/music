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

  private async createAVSession(generation: number): Promise<void> {
    const context: common.UIAbilityContext | undefined = AppStorage.get(APP_STORAGE_KEYS.CONTEXT);
    if (!context) {
      Logger.warn(TAG, 'Session creation skipped: context is unavailable');
      return;
    }

    const session = await avSession.createAVSession(context, 'PLAY_AUDIO', 'audio');
    if (generation !== this.sessionGeneration) {
      await session.destroy();
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
        await session.destroy();
        throw new Error(error.message);
      }
      // The teardown path already took ownership of destroying this session.
      return;
    }

    Logger.info(TAG, `AVSession created successfully: ${session.sessionId}`);
    this.setLaunchAbility(session, generation);
    this.setListenerForMesFromController();
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
    this.songList = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST) ?? this.songList;
    this.musicIndex = AppStorage.get(APP_STORAGE_KEYS.SELECT_INDEX) ?? 0;
    Logger.info(TAG, 'Current music index: ' + this.musicIndex);

    const currentSong = this.songList[this.musicIndex];
    if (!currentSong) {
      Logger.warn(TAG, `Metadata update skipped: invalid song index ${this.musicIndex}`);
      return;
    }

    try {
      if (this.context) {
        const mediaImage = AppStorage.get<PixelMap>(APP_STORAGE_KEYS.CURRENT_PIXEL_MAP);
        Logger.info(TAG, `Metadata image available: ${mediaImage !== undefined}`);
        const metadata: avSession.AVMetadata = {
          assetId: currentSong.bvid,
          title: currentSong.title,
          artist: currentSong.singer,
          mediaImage: mediaImage,
          duration: this.getDuration(),
          avQueueName: 'Aurym Music',
          avQueueId: 'AurymMusic',
          avQueueImage: mediaImage
        };
        if (this.avSession) {
          this.avSession.setAVMetadata(metadata).then(() => {
            Logger.info(TAG, 'SetAVMetadata successfully');
          }).catch((err: BusinessError) => {
            Logger.error(TAG, `SetAVMetadata BusinessError: code: ${err.code}, message: ${err.message}`);
          });
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      Logger.error(TAG, `SetAVMetadata failed: ${message}`);
    }
  }
  // [End setAVMetadata]

  // [Start setListenerForMesFromController]
  // Set listening events
  public setListenerForMesFromController(): void {
    if (!this.avSession) {
      return;
    }
    this.avSession.on('play', this.onPlay);
    this.avSession.on('pause', this.onPause);
    this.avSession.on('playNext', this.onPlayNext);
    this.avSession.on('playPrevious', this.onPlayPrevious);
    this.avSession.on('seek', this.onSeek);
    this.avSession.on('setLoopMode', this.onSetLoopMode);
    this.avSession.on('toggleFavorite', this.onToggleFavorite);
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
  // Set set loopMode listening.
  private onSetLoopMode: (loopMode: avSession.LoopMode) => void = (loopMode: avSession.LoopMode) => {
    Logger.info(TAG, 'on setLoopMode, dispatch command');
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

    Logger.info(TAG, 'on toggleFavorite, updating the target asset state');
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

  // [Start setPlayState]
  // Set favorite state.
  private setFavoriteState(isFavorite: boolean) {
    if (this.avSession) {
      this.avSession.setAVPlaybackState({ isFavorite }, (err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `setFavoriteState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          Logger.info(TAG, 'setFavoriteState successfully');
        }
      });
    }
  }

  // Set progress state.
  public setProgressState(ms: number) {
    if (this.avSession) {
      this.avSession.setAVPlaybackState({
        position: {
          elapsedTime: ms,
          updateTime: new Date().getTime()
        }
      }, (err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `setProgressState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          Logger.info(TAG, 'setProgressState successfully');
        }
      });
    }
  }

  // Set play state.
  public setPlayState(isPlay: boolean, currentMs: number) {
    if (!this.avSession) {
      Logger.error(TAG, 'AVSession is undefined');
      return;
    }
    const playbackState: avSession.AVPlaybackState = {
      state: isPlay ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
    };
    playbackState.position = {
      elapsedTime: currentMs,
      updateTime: new Date().getTime()
    };
    this.avSession.setAVPlaybackState(playbackState, (err: BusinessError) => {
      if (err) {
        Logger.error(TAG, `setPlayState BusinessError: code: ${err.code}, message: ${err.message}`);
      } else {
        Logger.info(TAG, 'setPlayState successfully');
      }
    });
  }
  // [End setPlayState]

  public updateFavoriteState(assetId: string, isFavorite: boolean): void {
    if (!assetId) {
      return;
    }
    PreferencesUtil.getInstance().preferencesPut(assetId, isFavorite);
    this.songList = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST) ?? this.songList;
    const currentIndex = AppStorage.get<number>(APP_STORAGE_KEYS.SELECT_INDEX) ?? 0;
    const currentSong = this.songList[currentIndex];
    if (currentSong?.bvid !== assetId) {
      return;
    }
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_FAVORITE, isFavorite);
    this.setFavoriteState(isFavorite);
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

  // Set loopMode state.
  public setLoopModeState(sessionLoopMode: avSession.LoopMode): void {
    if (this.avSession) {
      this.avSession.setAVPlaybackState({ loopMode: sessionLoopMode }, (err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `setLoopModeState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          Logger.info(TAG, 'setLoopModeState successfully');
        }
      });
    }
  }

  public async unregisterSessionListener(): Promise<void> {
    this.sessionGeneration++;
    const previousDestroy = this.destroyPromise;
    const pendingInit = this.initPromise;
    this.initPromise = undefined;

    const session = this.avSession;
    // Detach session and ability references immediately. A new initialization
    // must wait until the exact session instance has completed teardown.
    this.avSession = undefined;
    this.context = undefined;
    this.commandCallbacks = undefined;
    this.songList = [];
    this.musicIndex = 0;

    if (session) {
      session.off('play');
      session.off('pause');
      session.off('playNext');
      session.off('playPrevious');
      session.off('setLoopMode');
      session.off('seek');
      session.off('toggleFavorite');
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
      // Wait for activate() to settle before destroying its session. This avoids
      // concurrently activating and destroying the same native AVSession.
      if (session) {
        await session.destroy();
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
