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
import { MediaControlCenter } from './MediaControlCenter';
import { APP_STORAGE_KEYS } from '../../constants/AppStorageKeys';

const TAG = 'AVSessionController';

export class AVSessionController {
  private context: common.UIAbilityContext | undefined = undefined;
  private AVSession: avSession.AVSession | undefined = undefined;
  private songList: SongItem[] = [];
  private musicIndex: number | undefined = 0;
  private mediaControlCenter: MediaControlCenter | undefined = undefined;
  private static avSessionController: AVSessionController;

  constructor() {
    let list: SongItem[] | undefined = AppStorage.get(APP_STORAGE_KEYS.SONG_LIST);
    if (list) {
      this.songList = list;
    }
  }

  public static getInstance(): AVSessionController {
    if (!AVSessionController.avSessionController) {
      AVSessionController.avSessionController = new AVSessionController();
    }
    return AVSessionController.avSessionController;
  }

  // [Start initAVSession]
  public async initAVSession() {
    this.context = AppStorage.get(APP_STORAGE_KEYS.CONTEXT);
    if (!this.context) {
      Logger.info(TAG, `session create failed, conext is undefined`);
      return;
    }
    this.mediaControlCenter = MediaControlCenter.getInstance();
    this.AVSession = await avSession.createAVSession(this.context, "PLAY_AUDIO", 'audio');
    await this.AVSession.activate();
    Logger.info(TAG, `session create successed : sessionId : ${this.AVSession.sessionId}`);
    this.setLaunchAbility();
    this.setListenerForMesFromController();
    if (this.musicIndex !== undefined) {
      this.getAndUpdateFavoriteState(this.songList[this.musicIndex].bvid);
    }
  }
  // [End initAVSession]

  // [Start setLaunchAbility]
  // Set LaunchAbility.
  private setLaunchAbility() {
    if (!this.context) {
      return;
    }
    let wantAgentInfo: wantAgent.WantAgentInfo = {
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
      if (this.AVSession) {
        this.AVSession.setLaunchAbility(agent);
      }
    })
      .catch((err: BusinessError) => {
        Logger.error(TAG, `getWantAgent failed: code: ${err.code}, message: ${err.message}`);
      });
  }
  // [End setLaunchAbility]

  private getDuration() {
    let duration: number | undefined = AppStorage.get(APP_STORAGE_KEYS.TOTAL_MS_TIME);
    if (!duration) {
      Logger.error(TAG, 'get duration failed');
      return;
    }
    return duration;
  }

  // [Start setAVMetadata]
  // Set metadata
  public async setAVMetadata() {
    this.musicIndex = AppStorage.get(APP_STORAGE_KEYS.SELECT_INDEX) ?? 0;
    Logger.info(TAG, 'current musicIndex is: ' + this.musicIndex);
    if (this.musicIndex === undefined) {
      this.musicIndex = 0;
    }
    try {
      if (this.context) {
        let mediaImage = this.songList[this.musicIndex].label;
        Logger.info(TAG, 'getPixelMapFromResource success' + JSON.stringify(mediaImage));
        let title = '';
        let artist = '';
        if (this.songList[this.musicIndex].title !== undefined) {
          title = this.songList[this.musicIndex].title;
        }
        if (this.songList[this.musicIndex].singer !== undefined) {
          artist = this.songList[this.musicIndex].singer;
        }

        let metadata: avSession.AVMetadata = {
          assetId: this.songList[this.musicIndex].bvid,
          title: title,
          artist: artist,
          mediaImage: mediaImage,
          duration: this.getDuration(),
          avQueueName: 'Aurym Music',
          avQueueId: 'AurymMusic',
          avQueueImage: mediaImage
        };
        if (this.AVSession) {
          this.AVSession.setAVMetadata(metadata).then(() => {
            Logger.info(TAG, 'SetAVMetadata successfully');
          }).catch((err: BusinessError) => {
            Logger.error(TAG, `SetAVMetadata BusinessError: code: ${err.code}, message: ${err.message}`);
          });
        }
      }
    } catch (error) {
      Logger.error(TAG, `SetAVMetadata faile, code: ${(error as BusinessError).code}`);
    }
  }
  // [End setAVMetadata]

  // [Start setListenerForMesFromController]
  // Set listening events
  async setListenerForMesFromController() {
    if (!this.AVSession) {
      return;
    }
    this.AVSession.on('play', this.onPlay);
    this.AVSession.on('pause', this.onPause);
    this.AVSession.on('playNext', this.onPlayNext);
    this.AVSession.on('playPrevious', this.onPlayPrevious);
    this.AVSession.on('seek', this.onSeek);
    this.AVSession.on('setLoopMode', this.onSetLoopMode);
    this.AVSession.on('toggleFavorite', this.onToggleFavorite);
  }

  // [End setListenerForMesFromController]

  // Set playback listening
  private onPlay: () => void = () => {
    Logger.info(TAG, `on play , do play task`);
    if (!this.mediaControlCenter) {
      Logger.error(TAG, 'mediaControlFunction is undefined in onPlay');
      return;
    }
    this.mediaControlCenter.play();
  }
  // Set pause listening
  private onPause: () => void = () => {
    Logger.info(TAG, `on pause , do pause task`);
    if (!this.mediaControlCenter) {
      Logger.error(TAG, 'mediaControlFunction is undefined in onPause');
      return;
    }
    this.mediaControlCenter.pause();
  }
  // Set play next song listening.
  private onPlayNext: () => void = () => {
    Logger.info(TAG, `on playNext , do playNext task`);
    if (!this.mediaControlCenter) {
      Logger.error(TAG, 'mediaControlFunction is undefined in onPlayNext');
      return;
    }
    this.mediaControlCenter.playNext();
  }
  // Set play previous song listening.
  private onPlayPrevious: () => void = () => {
    Logger.info(TAG, `on playPrevious , do playPrevious task`);
    if (!this.mediaControlCenter) {
      Logger.error(TAG, 'mediaControlFunction is undefined in onPlayPrevious');
      return;
    }
    this.mediaControlCenter.playPrevious();
  }
  // Set seek listening.
  private onSeek: (curMs: number) => void = (curMs: number) => {
    Logger.info(TAG, `on seek , do seek task`);
    if (!this.mediaControlCenter) {
      Logger.error(TAG, 'mediaControlFunction is undefined in onSeek');
      return;
    }
    this.mediaControlCenter.seek(curMs);
  }
  // Set set loopMode listening.
  private onSetLoopMode: (loopMode: avSession.LoopMode) => void = (loopMode: avSession.LoopMode) => {
    Logger.info(TAG, `on setLoopMode , do loopMode task`);
    if (!this.mediaControlCenter) {
      Logger.error(TAG, 'mediaControlFunction is undefined in onSetLoopMode');
      return;
    }
    switch (loopMode) {
      case avSession.LoopMode.LOOP_MODE_SINGLE:
        this.mediaControlCenter.setPlayMode(MusicPlayMode.ORDER);
        break;
      case avSession.LoopMode.LOOP_MODE_SEQUENCE:
        this.mediaControlCenter.setPlayMode(MusicPlayMode.RANDOM);
        break;
      case avSession.LoopMode.LOOP_MODE_SHUFFLE:
        this.mediaControlCenter.setPlayMode(MusicPlayMode.SINGLE_CYCLE);
        break;
      default:
        break;
    }
  }
  // Set favorite state listening.
  private onToggleFavorite: (assetId: string) => void = (assetId: string) => {
    Logger.info(TAG, `on toggleFavorite , do toggleFavorite task`);
    let isFavorite: boolean | undefined = AppStorage.get(APP_STORAGE_KEYS.IS_FAVORITE);
    this.updateFavoriteState(assetId, isFavorite ? !isFavorite : true);
  }

  // Set play mode listening.
  public setPlayModeToAVSession(currentPlayMode: MusicPlayMode) {
    if (!this.mediaControlCenter) {
      Logger.error(TAG, 'mediaControlFunction is undefined in setPlayModeToAVSession');
      return;
    }
    let AVSessionLoopMode: avSession.LoopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
    switch (currentPlayMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        AVSessionLoopMode = avSession.LoopMode.LOOP_MODE_SINGLE;
        break;
      case MusicPlayMode.ORDER:
        AVSessionLoopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
        break;
      case MusicPlayMode.RANDOM:
        AVSessionLoopMode = avSession.LoopMode.LOOP_MODE_SHUFFLE;
        break;
      default:
        break;
    }
    this.setLoopModeState(AVSessionLoopMode);
  }

  // [Start setPlayState]
  // Set favorite state.
  private setFavoriteState(isFavorite: boolean) {
    if (this.AVSession) {
      this.AVSession.setAVPlaybackState({ isFavorite }, (err: BusinessError) => {
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
    if (this.AVSession) {
      this.AVSession.setAVPlaybackState({
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
    if (!this.AVSession) {
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
    this.AVSession.setAVPlaybackState(playbackState, (err: BusinessError) => {
      if (err) {
        Logger.error(TAG, `setPlayState BusinessError: code: ${err.code}, message: ${err.message}`);
      } else {
        Logger.info(TAG, 'setPlayState successfully');
      }
    });
  }
  // [End setPlayState]

  public async updateFavoriteState(assetId: string, isFavorite: boolean) {
    if (!this.context) {
      return;
    }
    PreferencesUtil.getInstance().preferencesPut(assetId, isFavorite);
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_FAVORITE, isFavorite);
    this.setFavoriteState(isFavorite);
  }

  public async getAndUpdateFavoriteState(assetId: string) {
    let isFavorite = false;
    if (!this.context) {
      return;
    }
    let isHas: boolean = PreferencesUtil.getInstance().preferencesHas(assetId);
    Logger.info(TAG, `isHas: ${isHas}, assetId:${assetId}`)
    if (isHas) {
      isFavorite = PreferencesUtil.getInstance().getValue(assetId) as boolean;
      Logger.info(TAG, `isFavorite: ${isFavorite}`)
    }
    AppStorage.setOrCreate(APP_STORAGE_KEYS.IS_FAVORITE, isFavorite);
    this.setFavoriteState(isFavorite);
  }

  // Set loopMode state.
  public async setLoopModeState(AVSessionLoopMode: avSession.LoopMode) {
    if (this.AVSession) {
      this.AVSession.setAVPlaybackState({ loopMode: AVSessionLoopMode }, (err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `setLoopModeState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          Logger.info(TAG, 'setLoopModeState successfully');
        }
      });
    }
  }

  async unregisterSessionListener() {
    if (!this.AVSession) {
      return;
    }
    this.AVSession.off('play');
    this.AVSession.off('pause');
    this.AVSession.off('playNext');
    this.AVSession.off('playPrevious');
    this.AVSession.off('setLoopMode');
    this.AVSession.off('seek');
    this.AVSession.off('toggleFavorite');
    this.AVSession.destroy();
  }
}
