/*
 * Copyright (c) 2026 Aurym
 * Released under the MIT License.
 * https://opensource.org/licenses/MIT
 */

import Logger from '../Logger';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { MediaTools } from './MediaTools';
import { AVSessionController } from './AVSessionController';
import { MediaControlCenter } from './MediaControlCenter';
import SongItemBuilder from '../../../viewmodel/SongItemBuilder';

const TAG = 'AVPlayerController'

export class AVPlayerController {
  public avPlayer?: media.AVPlayer;
  private avSessionController: AVSessionController | undefined = undefined;
  private currentState: media.AVPlayerState = 'idle';
  private waitPlay: boolean = false;
  static avPlayerController: AVPlayerController | undefined;
  private preparedResolve?: () => void;
  private preparedReject?: (error: Error) => void;
  private preparedPromise?: Promise<void>;
  private preparedTimeoutId?: number;

  public waitForPrepared(timeoutMs: number = 10000): Promise<void> {
    if (this.currentState === 'prepared') {
      return Promise.resolve();
    }
    if (!this.preparedPromise) {
      this.preparedPromise = new Promise((resolve, reject) => {
        this.preparedResolve = resolve;
        this.preparedReject = reject;

        const timeoutId = setTimeout(() => {
          const error = new Error('waitForPrepared timeout');
          if (this.preparedReject) {
            this.preparedReject(error);
            this.cleanupPreparedPromise();
          }
        }, timeoutMs);
        this.preparedTimeoutId = timeoutId;
      });
    }
    return this.preparedPromise;
  }

  private cleanupPreparedPromise() {
    if (this.preparedTimeoutId) {
      clearTimeout(this.preparedTimeoutId);
      this.preparedTimeoutId = undefined;
    }
    this.preparedResolve = undefined;
    this.preparedReject = undefined;
    this.preparedPromise = undefined;
  }

  async setPlayerUrl(url: string) {
    if (this.preparedReject) {
      this.preparedReject(new Error('setPlayerUrl called with new url, cancelling previous wait'));
      this.cleanupPreparedPromise();
    }
    const currentVersion = AppStorage.get<number>('switchVersion') ?? 0;
    const headers: Record<string, string> = {
      'Referer': 'https://www.bilibili.com/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    };
    if (AppStorage.get<number>('switchVersion') !== currentVersion) {
      if (this.preparedReject) {
        this.preparedReject(new Error('setPlayerUrl cancelled due to version change'));
        this.cleanupPreparedPromise();
      }
      return;
    }
    await this.avPlayer!.reset();
    if (AppStorage.get<number>('switchVersion') !== currentVersion) {
      if (this.preparedReject) {
        this.preparedReject(new Error('setPlayerUrl cancelled after reset'));
        this.cleanupPreparedPromise();
      }
      return;
    }
    let mediaSource: media.MediaSource = media.createMediaSourceWithUrl(url, headers);
    let playStrategy: media.PlaybackStrategy = {
      preferredBufferDuration: 1,
    };
    await this.avPlayer!.setMediaSource(mediaSource, playStrategy);
  }

  // [Start loadSongAssent]
  async loadSongAssent(src: string) {
    if (!src) {
      Logger.error(TAG, `loadSongAssent faile : src get failed`);
      return;
    }
    if (!this.avPlayer) {
      return;
    }
    try {
      await this.setPlayerUrl(src);
      await this.waitForPrepared();
    } catch (e) {
      Logger.error(TAG, `loadSongAssent failed: ${e.message}`);
      AppStorage.setOrCreate('isLoading', false);
      return;
    }
    Logger.info(TAG, `set avPlayer url is ${this.avPlayer.url}, curState is ${this.avPlayer.state}`);
  }
  // [End loadSongAssent]

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
  public async initAVPlayer() {
    if (this.avPlayer) {
      Logger.info(TAG, 'avPlayer already created');
      return;
    }
    this.avPlayer = await media.createAVPlayer();
    Logger.info(TAG, `createAVPlayer success, curState is ${this.avPlayer.state}`);
    this.setAVPlayerCallbacks();
    Logger.info(TAG, `setAVPlayerCallbacks success, curState is ${this.avPlayer.state}`);
  }
  // [End initAVPlayer]

  // [Start prepare]
  // Prepare the player
  public async prepare() {
    if (!this.avPlayer) {
      Logger.info(TAG, 'avPlayer is undefined')
      return;
    }
    await this.avPlayer.prepare();
    Logger.info(TAG, `prepare success , curState is ${this.avPlayer.state}`);
  }
  // [End prepare]

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
  // Set Speed
  public setSpeed(speed: number) {
    if (!this.avPlayer) {
      Logger.info(TAG, 'avPlayer is undefined')
      return;
    }
    Logger.info(TAG, `set speed is ${speed}`)
    this.avPlayer.setSpeed(this.switchSpeed(speed));
  }
  // [End setSpeed]

  // [Start setVolume]
  // Set Volume
  public setVolume(volume: number) {
    if (!this.avPlayer) {
      Logger.info(TAG, 'avPlayer is undefined')
      return;
    }
    Logger.info(TAG, `set volume is ${volume}`)
    this.avPlayer.setVolume(volume / 100);
  }
  // [End setVolume]

  // [Start play]
  public async play() {
    if (!this.avPlayer) {
      Logger.info(TAG, 'avPlayer is undefined')
      return;
    }
    if (this.currentState !== 'prepared' && this.currentState !== 'paused' && this.currentState !== 'stopped' &&
      this.currentState !== 'completed') {
      this.waitPlay = true;
      Logger.info(TAG, 'avPlayer current playState is not prepared')
      return;
    }
    await this.avPlayer.play();
    this.waitPlay = false;
    Logger.info(TAG, 'play success');
    this.updateIsPlay(true);
    Logger.info(TAG, `curState is ${this.avPlayer.state}`);
  }
  // [End play]

  // [Start pause]
  public pause() {
    if (!this.avPlayer) {
      Logger.info(TAG, 'avPlayer is undefined')
      return;
    }
    this.avPlayer.pause();
    this.updateIsPlay(false);
  }
  // [End pause]

  // [Start seek]
  public seek(ms: number) {
    if (!this.avPlayer) {
      Logger.info(TAG, 'avPlayer is undefined')
      return;
    }
    this.avPlayer.seek(ms);
  }
  // [End seek]

  // [Start stop]
  public async stop() {
    if (!this.avPlayer) {
      Logger.error(TAG, 'avPlayer is undefined')
      return;
    }
    await this.avPlayer.stop();
    Logger.info(TAG, 'avPlayer stop success')
  }
  // [End stop]

  // [Start setSilentMode]
  public setSilentMode(isSilentMode: boolean) {
    if (!this.avPlayer) {
      Logger.error(TAG, 'avPlayer is undefined')
      return;
    }
    this.avPlayer.setMediaMuted(media.MediaType.MEDIA_TYPE_AUD, isSilentMode);
    Logger.info(TAG, `avPlayer setMediaMuted is ${isSilentMode} success`)
  }
  // [End setSilentMode]

  // [Start release]
  public release() {
    if (!this.avPlayer) {
      Logger.error(TAG, 'avPlayer is undefined')
      return;
    }
    if (this.preparedReject) {
      this.preparedReject(new Error('Player released'));
      this.cleanupPreparedPromise();
    }
    this.avPlayer.off('error');
    this.avPlayer.off('stateChange');
    this.avPlayer.off('durationUpdate');
    this.avPlayer.off('timeUpdate');
    this.avPlayer.off('audioInterrupt');
    this.avPlayer.off('volumeChange');
    this.avPlayer.off('audioOutputDeviceChangeWithInfo');
    this.avPlayer.release();
    this.avPlayer = undefined;
    Logger.info(TAG, 'avPlayer release success');
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
  private durationUpdateCallback() {
    if (!this.avPlayer) {
      Logger.info(TAG, 'avPlayer is undefined')
      return;
    }
    this.avPlayer.on('durationUpdate', (duration: number) => {
      Logger.info(TAG, 'durationUpdate called,new duration is :' + duration);
    });
  }

  private timeUpdateCallback() {
    if (!this.avPlayer) {
      return;
    }
    this.avPlayer.on('timeUpdate', (time: number) => {
      MediaControlCenter.getInstance().updateProgress(time);
    });
  }

  private setAudioRendererInfo() {
    if (!this.avPlayer) {
      return;
    }
    this.avPlayer.audioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0,
      volumeMode: audio.AudioVolumeMode.SYSTEM_GLOBAL
    }
  }

  private setAvSessionCallback() {
    this.avSessionController = AVSessionController.getInstance();
  }

  // [Start errorCallback]
  private errorCallback() {
    if (!this.avPlayer) {
      return;
    }
    this.avPlayer.on('error', async (error: BusinessError) => {
      Logger.error(TAG, `errorCallback , code is ${error.code} message is ${error.message}`);
      if (error.code === 5411006) {
        const songItemBuilder = new SongItemBuilder();
        const bvid = AppStorage.get<string>('currentBvid')!;
        const cid = AppStorage.get<number>('currentCid')!;
        const url = await songItemBuilder.getBiliPlayUrl(bvid, cid);
        this.waitPlay = true;
        await this.setPlayerUrl(url);
      }
      AppStorage.setOrCreate('isLoading', false);
    });
  }
  // [End errorCallback]

  // [Start stateChangeCallback]
  // Watch state
  private stateChangeCallback() {
    if (!this.avPlayer) {
      Logger.error(TAG, `stateChangeCallback , avPlayer is undefined`);
      return;
    }
    this.avPlayer.on('stateChange', async (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      this.currentState = state;
      switch (state) {
        case 'idle':
          Logger.info(TAG, `state idle called , resson is ${reason}`);
          break;
        case 'initialized':
          Logger.info(TAG, `state initialized called , resson is ${reason}`);
          this.setAudioRendererInfo();
          this.prepare();
          break;
        case 'prepared':
          Logger.info(TAG, `state prepared called , resson is ${reason}`);
          AppStorage.setOrCreate('totalTime', MediaTools.msToCountdownTime(this.avPlayer?.duration!));
          AppStorage.setOrCreate('totalMsTime', this.avPlayer?.duration!);
          AppStorage.setOrCreate('progressMax', this.avPlayer?.duration!);
          AppStorage.setOrCreate('isLoading', false);
          if (!this.avSessionController) {
            Logger.error(TAG, 'avSessionController is undefined');
            return;
          }
          this.avSessionController.setAVMetadata();
          if (this.waitPlay) {
            this.play();
          }
          if (this.preparedResolve) {
            this.preparedResolve();
            this.cleanupPreparedPromise();
          }
          break;
        // [StartExclude stateChangeCallback]
        case 'playing':
          Logger.info(TAG, `state playing called , resson is ${reason}`);
          break;
        case 'paused':
          Logger.info(TAG, `state paused called , resson is ${reason}`);
          break;
        case 'completed':
          MediaControlCenter.getInstance().playNext();
          break;
        case 'stopped':
          Logger.info(TAG, `state stopped called , resson is ${reason}`);
          break;
        case 'released':
          Logger.info(TAG, `state released called , resson is ${reason}`);
          break;
        case 'error':
          Logger.info(TAG, `state error called , resson is ${reason}`);
          if (this.preparedReject) {
            this.preparedReject(new Error(`AVPlayer entered error state, reason: ${reason}`));
            this.cleanupPreparedPromise();
          }
          break;
        default:
          Logger.info(TAG, `state unknown called , resson is ${reason}`);
          break;
        // [EndExclude stateChangeCallback]
      }
    });
    Logger.info(TAG, `set stateChangeCallback success`);
  }
  // [End stateChangeCallback]

  private audioInterruptCallback() {
    if (!this.avPlayer) {
      return;
    }
    this.avPlayer.on('audioInterrupt', (interruptEvent: audio.InterruptEvent) => {
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

  private volumeChangeCallback() {
    if (!this.avPlayer) {
      return;
    }
    this.avPlayer.on('volumeChange', (volume) => {
      Logger.info(TAG, `current volume is ${volume}`)
      Logger.info(TAG, `current 100*volume is ${100 * volume}`)
    })
  }

  private outputDeviceChange() {
    if (!this.avPlayer) {
      return;
    }
    this.avPlayer.on('audioOutputDeviceChangeWithInfo', (deviceChangeInfo: audio.AudioStreamDeviceChangeInfo) => {
      Logger.info(TAG, `DeviceInfo id: ${deviceChangeInfo.devices[0].id}`);
      Logger.info(TAG, `DeviceInfo name: ${deviceChangeInfo.devices[0].name}`);
      Logger.info(TAG, `DeviceInfo address: ${deviceChangeInfo.devices[0].address}`);
      Logger.info(TAG, `Device change reason: ${deviceChangeInfo.changeReason}`);
      if (deviceChangeInfo.changeReason === audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {
        Logger.info(TAG, `Device change reason: ${deviceChangeInfo.changeReason}`);
        MediaControlCenter.getInstance().pause();
      }
    })
  }

  // Update play state
  private updateIsPlay(isPlay: boolean) {
    AppStorage.setOrCreate<boolean>('isPlay', isPlay);
    if (!this.avSessionController) {
      return;
    }
    const progress = AppStorage.get<number>('progress') ?? 0;
    this.avSessionController.setPlayState(isPlay, progress);
  }
}