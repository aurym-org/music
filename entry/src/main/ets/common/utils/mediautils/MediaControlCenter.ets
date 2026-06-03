/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import { getFavoriteDetail } from '../../../model/SongListData';
import { SongItem } from '../../../viewmodel/SongData';
import SongItemBuilder from '../../../viewmodel/SongItemBuilder';
import { DEFAULT_VOLUME, MusicPlayMode, SILENT_ID, VOLUME_ID, PLAY_MODE_ID } from '../../constants/PlayerConstants';
import { ContentConstants } from '../../constants/ContentConstants';
import Logger from '../Logger';
import { AVSessionController } from './AVSessionController';
import { MediaTools } from './MediaTools';
import { AVPlayerController } from './AVPlayerController';
import { BackgroundUtil } from '../BackgroundUtil';
import { common } from '@kit.AbilityKit';
import { PreferencesUtil } from '../PreferencesUtil';
import { audio } from '@kit.AudioKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { wbiSigner } from '../BiliWbiUtil';

const TAG = 'MediaControlCenter';

export class MediaControlCenter {
  private avSessionController: AVSessionController | undefined = undefined;
  private avPlayerController: AVPlayerController | undefined = undefined;
  private context: common.UIAbilityContext | undefined = AppStorage.get('context');
  private songItemBuilder: SongItemBuilder = new SongItemBuilder();
  private playMode: MusicPlayMode | undefined = undefined;
  private songList: SongItem[] = [];
  private musicIndex: number = 0;
  private audioSessionManager: audio.AudioSessionManager | undefined = undefined;
  private isInitted = false;
  private static mediaControlFunction: MediaControlCenter;
  private switchTimer: number = -1;
  private switchVersion: number = 0;
  private lastProgressUpdateTime: number = 0;

  constructor() {
    this.songItemBuilder = new SongItemBuilder();
  }

  /**
   * 设置全局加载状态
   */
  private setLoading(loading: boolean) {
    AppStorage.setOrCreate('isLoading', loading);
  }

  // [Start loadSongAssent]
  private async loadSongAssent() {
    const currentVersion = this.switchVersion;
    if (this.switchVersion !== currentVersion) return;
    await this.songItemBuilder.build(this.songList[this.musicIndex]);
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }
    if (this.switchVersion !== currentVersion) return;
    AppStorage.setOrCreate('currentBvid', this.songList[this.musicIndex].bvid);
    AppStorage.setOrCreate('currentCid', this.songList[this.musicIndex].cid);
    await this.avPlayerController.loadSongAssent(this.songList[this.musicIndex].src);
    this.setLoading(false);
  }
  // [End loadSongAssent]

  public static getInstance(): MediaControlCenter {
    if (!MediaControlCenter.mediaControlFunction) {
      MediaControlCenter.mediaControlFunction = new MediaControlCenter();
    }
    return MediaControlCenter.mediaControlFunction;
  }

  private async initAVSession() {
    this.avSessionController = AVSessionController.getInstance();
    await this.avSessionController.initAVSession();
  }

  private async initAvplayer() {
    this.avPlayerController = AVPlayerController.getInstance();
    await this.avPlayerController.initAVPlayer();
  }

  private async initAudioManager() {
    let audioManger = audio.getAudioManager();
    this.audioSessionManager = audioManger.getSessionManager();
    await this.activateAudioSession();
  }

  private async activateAudioSession(concurrencyMode: audio.AudioConcurrencyMode = audio.AudioConcurrencyMode.CONCURRENCY_PAUSE_OTHERS) {
    if (!this.audioSessionManager) {
      return;
    }
    let strategy: audio.AudioSessionStrategy = {
      concurrencyMode: concurrencyMode
    };
    await this.audioSessionManager.activateAudioSession(strategy);
    Logger.info(TAG, 'activateAudioSession SUCCESS');
  }

  public async init() {
    if (this.isInitted) {
      return;
    }
    await wbiSigner.fetchAndCacheWbiKeys();
    AppStorage.setOrCreate('switchVersion', this.switchVersion);
    await getFavoriteDetail(ContentConstants.FAV_ID);
    this.songList = AppStorage.get('songList')!;
    await Promise.all([
      this.initAvplayer(),
      this.initAVSession(),
      this.initAudioManager()
    ]);
    await this.loadSongAssent();
    this.avSessionController?.setAVMetadata();
    this.setSilentModeFromPrefer();
    this.setVolumeFromPrefer();
    this.setPlayModeFromPrefer();
    this.setLoading(false);
    this.isInitted = true;
  }

  public release() {
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }
    if (!this.avSessionController) {
      Logger.error(TAG, 'avSessionController is undefined');
      return;
    }
    this.avSessionController.unregisterSessionListener();
    try {
      this.avPlayerController.release();
    } catch (err) {
      Logger.error(TAG, `release failed: code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`)
    }
  }

  public async switchToIndex(newIndex: number) {
    this.setLoading(true);
    this.switchVersion++;
    AppStorage.setOrCreate('switchVersion', this.switchVersion);
    const currentVersion = this.switchVersion;

    if (this.switchTimer !== -1) {
      clearTimeout(this.switchTimer);
    }
    this.updateMusicIndex(newIndex);
    this.updateProgress(0);

    this.switchTimer = setTimeout(async () => {
      this.switchTimer = -1;
      if (this.switchVersion !== currentVersion) return;
      await this.stop();
      if (this.switchVersion !== currentVersion) return;
      await this.loadSongAssent();
      if (this.switchVersion !== currentVersion) return;
      await this.play();
    }, ContentConstants.DEBOUNCE_DELAY);
  }

  // [Start StartContinuousTask]
  public async play() {
    Logger.info(TAG, `musicIndex is ${this.musicIndex}`)
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }
    if (!this.avSessionController) {
      Logger.error(TAG, 'avSessionController is undefined');
      return;
    }
    this.updateIsPlay(true);
    try {
      this.avPlayerController.play();
    } catch (err) {
      Logger.error(TAG, `play failed: code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`)
    }
    BackgroundUtil.startContinuousTask(this.context);
  }

  public pause() {
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }
    try {
      this.avPlayerController.pause();
    } catch (err) {
      Logger.error(TAG, `pause failed: code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`)
    }
    this.updateIsPlay(false);
    BackgroundUtil.stopContinuousTask(this.context!);
  }

  // [End StartContinuousTask]

  // Obtain a secure random number between 0 and 1
  private getSecureRandom0To1(): number {
    const rand = cryptoFramework.createRandom();
    // Generate 1-byte random data (0-255)
    const randData = rand.generateRandomSync(1);
    // Convert floating-point numbers within the range
    let randomMum: number = randData.data[0] * 1 / 255;
    return randomMum;
  }

  // Set a secure random number
  private setRandom() {
    const max = this.songList.length - 1;
    if (max <= 0) {
      return 0;
    }
    let num: number;
    do {
      const random0To1 = this.getSecureRandom0To1();
      num = Math.round(random0To1 * max);
    } while (num === this.musicIndex);
    Logger.info(TAG, `random num is ${num}, max length is ${max}`);
    return num;
  }

  // [Start playNext]
  public async playNext() {
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

  public async playPrevious() {
    let preIndex = this.musicIndex;
    switch (this.playMode) {
      case MusicPlayMode.SINGLE_CYCLE:
        break;
      case MusicPlayMode.ORDER:
        if (this.musicIndex === 0) {
          preIndex = this.songList.length - 1;
        } else {
          preIndex -= 1;
          if (preIndex < 0) {
            preIndex = this.songList.length - 1
          }
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

  public async stop() {
    if (!this.context) {
      return;
    }
    if (!this.avPlayerController) {
      return;
    }
    try {
      await this.avPlayerController.stop();
    } catch (err) {
      Logger.error(TAG, `stop failed: code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`)
    }
    this.updateIsPlay(false);
    Logger.info(TAG, 'stop success')
    BackgroundUtil.stopContinuousTask(this.context);
  }

  // Set play mode
  public setPlayMode(playMode: MusicPlayMode | undefined) {
    if (!this.avSessionController) {
      return;
    }
    this.playMode = playMode ?? MusicPlayMode.ORDER;
    this.avSessionController.setPlayModeToAVSession(this.playMode);
    this.setPlayModeToControlArea(this.playMode);
  }

  private setPlayModeToControlArea(playMode: MusicPlayMode) {
    AppStorage.setOrCreate('playMode', playMode);
    PreferencesUtil.getInstance().preferencesPut(PLAY_MODE_ID, playMode);
  }

  public updateIsPlay(isPlay: boolean) {
    Logger.info(TAG, `avSessionController isPlay is ${isPlay}`)
    AppStorage.setOrCreate<boolean>('isPlay', isPlay);
    if (!this.avSessionController) {
      Logger.error(TAG, `avSessionController is undefined`);
      return;
    }
    this.avSessionController.setPlayState(isPlay);
  }

  public getVolume(): number {
    if (!this.avPlayerController) {
      return 0;
    }
    let volume: number | undefined;
    volume = PreferencesUtil.getInstance().getValue(VOLUME_ID) as number;
    if (volume === undefined) {
      return DEFAULT_VOLUME;
    } else {
      return volume
    }
  }

  public setVolume(volume: number) {
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }
    try {
      this.avPlayerController.setVolume(volume);
      if (!AppStorage.get('isSilentMode') || volume !== 0) {
        PreferencesUtil.getInstance().preferencesPut(VOLUME_ID, volume);
      }
    } catch (err) {
      Logger.error(TAG,
        `set volume failed: code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`)
    }
    Logger.info(TAG, `setVolume is ${volume}`)
  }

  public setSpeed(speed: number) {
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }
    try {
      this.avPlayerController.setSpeed(speed);
    } catch (err) {
      Logger.error(TAG,
        `set speed failed: code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`)
    }
  }

  // Set silent mode
  public async setSilentMode(isSilentMode: boolean = false) {
    if (!this.context) {
      return;
    }
    if (!this.avPlayerController) {
      Logger.info(TAG, 'avPlayerController is undefined in setSilentModeAndMixWithOthers')
      return;
    }
    PreferencesUtil.getInstance().preferencesPut(SILENT_ID, isSilentMode);
    if (isSilentMode) {
      this.activateAudioSession(audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS)
    } else {
      this.activateAudioSession();
    }
    try {
      this.avPlayerController.setSilentMode(isSilentMode);
      PreferencesUtil.getInstance().preferencesPut(SILENT_ID, isSilentMode);
    } catch (err) {
      Logger.error(TAG,
        `set silentMode failed: code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`)
    }
  }

  private async setSilentModeFromPrefer() {
    if (!this.context) {
      return;
    }
    let isSupportSilent: boolean | undefined = PreferencesUtil.getInstance().getValue(SILENT_ID) as boolean | undefined;
    if (isSupportSilent === undefined) {
      isSupportSilent = false;
    }
    AppStorage.setOrCreate('isSilentMode', isSupportSilent);
    this.setSilentMode(isSupportSilent)
  }

  private async setVolumeFromPrefer() {
    if (!this.context) {
      return;
    }
    let volume: number | undefined = PreferencesUtil.getInstance().getValue(VOLUME_ID) as number | undefined;
    if (volume === undefined) {
      volume = DEFAULT_VOLUME;
    }
    Logger.info(TAG, `setVolumeFromPrefer volume is ${volume}`)
    this.setVolume(volume);
    AppStorage.setOrCreate('currentVolume', volume);
  }

  private async setPlayModeFromPrefer() {
    if (!this.context) {
      return;
    }
    let playMode: MusicPlayMode | undefined = PreferencesUtil.getInstance().getValue(PLAY_MODE_ID) as MusicPlayMode | undefined;
    if (playMode === undefined) {
      playMode = MusicPlayMode.ORDER;
    }
    this.setPlayMode(playMode);
  }

  public seek(ms: number) {
    if (!this.avPlayerController) {
      Logger.error(TAG, 'avPlayerController is undefined');
      return;
    }
    try {
      this.avPlayerController.seek(ms);
    } catch (err) {
      Logger.error(TAG, `seek failed: code is ${JSON.stringify(err.code)},message is ${JSON.stringify(err.message)}`)
    }
    this.updateProgress(ms);
  }

  public updateProgress(ms: number) {
    if (!this.avSessionController) {
      return;
    }
    const now = Date.now();
    if (now - this.lastProgressUpdateTime < 300) {
      return;
    }
    this.lastProgressUpdateTime = now;
    this.avSessionController.setProgressState(ms);
    AppStorage.setOrCreate('progress', ms);
    const newTimeStr = MediaTools.msToCountdownTime(ms);
    const oldTimeStr = AppStorage.get<string>('currentTime');
    if (newTimeStr !== oldTimeStr) {
      AppStorage.setOrCreate('currentTime', newTimeStr);
    }
  }

  private updateMusicIndex(musicIndex: number) {
    Logger.info(TAG, 'updateMusicIndex ===> ' + musicIndex);
    this.musicIndex = musicIndex;
    AppStorage.setOrCreate('selectIndex', musicIndex);
    if (!this.avSessionController) {
      return;
    }
    this.avSessionController.setAVMetadata();
    this.avSessionController.getAndUpdateFavoriteState(this.musicIndex.toString());
  }
}